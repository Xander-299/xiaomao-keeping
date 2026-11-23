package com.teacodeman.yanxin.autobook

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import com.teacodeman.yanxin.MainActivity
import com.teacodeman.yanxin.R

/**
 * 「后台常驻」前台服务（F7.22）：让通知监听服务尽量别被系统回收/解绑。
 *
 * 为什么需要：支付通知来的时候 App 可能不在后台 —— 监听服务与 UI 同进程，
 * MIUI 一回收进程，通知就不会进落盘队列；重开 App 也补不回来（公开 SDK 没有「历史通知」接口）。
 *
 * 三层配合：
 * 1. **前台常驻**（本文件）：低优先级常驻通知，抬高进程优先级，`START_STICKY` 被杀后自恢复；
 * 2. **周期自愈**：每 [CHECK_INTERVAL_MS] 检查监听服务是否还被系统绑着，没绑就 `requestRebind`，
 *    顺带把补抓守护续期（它与 `AutoBookGuard` 是两条独立防线）；
 * 3. **设置引导**：省电优化 / 自启动在 `/autobook` 页检测并给入口（系统策略我们改不了，只能引导）。
 *
 * ⚠️ 产品代价：状态栏会常驻一条通知 —— 所以**默认关闭**，由用户在 `/autobook` 页显式打开。
 * ⚠️ 诚实边界：MIUI 仍可能杀掉常驻服务；本服务只提高「不再漏记」的概率，不承诺 100%。
 */
object AutoBookKeepAlive {

    private const val TAG = "AutoBookKeepAlive"

    /** 独立渠道：常驻提示与「已自动记账」回执是两件事，别混在一个渠道里。 */
    private const val CHANNEL_ID = "autobook_keepalive"
    private const val CHANNEL_NAME = "自动记账（后台待命）"

    /** 与服务里的 NOTIFICATION_ID 保持一致（固定 id：重复 start 不会叠通知）。 */
    const val NOTIFICATION_ID = 0x7A16

    fun start(context: Context) {
        try {
            val intent = Intent(context, AutoBookKeepAliveService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (t: Throwable) {
            // 后台限制 / 用户关掉通知都可能抛 —— 常驻是加强项，不能拖垮调用方
            Log.w(TAG, "start 失败（可能有后台限制）：$t")
        }
    }

    fun stop(context: Context) {
        try {
            context.stopService(Intent(context, AutoBookKeepAliveService::class.java))
        } catch (t: Throwable) {
            Log.w(TAG, "stop 失败：$t")
        }
    }

    /** 供 Dart 侧显示「常驻服务：运行中 / 未运行」。 */
    @Volatile
    var running: Boolean = false
        private set

    internal fun setRunning(value: Boolean) {
        running = value
    }

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = "让自动记账在后台持续监听支付通知"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    internal fun buildNotification(context: Context): Notification {
        ensureChannel(context)
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_autobook)
            .setContentTitle("自动记账待命中")
            .setContentText("支付通知会实时记录；监听被系统断开时会自动重试")
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }
}

/**
 * 常驻服务本体：拉起前台通知 + 每 10 分钟自愈一次。
 *
 * 用 `Handler.postDelayed` 而不是 `AlarmManager`：进程活着时它才需要跑；
 * 进程被杀由 `START_STICKY` 让系统重建，重建后循环自然恢复。
 */
class AutoBookKeepAliveService : Service() {

    private val handler = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            healOnce()
            handler.postDelayed(this, CHECK_INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        startForeground(AutoBookKeepAlive.NOTIFICATION_ID, AutoBookKeepAlive.buildNotification(this))
        AutoBookKeepAlive.setRunning(true)
        handler.postDelayed(tick, CHECK_INTERVAL_MS)
        healOnce()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 幂等：重复 start 只是再确认一次前台通知，不新建服务
        startForeground(AutoBookKeepAlive.NOTIFICATION_ID, AutoBookKeepAlive.buildNotification(this))
        return START_STICKY
    }

    override fun onDestroy() {
        AutoBookKeepAlive.setRunning(false)
        handler.removeCallbacks(tick)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * 一轮自愈：监听没被绑 → 请求重绑；无论如何都把补抓守护续期一次。
     *
     * 为什么两条都做：`requestRebind` 恢复的是「实时回调 + 补抓」的前提，
     * 而 `AutoBookGuard` 是 posted 不投递时的主防线，两者互不替代。
     */
    private fun healOnce() {
        val bound = AutoBookListenerService.isBound()
        if (!bound) {
            Log.i(TAG, "自愈：监听服务未绑定 → requestRebind")
            AutoBookListenerService.tryRebind(this, "keepalive")
        }
        AutoBookGuard.schedule(this)
    }

    companion object {
        private const val TAG = "AutoBookKeepAlive"

        /** 10 分钟一次：足够快恢复绑定，又不会让系统觉得我们在刷它。 */
        private const val CHECK_INTERVAL_MS = 10L * 60 * 1000
    }
}
