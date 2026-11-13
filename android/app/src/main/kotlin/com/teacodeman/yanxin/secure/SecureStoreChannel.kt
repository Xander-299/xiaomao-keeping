package com.teacodeman.yanxin.secure

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 平台通道 `yanxin/secure`（P6.2 云同步登录态）。
 *
 * 职责只有一个：把**小段字符串**加密后存进 `SharedPreferences`，读的时候解密。
 * 密钥由 Android Keystore 持有（`AES/GCM/NoPadding`），**不落盘、不出设备**。
 *
 * 为什么不引 `flutter_secure_storage`：本项目依赖锁死（见 `pubspec.yaml` 注释），
 * 自建通道与 `yanxin/ocr`、`yanxin/autobook` 同构，少一个第三方 Gradle 插件就少一个未知数。
 *
 * ⚠️ 这里只存登录 token 与邮箱，不碰账本数据（drift 仍是唯一 DB writer）。
 * ⚠️ 加密值格式：`base64(iv) + ":" + base64(ciphertext)`；密钥被系统作废（如恢复出厂、
 *    生物识别变更）时解密会抛 `KeyPermanentlyInvalidatedException` → 统一报错，
 *    Dart 侧按「未登录」处理。
 */
class SecureStoreChannel(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val NAME = "yanxin/secure"

        private const val PREFS_NAME = "yanxin_secure"
        private const val KEY_ALIAS = "yanxin_sync_token_key"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
    }

    private var channel: MethodChannel? = null

    private val prefs by lazy {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, NAME).also { it.setMethodCallHandler(this) }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "read" -> result.success(read(requireKey(call)))
                "write" -> {
                    val key = requireKey(call)
                    val value = call.argument<String>("value")
                        ?: return result.error("bad_args", "value 不能为空", null)
                    prefs.edit().putString(key, encrypt(value)).apply()
                    result.success(null)
                }
                "delete" -> {
                    prefs.edit().remove(requireKey(call)).apply()
                    result.success(null)
                }
                "clear" -> {
                    prefs.edit().clear().apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            // 不把密文 / 明文拼进错误信息
            result.error("secure_store", t.javaClass.simpleName, null)
        }
    }

    private fun requireKey(call: MethodCall): String {
        val key = call.argument<String>("key")
        if (key.isNullOrEmpty()) {
            throw IllegalArgumentException("key 不能为空")
        }
        return key
    }

    private fun read(key: String): String? {
        val payload = prefs.getString(key, null) ?: return null
        return decrypt(payload)
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = keyStore.getEntry(KEY_ALIAS, null)
        if (existing is KeyStore.SecretKeyEntry) return existing.secretKey

        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val iv = cipher.iv
        val ciphertext = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(ciphertext, Base64.NO_WRAP)
    }

    private fun decrypt(payload: String): String {
        val parts = payload.split(":", limit = 2)
        require(parts.size == 2) { "密文格式不对" }
        val iv = Base64.decode(parts[0], Base64.NO_WRAP)
        val ciphertext = Base64.decode(parts[1], Base64.NO_WRAP)

        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
        return String(cipher.doFinal(ciphertext), Charsets.UTF_8)
    }
}
