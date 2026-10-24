package dev.codexlink.codex_link

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal data class NoticeSession(val origin: String, val token: String, val identity: String)

/** The service can restart without a Flutter engine; its credential stays encrypted at rest. */
internal class NotificationStore(context: Context) {
    val preferences = context.getSharedPreferences("task_notifications", Context.MODE_PRIVATE)
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("codexlink_task_notifications", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("codexlink_task_notifications",
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    fun save(origin: String, token: String): Boolean {
        val identity = MessageDigest.getInstance("SHA-256")
            .digest("$origin\n$token".toByteArray()).joinToString("") { "%02x".format(it) }
        if (preferences.getString("identity", null) == identity && read() != null) return false
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val content = JSONObject().put("origin", origin).put("token", token).toString()
        val encrypted = cipher.doFinal(content.toByteArray())
        preferences.edit().clear().putString("identity", identity)
            .putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .putString("secret", Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit()
        return true
    }
    fun read(): NoticeSession? {
        val secret = preferences.getString("secret", null) ?: return null
        val iv = preferences.getString("iv", null) ?: return null
        val identity = preferences.getString("identity", null) ?: return null
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
        }
        val data = JSONObject(String(cipher.doFinal(Base64.decode(secret, Base64.NO_WRAP))))
        return NoticeSession(data.getString("origin"), data.getString("token"), identity)
    }
    fun clear() { preferences.edit().clear().commit() }
}
