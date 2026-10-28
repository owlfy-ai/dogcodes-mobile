package codes.dog.mobile

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.google.android.gms.common.GoogleApiAvailabilityLight
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.huawei.hms.api.HuaweiApiAvailability
import com.huawei.hms.aaid.HmsInstanceId
import com.aliyun.ams.push.AliyunThirdPushUtils
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal object PushChannels {
    var changed: (() -> Unit)? = null
    private val main = Handler(Looper.getMainLooper())
    private val hmsBusy = AtomicBoolean(false)
    private var hmsSignal: CountDownLatch? = null

    private fun metadata(context: Context, name: String): String =
        context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
            .metaData?.get(name)?.toString().orEmpty()

    fun capabilities(context: Context): Map<String, Boolean> {
        val fcmConfigured = listOf("sender_id", "app_id", "project_id", "api_key").all {
            metadata(context, "dogcodes.push.fcm.$it").isNotEmpty()
        }
        return mapOf(
            "configured" to (fcmConfigured || metadata(context, "com.huawei.hms.client.appid").isNotEmpty()),
            "fcm" to (fcmConfigured && GoogleApiAvailabilityLight.getInstance().isGooglePlayServicesAvailable(context) == 0),
            "hms" to (Build.MANUFACTURER.equals("huawei", true) &&
                metadata(context, "com.huawei.hms.client.appid").isNotEmpty() &&
                HuaweiApiAvailability.getInstance().isHuaweiMobileServicesAvailable(context) == 0)
        )
    }

    fun prepare(context: Context) {
        if (Build.VERSION.SDK_INT >= 26) context.getSystemService(NotificationManager::class.java)
            .createNotificationChannel(NotificationChannel("dogcodes_tasks", "任务提醒", NotificationManager.IMPORTANCE_DEFAULT))
    }

    fun registerFcm(context: Context, result: MethodChannel.Result) {
        val reply = PushReply(result)
        try {
            if (capabilities(context)["fcm"] != true) { reply.fail(); return }
            prepare(context)
            FirebaseApp.initializeApp(context)
            FirebaseMessaging.getInstance().apply { isAutoInitEnabled = true }.token
                .addOnCompleteListener { task ->
                    if (task.isSuccessful && !task.result.isNullOrEmpty()) reply.success(task.result)
                    else reply.fail()
                }
        } catch (_: Exception) { reply.fail() }
    }

    fun registerHms(context: Context, result: MethodChannel.Result) {
        val reply = PushReply(result)
        if (capabilities(context)["hms"] != true || !hmsBusy.compareAndSet(false, true)) { reply.fail(); return }
        prepare(context)
        val app = context.applicationContext
        val signal = CountDownLatch(1)
        synchronized(this) { hmsSignal = signal }
        // HMS getToken is synchronous. At most one physical call may remain
        // outstanding, even if its caller has already reached the deadline.
        Thread({
            try {
                val id = metadata(app, "com.huawei.hms.client.appid").removePrefix("appid=")
                var token = HmsInstanceId.getInstance(app).getToken(id, "HCM")
                if (token.isNullOrEmpty() && signal.await(15, TimeUnit.SECONDS)) {
                    token = app.getSharedPreferences("direct_push", Context.MODE_PRIVATE).getString("hms_token", null)
                }
                if (token.isNullOrEmpty()) reply.fail() else reply.success(token)
            } catch (_: Exception) { reply.fail() }
            finally {
                synchronized(this) { if (hmsSignal === signal) hmsSignal = null }
                hmsBusy.set(false)
            }
        }, "dogcodes-hms-token").apply { isDaemon = true }.start()
    }

    fun tokenChanged(context: Context, hmsToken: String? = null) {
        var isChanged = true
        if (!hmsToken.isNullOrEmpty()) {
            val preferences = context.getSharedPreferences("direct_push", Context.MODE_PRIVATE)
            isChanged = preferences.getString("hms_token", null) != hmsToken
            preferences.edit().putString("hms_token", hmsToken).apply()
            synchronized(this) { hmsSignal?.countDown() }
        }
        if (isChanged) main.post { changed?.invoke() }
    }

    fun initEmasVendors(context: Context) {
        val app = context.applicationContext as Application
        // Direct FCM/HMS services are deliberately excluded from EMAS.
        AliyunThirdPushUtils.registerXiaoMiPush(app)
        AliyunThirdPushUtils.registerVivoPush(app)
        AliyunThirdPushUtils.registerOppoPush(app)
        AliyunThirdPushUtils.registerMeizuPush(app)
        AliyunThirdPushUtils.registerHonorPush(app)
    }
}

private class PushReply(private val result: MethodChannel.Result) {
    private val main = Handler(Looper.getMainLooper())
    private val completed = AtomicBoolean(false)
    private val timeout = Runnable { fail() }
    init { main.postDelayed(timeout, 20000) }
    private fun finish(action: () -> Unit) { main.post {
        if (completed.compareAndSet(false, true)) { main.removeCallbacks(timeout); action() }
    } }
    fun success(token: String) = finish { result.success(token) }
    fun fail() = finish { result.error("push_unavailable", "通知通道暂不可用。", null) }
}
