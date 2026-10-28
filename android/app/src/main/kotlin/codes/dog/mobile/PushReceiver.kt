package codes.dog.mobile

import android.content.Context
import android.content.Intent
import com.aliyun.ams.push.AliyunPushMessageReceiver
import com.alibaba.sdk.android.push.notification.CPushMessage

// Notification delivery must not require a live Flutter engine. Only a user
// click opens the activity; task data remains a hint for the authenticated PC.
class PushReceiver : AliyunPushMessageReceiver() {
    override fun onNotification(context: Context?, title: String?, summary: String?, extraMap: Map<String, String>?) {}
    override fun onMessage(context: Context?, message: CPushMessage?) {}
    override fun onNotificationRemoved(context: Context?, messageId: String?) {}
    override fun onNotificationReceivedInApp(context: Context?, title: String?, summary: String?, extraMap: Map<String, String>?, openType: Int, activity: String?, url: String?) {}
    override fun onNotificationOpened(context: Context, title: String?, summary: String?, extraMap: String?) = openPush(context, extraMap)
    override fun onNotificationClickedWithNoAction(context: Context, title: String?, summary: String?, extraMap: String?) = openPush(context, extraMap)
}

internal fun openPush(context: Context, extra: String?) {
    if (extra == null || extra.length > 4096) return
    context.startActivity(Intent(context, MainActivity::class.java)
        .putExtra("dogcodesPush", extra)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
}
