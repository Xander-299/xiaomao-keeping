package com.teacodeman.yanxin.autobook

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * 自动记账的**落盘队列**（F7.15 SPEC §3.1）。
 *
 * 职责边界（刻意压到最薄）：Kotlin 只做「过滤 + 落盘」，**不解析金额、不碰数据库**
 * —— drift 是唯一 DB writer，解析与入账全部在 Dart 侧（`auto_book_rules.dart`）。
 *
 * 文件（都在 `filesDir`，随 App 卸载清理）：
 * - `autobook_queue.jsonl`：一行一条 JSON，Dart drain 后整文件清空
 * - `autobook_command.json`：通知按钮落下的待办命令（撤销），Dart 取走后删除
 * - 已入队指纹见 `AutoBookSeen`（`autobook_seen.json`）
 *
 * 队列纪律：上限 500 条 / 保留 7 天；写入侧两层去重 —— 实时捕获用「同 pkg+title+text
 * 5 秒窗口」，补抓（catch-up）用 [AutoBookSeen] 的持久指纹；Dart 侧还有指纹唯一索引兜底，
 * 三层互不依赖。
 */
object AutoBookQueue {

    private const val QUEUE_FILE = "autobook_queue.jsonl"
    private const val COMMAND_FILE = "autobook_command.json"
    private const val MAX_LINES = 500
    private const val RETENTION_MS = 7L * 24 * 60 * 60 * 1000
    private const val DEDUP_WINDOW_MS = 5_000L
    private const val DEDUP_KEEP = 16

    /** 近 5 秒见过的通知（key = pkg|title|text），只在进程内，不做持久化。 */
    private val recent = ArrayDeque<Pair<String, Long>>()

    private fun queueFile(context: Context): File =
        File(context.filesDir, QUEUE_FILE)

    private fun commandFile(context: Context): File =
        File(context.filesDir, COMMAND_FILE)

    /**
     * 通知入队；已被丢弃（实时 5 秒窗口内重复 / 补抓时发现指纹已见过）返回 false。
     *
     * [fromCatchUp] = true 时**不走 5 秒窗口**（补抓与实时捕获可能相隔数小时），
     * 改用 [AutoBookSeen] 的持久指纹去重 —— 两条路径都必须回答同一个问题：
     * 「这条通知是不是已经入过队了」。
     */
    @Synchronized
    fun enqueueNotification(
        context: Context,
        pkg: String,
        title: String,
        text: String,
        bigText: String,
        subText: String,
        postTimeMs: Long,
        fromCatchUp: Boolean = false,
    ): Boolean {
        val key = "$pkg|$title|$text"
        if (fromCatchUp) {
            // 补抓：只看持久指纹，不看 5 秒窗口
            if (AutoBookSeen.contains(context, "$key|$postTimeMs")) return false
        } else {
            val now = System.currentTimeMillis()
            // 过期条目先清掉，避免 deque 无限增长
            while (recent.isNotEmpty() && now - recent.first().second > DEDUP_WINDOW_MS) {
                recent.removeFirst()
            }
            for (entry in recent) {
                if (entry.first == key) return false
            }
        }
        // 双保险：实时与补抓共用一份持久指纹（同一条通知经两条路径到达时只入队一次）
        if (!AutoBookSeen.remember(context, "$key|$postTimeMs")) return false
        if (!fromCatchUp) {
            recent.addLast(key to System.currentTimeMillis())
            while (recent.size > DEDUP_KEEP) recent.removeFirst()
        }

        val json = JSONObject()
            .put("kind", "notification")
            .put("pkg", pkg)
            .put("title", title)
            .put("text", text)
            .put("bigText", bigText)
            .put("subText", subText)
            .put("postTimeMs", postTimeMs)
            .toString()
        append(context, json)
        return true
    }

    /** 分享进来的文本入队（`ACTION_SEND` + `text/plain`）。 */
    @Synchronized
    fun enqueueShare(context: Context, text: String, atMs: Long) {
        if (text.isBlank()) return
        val json = JSONObject()
            .put("kind", "share")
            .put("text", text)
            .put("postTimeMs", atMs)
            .toString()
        append(context, json)
    }

    /** 未处理条数（用于「识别到 N 笔」提示）。 */
    @Synchronized
    fun pendingCount(context: Context): Int {
        val f = queueFile(context)
        if (!f.exists()) return 0
        return try {
            f.readLines().count { it.isNotBlank() }
        } catch (_: Exception) {
            0
        }
    }

