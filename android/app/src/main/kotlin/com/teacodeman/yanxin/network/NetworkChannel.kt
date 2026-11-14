package com.teacodeman.yanxin.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 平台通道 `yanxin/network`（P6.4b 自动同步）。
 *
 * 职责只有一个：回答「当前是不是 WiFi」。自动同步只在 WiFi 下跑（用户 2026-11-14 裁定），
 * 而 Dart 侧拿不到网络类型 —— 只能问系统。
 *
 * 为什么不引 `connectivity_plus`：本项目依赖锁死（见 pubspec.yaml 注释），
 * 自建通道与 `yanxin/secure`、`yanxin/ocr` 同构，少一个 Gradle 插件少一个未知数。
 *
 * ⚠️ 只读 `ConnectivityManager` 的能力位，**不采集 SSID / 不读流量 / 不上报任何网络信息**。
 * ⚠️ 以太网也算「WiFi」：模拟器 `adb reverse` 与部分平板走的就是 ETHERNET。
 * ⚠️ 任何异常一律返回 false —— 宁可这次不同步，也不要偷偷走蜂窝流量。
 */
class NetworkChannel(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val NAME = "yanxin/network"
    }

    private var channel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, NAME).also { it.setMethodCallHandler(this) }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isWifi" -> result.success(isWifi())
            else -> result.notImplemented()
        }
    }

    private fun isWifi(): Boolean = try {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        if (cm == null) {
            false
        } else {
            val network = cm.activeNetwork
            val caps = network?.let { cm.getNetworkCapabilities(it) }
            if (caps == null) {
                false
            } else {
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    (
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
                        )
            }
        }
    } catch (_: Exception) {
        false
    }
}
