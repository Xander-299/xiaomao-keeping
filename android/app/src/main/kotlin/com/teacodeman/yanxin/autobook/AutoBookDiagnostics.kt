package com.teacodeman.yanxin.autobook

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * 自动记账的**活性诊断**（F7.15 走查补丁）。
 *
 * 为什么需要它：整条链路有四个断点（系统→服务 / 服务→队列 / Dart 触发 / Dart 入账），
 * 但**每一层都是静默的** —— 用户只看到「没记上」，无法区分是没抓到、没触发、还是解析失败。
 * 这里把每层的最后一跳记下来，让 `/autobook` 页能回答「到底断在哪」。
 *
 * 设计约束：
 * - **跨进程持久化**：App 冷启动时 Service 可能已被系统重启，纯内存计数会丢 →
 *   关键事件（连接 / 捕获 / drain）**落盘覆盖写**一个小 JSON；
 * - **累计值用「盘上基线 + 本进程增量」合成**（见 [recomputeTotals]）——
 *   不能靠「内存为 0 才回填」的守卫：`noteDrained` 对**空 drain** 也会刷新
 *   `lastDrainAtMs`（但刻意不落盘），会把与它同守卫的 `drainedTotal` 一起"毒化"，
 *   导致下一次任何 persist 都把真实累计值写回 0
 *   （2026-10-08 Redmi K50 实测：`drainedTotal` 8 → 0）；
 * - 读盘失败一律退回零值 —— 诊断本身绝不能影响记账。
 */
object AutoBookDiagnostics {

    private const val FILE = "autobook_diag.json"

    /** 系统是否绑定着本监听服务（`onListenerConnected` / `onListenerDisconnected`）。 */
    @Volatile var listenerConnected: Boolean = false
        private set
    @Volatile var lastConnectedAtMs: Long = 0L
        private set

    /** 最后一次「命中白名单并成功入队」的时间与来源。 */
    @Volatile var lastCaptureAtMs: Long = 0L
        private set
    @Volatile var lastCapturePkg: String = ""
        private set
    @Volatile var capturedTotal: Int = 0
        private set

    /** 被各层过滤掉的条数（用于判断「抓到了但没记账」）。 */
    @Volatile var skippedNotWatched: Int = 0
        private set
    @Volatile var skippedEmpty: Int = 0
        private set
    @Volatile var skippedDedup: Int = 0
        private set

    /** 组摘要被丢弃的条数（正常应当 > 0：聚合通知必然伴随摘要条目）。 */
    @Volatile var skippedGroupSummary: Int = 0
        private set

    /**
     * 补抓（catch-up）次数与结果。
     *
     * `lastCatchUpActive` = 补抓时通知栏里的通知总数（0 说明拉到空，多半是服务没连上），
     * `catchUpAddedTotal` = 累计补入队条数。两者用来判断「通知栏里明明有支付消息却没记上」
     * 到底是补抓没跑、还是跑了但通知已不在栏里。
     */
    @Volatile var lastCatchUpAtMs: Long = 0L
        private set
    @Volatile var lastCatchUpActive: Int = 0
        private set
    @Volatile var lastCatchUpAdded: Int = 0
        private set
    @Volatile var catchUpTotal: Int = 0
        private set
    @Volatile var catchUpAddedTotal: Int = 0
        private set

    /** 最后一次被 Dart drain 取走的时间与条数。 */
    @Volatile var lastDrainAtMs: Long = 0L
        private set
    @Volatile var lastDrainCount: Int = 0
        private set
    @Volatile var drainedTotal: Int = 0
        private set

    /**
     * **通道可用性**（2026-10-09 真机取证新增）。
     *
     * 国产 ROM（MIUI/HyperOS 实测）上，`onNotificationPosted` 这个**推送式回调**
     * 可能**完全不投递**，而服务进程健康、绑定关系仍在（`dumpsys` 的
     * `Live notification listeners` 里也有）。实测证据：重绑（disallow→allow）
     * 能恢复 `onListenerConnected` 与补抓，但探针通知的 posted 回调仍然 0 条。
     *
     * 所以「实时推送」必须被当作**可选加速通道**，而不是唯一防线 ——
     * 主防线是 [AutoBookListenerService.catchUp] 主动拉取。
     *
     * - [postedCallbackSeen]：本进程内**是否见到过任何** posted 回调（哪怕被去重/过滤掉的）。
     *   为 false 且已过观察窗口 → `/autobook` 页面提示「实时推送不可用，已靠主动补抓」。
     * - [lastPostedAtMs]：最后一次收到 posted 回调的时刻，用于算「推送静默了多久」。
     */
    @Volatile var postedCallbackSeen: Boolean = false
        private set
    @Volatile var lastPostedAtMs: Long = 0L
        private set

