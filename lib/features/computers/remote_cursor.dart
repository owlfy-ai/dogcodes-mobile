import 'dart:ui';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Reconciles immediate finger feedback with the PC pointer. Each source
/// reports whether its pixels already include the pointer, including JPEG.
class RemoteCursor {
  static const predictionWindow = Duration(milliseconds: 400);
  bool? embedded = false;
  bool get predictionOnly => embedded != false;
  Offset? _position;
  DateTime? _localAt;
  RemoteCursorShape? _shape;
  RemoteCursorShape? get shape => _shape;
  String? get shapeId => _shape?.id;

  void configure({Map? video}) {
    embedded =
        video != null &&
            video.containsKey('cursorEmbedded') &&
            video['cursorEmbedded'] == null
        ? null
        : video?['cursorEmbedded'] == true;
    _position = null;
    _localAt = null;
    _shape = null;
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
      predictionOnly && !_predicting(now) ? null : _position;

  void expirePrediction() {
    if (!predictionOnly) return;
    _position = null;
    _localAt = null;
  }

  void update(Map message, DateTime now) {
    final video = message['video'];
    final mode =
        message['cursorEmbedded'] ??
        (video is Map ? video['cursorEmbedded'] : null);
    final hasMode =
        message.containsKey('cursorEmbedded') ||
        (video is Map && video.containsKey('cursorEmbedded'));
    if (hasMode && (mode is bool || mode == null) && mode != embedded) {
      // A source transition must not keep an old overlay or prediction. This
      // metadata also arrives on unchanged JPEGs without image bytes.
      embedded = mode;
      _position = null;
      _localAt = null;
      _shape = null;
    }
    final cursor = message['cursor'];
    if (embedded == false && cursor is Map) {
      _shape = RemoteCursorShape.read(cursor, _shape);
    }
    if (predictionOnly || _predicting(now) || !message.containsKey('cursor')) {
      return;
    }
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

/// One bounded current shape; pixels are sent again if this cache is cleared.
class RemoteCursorShape {
  RemoteCursorShape._(
    this.id,
    this.bytes,
    this.size,
    this.hotspot,
    this.display,
  );
  final String id;
  final Uint8List bytes;
  final Size size, display;
  final Offset hotspot;
  static const maxBytes = 128 * 1024;

  static RemoteCursorShape? read(Map cursor, RemoteCursorShape? previous) {
    final id = cursor['shapeId'];
    if (id is! String || !RegExp(r'^[0-9a-f]{16}$').hasMatch(id)) return null;
    int? bounded(dynamic value, int min, int max) =>
        value is int && value >= min && value <= max ? value : null;
    final dw = bounded(cursor['displayWidth'], 1, 1000000);
    final dh = bounded(cursor['displayHeight'], 1, 1000000);
    if (dw == null || dh == null) return null;
    final display = Size(dw.toDouble(), dh.toDouble());
    if (previous?.id == id) {
      return RemoteCursorShape._(
        id,
        previous!.bytes,
        previous.size,
        previous.hotspot,
        display,
      );
    }
    final shape = cursor['shape'];
    if (shape is! Map || shape['id'] != id) return null;
    final w = bounded(shape['width'], 1, 512),
        h = bounded(shape['height'], 1, 512);
    if (w == null || h == null) return null;
    final x = bounded(shape['hotX'], 0, w - 1),
        y = bounded(shape['hotY'], 0, h - 1);
    final encoded = shape['bytes'];
    if (x == null ||
        y == null ||
        encoded is! String ||
        encoded.length > ((maxBytes + 2) ~/ 3) * 4) {
      return null;
    }
    try {
      final bytes = base64Decode(encoded);
      if (bytes.length < 33 || bytes.length > maxBytes) return null;
      const signature = [137, 80, 78, 71, 13, 10, 26, 10];
      for (var i = 0; i < signature.length; i++) {
        if (bytes[i] != signature[i]) return null;
      }
      final data = ByteData.sublistView(bytes);
      if (data.getUint32(8) != 13 ||
          data.getUint32(12) != 0x49484452 ||
          data.getUint32(16) != w ||
          data.getUint32(20) != h) {
        return null;
      }
      return RemoteCursorShape._(
        id,
        bytes,
        Size(w.toDouble(), h.toDouble()),
        Offset(x.toDouble(), y.toDouble()),
        display,
      );
    } on FormatException {
      return null;
    }
  }

  Rect rect(Offset tip, Rect screen) {
    // Keep a normal 32px pointer legible when fitting a large desktop, then
    // scale naturally with zoom. The native hotspot remains the click target.
    final scale = math.max(
      0.5,
      math.min(screen.width / display.width, screen.height / display.height),
    );
    return Rect.fromLTWH(
      tip.dx - hotspot.dx * scale,
      tip.dy - hotspot.dy * scale,
      size.width * scale,
      size.height * scale,
    );
  }
}
