package ai.owlfy.dogcodes_video

import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaCodecList
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.ConcurrentHashMap

/** `dogcodes/h264`: hardware H.264 decoders rendering into Flutter textures. */
class DogcodesVideoPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var textures: TextureRegistry
    private val decoders = HashMap<Long, H264Surface>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        textures = binding.textureRegistry
        channel = MethodChannel(binding.binaryMessenger, "dogcodes/h264")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        decoders.values.forEach { it.release() }
        decoders.clear()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> {
                val width = call.argument<Int>("width") ?: 1920
                val height = call.argument<Int>("height") ?: 1080
                val entry = textures.createSurfaceTexture()
                try {
                    val decoder = H264Surface(entry, width, height)
                    decoders[entry.id()] = decoder
                    result.success(entry.id())
                } catch (error: Exception) {
                    entry.release()
                    result.error("unsupported", "H.264 format is unavailable", null)
                }
            }
            "decode" -> {
                val id = call.argument<Number>("id")?.toLong()
                val data = call.argument<ByteArray>("data")
                val decoder = id?.let { decoders[it] }
                if (decoder == null || data == null) {
                    result.error("invalid", "unknown decoder", null)
                } else {
                    decoder.decode(data, call.argument<Boolean>("keyframe") == true) { decoded ->
                        if (decoded) result.success(null)
                        else result.error("needKeyframe", "decoder needs a keyframe", null)
                    }
                }
            }
            "stats" -> {
                val decoder = call.argument<Number>("id")?.toLong()?.let { decoders[it] }
                if (decoder == null) {
                    result.error("invalid", "unknown decoder", null)
                } else {
                    result.success(decoder.stats())
                }
            }
            "dispose" -> {
                call.argument<Number>("id")?.toLong()?.let { decoders.remove(it)?.release() }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}

/** Splits Annex-B into NAL units without start codes. */
internal fun annexBUnits(data: ByteArray): List<ByteArray> {
    val units = ArrayList<ByteArray>()
    var start = -1
    var i = 0
    while (i + 2 < data.size) {
        if (data[i].toInt() == 0 && data[i + 1].toInt() == 0 && data[i + 2].toInt() == 1) {
            if (start >= 0) {
                var end = i
                if (end > start && data[end - 1].toInt() == 0) end--
                units.add(data.copyOfRange(start, end))
            }
            i += 3
            start = i
        } else {
            i++
        }
    }
    if (start in 0 until data.size) units.add(data.copyOfRange(start, data.size))
    return units
}

private val START_CODE = byteArrayOf(0, 0, 0, 1)

/**
 * One stream decoded by MediaCodec in asynchronous mode onto the texture's
 * surface. Input buffers and pending access units meet on one handler
 * thread; output buffers are rendered as soon as they are ready.
 */
