package com.teacodeman.yanxin.autobook

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 平台通道 `yanxin/autobook`（F7.15）。
 *
 * 通道是**单向依赖**：Dart 侧 `auto_book_bridge.dart` 调这些方法；Kotlin 侧不回调用 Dart
 * （回执通知由 Dart 主动调 `showReceipt` 触发）。
 *
 * ⚠️ 非 Android 平台（含 widget 测试）调用这些方法会抛 `MissingPluginException`
 * → Dart 侧全部捕获后按「不支持」处理，**不得阻断冷启动**。
 */
class AutoBookChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val NAME = "yanxin/autobook"
        private const val REQ_POST_NOTIFICATIONS = 0x7A16

        /** 「通知使用权」是否已授予：查系统 Secure 设置里的已启用监听器列表。 */
        fun isListenerEnabled(context: Context): Boolean {
            val flat = try {
                Settings.Secure.getString(
                    context.contentResolver,
                    "enabled_notification_listeners",
                )
            } catch (_: Exception) {
                null
            } ?: return false
            val component = ComponentName(context, AutoBookListenerService::class.java)
            return flat.contains(component.flattenToString()) ||
                flat.contains(component.flattenToShortString())
        }

        /** 通知是否允许（Android 13+ 还要求 POST_NOTIFICATIONS 运行时权限）。 */
        fun areNotificationsAllowed(context: Context): Boolean {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val granted = context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                    PackageManager.PERMISSION_GRANTED
                if (!granted) return false
            }
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as? android.app.NotificationManager ?: return false
            return try {
                manager.areNotificationsEnabled()
            } catch (_: Exception) {
                false
            }
        }
    }

    private var channel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, NAME)
        ch.setMethodCallHandler(this)
        channel = ch
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "permissionStatus" -> result.success(isListenerEnabled(activity))

            "notificationPermissionStatus" -> result.success(areNotificationsAllowed(activity))

            "requestNotificationPermission" -> {
                requestNotificationPermission()
                result.success(null)
            }

            "openNotificationSettings" -> result.success(open(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))

            "openAppNotificationSettings" -> result.success(openAppNotificationSettings())

            "drainQueue" -> result.success(AutoBookQueue.drain(activity))

            // 补抓：通知在服务未连接期间发布时系统**不会补发回调**（真机实测：支付宝付款
            // 通知早于服务连接 1 分 51 秒 → 永久丢失）。App 每次回前台、drain 之前调一次，
            // 把通知栏里仍存在的通知捞回队列。返回补入队条数；服务未绑定返回 -1。
            "catchUp" -> result.success(AutoBookListenerService.catchUpNow(activity))

            // 补抓守护排期：闹钟是「一次性 + 每次醒来续期」的，进程被杀就没人续期 →
            // App 每次启动 / 回前台都补一次排期，保证「进程活着期间守护在转」
            "ensureGuard" -> {
                AutoBookGuard.schedule(activity)
                result.success(null)
            }

            // 兜底回写：Dart 侧临时性失败（账本未就绪 / 写库异常）时把原始行放回队列，
            // 否则「取走即清空」会让这批通知永久消失
            "restoreQueue" -> {
                val lines = (call.argument<List<*>>("lines") ?: emptyList<Any?>())
                    .map { it?.toString().orEmpty() }
                    .filter { it.isNotEmpty() }
                AutoBookQueue.restore(activity, lines)
                result.success(null)
            }

            // 活性诊断：让「没记上」可归因（服务没绑定 / 没抓到 / 抓到被过滤 / 没 drain）
            "diagnostics" -> {
                AutoBookDiagnostics.load(activity)
                result.success(AutoBookDiagnostics.snapshot(activity))
            }

            "pendingCount" -> result.success(AutoBookQueue.pendingCount(activity))

            "takeCommand" -> result.success(AutoBookQueue.takeCommand(activity))

            "showReceipt" -> {
                val count = call.argument<Int>("count") ?: 0
                val amountText = call.argument<String>("amountText").orEmpty()
                val batchId = call.argument<String>("batchId").orEmpty()
                val lines = (call.argument<List<*>>("lines") ?: emptyList<Any?>())
                    .map { it?.toString().orEmpty() }
                    .filter { it.isNotEmpty() }
                AutoBookNotifier.showReceipt(activity, count, amountText, batchId, lines)
                result.success(null)
            }

            "cancelReceipt" -> {
                AutoBookNotifier.cancel(activity)
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    @Suppress("DEPRECATION")
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) return
        try {
            activity.requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQ_POST_NOTIFICATIONS,
            )
        } catch (_: Exception) {
        }
    }

    private fun open(action: String): Boolean {
        val intent = Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            // 部分 ROM 没有这个设置页 → 退回应用详情页
            openAppNotificationSettings()
        }
    }

    private fun openAppNotificationSettings(): Boolean {
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}
