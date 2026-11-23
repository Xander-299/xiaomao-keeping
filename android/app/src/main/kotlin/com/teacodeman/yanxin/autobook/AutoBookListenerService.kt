package com.teacodeman.yanxin.autobook

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

/**
 * 监听范围的包名白名单（**MVP 仅微信 + 支付宝**，SPEC §3.4 第 ① 层）。
 */
object AutoBookPackages {
    const val WECHAT = "com.tencent.mm"
    const val ALIPAY = "com.eg.android.AlipayGphone"
    val WATCHED: Set<String> = setOf(WECHAT, ALIPAY)

    fun isWatched(pkg: String?): Boolean = pkg != null && WATCHED.contains(pkg)
}

/**
 * 通知监听服务（F7.15）。
 *
 * 由**系统**绑定（`BIND_NOTIFICATION_LISTENER_SERVICE`），用户需在「设置 → 通知 → 通知使用权」
 * 里手动打开；**不需要前台服务**（省掉 Android 14 的 FGS 类型申报）。
 *
 * 只做三件事：包名过滤 → 取文案 → 落盘队列 + 更新「识别到 N 笔」提示。
 * **不做金额解析、不碰数据库**（见 AutoBookQueue 注释）。
 *
 * 另：每层判定都往 [AutoBookDiagnostics] 记一笔 + `Log` 一行 —— 这个功能一旦不生效，
 * 用户只看到「没记上」，必须能区分「服务没被绑定 / 没抓到 / 抓到被过滤 / 没 drain」。
 *
 * ## 采集通道的真实状况（2026-10-09 两轮真机取证，Redmi K50 / MIUI）
 *
 * ⚠️ **不要假设 `onNotificationPosted` 一定来** —— 实测它**一条都不投递**，
 * 而进程健康（`foreground` cgroup、未冻结）、绑定在（`dumpsys` 的
 * `Live notification listeners` 里有）、补抓通道通。
 * **重绑也救不了**（`disallow`→`allow` 能恢复 `onListenerConnected` 与补抓，
 * 但之后发探针通知 posted 仍为 0 条）。
 *
 * ⚠️ **也不要假设后台唤醒可靠** —— [AutoBookGuard] 的闹钟与 `TickReceiver`
 * 在本机**全被静默吞掉**（`am broadcast` 还回报 `result=0` 假成功），详见该文件。
 *
 * | 通道 | 本机实测 | 角色 |
 * |---|---|---|
 * | [onNotificationPosted] | ❌ 不投递 | 可选加速（非国产 ROM 上可能可用） |
 * | [AutoBookGuard] 周期补抓 | ❌ 被 ROM 吞 | 仅非国产 ROM 兜底 |
 * | [onNotificationRemoved] | ✅ 理论可用（extras 完整） | 撤回窗口内的兜底 |
 * | **Dart 侧回前台 catchUp** | ✅ **实测通**（扫 123~124 条） | **本机唯一可靠主防线** |
 *
 * 支付通知**只活 26 秒**（实测）→ 用户若没在这段时间内回到 App，就丢失。
 * 这不是代码能补的，是 ROM 限制；页面必须如实告诉用户「打开 App 即可补上」。
 *
 * ## 补抓（catch-up）为什么是必需的（2026-10-08 Redmi K50 事故）
 *
 * `onNotificationPosted` 是**推送**式回调：**通知在服务未连接期间发布，系统不会在连上后补发**。
 * 真机实测：支付宝付款通知 22:29:37 发布，本服务 22:31:28 才被系统连上 → 那笔支付
 * **永久丢失**，而 App 界面上完全看不出来（诊断只显示「最近捕获：从未」）。
 *
 * 所以连接成功时、以及 App 每次回到前台时（Dart 侧 `catchUp` 通道调用，必须在 drain 之前），
 * 都主动 `getActiveNotifications()` 把**通知栏里仍存在的**通知过一遍。
 * 去重交给 [AutoBookSeen]（持久指纹），所以重复补抓不会重复入队。
 */
class AutoBookListenerService : NotificationListenerService() {

    /** 单条通知的处理结论（同时用于日志与诊断）。 */
    enum class Decision { NOT_WATCHED, EMPTY, GROUP_SUMMARY, DEDUP, CAPTURED }