    /**
     * 撤回通道（`onNotificationRemoved`）的捕获计数。
     *
     * 通知被撤回（微信/支付宝在用户点进支付结果页时 cancel）那一刻，
     * extras 仍然完整（AOSP 保证只丢 contentView/largeIcon）→ 窗口消失前的最后机会。
     */
    @Volatile var removedCaptureTotal: Int = 0
        private set
    @Volatile var lastRemovedAtMs: Long = 0L
        private set

    /** 守护补抓（AlarmManager 周期任务）跑了几轮 —— 用于确认它到底有没有在转。 */
    @Volatile var tickCatchUpTotal: Int = 0
        private set
    @Volatile var lastTickCatchUpAtMs: Long = 0L
        private set

    /**
     * **补抓通道**（F7.20 新增，2026-11-19）。
     *
     * 为什么单独记：`catchUp` 是 posted 推送不投递时**唯一**还能救回通知的通道，
     * 而它要求服务确实被系统绑定。`catchUpNow()` 拿不到实例时返回 `-1`，
     * 这个状态以前被 Dart 侧折成 `0`（= 通知栏为空），于是「服务没绑定」看起来和
     * 「今天没支付」一模一样 —— 用户与开发者都被误导。
     *
     * 现在：Dart 保留 `-1` 语义，同时这里落一条 `lastCatchUpUnbound`，
     * `/autobook` 的诊断块据此单列「补抓通道：服务未绑定」。
     */
    @Volatile var lastCatchUpUnbound: Boolean = false
        private set
    @Volatile var lastCatchUpUnboundAtMs: Long = 0L
        private set
    @Volatile var catchUpUnboundTotal: Int = 0
        private set

    /**
     * 断连后主动 `requestRebind` 的次数与结果（F7.20 新增）。
     *
     * 重绑救不回 posted 投递（2026-10-09 实测），但**能恢复 `catchUp`** ——
     * 而 catchUp 才是现在的主防线。所以断开时重绑是必须尝试的自愈动作，
     * 失败了也要留下证据，而不是只打一行日志。
     */
    @Volatile var rebindAttempts: Int = 0
        private set
    @Volatile var lastRebindAtMs: Long = 0L
        private set
    @Volatile var lastRebindOk: Boolean = false
        private set

    /** 本进程启动时盘上的值（每进程只读一次），只作为累计值的**基线**。 */
    @Volatile private var base: JSONObject = JSONObject()

    // 本进程产生的增量 —— 写盘时与 [base] 相加，绝不能直接把内存值覆盖上去。
    private var addCaptured = 0
    private var addDrained = 0
    private var addSkippedNotWatched = 0
    private var addSkippedEmpty = 0
    private var addSkippedDedup = 0
    private var addSkippedGroupSummary = 0
    private var addCatchUp = 0
    private var addCatchUpAdded = 0
    private var addRemovedCapture = 0
    private var addTickCatchUp = 0
    private var addCatchUpUnbound = 0
    private var addRebind = 0

    /** 本进程是否已读过盘。 */
    private var loaded = false

    private fun file(context: Context): File = File(context.filesDir, FILE)

    /**
     * 冷启动读回上次落盘的值。**每进程只读一次**（重复调用无副作用）。
     *
     * 两类字段处理方式不同：
     * - **累计值**（`*Total`）由 [recomputeTotals] 合成，不在这里直接赋值；
     * - **「最后一次事件」时间戳**：仅在内存仍为初始值时回填，以免覆盖本进程的新值。
     *
     * `listenerConnected` **故意不回填** —— 它的语义是「本进程内系统是否绑定了服务」。
     * 若把上次的 `true` 恢复出来，force-stop 后重开（系统并未重新绑定）就会谎报「已绑定」，
     * 把用户和开发者一起带偏；而页面正是靠 `!listenerConnected && lastConnectedAtMs > 0`
     * 提示「设置里开着但系统没绑定（国产 ROM 后台限制）」的。
     */
    @Synchronized
    fun load(context: Context) {
        if (loaded) return
        loaded = true
        val f = file(context)
        base = if (f.exists()) {
            try {
                JSONObject(f.readText())
            } catch (_: Exception) {
                JSONObject()
            }
        } else {
            JSONObject()
        }
        if (lastConnectedAtMs == 0L) {
            lastConnectedAtMs = base.optLong("lastConnectedAtMs", 0L)
        }
        if (lastCaptureAtMs == 0L) {
            lastCaptureAtMs = base.optLong("lastCaptureAtMs", 0L)
            lastCapturePkg = base.optString("lastCapturePkg", "")
        }
        if (lastDrainAtMs == 0L) {
            lastDrainAtMs = base.optLong("lastDrainAtMs", 0L)
            lastDrainCount = base.optInt("lastDrainCount", 0)
        }
        if (lastCatchUpAtMs == 0L) {
            lastCatchUpAtMs = base.optLong("lastCatchUpAtMs", 0L)
            lastCatchUpActive = base.optInt("lastCatchUpActive", 0)
            lastCatchUpAdded = base.optInt("lastCatchUpAdded", 0)
        }
        if (lastPostedAtMs == 0L) {
            lastPostedAtMs = base.optLong("lastPostedAtMs", 0L)
        }
        if (lastRemovedAtMs == 0L) {
            lastRemovedAtMs = base.optLong("lastRemovedAtMs", 0L)
        }
        if (lastTickCatchUpAtMs == 0L) {
            lastTickCatchUpAtMs = base.optLong("lastTickCatchUpAtMs", 0L)
        }
        if (lastCatchUpUnboundAtMs == 0L) {
            lastCatchUpUnboundAtMs = base.optLong("lastCatchUpUnboundAtMs", 0L)
            lastCatchUpUnbound = base.optBoolean("lastCatchUpUnbound", false)
        }
        if (lastRebindAtMs == 0L) {
            lastRebindAtMs = base.optLong("lastRebindAtMs", 0L)
            lastRebindOk = base.optBoolean("lastRebindOk", false)
        }
        recomputeTotals()
    }

