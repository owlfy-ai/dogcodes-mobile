package codes.dog.mobile

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.huawei.hms.push.HmsMessageService
import org.json.JSONObject

class FcmPushService : FirebaseMessagingService() {
    override fun onNewToken(token: String) { PushChannels.tokenChanged(this) }
    override fun onMessageReceived(message: RemoteMessage) {
        // Background notification payloads are shown by FCM itself. This
        // callback handles foreground/data delivery without a Flutter engine.
        showDirectPush(this, JSONObject(message.data as Map<*, *>))
    }
}

class HmsPushService : HmsMessageService() {
    override fun onNewToken(token: String) { PushChannels.tokenChanged(this, token) }
    override fun onMessageReceived(message: com.huawei.hms.push.RemoteMessage) {
        if (message.notification == null) {
            try { showDirectPush(this, JSONObject(message.data)) } catch (_: Exception) {}
        }
    }
}

private fun showDirectPush(context: Context, data: JSONObject) {
    val payload = validPushPayload(data) ?: return
    val manager = context.getSystemService(NotificationManager::class.java)
    if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) return
    PushChannels.prepare(context)
    val id = data.getString("notificationId")
    val open = Intent(context, MainActivity::class.java)
        .setData(Uri.parse("dogcodes-notification:${Uri.encode(id)}"))
        .putExtra("dogcodesPush", payload)
        .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    val pending = PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    val text = when (data.getString("kind")) {
        "approval", "question" -> "有任务需要你处理"
        "completed" -> "任务已完成"
        else -> "任务执行失败，请打开应用查看"
    }
    val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, "dogcodes_tasks") else Notification.Builder(context)
    try {
        manager.notify(id, 0, builder.setSmallIcon(R.mipmap.ic_launcher).setContentTitle("DogCodes")
            .setContentText(text).setAutoCancel(true).setContentIntent(pending).build())
    } catch (_: SecurityException) { /* The user may revoke permission while delivery is in progress. */ }
}

internal fun validPushPayload(data: JSONObject): String? {
    val keys = listOf("notificationId", "hostId", "taskId", "kind")
    for (key in keys) {
        val value = data.opt(key) as? String ?: return null
        if (value.isEmpty() || value.length > 128 || value.any { it.code < 32 }) return null
    }
    if (data.getString("kind") !in listOf("approval", "question", "completed", "failed")) return null
    return JSONObject(keys.associateWith { data.getString(it) }).toString()
}
