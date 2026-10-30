import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'protocol.dart';

/// Reassembles the PC's length-prefixed messages from decrypted chunks.
///
/// `[u32 length][JSON]` is a JSON message. With the top bit of the length
/// set, it is binary: `[u32 header length][header JSON][payload]`, returned
/// as the header map plus `payload` (raw bytes, e.g. one H.264 access unit).
/// The PC sends binary messages only for streams this phone asked for.
///
/// Bytes live in one growable buffer consumed from the front, so a large
/// message costs a copy in and a copy out, not one per chunk.
class FrameReader {
  FrameReader({void Function(String id, int offset)? onFragment})
    : _onFragment = onFragment;
  final void Function(String, int)? _onFragment;
  static const maxMessage = 8 * 1024 * 1024;
  static const _binary = 0x80000000;

  final _fragments = <String, _Fragment>{};

  Uint8List _bytes = Uint8List(64 * 1024);
  int _start = 0, _end = 0;

  int get buffered => _end - _start;

  void add(List<int> chunk) {
    if (_end + chunk.length > _bytes.length) {
      final live = _end - _start;
      if (live + chunk.length > _bytes.length) {
        var size = _bytes.length;
        while (size < live + chunk.length) {
          size *= 2;
        }
        final grown = Uint8List(size)..setRange(0, live, _bytes, _start);
        _bytes = grown;
      } else {
        _bytes.setRange(0, live, _bytes, _start);
      }
      _end = live;
      _start = 0;
    }
    _bytes.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  /// Release incomplete messages when the authenticated connection is retired.
  void clear() {
    _fragments.clear();
    _bytes = Uint8List(64 * 1024);
    _start = _end = 0;
  }

  /// The next complete message, or null until more bytes arrive.
  Map<String, dynamic>? next() {
    while (true) {
      final message = _take();
      if (message == null) return null;
      if (message['type'] == 'fragment_cancel') {
        final id = message['id'];
        if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
          throw ProtocolException(tr("消息分片取消标识无效。"));
        }
        _fragments.remove(id);
        continue;
      }
      if (message['type'] != 'fragment') return message;
      final complete = _fragment(message);
      if (complete != null) return complete;
    }
  }

  Map<String, dynamic>? _take() {
    if (buffered < 4) return null;
    final view = ByteData.sublistView(_bytes, _start, _end);
    final word = view.getUint32(0);
    final binary = word & _binary != 0;
    final length = word & ~_binary & 0xffffffff;
    if (length == 0 || length > maxMessage) {
      throw ProtocolException(tr("消息大小超出范围。"));
    }
    if (buffered < length + 4) return null;
    final body = Uint8List.sublistView(_bytes, _start + 4, _start + 4 + length);
    _start += 4 + length;
    if (_start == _end) _start = _end = 0;
    return _decode(body, binary);
  }

  static Map<String, dynamic> _decode(Uint8List body, bool binary) {
    final length = body.length;
    if (!binary) {
      return jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
    }
    if (length < 4) throw ProtocolException(tr("二进制消息格式无效。"));
    final headerLength = ByteData.sublistView(body).getUint32(0);
    if (headerLength > length - 4 || headerLength > 64 * 1024) {
      throw ProtocolException(tr("二进制消息格式无效。"));
    }
    final header =
        jsonDecode(utf8.decode(body.sublist(4, 4 + headerLength)))
            as Map<String, dynamic>;
    // `sublist` copies: the payload outlives this buffer's next refill.
    return {...header, 'payload': body.sublist(4 + headerLength)};
  }

  Map<String, dynamic>? _fragment(Map<String, dynamic> message) {
    final id = message['id'],
        offset = message['offset'],
        total = message['total'],
        payload = message['payload'];
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        offset is! int ||
        offset < 0 ||
        total is! int ||
        total < 5 ||
        total > maxMessage + 4 ||
        payload is! Uint8List ||
        payload.isEmpty ||
        payload.length > 8192 ||
        offset + payload.length > total) {
      throw ProtocolException(tr("消息分片格式无效。"));
    }
    var fragment = _fragments[id];
    if (fragment == null) {
      // One large control response may pass an incomplete video. A third
      // simultaneous assembly is never produced by the PC scheduler.
      if (offset != 0 || _fragments.length >= 2) {
        throw ProtocolException(tr("消息分片顺序或数量无效。"));
      }
      fragment = _Fragment(total);
      _fragments[id] = fragment;
    }
    if (fragment.bytes.length != total || fragment.received != offset) {
      throw ProtocolException(tr("消息分片不连续。"));
    }
    fragment.bytes.setRange(offset, offset + payload.length, payload);
    fragment.received += payload.length;
    if (fragment.received != total) {
      _onFragment?.call(id, fragment.received);
      return null;
    }
    _fragments.remove(id);
    final word = ByteData.sublistView(fragment.bytes).getUint32(0);
    final length = word & ~_binary & 0xffffffff;
    if (length != total - 4 || length > maxMessage || length == 0) {
      throw ProtocolException(tr("消息分片长度无效。"));
    }
    final result = _decode(
      Uint8List.sublistView(fragment.bytes, 4),
      word & _binary != 0,
    );
    if (result['type'] == 'fragment') {
      throw ProtocolException(tr("不允许嵌套消息分片。"));
    }
    _onFragment?.call(id, total);
    return result;
  }
}

class _Fragment {
  _Fragment(int length) : bytes = Uint8List(length);
  final Uint8List bytes;
  int received = 0;
}