    companion object {
        private const val TAG = "AutoBookListener"

        /** 补抓只认 24 小时内的通知 —— 更早的多半是过期的营销推送，捞回来只会污染账本。 */
        private const val CATCH_UP_MAX_AGE_MS = 24L * 60 * 60 * 1000

        /** 系统当前是否绑着本服务（常驻服务的自愈循环用它判断要不要重绑）。 */
        fun isBound(): Boolean = instance != null

        /** 当前存活的实例（补抓需要实例方法 `activeNotifications`）。 */
        @Volatile
        private var instance: AutoBookListenerService? = null

        /**
         * 供 Dart 侧在**每次 drain 之前**调用：把通知栏里仍存在、但服务当时没接到的通知补入队。
         *
         * @return 补入队条数；服务未被系统绑定（拿不到实例）时返回 `-1`。
         *
         * ⚠️ **`-1` 必须原样传出去**（F7.20，2026-11-19）：它表示「补抓这条通道根本不通」，
         * 与「通知栏是空的（0）」是两件事。上游 `auto_book_bridge.dart` 以前把 `<=0` 折成 0，
         * 于是「设置里开着、系统没绑定」在界面上看起来和「今天没支付」一模一样。
         * 拿不到实例时顺手落一条诊断（`lastCatchUpUnbound`），让 `/autobook` 能点名这个断点。
         */
        fun catchUpNow(context: Context?): Int {
            val svc = instance ?: run {
                if (context != null) {
                    AutoBookDiagnostics.noteCatchUpUnbound(context)
                    // ⚠️ 真机 2026-11-19 补的一条：**从来没被绑定过**时不会有
                    // onListenerDisconnected，光靠断连重绑救不回来（当时设备上就是这个状态：
                    // `enabled_notification_listeners` 里有条目、`Live notification listeners`
                    // 里没有 → 补抓永远 -1）。所以发现拿不到实例时也主动请求一次重绑。
                    tryRebind(context, "catchUp-unbound")
                }
                Log.w(TAG, "catchUpNow：服务实例不存在（系统没绑定）→ 返回 -1")
                return -1
            }
            return svc.catchUp("channel")
        }

        /** 上一次主动 requestRebind 的时刻（防抖用）。 */
        @Volatile
        private var lastRebindAtMs = 0L

        /** 两次重绑之间至少隔这么久 —— 补抓每次回前台都会调，不能不设防地刷系统。 */
        private const val REBIND_MIN_INTERVAL_MS = 60_000L

        /**
         * 主动向系统请求重绑（F7.20）。
         *
         * 官方允许随时调用；已经绑着时是空操作。**带 60s 防抖**：
         * 拿不到实例的路径每次 drain 都会命中，不防抖就是在后台反复敲系统。
         * 结果（成功请求 / 抛异常 + 计数）落进诊断，页面才能说「试过了、没救回来」。
         */
        fun tryRebind(context: Context, reason: String) {
            val now = System.currentTimeMillis()
            if (now - lastRebindAtMs < REBIND_MIN_INTERVAL_MS) return
            lastRebindAtMs = now
            val ok = try {
                requestRebind(ComponentName(context, AutoBookListenerService::class.java))
                true
            } catch (t: Throwable) {
                Log.w(TAG, "requestRebind($reason) 失败：$t")
                false
            }
            Log.i(TAG, "requestRebind($reason) → ${if (ok) "已请求" else "请求失败"}")
            AutoBookDiagnostics.noteRebind(context, ok)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        AutoBookDiagnostics.load(this)
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    /** 系统把服务绑上了（此后 `onNotificationPosted` 才会来）。 */
    override fun onListenerConnected() {
        super.onListenerConnected()
        AutoBookDiagnostics.noteConnected(this, true)
        Log.i(TAG, "onListenerConnected → 立即补抓通知栏（服务未连接期间发布的通知不会补发）")
        // 补抓守护层从「服务可用」这一刻开始排期 —— posted 推送不可靠时，它是主防线。
        AutoBookGuard.schedule(this)
        catchUp("connect")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        AutoBookDiagnostics.noteConnected(this, false)
        Log.w(TAG, "onListenerDisconnected → 此后实时通知不再送达")
        // ⚠️ 实测（2026-10-09 Redmi K50）：重绑**恢复不了 posted 推送投递** ——
        // 所以这里不指望它救实时回调。但重绑**能恢复 `catchUp`**（`activeNotifications`
        // 需要系统真的绑着服务），而 posted 不投递时 catchUp 才是唯一还在工作的通道。
        // 不重绑 = 放弃唯一可行的自愈手段（F7.20：用户机器上就是「设置里开着但没绑定」）。
        rebindNow("disconnect")
    }

    /**
     * 断连自愈（F7.20）：向系统请求重新绑定本监听服务。
     *
     * 重绑救不回 posted 投递（2026-10-09 实测），但能恢复 `catchUp`。
     * 防抖与诊断都在 [tryRebind] 里 —— 同一个动作在「从未绑定」路径上也要用。
     */
    private fun rebindNow(reason: String) = tryRebind(this, reason)

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        // 通道可用性信号：只要回调**到过**就记一笔（无论最终是否入队）。
        // 实测部分国产 ROM 下本回调完全不投递（见 AutoBookGuard 的类注释），
        // 这条信号让 `/autobook` 页面能直接告诉用户「走的是哪条通道」。
        AutoBookDiagnostics.notePostedCallback(this)
        // 判定链整体兜异常：这里抛出去会被系统吞掉，外部只表现为「什么都没发生」——
        // 排查时最怕这种静默（2026-10-08 事故里，实时回调没落下任何一行日志，只能靠猜）。
        val decision = try {
            handle(sbn, fromCatchUp = false)
        } catch (t: Throwable) {
            Log.e(TAG, "posted pkg=${sbn.packageName} 判定链异常，已吞掉", t)
            return
        }
        // 非白名单是绝大多数（每个 App 的每条通知都算）→ 不打日志，否则日志会被淹掉
        if (decision != Decision.NOT_WATCHED) {
            Log.i(TAG, "posted pkg=${sbn.packageName} → $decision")
        }
    }

    /**
     * **撤回通道**（2026-10-09 真机取证后新增 · 第三层兜底）。
     *
     * ## 为什么需要
     *
     * 实测：微信支付通知**只存活 26 秒**，用户点进支付结果页后微信就 `cancel()` 掉它 →
     * 此后 [catchUp] 用的 `getActiveNotifications()` **捞不到**（实测补抓扫 115 条补入队 0）。
     * 而 `posted` 推送在该机型上根本不投递 → 这 26 秒是**唯一的采集窗口**。
     *
     * ## 官方保证（这是本方案成立的前提）
     *
     * AOSP `NotificationListenerService.onNotificationRemoved` 注释原文：
     * > the StatusBarNotification object you receive will be "light"; that is, the result
     * > from getNotification() may be missing some heavyweight fields such as contentView
     * > and largeIcon. **However, all other fields on StatusBarNotification, sufficient
     * > to match this call with a prior call to onNotificationPosted(StatusBarNotification),
     * > will be intact.**
     *
     * 即：**丢的只有 `contentView` 与 `largeIcon`**（自定义视图与大图），
     * 而我们解析金额/方向/商户靠的是 `extras` 里的 `EXTRA_TITLE` / `EXTRA_TEXT` /
     * `EXTRA_BIG_TEXT` / `EXTRA_SUB_TEXT` —— **全部保留**。
     *
     * ## 复用同一条判定链
     *
     * 直接调 [handle]，与 posted / catchUp 三条路径共用去重与过滤逻辑 ——
     * 同一笔不会因三条通道而记两遍（`AutoBookSeen` 持久指纹兜底）。
     */
    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        if (sbn == null) return
        val decision = try {
            handle(sbn, fromCatchUp = true)
        } catch (t: Throwable) {
            Log.e(TAG, "removed pkg=${sbn.packageName} 判定链异常，已吞掉", t)
            return
        }
        if (decision == Decision.NOT_WATCHED) return
        Log.i(TAG, "removed pkg=${sbn.packageName} → $decision")
        // 只有真的入队了才记「撤回救回来一笔」—— 必须落盘（撤回不可复现，错过就没了）
        if (decision == Decision.CAPTURED) {
            AutoBookDiagnostics.noteRemovedCapture(this)
        }
    }

