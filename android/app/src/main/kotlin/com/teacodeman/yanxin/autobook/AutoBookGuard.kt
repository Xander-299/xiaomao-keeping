package com.teacodeman.yanxin.autobook

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * **补抓守护层**（F7.16 · 2026-10-09 真机取证后新增）。
 *
 * ## ⚠️ 实测结论：本机（MIUI/HyperOS）上**完全无效**，保留仅为非国产 ROM 的兜底
 *
 * Redmi K50 实测（装包后等 100 秒，`tickCatchUpTotal` 恒为 0）：
 *
 * | 手段 | 结果 |
 * |---|---|
 * | `AlarmManager.setAndAllowWhileIdle` | `dumpsys alarm` 里**搜不到**本 App 的 PendingIntent → 排期被吞 |
 * | `am broadcast`（自定义 / `SCREEN_ON` / 显式 component / `-f 1`）| `am` 回报 `Broadcast completed: result=0`，但 `onReceive` **一行日志都没有** → 投递被吞 |
 * | manifest 静态注册 | `aapt2 dump xmltree` 确认 receiver 与 3 个 action **完整存在**，重签前后一致 |
 * | 进程状态 | 活着、`foreground` cgroup、`oom_score_adj=250` → 不是被回收 |
 *
 * **最坑的一点**：ROM 拦截时 `am broadcast` 仍回报 **`result=0`（假成功）** ——
 * 只看命令行输出会误判成「receiver 正常，是逻辑没触发」。
 *
 * 所以本文件**不是**本机的主防线，仅在非国产 ROM 上可能生效；
 * 本机的真实主防线是 **Dart 侧「回前台即 catchUp + drain」**（实测通道通：扫 123~124 条）。
 * ⚠️ 别再尝试：悬浮窗 / 无障碍 / 前台常驻服务 / AlarmManager / 静态 receiver ——
 * 本机全部被拦死。
 *
 * ## 为什么仍保留
 *
 * 非国产 ROM（Pixel / 原生 AOSP）上这些手段是标准做法，且**零额外权限**；
 * 删掉等于放弃那片市场。诊断字段 [AutoBookDiagnostics.tickCatchUpTotal]
 * 让页面能如实告诉用户「你这台机器后台唤醒被拦了，请打开 App 手动补一下」，
 * 而不是让用户面对「没记上」却不知道该做什么。
 */
object AutoBookGuard {

    private const val TAG = "AutoBookGuard"

    /** 周期：1 分钟。这是「通知只活 26 秒」与「省电/被 ROM 限制」之间的折中。 */
    private const val INTERVAL_MS = 60_000L

    /** 首次触发延迟（不给 0，避免与刚做完的 `onListenerConnected` 补抓重复打转）。 */
    private const val FIRST_DELAY_MS = 30_000L

    const val ACTION_TICK = "com.teacodeman.yanxin.autobook.TICK"

    /**
     * 开闹钟。用 `RTC_WAKEUP` + `setAndAllowWhileIdle` ——
     * doze 待机时也能被放行，否则息屏一晚上就完全不转了。
     */
    fun schedule(context: Context) {
        val am = context.getSystemService(AlarmManager::class.java) ?: run {
            Log.w(TAG, "取不到 AlarmManager，守护层未启动")
            return
        }
        val pi = tickIntent(context)
        try {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, System.currentTimeMillis() + FIRST_DELAY_MS, pi)
            Log.i(TAG, "补抓守护已排期：每 ${INTERVAL_MS / 1000}s 一轮")
        } catch (t: Throwable) {
            // 部分 ROM 对自启/后台限流会抛异常 —— 不能因此崩掉启动流程
            Log.w(TAG, "排期失败（可能有后台限制）：$t")
        }
    }

    private fun tickIntent(context: Context): PendingIntent {
        val intent = Intent(context, TickReceiver::class.java).setAction(ACTION_TICK)
        return PendingIntent.getBroadcast(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /**
     * 跑一轮补抓并**续期**下一次闹钟。
     *
     * 「续期」用 `setAndAllowWhileIdle` 而非 `setRepeating`：闹钟是一次性的，
     * 每次醒来重排 —— 这样系统能按当下负载决定下次何时唤醒（省电），
     * 也避免 `setRepeating` 在 doze 里被静默丢弃后**永久停摆**。
     *
     * ⚠️ 本机（MIUI）实测**这条路完全不通**（排期被吞，见类注释），
     * 但 [noteTickCatchUp] 仍必须落盘：它是「后台唤醒有没有生效」的**唯一**判据 ——
     * 页面上「这台机器后台被拦了，请打开 App 手动补一下」这句话全靠它。
     */
    fun runTick(context: Context, reason: String) {
        AutoBookDiagnostics.noteTickCatchUp(context)
        val added = AutoBookListenerService.catchUpNow(context)
        Log.i(TAG, "tick($reason) 补抓返回=$added（-1 = 服务未绑定）")
        schedule(context)
    }
}

/**
 * 闹钟接收器。三类唤醒源统一处理：**周期闹钟**（主路径）、**开机**、**亮屏**。
 *
 * 为什么加亮屏：用户亮屏往往就是为了看刚付的款 —— 那正是通知还在栏里的窗口。
 * `ACTION_SCREEN_ON` 是 manifest 静态注册**仍能收到**的少数广播之一
 * （不在 Android 8 的隐式广播禁令名单内）。
 *
 * ⚠️ 固有边界：进程被杀时该轮丢失（`AlarmManager` 回调无法 `goAsync` 保活）。
 * 靠 [AutoBookGuard.schedule] 在「服务连接」与「App 每次 drain 前」重新排期来兜 ——
 * 即「进程活着期间守护一定在转」是靠这两处维持的，不靠系统保活进程。
 */
class TickReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        // 每轮都必须整体兜异常：BroadcastReceiver 里抛出去会被系统吞掉并可能
        // 连带中断同进程的其他 receiver，表现就是「闹钟偶尔不响且毫无线索」。
        try {
            when (intent?.action) {
                AutoBookGuard.ACTION_TICK -> AutoBookGuard.runTick(context, "alarm")
                Intent.ACTION_BOOT_COMPLETED -> AutoBookGuard.runTick(context, "boot")
                Intent.ACTION_SCREEN_ON -> AutoBookGuard.runTick(context, "screenOn")
                else -> Log.w(TAG, "收到未登记的 action：${intent?.action}")
            }
        } catch (t: Throwable) {
            Log.e(TAG, "tick 异常（已吞掉，否则会连带影响同进程其他 receiver）", t)
        }
    }

    private companion object {
        const val TAG = "AutoBookGuard"
    }
}