private class H264Surface(
    private val entry: TextureRegistry.SurfaceTextureEntry,
    private val width: Int,
    private val height: Int,
) {
    // Check format support before allocating a worker or texture surface.
    private val codecName = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        .findDecoderForFormat(MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height))
        ?: throw IllegalArgumentException("unsupported H.264 size")
    private val thread = HandlerThread("dogcodes-h264").apply { start() }
    private val handler = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())
    private val surface: Surface
    private val closed = AtomicBoolean(false)
    private val admitted = AtomicInteger(0)
    private val peakPending = AtomicInteger(0)
    private val tickets = AtomicLong(0)
    private val active = ConcurrentHashMap<Long, (Boolean) -> Unit>()
    // Codec, queues and callbacks below belong exclusively to handler.
    private var codec: MediaCodec? = null
    private var sps: ByteArray? = null
    private var pps: ByteArray? = null
    private val freeInputs = ArrayDeque<Int>()
    private data class Input(val pts: Long, val bytes: ByteArray, val keyframe: Boolean)
    private val pending = ArrayDeque<Input>()
    private val inFlight = HashMap<Long, (Boolean) -> Unit>()
    @Volatile private var failed = false
    @Volatile private var decoded = 0L
    private var pts = 0L

    init {
        entry.surfaceTexture().setDefaultBufferSize(width, height)
        surface = Surface(entry.surfaceTexture())
    }

    fun stats(): Map<String, Any> = mapOf(
        "decoded" to decoded, "pending" to admitted.get(), "maxPending" to peakPending.get(),
    )

    /** Completion means this exact PTS produced decoded output, not queue admission. */
    fun decode(data: ByteArray, keyframe: Boolean, done: (Boolean) -> Unit) {
        if (closed.get() || data.isEmpty() || data.size > 4 * 1024 * 1024) {
            done(false)
            return
        }
        while (true) {
            val count = admitted.get()
            if (count >= 3) {
                failed = true
                done(false)
                return
            }
            if (admitted.compareAndSet(count, count + 1)) {
                while (true) {
                    val peak = peakPending.get()
                    if (peak >= count + 1 || peakPending.compareAndSet(peak, count + 1)) break
                }
                break
            }
        }
        val ticket = tickets.incrementAndGet()
        val completed = AtomicBoolean(false)
        val finish: (Boolean) -> Unit = { success ->
            if (completed.compareAndSet(false, true)) {
                active.remove(ticket)
                admitted.decrementAndGet()
                main.post { done(success) }
            }
        }
        active[ticket] = finish
        if (!handler.post {
            if (closed.get()) {
                finish(false)
            } else {
                try {
                    val units = annexBUnits(data)
                    val newSps = units.firstOrNull { it.isNotEmpty() && it[0].toInt() and 0x1f == 7 }
                    val newPps = units.firstOrNull { it.isNotEmpty() && it[0].toInt() and 0x1f == 8 }
                    if (newSps != null && newPps != null &&
                        (codec == null || failed || !newSps.contentEquals(sps) || !newPps.contentEquals(pps))
                    ) start(newSps, newPps)
                    if (codec == null || failed) {
                        finish(false)
                    } else {
                        pts += 33_333
                        inFlight[pts] = finish
                        pending.addLast(Input(pts, data, keyframe))
                        feed()
                    }
                } catch (_: Exception) {
                    finish(false)
                    failCodec()
                }
            }
        }) finish(false)
    }

    private fun start(sps: ByteArray, pps: ByteArray) {
        stopCodec()
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        format.setByteBuffer("csd-0", ByteBuffer.wrap(START_CODE + sps))
        format.setByteBuffer("csd-1", ByteBuffer.wrap(START_CODE + pps))
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4 * 1024 * 1024)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        format.setInteger(MediaFormat.KEY_PRIORITY, 0)
        val created = MediaCodec.createByCodecName(codecName)
        // Assign before configure/start so every failure is torn down too.
        codec = created
        created.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                if (codec != this@H264Surface.codec || closed.get()) return
                freeInputs.addLast(index)
                feed()
            }
            override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                if (codec != this@H264Surface.codec || closed.get()) return
                val completion = inFlight.remove(info.presentationTimeUs)
                try {
                    codec.releaseOutputBuffer(index, completion != null)
                    if (completion != null) {
                        decoded++
                        completion(true)
                    }
                } catch (_: IllegalStateException) {
                    completion?.invoke(false)
                    failCodec()
                }
            }
            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                // An error from a retired codec must not poison its replacement.
                if (codec == this@H264Surface.codec) failCodec()
            }
            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {}
        }, handler)
        created.configure(format, surface, null, 0)
        created.start()
        this.sps = sps
        this.pps = pps
        failed = false
    }

    private fun feed() {
        val current = codec ?: return
        if (failed || closed.get()) return
        while (freeInputs.isNotEmpty() && pending.isNotEmpty()) {
            val index = freeInputs.removeFirst()
            val frame = pending.removeFirst()
            try {
                val buffer = current.getInputBuffer(index)
                if (buffer == null || buffer.capacity() < frame.bytes.size) {
                    failCodec()
                    return
                }
                buffer.clear()
                buffer.put(frame.bytes)
                current.queueInputBuffer(index, 0, frame.bytes.size, frame.pts,
                    if (frame.keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            } catch (_: IllegalStateException) {
                failCodec()
                return
            }
        }
    }

    private fun failCodec() {
        failed = true
        stopCodec()
    }

    private fun stopCodec() {
        val old = codec
        codec = null
        freeInputs.clear()
        pending.clear()
        val callbacks = inFlight.values.toList()
        inFlight.clear()
        callbacks.forEach { it(false) }
        if (old != null) {
            try { old.stop() } catch (_: IllegalStateException) {}
            try { old.release() } catch (_: IllegalStateException) {}
        }
    }

    fun release() {
        if (!closed.compareAndSet(false, true)) return
        // Callers can leave even when a hardware driver stalls the worker.
        active.values.toList().forEach { it(false) }
        handler.post {
            stopCodec()
            surface.release()
            main.post { entry.release() }
            thread.quitSafely()
        }
    }
}