    /**
     * 累计值 = 盘上基线 + 本进程增量。幂等，可重复调用。
     *
     * 这样即便本进程一次事件都没有（内存全 0），也不会把盘上的历史累计抹掉。
     */
    private fun recomputeTotals() {
        val b = base
        capturedTotal = b.optInt("capturedTotal", 0) + addCaptured
        drainedTotal = b.optInt("drainedTotal", 0) + addDrained
        skippedNotWatched = b.optInt("skippedNotWatched", 0) + addSkippedNotWatched
        skippedEmpty = b.optInt("skippedEmpty", 0) + addSkippedEmpty
        skippedDedup = b.optInt("skippedDedup", 0) + addSkippedDedup
        skippedGroupSummary = b.optInt("skippedGroupSummary", 0) + addSkippedGroupSummary
        catchUpTotal = b.optInt("catchUpTotal", 0) + addCatchUp
        catchUpAddedTotal = b.optInt("catchUpAddedTotal", 0) + addCatchUpAdded
        removedCaptureTotal = b.optInt("removedCaptureTotal", 0) + addRemovedCapture
        tickCatchUpTotal = b.optInt("tickCatchUpTotal", 0) + addTickCatchUp
        catchUpUnboundTotal = b.optInt("catchUpUnboundTotal", 0) + addCatchUpUnbound
        rebindAttempts = b.optInt("rebindAttempts", 0) + addRebind
    }

    /**
     * 收到了一条 posted 回调（**无论最终是否入队**）—— 只用来回答
     * 「实时推送这个通道到底通不通」。**必须落盘**，否则跨进程重启后看不出通道状态。
     */
    fun notePostedCallback(context: Context) {
        load(context)
        postedCallbackSeen = true
        lastPostedAtMs = System.currentTimeMillis()
        persist(context)
    }

    /**
     * 撤回通道捕获到一条（`onNotificationRemoved` 里成功入队）。
     *
     * **必然落盘**：这条计数是「通知撤回那一刻我们救回来了多少笔」的唯一证据，
     * 而通知撤回是**不可复现**的（错过就永远错过）→ 必须跨进程留存。
     */
    fun noteRemovedCapture(context: Context) {
        load(context)
        lastRemovedAtMs = System.currentTimeMillis()
        addRemovedCapture++
        recomputeTotals()
        persist(context)
    }

    /**
     * 守护补抓（AlarmManager 周期任务）跑完一轮。
     *
     * **必然落盘** —— 「守护层到底有没有在转」只能靠这条。
     * 如果用户的 `/autobook` 页面显示 `tickCatchUpTotal` 长期为 0，
     * 说明周期任务被国产 ROM 的后台限制干掉了（与监听服务被解绑同一类问题）。
     */
    fun noteTickCatchUp(context: Context) {
        load(context)
        lastTickCatchUpAtMs = System.currentTimeMillis()
        addTickCatchUp++
        recomputeTotals()
        persist(context)
    }

    fun noteConnected(context: Context, connected: Boolean) {
        load(context)
        listenerConnected = connected
        if (connected) lastConnectedAtMs = System.currentTimeMillis()
        persist(context)
    }

    fun noteCapture(context: Context, pkg: String) {
        load(context)
        lastCaptureAtMs = System.currentTimeMillis()
        lastCapturePkg = pkg
        addCaptured++
        recomputeTotals()
        persist(context)
    }

    fun noteSkippedNotWatched() {
        addSkippedNotWatched++
        recomputeTotals()
    }

    fun noteSkippedEmpty() {
        addSkippedEmpty++
        recomputeTotals()
    }

