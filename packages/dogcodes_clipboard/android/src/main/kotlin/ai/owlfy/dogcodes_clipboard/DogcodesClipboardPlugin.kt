package ai.owlfy.dogcodes_clipboard

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class ClipboardImageProvider : FileProvider()

/** No clipboard listener, background reads, storage permission or broad provider. */
class DogcodesClipboardPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var attached = true
    private val writes = HashSet<String>() // Main-thread owned.

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dogcodes/clipboard")
        channel.setMethodCallHandler(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        writes.clear()
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { activity = null }
    private fun foreground() = attached && activity?.hasWindowFocus() == true
    private fun invalid(result: MethodChannel.Result, message: String = "剪贴板图片无效，或超过 16 MB / 800 万像素") {
        result.error("image", message, null)
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "cancelWrite") { val id = call.argument<String>("id"); result.success(id != null && writes.remove(id)); return }
        if (!foreground()) { result.error("foreground", "请回到 App 后操作剪贴板", null); return }
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        when (call.method) {
            "readPng" -> {
                // Only this user-invoked method inspects the primary clip.
                val clip = clipboard.primaryClip
                val uri = if (clip != null && clip.itemCount > 0) clip.getItemAt(0).uri else null
                if (uri == null) { result.success(null); return }
                if (uri.scheme != "content") { invalid(result); return }
                worker.execute {
                    try {
                        val resolver = context.contentResolver
                        require(resolver.getType(uri)?.startsWith("image/") == true)
                        val source = resolver.openInputStream(uri)?.use { input ->
                            val out = ByteArrayOutputStream()
                            val chunk = ByteArray(32768)
                            while (true) {
                                val n = input.read(chunk)
                                if (n < 0) break
                                require(out.size() + n <= MAX_BYTES)
                                out.write(chunk, 0, n)
                            }
                            out.toByteArray()
                        } ?: throw IllegalArgumentException()
                        val bytes = normalize(source)
                        main.post { if (attached) result.success(bytes) }
                    } catch (_: Exception) { main.post { if (attached) invalid(result) } }
                }
            }
            "writePng" -> {
                val bytes = call.argument<ByteArray>("png")
                val id = call.argument<String>("id")
                if (id == null || id.isEmpty() || id.length > 128 || bytes == null || bytes.isEmpty() || bytes.size > MAX_BYTES || writes.size >= 2 || !writes.add(id)) { invalid(result); return }
                worker.execute {
                    try {
                        validate(bytes, pngOnly = true)
                        // Verify actual decoding before publishing a content URI.
                        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: throw IllegalArgumentException()
                        bitmap.recycle()
                        val dir = File(context.filesDir, "clipboard-v1").apply { mkdirs() }
                        val file = File(dir, "${UUID.randomUUID()}.png").apply { writeBytes(bytes) }
                        val uri = FileProvider.getUriForFile(context, "${context.packageName}.clipboard", file)
                        main.post {
                            if (!writes.remove(id)) { file.delete(); result.error("cancelled", "图片复制已取消", null); return@post }
                            if (!foreground()) { file.delete(); invalid(result, "App 已进入后台，未写入手机剪贴板"); return@post }
                            try {
                                clipboard.setPrimaryClip(ClipData.newUri(context.contentResolver, "DogCodes 图片", uri))
                                // Keep a few recent files for in-flight paste consumers.
                                dir.listFiles()?.sortedByDescending { it.lastModified() }?.drop(4)?.forEach { it.delete() }
                                result.success(null)
                            } catch (_: Exception) { file.delete(); invalid(result) }
                        }
                    } catch (_: Exception) { main.post { writes.remove(id); if (attached) invalid(result) } }
                }
            }
            else -> result.notImplemented()
        }
    }
    private fun validate(bytes: ByteArray, pngOnly: Boolean = false) {
        require(bytes.isNotEmpty() && bytes.size <= MAX_BYTES)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0 && bounds.outWidth.toLong()*bounds.outHeight <= MAX_PIXELS)
        if (pngOnly) require(bounds.outMimeType == "image/png")
    }
    private fun normalize(bytes: ByteArray): ByteArray {
        validate(bytes)
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: throw IllegalArgumentException()
        var normalized = bitmap
        try {
            val orientation = if (Build.VERSION.SDK_INT >= 24) {
                try { ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) }
                catch (_: Exception) { 1 }
            } else 1
            val matrix = Matrix()
            when (orientation) {
                2 -> matrix.setScale(-1f, 1f)
                3 -> matrix.setRotate(180f)
                4 -> matrix.setScale(1f, -1f)
                5 -> { matrix.setRotate(90f); matrix.postScale(-1f, 1f) }
                6 -> matrix.setRotate(90f)
                7 -> { matrix.setRotate(270f); matrix.postScale(-1f, 1f) }
                8 -> matrix.setRotate(270f)
            }
            if (!matrix.isIdentity) normalized = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
            val out = ByteArrayOutputStream()
            require(normalized.compress(Bitmap.CompressFormat.PNG, 100, out))
            require(out.size() <= MAX_BYTES)
            return out.toByteArray()
        } finally {
            if (normalized !== bitmap) normalized.recycle()
            bitmap.recycle()
        }
    }
    companion object {
        private const val MAX_BYTES = 16 * 1024 * 1024
        private const val MAX_PIXELS = 8L * 1024 * 1024
    }
}
