/// One reading of the screen track's WebRTC statistics.
class VideoStatsSample {
  const VideoStatsSample({
    required this.at,
    required this.bytes,
    required this.framesDecoded,
    required this.packetsLost,
    this.fps,
    this.rttMs,
    this.width,
    this.height,
  });
  final DateTime at;
  final int bytes, framesDecoded, packetsLost;
  final double? fps, rttMs;
  final int? width, height;

  /// Receive rate since [previous], KB/s.
  double kbps(VideoStatsSample? previous) {
    if (previous == null) return 0;
    final seconds = at.difference(previous.at).inMilliseconds / 1000;
    if (seconds <= 0) return 0;
    return (bytes - previous.bytes).clamp(0, 1 << 40) / 1024 / seconds;
  }

  /// Frames decoded per second since [previous], when the platform does not
  /// report `framesPerSecond` itself.
  double decodedFps(VideoStatsSample? previous) {
    if (fps != null) return fps!;
    if (previous == null) return 0;
    final seconds = at.difference(previous.at).inMilliseconds / 1000;
    if (seconds <= 0) return 0;
    return (framesDecoded - previous.framesDecoded).clamp(0, 1 << 30) / seconds;
  }
}

num? _num(Object? v) => v is num ? v : num.tryParse('$v');

/// Picks the inbound video stream and the selected candidate pair out of a
/// `getStats()` report (as type + values pairs, which is what flutter_webrtc
/// hands back on every platform).
VideoStatsSample? parseVideoStats(
  Iterable<(String type, Map<dynamic, dynamic> values)> reports,
  DateTime at,
) {
  Map<dynamic, dynamic>? inbound;
  double? rtt;
  for (final (type, values) in reports) {
    if (type == 'inbound-rtp' &&
        (values['kind'] == 'video' || values['mediaType'] == 'video')) {
      inbound = values;
    } else if (type == 'candidate-pair' &&
        (values['nominated'] == true || values['nominated'] == 'true') &&
        values['state'] == 'succeeded') {
      final seconds = _num(values['currentRoundTripTime']);
      if (seconds != null) rtt = seconds * 1000;
    }
  }
  if (inbound == null) return null;
  return VideoStatsSample(
    at: at,
    bytes: _num(inbound['bytesReceived'])?.toInt() ?? 0,
    framesDecoded: _num(inbound['framesDecoded'])?.toInt() ?? 0,
    packetsLost: _num(inbound['packetsLost'])?.toInt() ?? 0,
    fps: _num(inbound['framesPerSecond'])?.toDouble(),
    rttMs: rtt,
    width: _num(inbound['frameWidth'])?.toInt(),
    height: _num(inbound['frameHeight'])?.toInt(),
  );
}