    /**
     * 取走全部条目并清空队列。返回原始 JSONL 行（Dart 侧自行解码/丢弃坏行）。
     * 读取或清空失败都返回空列表 —— **绝不抛异常给 Flutter 侧**。
     */
    @Synchronized
    fun drain(context: Context): List<String> {
        val f = queueFile(context)
        if (!f.exists()) {
            AutoBookDiagnostics.noteDrained(context, 0)
            return emptyList()
        }
        val lines: List<String> = try {
            f.readLines()
        } catch (_: Exception) {
            return emptyList()
        }
        try {
            f.writeText("")
        } catch (_: Exception) {
            // 清空失败：下次 drain 会再取一遍，指纹去重保证不重复入账
        }
        recent.clear()
        val cutoff = System.currentTimeMillis() - RETENTION_MS
        val kept = lines.filter { it.isNotBlank() && !isExpired(it, cutoff) }
        AutoBookDiagnostics.noteDrained(context, kept.size)
        return kept
    }

    /**
     * 把 Dart 侧**未能处理**的原始行放回队列头 —— 兜住「取走即清空」的丢账路径。
     *
     * 只用于**临时性失败**（账本未就绪 / 写库异常 / 进程被杀）；解析不出的行
     * 由 Dart 侧判定后直接丢弃，不会走这里（否则会无限重试）。
     * 回写的行更早，放在队首。
     *
     * ⚠️ **超限时先丢掉 `existing` 里最旧的，不能丢 `fresh`**（F7.20，2026-11-19）：
     * 老实现是 `merged.takeLast(MAX_LINES)`，而 `fresh` 在队首 → 一旦 `fresh + existing`
     * 超过 500 行，被裁掉的恰恰是**这次刚回写、还没入账**的通知，等于静默丢账。
     * `fresh` 是「上一轮已经取走但没来得及入账」的数据，比队列里排队的更旧也更要紧 ——
     * 它已经在内存外没有任何副本了。
     */
    @Synchronized
    fun restore(context: Context, lines: List<String>) {
        val fresh = lines.filter { it.isNotBlank() }
        if (fresh.isEmpty()) return
        val f = queueFile(context)
        try {
            val existing = if (f.exists()) {
                f.readLines().filter { it.isNotBlank() }
            } else {
                emptyList()
            }
            val merged = fresh + existing
            val kept = if (merged.size > MAX_LINES) {
                // fresh 优先保留；剩下的额度给 existing 的**队尾**（越靠后越新）
                val room = (MAX_LINES - fresh.size).coerceAtLeast(0)
                if (room == 0) fresh.takeLast(MAX_LINES) else fresh + existing.takeLast(room)
            } else {
                merged
            }
            f.writeText(kept.joinToString("\n") + "\n")
        } catch (_: Exception) {
            // 回写失败只能接受丢失：指纹去重保证不会因此重复入账
        }
    }

    private fun append(context: Context, line: String) {
        val f = queueFile(context)
        try {
            f.appendText(line + "\n")
            prune(f)
        } catch (_: Exception) {
        }
    }

    /** 超出上限只保留最后 MAX_LINES 行。 */
    private fun prune(f: File) {
        try {
            val lines = f.readLines()
            if (lines.size <= MAX_LINES) return
            f.writeText(lines.takeLast(MAX_LINES).joinToString("\n") + "\n")
        } catch (_: Exception) {
        }
    }

    private fun isExpired(line: String, cutoff: Long): Boolean {
        return try {
            val at = JSONObject(line).optLong("postTimeMs", 0L)
            at > 0L && at < cutoff
        } catch (_: Exception) {
            false // 坏行交给 Dart 侧丢弃并计数，这里不静默吞掉
        }
    }

    /** 通知按钮落命令（撤销）。同一次只保留一条，后写覆盖先写。 */
    @Synchronized
    fun writeCommand(context: Context, action: String, batchId: String?) {
        val json = JSONObject().put("action", action)
        if (batchId != null) json.put("batchId", batchId)
        try {
            commandFile(context).writeText(json.toString())
        } catch (_: Exception) {
        }
    }

    /** 取走命令（读后即删）；无命令返回 null。 */
    @Synchronized
    fun takeCommand(context: Context): String? {
        val f = commandFile(context)
        if (!f.exists()) return null
        val content: String = try {
            f.readText()
        } catch (_: Exception) {
            return null
        }
        try {
            f.delete()
        } catch (_: Exception) {
        }
        return if (content.isBlank()) null else content
    }
}
