package codes.dog.mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private var pushChannel: MethodChannel? = null
    private var tokenChanged: (() -> Unit)? = null
    private var permissionResult: MethodChannel.Result? = null
    private fun notificationsAllowed(): Boolean = Build.VERSION.SDK_INT < 24 ||
        getSystemService(NotificationManager::class.java).areNotificationsEnabled()

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        pushChannel = MethodChannel(engine.dartExecutor.binaryMessenger, "dogcodes_push_permissions").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> result.success(PushChannels.capabilities(this))
                    "register_fcm" -> PushChannels.registerFcm(this, result)
                    "register_hms" -> PushChannels.registerHms(this, result)
                    "initEmasVendors" -> {
                        try { PushChannels.initEmasVendors(this); result.success(null) }
                        catch (_: Exception) { result.error("push_unavailable", "备用通知通道初始化失败。", null) }
                    }
                    "allowed" -> result.success(notificationsAllowed())
                    "authorize" -> {
                        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            if (permissionResult != null) result.success(false) else {
                                permissionResult = result
                                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7391)
                            }
                        } else result.success(notificationsAllowed())
                    }
                    "initialNotification" -> result.success(takePush())
                    else -> result.notImplemented()
                }
            }
        }
        tokenChanged = { pushChannel?.invokeMethod("registrationChanged", null) }
        PushChannels.changed = tokenChanged
    }
    private fun takePush(consume: Boolean = true): Map<String, Any>? {
        val raw = intent?.getStringExtra("dogcodesPush")
        // FCM's system notification copies the data payload into the launch Intent.
        val value = raw ?: validPushPayload(JSONObject(mapOf(
            "notificationId" to intent?.getStringExtra("notificationId"),
            "hostId" to intent?.getStringExtra("hostId"),
            "taskId" to intent?.getStringExtra("taskId"),
            "kind" to intent?.getStringExtra("kind")
        ))) ?: return null
        if (consume) {
            for (key in listOf("notificationId", "hostId", "taskId", "kind", "dogcodesPush")) intent.removeExtra(key)
        }
        return try {
            val data = JSONObject(value)
            data.keys().asSequence().associateWith { data.get(it) }
        } catch (_: Exception) { null }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Retain until Dart accepts it, so startup cannot lose a click. Clear
        // acknowledged extras so reopening from recents won't replay old clicks.
        takePush(consume = false)?.let { data ->
            val payload = JSONObject(data).toString()
            intent.putExtra("dogcodesPush", payload)
            pushChannel?.invokeMethod("opened", mapOf("extraMap" to payload), object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (getIntent()?.getStringExtra("dogcodesPush") == payload) {
                        for (key in listOf("notificationId", "hostId", "taskId", "kind", "dogcodesPush")) getIntent()?.removeExtra(key)
                    }
                }
                override fun error(code: String, message: String?, details: Any?) {}
                override fun notImplemented() {}
            })
        }
    }
    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        if (code == 7391) {
            permissionResult?.success(notificationsAllowed())
            permissionResult = null
        }
    }
    override fun onDestroy() {
        if (PushChannels.changed === tokenChanged) PushChannels.changed = null
        permissionResult?.success(false)
        permissionResult = null
        super.onDestroy()
    }
}
