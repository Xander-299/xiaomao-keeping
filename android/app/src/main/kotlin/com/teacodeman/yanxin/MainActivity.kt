package com.teacodeman.yanxin

import android.content.Intent
import com.teacodeman.yanxin.autobook.AutoBookChannel
import com.teacodeman.yanxin.autobook.AutoBookNotifier
import com.teacodeman.yanxin.autobook.AutoBookQueue
import com.teacodeman.yanxin.ocr.OcrChannel
import com.teacodeman.yanxin.secure.SecureStoreChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * 应用唯一 Activity。
 *
 * F7.15 起兼任两件事（此前是 13 行脚手架空实现）：
 * 1. 注册自动记账的平台通道 `yanxin/autobook`；
 * 2. 处理两类外部 intent：
 *    - `ACTION_SEND` + `text/plain`（从微信/支付宝「分享」一条账单文本 → 入队）
 *    - 回执通知按钮带来的 extra（`撤销` → 落命令文件，等 Dart 侧执行软删）
 *
 * F8.1 起再加一条平台通道 `yanxin/ocr`（截图记账的端上文字识别）。
 *
 * ⚠️ 只**落盘**、不碰数据库（drift 是唯一 DB writer，见 SPEC-F7.15 §3.1）。
 */
class MainActivity : FlutterActivity() {

    private var autoBookChannel: AutoBookChannel? = null
    private var ocrChannel: OcrChannel? = null
    private var secureStoreChannel: SecureStoreChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = AutoBookChannel(this)
        channel.attach(flutterEngine.dartExecutor.binaryMessenger)
        autoBookChannel = channel

        // 截图识别（F8.1）：只做「图片 → 文字行」，写库仍由 Dart 侧走 drift
        val ocr = OcrChannel(this)
        ocr.attach(flutterEngine.dartExecutor.binaryMessenger)
        ocrChannel = ocr

        // 登录态安全存储（P6.2）：Keystore 加密小段 JSON，不碰数据库
        val secure = SecureStoreChannel(this)
        secure.attach(flutterEngine.dartExecutor.binaryMessenger)
        secureStoreChannel = secure

        // 冷启动带进来的 intent（分享 / 通知按钮）在这里处理 —— 通道已就绪
        handleAutoBookIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleAutoBookIntent(intent)
    }

    override fun onDestroy() {
        autoBookChannel?.detach()
        autoBookChannel = null
        ocrChannel?.detach()
        ocrChannel = null
        secureStoreChannel?.detach()
        secureStoreChannel = null
        super.onDestroy()
    }

    /**
     * 选图（截图记账）走 `startActivityForResult`，结果在这里回收。
     *
     * 为什么不用 ActivityResultLauncher：本项目 MainActivity 没有注册 `ActivityResultRegistry`
     * 的生命周期回调，用最朴素的 `startActivityForResult` + 这一处转发最少代码、也最少意外。
     */
    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val handled = ocrChannel?.handleActivityResult(requestCode, resultCode, data) == true
        if (!handled) super.onActivityResult(requestCode, resultCode, data)
    }

    private fun handleAutoBookIntent(intent: Intent?) {
        if (intent == null) return

        if (Intent.ACTION_SEND == intent.action && intent.type?.startsWith("text/") == true) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (!text.isNullOrBlank()) {
                AutoBookQueue.enqueueShare(this, text, System.currentTimeMillis())
            }
        }

        // 通知按钮：落命令文件，由 Dart 在下次 drain 时取走（冷启动也能撤销）
        val action = intent.getStringExtra(AutoBookNotifier.EXTRA_ACTION)
        if (action != null) {
            AutoBookQueue.writeCommand(
                this,
                action,
                intent.getStringExtra(AutoBookNotifier.EXTRA_BATCH),
            )
            intent.removeExtra(AutoBookNotifier.EXTRA_ACTION)
            intent.removeExtra(AutoBookNotifier.EXTRA_BATCH)
        }
    }
}
