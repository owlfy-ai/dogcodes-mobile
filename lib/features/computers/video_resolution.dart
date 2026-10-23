import 'dart:math' as math;
import 'remote_view.dart';

/// One frozen width request per video instance. Superseding desired widths
/// stay local until the current request is applied; native work cannot be
/// starved by a continuous pinch or by repeated heartbeat requests.
class VideoResolution {
  String? instance;
  int applied = 0, _next = 0, target = 0, limit = 1920;
  Map<String, dynamic>? _pending;
  int? _desired;
  Duration? _lastSent;

  bool get supported => instance != null;
  bool get inFlight => _pending != null;
  void reset() {
    instance = null;
    applied = _next = target = 0;
    _pending = null;
    _desired = null;
    _lastSent = null;
    limit = 1920;
  }

  void start(Map video) {
    reset();
    final resize = video['resize'];
    if (resize is! Map || resize['instanceId'] is! String) return;
    instance = resize['instanceId'] as String;
    applied = int.tryParse('${resize['applied']}') ?? 0;
    _next = math.max(applied, int.tryParse('${resize['requested']}') ?? 0);
    target =
        (resize['targetWidth'] as num?)?.toInt() ??
        (video['width'] as num?)?.toInt() ??
        960;
    limit = ((resize['maxWidth'] as num?)?.toInt() ?? 1920).clamp(320, 1920);
  }

  int widthFor(RemoteViewport viewport, double density) {
    final pixels = viewport.rect.width * density;
    return ((pixels / 160).ceil() * 160).clamp(320, limit);
  }

  void want(int width) => _desired = width.clamp(320, limit);
  Map<String, dynamic> request(Duration now) {
    if (!supported) return const {};
    if (_pending != null) return Map.of(_pending!);
    final width = _desired;
    if (width == null || width == target) return const {};
    if (_lastSent != null && now - _lastSent! < const Duration(seconds: 2)) {
      return const {};
    }
    // Small layout rounding changes should not rebuild a codec.
    if (width > target && width < target * 1.15) return const {};
    if (width < target && width > target * .75) return const {};
    _lastSent = now;
    _pending = {
      'videoInstance': instance,
      'viewRequest': '${++_next}',
      'targetWidth': width,
    };
    return Map.of(_pending!);
  }

  bool newer(Map video) {
    final resize = video['resize'];
    return resize is Map &&
        resize['instanceId'] == instance &&
        (int.tryParse('${resize['applied']}') ?? -1) > applied;
  }

  void accept(Map video) {
    if (!newer(video)) return;
    final resize = video['resize'] as Map;
    applied = int.parse('${resize['applied']}');
    target = (resize['targetWidth'] as num).toInt();
    if (_pending != null &&
        applied >= int.parse(_pending!['viewRequest'] as String)) {
      _pending = null;
    }
  }
}
