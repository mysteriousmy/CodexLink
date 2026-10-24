package dev.codexlink.codex_link

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private val store by lazy { NotificationStore(this) }
    private var permissionResult: MethodChannel.Result? = null
    private var resumed = false
    private var pendingThread: String? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "codexlink/task_notifications")
        channel.setMethodCallHandler { call, result ->
            try {
                synchronized(TaskNotificationService.deliveryLock) {
                    when (call.method) {
                        "configure" -> {
                            val origin = call.argument<String>("origin")!!
                            val token = call.argument<String>("token")!!
                            val uri = Uri.parse(origin)
                            require(uri.scheme in listOf("http", "https") && uri.host != null &&
                                uri.userInfo == null && uri.query == null && uri.fragment == null &&
                                (uri.path.isNullOrEmpty() || uri.path == "/") && token.isNotBlank())
                            val changed = store.save(origin, token)
                            if (changed) { cancelPermission(); stopNotifications(); pendingThread = null }
                            store.preferences.edit().putBoolean("supported", call.argument<Boolean>("supported") == true).apply()
                            if (!store.preferences.getBoolean("supported", false)) {
                                store.preferences.edit().putBoolean("enabled", false).apply()
                                stopNotifications()
                            } else startIfEnabled()
                            acceptIntent(intent)
                            result.success(status())
                        }
                        "status" -> result.success(status())
                        "enable" -> {
                            if (!store.preferences.getBoolean("supported", false)) {
                                result.error("server_upgrade", "电脑服务需升级后才能开启后台通知", null)
                            } else if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                                if (permissionResult != null) result.error("busy", "正在等待系统授权", null)
                                else {
                                    permissionResult = result
                                    requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 701)
                                }
                            } else { enable(); result.success(status()) }
                        }
                        "disable" -> {
                            store.preferences.edit().putBoolean("enabled", false).apply()
                            stopNotifications()
                            result.success(status())
                        }
                        "clear" -> {
                            cancelPermission(); store.clear(); pendingThread = null; stopNotifications(); result.success(null)
                        }
                        "takePendingThread" -> { result.success(pendingThread); pendingThread = null }
                        "batterySettings" -> {
                            startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName")))
                            result.success(null)
                        }
                        "notificationSettings" -> {
                            val settings = if (Build.VERSION.SDK_INT >= 26)
                                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                            startActivity(settings); result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            } catch (_: Exception) {
                result.error("notifications_unavailable", "通知设置未能完成，请重试或检查系统设置", null)
            }
        }
    }
    private fun enabledPermission() = getSystemService(NotificationManager::class.java).areNotificationsEnabled()
    private fun enable() {
        if (!enabledPermission()) return
        store.preferences.edit().putBoolean("enabled", true).remove("error").apply()
        startIfEnabled()
    }
    private fun startIfEnabled() {
        if (!resumed || !store.preferences.getBoolean("enabled", false) || !enabledPermission()) return
        val intent = Intent(this, TaskNotificationService::class.java)
        TaskNotificationService.preparingToStart()
        try {
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
        } catch (error: Exception) {
            TaskNotificationService.startFailed()
            throw error
        }
    }
    private fun stopNotifications() {
        stopService(Intent(this, TaskNotificationService::class.java))
        getSystemService(NotificationManager::class.java).cancelAll()
    }
    private fun status(): Map<String, Any?> {
        val manager = getSystemService(NotificationManager::class.java)
        val channelAllowed = Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(TaskNotificationService.TASK_CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE
        return mapOf("platform" to "android", "permission" to if (enabledPermission() && channelAllowed) "granted" else "denied",
            "enabled" to store.preferences.getBoolean("enabled", false),
            "batteryExempt" to getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName),
            "connection" to TaskNotificationService.connection,
            "error" to store.preferences.getString("error", null))
    }
    override fun onResume() { super.onResume(); resumed = true; startIfEnabled() }
    override fun onPause() { resumed = false; super.onPause() }
    override fun onCreate(savedInstanceState: Bundle?) { super.onCreate(savedInstanceState); acceptIntent(intent) }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); acceptIntent(intent) }
    private fun acceptIntent(intent: Intent?) {
        if (intent?.getStringExtra("noticeSession") != store.preferences.getString("identity", null)) return
        val thread = intent?.getStringExtra("noticeThread") ?: return
        pendingThread = thread
        intent.removeExtra("noticeThread")
        if (::channel.isInitialized) channel.invokeMethod("openThread", thread)
    }
    private fun cancelPermission() {
        permissionResult?.error("cancelled", "登录状态已改变，请重新开启通知", null)
        permissionResult = null
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 701 || permissionResult == null) return
        try { enable(); permissionResult?.success(status()) }
        catch (_: Exception) { permissionResult?.error("notifications_unavailable", "无法启动后台通知", null) }
        permissionResult = null
    }
    override fun onDestroy() {
        permissionResult?.error("cancelled", "通知授权已取消", null); permissionResult = null
        super.onDestroy()
    }
}
