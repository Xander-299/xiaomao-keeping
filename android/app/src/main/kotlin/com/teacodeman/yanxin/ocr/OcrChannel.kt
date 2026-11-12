package com.teacodeman.yanxin.ocr

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * 平台通道 `yanxin/ocr`（F8.1 截图记账）。
 *
 * 职责两件事：① 选图（系统 Photo Picker / SAF，**不需要任何运行时权限**）；
 * ② 把本地图片变成「文字行 + 归一化坐标」。
 * 解析、校验、写库全在 Dart 侧（drift 是唯一 DB writer —— 与 F7.15 同一条不变量）。
 *
 * 为什么自建通道而不是第三方插件：
 *  1. 中文**必须**额外加 `com.google.mlkit:text-recognition-chinese` 这个 AAR，
 *     `google_mlkit_text_recognition` 插件在这件事上只是薄封装；
 *  2. 本项目 AGP 9.1 / Gradle 9.3 / Kotlin 2.4 是相当新的组合，少一个第三方 Gradle 插件就少一个未知数；
 *  3. **选图也是自己做的**：真机实测（Redmi K50 / Android 14）`file_picker` 12 的选图
 *     在 release 包里**点了没反应、也不报错**（同一台机器上导入页的选文件同样失败），
 *     而系统 Photo Picker 用 `startActivityForResult` 一次就好 —— 干脆把这条链路收到自己手里。
 *
 * ⚠️ 离线：`text-recognition-chinese` 是 **bundled** 变体（模型随 APK），
 * 不依赖 Google Play 服务、不做运行时下载 → release 包**仍然不需要 `INTERNET` 权限**。
 *
 * ⚠️ 线程：ML Kit 的 Task 只能在**非主线程**上 `Tasks.await`，结果统一 post 回主线程，
 * 否则 `MethodChannel.Result` 在部分引擎版本上会抛 "Reply already submitted"。
 */
class OcrChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val NAME = "yanxin/ocr"

        /** 选图请求码（与 autobook 的 0x7A16 不冲突）。 */
        private const val REQ_PICK_IMAGE = 0x7A21

        /** 单张图识别的硬超时：超过就报错，绝不让 UI 无限转圈。 */
        private const val TIMEOUT_SECONDS = 25L
    }

    private var channel: MethodChannel? = null

    /** 识别是 CPU 密集的串行任务：单线程排队，避免并发抢占内存。 */
    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "yanxin-ocr").apply { isDaemon = true }
    }

    private val main = Handler(Looper.getMainLooper())

    /** 识别器单例（ML Kit 官方要求复用；`close()` 后不可再用）。 */
    private var recognizer: TextRecognizer? = null

    /** 正在等用户选图的那次调用（同一时刻只允许一次）。 */
    private var pendingPick: MethodChannel.Result? = null

    /** 本次选图的启动时刻（用来识别"秒退"）与"是否已经退到 SAF 再试一次"。 */
    private var pickStartedAt = 0L
    private var triedSaf = false

    /** 这次选的是什么（决定 MIME 过滤与缓存文件后缀）。 */
    private var pendingKind: PickKind = PickKind.image

    fun attach(messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, NAME)
        ch.setMethodCallHandler(this)
        channel = ch
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        pendingPick = null
        releaseRecognizer()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // 选图：系统 Photo Picker（Android 13+）/ SAF 兜底；返回缓存目录里的绝对路径
            "pickImage" -> pick(PickKind.image, result)
            // 选账单文件（csv / xlsx）：SAF；同样返回缓存目录里的绝对路径（字节由 Dart 读）
            "pickDocument" -> pick(PickKind.document, result)
            // 识别：path = 缓存目录里的图片绝对路径
            "recognize" -> recognize(call.argument<String>("path").orEmpty(), result)
            // 释放：页面销毁 / App 进后台时调，及时还回 native 内存
            "release" -> {
                releaseRecognizer()
                result.success(null)
            }
            // 让 Dart 侧能把「哪套引擎」写进诊断，不必硬编码字符串
            "engineInfo" -> result.success(
                mapOf(
                    "engine" to "ml-kit-text-recognition-chinese",
                    "bundled" to true,
                    "offline" to true,
                ),
            )
            else -> result.notImplemented()
        }
    }

    /** 选图的种类。 */
    private enum class PickKind { image, document }

    private fun cacheDirName(kind: PickKind): String =
        if (kind == PickKind.image) "receipt" else "import"

    /** 选一个东西（图片 / 文档）。结果在 [handleActivityResult] 里回。 */
    private fun pick(kind: PickKind, result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "已经有一个选择器在进行中", null)
            return
        }
        pendingKind = kind
        triedSaf = false
        startPick(result, buildPickIntent(kind, preferPhotoPicker = true))
    }

    private fun startPick(result: MethodChannel.Result, intent: Intent?) {
        if (intent == null) {
            result.error("unsupported_platform", "这台设备没有可用的文件选择器", null)
            return
        }
        pendingPick = result
        pickStartedAt = SystemClock.elapsedRealtime()
        try {
            activity.startActivityForResult(intent, REQ_PICK_IMAGE)
        } catch (e: Exception) {
            pendingPick = null
            result.error("unsupported_platform", e.message ?: e.javaClass.simpleName, null)
        }
    }

    /**
     * 图片：Android 13+ 用 **Photo Picker**（免权限、离线、不依赖 Play 服务），
     * 老系统 / Photo Picker 秒退时退回 `ACTION_OPEN_DOCUMENT`；
     * 文档（账单 csv/xlsx）：直接走 `ACTION_OPEN_DOCUMENT`（SAF，同样免权限）。
     *
     * ⚠️ 文档的 MIME 要给全：微信导出的是 **xlsx（zip）**、支付宝是 **csv（常被报成
     * `application/octet-stream`）**，只写 `text/csv` 会在部分 ROM 上把文件置灰选不了。
     */
    private fun buildPickIntent(kind: PickKind, preferPhotoPicker: Boolean): Intent? {
        if (kind == PickKind.image && preferPhotoPicker &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
        ) {
            val picker = Intent(MediaStore.ACTION_PICK_IMAGES).apply { type = "image/*" }
            if (picker.resolveActivity(activity.packageManager) != null) return picker
        }
        val open = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            if (kind == PickKind.image) {
                type = "image/*"
            } else {
                type = "*/*"
                putExtra(
                    Intent.EXTRA_MIME_TYPES,
                    arrayOf(
                        "text/csv",
                        "text/comma-separated-values",
                        "text/plain",
                        // 2026-11-13：小耄记账自己的备份是 .json。少了这三条，系统选择器里
                        // 备份文件是**灰的/看不见**，导入端再能识别也选不到。
                        "application/json",
                        "text/json",
                        "text/x-json",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                        "application/zip",
                        "application/vnd.ms-excel",
                        "application/octet-stream",
                    ),
                )
            }
        }
        return if (open.resolveActivity(activity.packageManager) != null) open else null
    }

    /** MainActivity.onActivityResult 转进来；返回 true 表示这是本通道的请求。 */
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ_PICK_IMAGE) return false
        val result = pendingPick ?: return true
        val elapsed = SystemClock.elapsedRealtime() - pickStartedAt
        // 系统 Photo Picker 在这台 MIUI 上曾出现**秒退**（<400ms 回 CANCELED 且无 data），
        // 用户看到的就是「点了没反应」。这种情况自动换 SAF 再试一次。
        if (resultCode != Activity.RESULT_OK && elapsed < 400 && !triedSaf) {
            triedSaf = true
            startPick(result, buildPickIntent(pendingKind, preferPhotoPicker = false))
            return true
        }
        pendingPick = null
        triedSaf = false
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null) // 用户取消
            return true
        }
        worker.execute {
            try {
                val path = copyToCache(uri, pendingKind)
                main.post { result.success(path) }
            } catch (e: Exception) {
                main.post {
                    result.error("file_not_found", e.message ?: "读取文件失败", null)
                }
            }
        }
        return true
    }

    /**
     * 把选中的东西**复制到应用缓存**再用。
     *
     * 原因：Photo Picker / SAF 给的 `content://` Uri 只在本次授权内有效，
     * ML Kit 的 `InputImage.fromFilePath` 要的是真实文件路径；导入页也要读字节流。
     * 顺手也保证原来的文件不会被改动。
     */
    private fun copyToCache(uri: Uri, kind: PickKind): String {
        val dir = File(activity.cacheDir, cacheDirName(kind)).apply { mkdirs() }
        // 清掉上次的临时文件（只留最近一个，避免缓存越攒越大）
        dir.listFiles()?.forEach { it.delete() }
        val ext = extensionOf(uri, kind)
        val out = File(dir, "pick_${System.currentTimeMillis()}$ext")
        val input = activity.contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("打不开文件流")
        input.use { src -> out.outputStream().use { dst -> src.copyTo(dst) } }
        if (out.length() == 0L) throw IllegalStateException("文件为空")
        return out.absolutePath
    }

    /** 缓存文件后缀：优先用 ContentResolver 报的 MIME，其次原文件名。 */
    private fun extensionOf(uri: Uri, kind: PickKind): String {
        val mime = try {
            activity.contentResolver.getType(uri)
        } catch (_: Exception) {
            null
        }
        val fromMime = when (mime) {
            "image/jpeg" -> ".jpg"
            "image/png" -> ".png"
            "image/webp" -> ".webp"
            "text/csv", "text/comma-separated-values" -> ".csv"
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" -> ".xlsx"
            "application/zip" -> ".zip"
            else -> null
        }
        if (fromMime != null) return fromMime
        val name = try {
            activity.contentResolver.query(uri, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex("_display_name")
                if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
            }
        } catch (_: Exception) {
            null
        }
        if (name != null) {
            val dot = name.lastIndexOf('.')
            if (dot >= 0 && dot < name.length - 1) return name.substring(dot)
        }
        return if (kind == PickKind.image) ".jpg" else ".bin"
    }

    private fun recognize(path: String, result: MethodChannel.Result) {
        if (path.isEmpty()) {
            fail(result, "bad_args", "缺少图片路径")
            return
        }
        val file = File(path)
        if (!file.exists() || file.length() == 0L) {
            fail(result, "file_not_found", "图片不存在或为空：$path")
            return
        }

        worker.execute {
            val startedAt = SystemClock.elapsedRealtime()
            try {
                // InputImage.fromFilePath 会按 EXIF 把旋转画正（截图库/相机原图都可能带方向），
                // 所以 Dart 侧拿到的坐标已经是"正的"。
                val image = InputImage.fromFilePath(activity, Uri.fromFile(file))
                val text = Tasks.await(
                    ensureRecognizer().process(image),
                    TIMEOUT_SECONDS,
                    TimeUnit.SECONDS,
                )
                val payload = toPayload(text, image, SystemClock.elapsedRealtime() - startedAt)
                main.post { result.success(payload) }
            } catch (e: Exception) {
                // 识别失败是**正常业务分支**（模糊图 / 不是截图 / 模型初始化失败），
                // 用 error 通道回 Dart，由那边翻译成可读中文 + 兜底手动记账入口。
                main.post {
                    result.error("ocr_failed", e.message ?: e.javaClass.simpleName, null)
                }
            }
        }
    }

    /** 把 ML Kit 结果拍平成 Dart 好消费的形状（线条级，保留 bbox 供"从右往左"取值）。 */
    private fun toPayload(text: Text, image: InputImage, elapsedMs: Long): Map<String, Any?> {
        val lines = ArrayList<Map<String, Any?>>(text.textBlocks.sumOf { it.lines.size })
        for (block in text.textBlocks) {
            for (line in block.lines) {
                val box = line.boundingBox
                lines.add(
                    mapOf(
                        "text" to (line.text ?: ""),
                        "left" to (box?.left ?: 0),
                        "top" to (box?.top ?: 0),
                        "right" to (box?.right ?: 0),
                        "bottom" to (box?.bottom ?: 0),
                        "language" to (line.recognizedLanguage ?: ""),
                    ),
                )
            }
        }
        return mapOf(
            "text" to text.text,
            "lines" to lines,
            "width" to image.width,
            "height" to image.height,
            "rotation" to image.rotationDegrees,
            "elapsedMs" to elapsedMs,
        )
    }

    private fun ensureRecognizer(): TextRecognizer {
        recognizer?.let { return it }
        // 中文模型同时覆盖拉丁字符（数字 / ¥ / 英文商户名），所以不必再建一个 latin 识别器。
        val created = TextRecognition.getClient(
            ChineseTextRecognizerOptions.Builder().build(),
        )
        recognizer = created
        return created
    }

    private fun releaseRecognizer() {
        val current = recognizer ?: return
        recognizer = null
        // close 要与 process 串行，否则可能在识别中途把底层 native 句柄关掉
        worker.execute {
            try {
                current.close()
            } catch (_: Exception) {
            }
        }
    }

    private fun fail(result: MethodChannel.Result, code: String, message: String) {
        main.post { result.error(code, message, null) }
    }
}
