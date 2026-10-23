import 'dart:ui';

/// Reconciles immediate finger feedback with the PC pointer. macOS video
/// embeds its pointer; software video/JPEG need a separate overlay. Legacy
/// video PCs only encoded on macOS, so omitted metadata means embedded.
class RemoteCursor {
  static const predictionWindow = Duration(milliseconds: 400);
  bool embedded = false;
  Offset? _position;
  DateTime? _localAt;

  void configure({Map? video}) {
    embedded = video != null && video['cursorEmbedded'] != false;
    _position = null;
    _localAt = null;
  }

  void move(Offset position, DateTime now) {
    _position = position;
    _localAt = now;
  }

  bool _predicting(DateTime now) {
    final local = _localAt;
    if (local == null) return false;
    final elapsed = now.difference(local);
    return !elapsed.isNegative && elapsed < predictionWindow;
  }

  Offset? position(DateTime now) =>
      embedded && !_predicting(now) ? null : _position;

  void expirePrediction() {
    if (!embedded) return;
    _position = null;
    _localAt = null;
  }

  void update(Map message, DateTime now) {
    if (embedded || _predicting(now) || !message.containsKey('cursor')) return;
    final cursor = message['cursor'];
    final x = cursor is Map ? cursor['x'] : null;
    final y = cursor is Map ? cursor['y'] : null;
    _position =
        x is num &&
            y is num &&
            x.isFinite &&
            y.isFinite &&
            x >= 0 &&
            y >= 0 &&
            x <= 65535 &&
            y <= 65535
        ? Offset(x / 65535, y / 65535)
        : null;
  }
}
