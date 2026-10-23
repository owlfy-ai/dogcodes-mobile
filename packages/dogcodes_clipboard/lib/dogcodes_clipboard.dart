import 'dart:math';
import 'package:flutter/services.dart';

/// Access is only requested by a foreground user action, never by a listener.
/// The OS owns paste permission and may prompt or refuse access.
class ImageClipboard {
  static const _channel = MethodChannel('dogcodes/clipboard');
  static const maxImageBytes = 16 * 1024 * 1024;
  static final _random = Random.secure();

  static Future<Uint8List?> readPng() =>
      _channel.invokeMethod<Uint8List>('readPng');

  static ImageClipboardWrite beginWrite(Uint8List png) {
    if (png.isEmpty || png.length > maxImageBytes) {
      throw ArgumentError('剪贴板图片需小于 16 MB');
    }
    final id =
        '${DateTime.now().microsecondsSinceEpoch}-'
        '${_random.nextInt(1 << 32)}-${_random.nextInt(1 << 32)}';
    return ImageClipboardWrite._(
      id,
      _channel.invokeMethod<void>('writePng', {'id': id, 'png': png}),
    );
  }

  static Future<void> writePng(Uint8List png) => beginWrite(png).done;
}

/// Cancellation is allowed in the background and is acknowledged on the native
/// main thread. True means it removed a pending write before the clipboard was
/// changed. False means it already ended; it never undoes a completed copy.
class ImageClipboardWrite {
  ImageClipboardWrite._(this.id, this.done);
  final String id;
  final Future<void> done;
  Future<bool> cancel() async =>
      await ImageClipboard._channel.invokeMethod<bool>('cancelWrite', {
        'id': id,
      }) ??
      false;
}