    fun noteSkippedDedup() {
        addSkippedDedup++
        recomputeTotals()
    }

    fun noteSkippedGroupSummary() {
        addSkippedGroupSummary++
        recomputeTotals()
    }

    /**
     * 补抓跑了一轮。**必然落盘** —— 「通知栏里有支付消息却没记上」这类问题的判别
     * 全靠这次记录（服务没连上时 `active` 会是 0）。
     */
    fun noteCatchUp(context: Context, active: Int, added: Int) {
        load(context)
        // 真的跑起来一轮 = 服务确实绑上了 → 清掉「补抓通道不通」的旧结论
        lastCatchUpUnbound = false
        lastCatchUpAtMs = System.currentTimeMillis()
        lastCatchUpActive = active
        lastCatchUpAdded = added
        addCatchUp++
        addCatchUpAdded += added
        recomputeTotals()
        persist(context)
    }

    /**
     * 补抓拿不到服务实例（`catchUpNow()` 返回 `-1`）。
     *
     * **必然落盘**：这是「设置里开着、系统其实没绑定」唯一的直接证据，
     * 而 App 可能马上被 ROM 杀掉，内存里的标记留不下来。
     */
    fun noteCatchUpUnbound(context: Context) {
        load(context)
        val wasUnbound = lastCatchUpUnbound
        lastCatchUpUnbound = true
        lastCatchUpUnboundAtMs = System.currentTimeMillis()
        addCatchUpUnbound++
        recomputeTotals()
        // 只在状态**翻转**时落盘：补抓在 App 每次回前台都会调，服务没绑定时会一直报 −1，
        // 每次都写盘等于后台常驻写 Flash（同一类问题见 F7.20 §3.6）。
        if (!wasUnbound) persist(context)
    }

    /** 断连后尝试重绑的结果（F7.20）。 */
    fun noteRebind(context: Context, ok: Boolean) {
        load(context)
        lastRebindAtMs = System.currentTimeMillis()
        lastRebindOk = ok
        addRebind++
        recomputeTotals()
        persist(context)
    }

    fun noteDrained(context: Context, count: Int) {
        load(context)
        lastDrainAtMs = System.currentTimeMillis()
        lastDrainCount = count
        addDrained += count
        recomputeTotals()
        // 空 drain 不落盘：`resumed` 触发很频繁，没必要每次都写文件
        if (count > 0) persist(context)
    }

    /** 供 Dart 侧读取的快照（JSON 字符串）。 */
    @Synchronized
    fun snapshot(context: Context): String {
        load(context)
        recomputeTotals()
        return JSONObject()
            .put("listenerConnected", listenerConnected)
            .put("lastConnectedAtMs", lastConnectedAtMs)
            .put("lastCaptureAtMs", lastCaptureAtMs)
            .put("lastCapturePkg", lastCapturePkg)
            .put("capturedTotal", capturedTotal)
            .put("skippedNotWatched", skippedNotWatched)
            .put("skippedEmpty", skippedEmpty)
            .put("skippedDedup", skippedDedup)
            .put("skippedGroupSummary", skippedGroupSummary)
            .put("lastDrainAtMs", lastDrainAtMs)
            .put("lastDrainCount", lastDrainCount)
            .put("drainedTotal", drainedTotal)
            .put("lastCatchUpAtMs", lastCatchUpAtMs)
            .put("lastCatchUpActive", lastCatchUpActive)
            .put("lastCatchUpAdded", lastCatchUpAdded)
            .put("catchUpTotal", catchUpTotal)
            .put("catchUpAddedTotal", catchUpAddedTotal)
            .put("postedCallbackSeen", postedCallbackSeen)
            .put("lastPostedAtMs", lastPostedAtMs)
            .put("removedCaptureTotal", removedCaptureTotal)
            .put("lastRemovedAtMs", lastRemovedAtMs)
            .put("tickCatchUpTotal", tickCatchUpTotal)
            .put("lastTickCatchUpAtMs", lastTickCatchUpAtMs)
            .put("lastCatchUpUnbound", lastCatchUpUnbound)
            .put("lastCatchUpUnboundAtMs", lastCatchUpUnboundAtMs)
            .put("catchUpUnboundTotal", catchUpUnboundTotal)
            .put("rebindAttempts", rebindAttempts)
            .put("lastRebindAtMs", lastRebindAtMs)
            .put("lastRebindOk", lastRebindOk)
            .put("nowMs", System.currentTimeMillis())
            .toString()
    }

    @Synchronized
    private fun persist(context: Context) {
        try {
            // 写盘前先把基线读回来（每进程只读一次），累计值由 recomputeTotals 合成。
            load(context)
            file(context).writeText(snapshot(context))
        } catch (_: Exception) {
            // 落盘失败只影响「跨重启可见性」，不影响本次会话
        }
    }
}
