import 'dart:async';
import 'package:flutter/services.dart';

/// Decodes an H.264 stream (Annex-B access units, as the PC sends them) in
/// hardware and shows it as a Flutter texture: VideoToolbox on iOS,
/// MediaCodec on Android. Used for remote desktop when only the relay
/// reaches the PC; on a WebRTC connection the stream decodes inside WebRTC.
class H264Decoder {
  H264Decoder._(this.textureId);

  static const _channel = MethodChannel('dogcodes/h264');

  /// The texture to show with `Texture(textureId: ...)`.
  final int textureId;
  bool _disposed = false;
  final _pending = <Completer<void>, Timer>{};

  /// A decoder for a stream of [width]×[height] pixels, or null where this
  /// platform has none (desktop, tests).
  static Future<H264Decoder?> create({
    required int width,
    required int height,
  }) async {
    try {
      final id = await _channel.invokeMethod<int>('create', {
        'width': width,
        'height': height,
      });
      return id == null ? null : H264Decoder._(id);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Completes when this access unit has produced decoder output. Throws
  /// [NeedKeyframe] when the decoder cannot
  /// continue from this frame (no keyframe yet, or a decode error): drop
  /// frames and ask the PC for an IDR.
  Future<void> decode(Uint8List accessUnit, {required bool keyframe}) async {
    if (_disposed) return;
    final completion = Completer<void>();
    void finish([Object? error, StackTrace? trace]) {
      _pending.remove(completion)?.cancel();
      if (completion.isCompleted) return;
      if (error == null) {
        completion.complete();
      } else {
        completion.completeError(error, trace);
      }
    }

    _pending[completion] = Timer(
      const Duration(seconds: 3),
      () => finish(const NeedKeyframe()),
    );
    unawaited(
      _channel
          .invokeMethod<void>('decode', {
            'id': textureId,
            'data': accessUnit,
            'keyframe': keyframe,
          })
          .then<void>(
            (_) => finish(),
            onError: (Object error, StackTrace trace) {
              finish(
                error is PlatformException && error.code == 'needKeyframe'
                    ? const NeedKeyframe()
                    : error,
                trace,
              );
            },
          ),
    );
    await completion.future;
  }

  /// Frames the platform decoder has output so far.
  Future<int> decodedFrames() async {
    final value = await stats();
    return (value['decoded'] as num?)?.toInt() ?? 0;
  }

  /// Native output and bounded admission counters, useful for diagnostics.
  Future<Map<String, dynamic>> stats() async {
    return await _channel.invokeMapMethod<String, dynamic>('stats', {
          'id': textureId,
        }) ??
        <String, dynamic>{};
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final abandoned = Map.of(_pending);
    _pending.clear();
    for (final entry in abandoned.entries) {
      entry.value.cancel();
      if (!entry.key.isCompleted) entry.key.completeError(const NeedKeyframe());
    }
    try {
      await _channel.invokeMethod<void>('dispose', {'id': textureId});
    } on PlatformException {
      // Already gone with its engine.
    }
  }
}

class NeedKeyframe implements Exception {
  const NeedKeyframe();
  @override
  String toString() => '需要关键帧';
}