    /**
     * 拉取通知栏里**现存的**全部通知过一遍，把其中应当记账的补入队。
     *
     * 必须在服务已连接时调用（`activeNotifications` 否则会抛异常）。
     */
    fun catchUp(reason: String): Int {
        val active: Array<StatusBarNotification>? = try {
            activeNotifications
        } catch (t: Throwable) {
            Log.w(TAG, "catchUp($reason) 取 activeNotifications 失败：$t")
            AutoBookDiagnostics.noteCatchUpUnbound(this)
            return -1
        }
        if (active == null) {
            Log.w(TAG, "catchUp($reason) 服务未连接，跳过")
            AutoBookDiagnostics.noteCatchUpUnbound(this)
            return -1
        }
        val now = System.currentTimeMillis()
        var added = 0
        for (sbn in active) {
            if (now - sbn.postTime > CATCH_UP_MAX_AGE_MS) continue
            // 单条炸掉不能拖垮整轮补抓（通知栏里常有 80+ 条，坏一条就全没了）
            val d = try {
                handle(sbn, fromCatchUp = true)
            } catch (t: Throwable) {
                Log.e(TAG, "catchUp($reason) pkg=${sbn.packageName} 判定链异常，跳过该条", t)
                continue
            }
            if (d == Decision.CAPTURED) added++
        }
        Log.i(TAG, "catchUp($reason) 活动通知=${active.size} 补入队=$added")
        AutoBookDiagnostics.noteCatchUp(this, active.size, added)
        // 「识别到 N 笔」只在这里弹一次（逐条弹会被同 id 反复覆盖）
        if (added > 0) {
            AutoBookNotifier.showPending(this, AutoBookQueue.pendingCount(this))
        }
        return added
    }

