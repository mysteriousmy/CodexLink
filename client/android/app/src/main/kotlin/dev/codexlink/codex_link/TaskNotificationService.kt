package dev.codexlink.codex_link

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException
import kotlin.math.min
import kotlin.random.Random

/** Independent of Flutter's UI connection and engine lifecycle. */
class TaskNotificationService : Service() {
    companion object {
        const val TASK_CHANNEL = "task_results"
        private const val STATUS_CHANNEL = "task_connection"
        private const val STATUS_ID = 7100
        internal val deliveryLock = Any()
        @Volatile var connection = "stopped"
            private set
        internal fun preparingToStart() {
            // startForegroundService returns before onStartCommand runs. The
            // permission action must not report a stopped service in that gap.
            if (connection == "stopped") connection = "connecting"
        }
        internal fun startFailed() { connection = "stopped" }
    }
    private class NotificationsBlocked : IOException()
    private class InvalidFeed(val reason: String) : IOException()
    private val store by lazy { NotificationStore(this) }
    private val manager by lazy { getSystemService(NotificationManager::class.java) }
    @Volatile private var generation = 0
    @Volatile private var transport: HttpURLConnection? = null
    private var worker: Thread? = null
    private var identity: String? = null

    override fun onBind(intent: Intent?): IBinder? = null
    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(STATUS_CHANNEL, "后台任务提醒连接", NotificationManager.IMPORTANCE_LOW))
            manager.createNotificationChannel(NotificationChannel(TASK_CHANNEL, "任务提问、完成与失败", NotificationManager.IMPORTANCE_HIGH))
        }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Every startForegroundService call must promptly enter foreground, even if config was revoked.
        val notification = builder(STATUS_CHANNEL).setSmallIcon(R.drawable.ic_task_notification)
            .setContentTitle("CodexLink 任务提醒")
            .setContentText("正在后台接收提问与任务结果")
            .setContentIntent(openApp()).setOngoing(true).setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE).build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(STATUS_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        else startForeground(STATUS_ID, notification)
        val session = try { store.read() } catch (_: Exception) { null }
        if (session == null || !store.preferences.getBoolean("enabled", false) || !manager.areNotificationsEnabled()) {
            stopSelf(); return START_NOT_STICKY
        }
        if (identity == session.identity && worker?.isAlive == true && intent?.getBooleanExtra("reconnect", false) != true) return START_STICKY
        generation++
        transport?.disconnect(); worker?.interrupt()
        identity = session.identity
        val current = generation
        worker = Thread({ listen(session, current) }, "codexlink-task-notices").apply { start() }
        return START_STICKY
    }
    private fun current(session: NoticeSession, expected: Int) = generation == expected &&
        store.preferences.getBoolean("enabled", false) && store.preferences.getString("identity", null) == session.identity

    private fun listen(session: NoticeSession, expected: Int) {
        var retry = 0
        while (current(session, expected) && !Thread.currentThread().isInterrupted) {
            var socket: HttpURLConnection? = null
            try {
                connection = "connecting"
                val epoch = store.preferences.getString("epoch", null)
                val endpoint = Uri.parse(session.origin + "/api/notifications/events").buildUpon()
                if (epoch != null) endpoint.appendQueryParameter("epoch", epoch)
                    .appendQueryParameter("after", store.preferences.getLong("cursor", 0).toString())
                socket = URL(endpoint.build().toString()).openConnection() as HttpURLConnection
                transport = socket
                socket.instanceFollowRedirects = false
                socket.connectTimeout = 15000
                socket.readTimeout = 45000
                socket.setRequestProperty("Authorization", "Bearer ${session.token}")
                socket.setRequestProperty("Accept", "text/event-stream")
                socket.setRequestProperty("Accept-Encoding", "identity")
                socket.setRequestProperty("Cache-Control", "no-cache")
                val code = socket.responseCode
                if (code in listOf(401, 403, 404) || code in 300..399) {
                    synchronized(deliveryLock) {
                        if (current(session, expected)) {
                            store.preferences.edit().putBoolean("enabled", false).putString("error",
                                if (code == 404) "电脑服务需升级后才能开启后台通知" else "通知连接失效，请重新登录并开启通知").commit()
                            connection = "stopped"
                            stopSelf()
                        }
                    }
                    return
                }
                if (code != 200) throw InvalidFeed("通知服务返回 HTTP $code，正在重试")
                if (socket.contentType?.startsWith("text/event-stream", ignoreCase = true) != true)
                    throw InvalidFeed("通知接口没有返回事件流，请检查服务地址或反向代理")
                if (!current(session, expected)) return
                socket.inputStream.bufferedReader(Charsets.UTF_8).use { input ->
                    var event = ""
                    var id = ""
                    var data = ""
                    while (current(session, expected)) {
                        val line = boundedLine(input) ?: break
                        if (line.isEmpty()) {
                            if (data.isNotEmpty()) {
                                synchronized(deliveryLock) {
                                    if (current(session, expected)) consume(event, id, JSONObject(data), session)
                                }
                                retry = 0
                            }
                            event = ""; id = ""; data = ""
                        } else if (line.startsWith("event:")) event = line.substring(6).trim()
                        else if (line.startsWith("id:")) id = line.substring(3).trim()
                        else if (line.startsWith("data:")) {
                            data += line.substring(5).trimStart() + "\n"
                            if (data.length > 65536) throw IOException("Notification frame too large")
                        }
                    }
                }
                throw IOException("Notification stream ended")
            } catch (_: NotificationsBlocked) {
                synchronized(deliveryLock) {
                    if (current(session, expected)) {
                        store.preferences.edit().putBoolean("enabled", false)
                            .putString("error", "系统通知权限已关闭，请允许通知后重新开启").commit()
                        stopSelf()
                    }
                }
                return
            } catch (error: Exception) {
                // Show a fixed diagnostic without leaking URLs, tokens or server bodies.
                val reason = when (error) {
                    is InvalidFeed -> error.reason
                    is UnknownHostException -> "无法解析通知服务地址，正在重试"
                    is ConnectException -> "无法连接通知服务，请检查网络与电脑服务"
                    is SocketTimeoutException -> "通知连接超时，请检查网络或代理是否缓冲事件流"
                    is SSLException -> "通知连接的 HTTPS 证书验证失败，请检查证书配置"
                    else -> "通知连接已断开，正在重新连接"
                }
                synchronized(deliveryLock) {
                    if (current(session, expected)) store.preferences.edit().putString("error", reason).apply()
                }
            } finally {
                socket?.disconnect()
                if (transport === socket) transport = null
            }
            if (!current(session, expected)) return
            connection = "reconnecting"
            val delay = min(30000L, 1000L shl min(retry++, 5)) + Random.nextLong(500)
            try { Thread.sleep(delay) } catch (_: InterruptedException) { return }
        }
    }
    private fun boundedLine(input: BufferedReader): String? {
        val line = StringBuilder()
        while (true) {
            val char = input.read()
            if (char == -1) return if (line.isEmpty()) null else line.toString().removeSuffix("\r")
            if (char == 10) return line.toString().removeSuffix("\r")
            if (line.length >= 65536) throw IOException("Notification line too large")
            line.append(char.toChar())
        }
    }
    private fun consume(event: String, eventId: String, data: JSONObject, session: NoticeSession) {
        if (event == "task" || event == "question") {
            val id = data.getString("id")
            val thread = data.getString("threadId")
            val state = data.getString("status")
            val question = if (event == "question") data.getString("questionId") else null
            val preview = data.optString("preview", "点按查看对应会话").take(240)
            require(id.length <= 513 && thread.length <= 256 &&
                if (question == null) state in listOf("completed", "failed")
                else question.length <= 1024 && state in listOf("question", "resolved"))
            val tag = if (question == null) "task:$thread" else "question:$thread:$question"
            val recent = JSONArray(store.preferences.getString("seen", "[]"))
            val seen = (0 until recent.length()).map { recent.getString(it) }.toMutableList()
            if (id !in seen) {
                // Persist after delivery: a process death can repeat a tag, but cannot acknowledge an unseen result.
                if (state == "resolved") manager.cancel(tag, 0)
                else postResult(thread, state, preview, tag, session)
                seen.add(id)
                store.preferences.edit().putString("seen", JSONArray(seen.takeLast(256)).toString()).commit()
            }
            saveCursor(eventId)
        } else if (event == "ready") {
            connection = "connected"
            store.preferences.edit().remove("error").apply()
            if (data.optBoolean("gap")) {
                manager.notify("task-gap", 0, builder(TASK_CHANNEL).setSmallIcon(R.drawable.ic_task_notification)
                    .setContentTitle("部分任务提醒可能已过期")
                    .setContentText("点按打开 CodexLink 查看会话最新状态")
                    .setContentIntent(openApp()).setAutoCancel(true).build())
            }
            saveCursor(eventId)
        }
    }
    private fun saveCursor(id: String) {
        val split = id.lastIndexOf(':')
        if (split < 1) return
        val sequence = id.substring(split + 1).toLongOrNull() ?: return
        if (sequence < 0) return
        store.preferences.edit().putString("epoch", id.substring(0, split)).putLong("cursor", sequence).commit()
    }
    private fun postResult(thread: String, state: String, preview: String, tag: String, session: NoticeSession) {
        if (!manager.areNotificationsEnabled()) throw NotificationsBlocked()
        if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(TASK_CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE)
            throw NotificationsBlocked()
        val intent = Intent(this, MainActivity::class.java)
            .setAction("dev.codexlink.OPEN_TASK")
            .setData(Uri.Builder().scheme("codexlink").authority("task").appendPath(session.identity).appendPath(thread).build())
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra("noticeThread", thread).putExtra("noticeSession", session.identity)
        val pending = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = builder(TASK_CHANNEL).setSmallIcon(R.drawable.ic_task_notification)
            .setContentTitle(when (state) { "question" -> "Codex 有问题请你回答"; "failed" -> "Codex 本轮任务失败"; else -> "Codex 本轮任务已完成" })
            .setContentText(preview).setStyle(Notification.BigTextStyle().bigText(preview))
            .setContentIntent(pending).setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE).setCategory(Notification.CATEGORY_STATUS)
            .setPriority(Notification.PRIORITY_HIGH).setDefaults(Notification.DEFAULT_ALL).build()
        // Keep each pending question independently, with at most twenty unread cards.
        val active = manager.activeNotifications.filter { (it.tag?.startsWith("task:") == true || it.tag?.startsWith("question:") == true) && it.tag != tag }
            .sortedBy { it.postTime }
        active.take((active.size - 19).coerceAtLeast(0)).forEach { manager.cancel(it.tag, it.id) }
        manager.notify(tag, 0, notification)
    }
    private fun openApp() = PendingIntent.getActivity(this, 0,
        Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    @Suppress("DEPRECATION")
    private fun builder(channel: String) = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channel) else Notification.Builder(this)
    override fun onDestroy() {
        synchronized(deliveryLock) { generation++; connection = "stopped" }
        transport?.disconnect(); worker?.interrupt(); worker = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