    /**
     * 单条通知的完整判定链：白名单 → 组摘要 → 空正文 → 去重 → 入队。
     *
     * 抽成函数是为了让**实时回调与补抓共用同一条判定链** —— 两处各写一遍必然漂移。
     */
    private fun handle(sbn: StatusBarNotification, fromCatchUp: Boolean): Decision {
        if (!AutoBookPackages.isWatched(sbn.packageName)) {
            AutoBookDiagnostics.noteSkippedNotWatched()
            return Decision.NOT_WATCHED
        }

        val extras = sbn.notification?.extras
        if (extras == null) {
            AutoBookDiagnostics.noteSkippedEmpty()
            return Decision.EMPTY
        }

        // 组摘要（系统把多条通知聚合成一条汇总时发的条目）直接丢 —— **只认系统标志**：
        // 它的文案与子通知不同 → 指纹不同 → 不过滤会把同一笔支付记两遍。
        //
        // ⚠️ 2026-10-08 修正：**不要拿正文里的 `[N条]` 前缀当判据**。真机取证
        // （`dumpsys notification` 的 `Group summaries:` 段里没有 com.tencent.mm、
        // flags=0x11 不含 FLAG_GROUP_SUMMARY、groupKey == 自己的 key、tickerText 无前缀）
        // 证明 `[3条]微信支付: 已支付¥0.03` 里的前缀只是 MIUI **显示层**加的，
        // 整条通知就是那笔支付本身。Dart 侧曾按 `^\[\d+条\]` 再兜一道 → 微信支付被**静默漏记**。
        // 现在判组摘要只有这一处（系统标志），到不了 Dart。
        val isGroupSummary =
            ((sbn.notification?.flags ?: 0) and Notification.FLAG_GROUP_SUMMARY) != 0 ||
                extras.getBoolean("android.isGroupSummary", false)
        if (isGroupSummary) {
            AutoBookDiagnostics.noteSkippedGroupSummary()
            return Decision.GROUP_SUMMARY
        }

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString().orEmpty()
        val subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString().orEmpty()
        // 四个正文位全空的（如纯进度通知）没有解析价值。
        // ⚠️ F7.20：`subText` 也算正文位 —— 只带 EXTRA_SUB_TEXT 的通知以前会被判成
        // EMPTY 丢掉并计入 `skippedEmpty`，排查时会被误读成「通知确实是空的」。
        if (title.isEmpty() && text.isEmpty() && bigText.isEmpty() && subText.isEmpty()) {
            AutoBookDiagnostics.noteSkippedEmpty()
            return Decision.EMPTY
        }

        val added = AutoBookQueue.enqueueNotification(
            this,
            sbn.packageName,
            title,
            text,
            bigText,
            subText,
            sbn.postTime,
            fromCatchUp,
        )
        if (!added) {
            AutoBookDiagnostics.noteSkippedDedup()
            return Decision.DEDUP
        }

        AutoBookDiagnostics.noteCapture(this, sbn.packageName)
        if (!fromCatchUp) {
            AutoBookNotifier.showPending(this, AutoBookQueue.pendingCount(this))
        }
        return Decision.CAPTURED
    }
}
