import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'adaptive_host_link.dart';
import 'host_api.dart';
import 'owned_resource.dart';
import 'protocol.dart';

enum ClipboardKind {
  text('text/plain;charset=utf-8', 1024 * 1024),
  image('image/png', 16 * 1024 * 1024);

  const ClipboardKind(this.mime, this.maxBytes);
  final String mime;
  final int maxBytes;
}

class _ClipboardResponseInvalid extends ProtocolException {
  const _ClipboardResponseInvalid(super.message);
}

class ClipboardCancelled implements Exception {
  const ClipboardCancelled();
}

/// A transfer owns a physical authenticated connection, separate from the
/// video/input lease and the business link. A route is chosen before staging;
/// it cannot migrate a connection-bound transfer or replay a clipboard write.
Future<HostLink> openClipboardLink(
  AdaptiveHostLink business, {
  required bool Function() current,
}) async {
  final relay = await ownedResource<HostLink>(
    create: business.relayDialer,
    current: current,
    release: (v) => v.close(),
    timeout: const Duration(seconds: 12),
  );
  try {
    final caps = await relay.call('remote_capabilities', null);
    if (!current()) throw const ClipboardCancelled();
    if (caps is Map &&
        (caps['transportMethods'] as List? ?? []).contains('direct_open')) {
      try {
        final direct = await ownedResource<DirectConnection>(
          create: () => business.directDialer(relay),
          current: current,
          release: (v) => v.link.close(),
          timeout: const Duration(seconds: 12),
        );
        try {
          await relay.close().timeout(const Duration(seconds: 3));
        } catch (_) {
          // A failed signalling close must not leak the valid direct link.
        }
        if (!current()) {
          await direct.link.close();
          throw const ClipboardCancelled();
        }
        return direct.link;
      } on ClipboardCancelled {
        rethrow;
      } catch (_) {
        if (!current()) throw const ClipboardCancelled();
        // Failed ICE/TURN leaves this transfer on its own authenticated relay.
      }
    }
    return relay;
  } catch (_) {
    unawaited(relay.close().catchError((Object _) {}));
    rethrow;
  }
}

/// One foreground user action. Small sequential chunks bound upstream send
/// queues, including when WebRTC is using TURN. A lost commit reply is checked
/// once with a read-only status request; the commit is never automatically sent
/// again. No clipboard payload is put into drafts, offline cache or server logs.
class ClipboardTransfer {
  ClipboardTransfer(this.link, {required this.current, this.onProgress});
  static const chunkBytes = 32 * 1024;
  final HostApi link;
  final bool Function() current;
  final void Function(int done, int total)? onProgress;
  bool _cancelled = false;
  bool mayHaveWritten = false;
  String? _id;
  DateTime _progressAt = DateTime(0);

  void _progress(int done, int total) {
    final now = DateTime.now();
    if (done == total || now.difference(_progressAt).inMilliseconds >= 100) {
      _progressAt = now;
      onProgress?.call(done, total);
    }
  }

  void cancel() => _cancelled = true;
  void _check() {
    if (_cancelled || !current()) throw const ClipboardCancelled();
  }

  Future<Map<String, dynamic>> _call(
    String op, [
    Map<String, dynamic>? args,
  ]) async {
    _check();
    final result = await link.call('clipboard_transfer', {
      'operation': op,
      if (_id != null) 'transferId': _id,
      ...?args,
    });
    if (result is! Map) throw const _ClipboardResponseInvalid('剪贴板传输响应无效');
    // Save even a late begin response so finally can close its orphaned buffer.
    if (op.startsWith('begin_') && result['transferId'] is String) {
      _id = result['transferId'] as String;
    }
    _check();
    if (result['transferId'] != _id) {
      throw const _ClipboardResponseInvalid('剪贴板传输身份不匹配');
    }
    return Map<String, dynamic>.from(result);
  }

  void _manifest(
    Map<String, dynamic> m,
    ClipboardKind kind, {
    int? size,
    String? hash,
    required String direction,
    required String state,
  }) {
    final n = m['size'];
    if (_id == null ||
        _id!.isEmpty ||
        _id!.length > 128 ||
        n is! int ||
        n <= 0 ||
        n > kind.maxBytes ||
        m['kind'] != kind.name ||
        m['mimeType'] != kind.mime ||
        m['direction'] != direction ||
        m['state'] != state ||
        m['sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(m['sha256'] as String) ||
        (size != null && n != size) ||
        (hash != null && m['sha256'] != hash) ||
        m['chunkBytes'] is! int ||
        (m['chunkBytes'] as int) < 1 ||
        (m['chunkBytes'] as int) > chunkBytes) {
      throw const ProtocolException('剪贴板传输校验信息不匹配');
    }
  }

  Future<void> send(Uint8List bytes, ClipboardKind kind) async {
    if (bytes.isEmpty || bytes.length > kind.maxBytes) {
      throw ProtocolException(
        kind == ClipboardKind.image
            ? '图片需小于 16 MB，请缩小图片后重试'
            : '剪贴板文字为空或超过 1 MB',
      );
    }
    final hash = await _hash(bytes);
    try {
      final m = await _call('begin_upload', {
        'kind': kind.name,
        'mimeType': kind.mime,
        'size': bytes.length,
        'sha256': hash,
      });
      _manifest(
        m,
        kind,
        size: bytes.length,
        hash: hash,
        direction: 'upload',
        state: 'staging',
      );
      if (m['offset'] != 0) throw const ProtocolException('图片传输起始位置无效');
      final chunk = m['chunkBytes'] as int;
      for (var offset = 0; offset < bytes.length;) {
        final end = min(offset + chunk, bytes.length);
        final reply = await _call('append', {
          'offset': offset,
          'bytes': base64Encode(Uint8List.sublistView(bytes, offset, end)),
        });
        if (reply['offset'] != end) throw const ProtocolException('剪贴板上传位置不匹配');
        offset = end;
        _progress(offset, bytes.length);
      }
      Map<String, dynamic> receipt;
      try {
        mayHaveWritten = true;
        receipt = await _call('commit');
      } catch (e) {
        if (e is _ClipboardResponseInvalid) rethrow;
        _check();
        try {
          receipt = await _call('status');
        } catch (_) {
          _check();
          throw const ProtocolException('尚未确认电脑剪贴板是否更新，请从电脑获取核实；不会自动重发');
        }
        if (receipt['state'] != 'applied') {
          throw const ProtocolException('未确认电脑剪贴板已更新，请从电脑获取核实；不会自动重发');
        }
      }
      _manifest(
        receipt,
        kind,
        size: bytes.length,
        hash: hash,
        direction: 'upload',
        state: 'applied',
      );
      if (receipt['offset'] != bytes.length) {
        throw const ProtocolException('剪贴板写入回执不完整，请从电脑获取核实');
      }
    } finally {
      await close();
    }
  }

  Future<Uint8List> receive(ClipboardKind kind) async {
    try {
      final m = await _call('begin_download', {'kind': kind.name});
      _manifest(m, kind, direction: 'download', state: 'ready');
      final size = m['size'] as int;
      final bytes = Uint8List(size);
      for (var offset = 0; offset < size;) {
        final r = await _call('read', {'offset': offset});
        final encoded = r['bytes'];
        if (encoded is! String ||
            encoded.length > ((chunkBytes + 2) ~/ 3) * 4) {
          throw const ProtocolException('剪贴板下载数据块过大');
        }
        final b = base64Decode(encoded);
        final end = offset + b.length;
        if (r['offset'] != offset ||
            b.isEmpty ||
            b.length > (m['chunkBytes'] as int) ||
            end > size ||
            r['nextOffset'] != end) {
          throw const ProtocolException('剪贴板下载位置不匹配');
        }
        bytes.setRange(offset, end, b);
        offset = end;
        _progress(offset, size);
      }
      if (await _hash(bytes) != m['sha256']) {
        throw const ProtocolException('剪贴板内容校验失败，未写入手机剪贴板');
      }
      _check();
      return bytes;
    } finally {
      await close();
    }
  }

  Future<void> close() async {
    final id = _id;
    _id = null;
    if (id != null) {
      try {
        await link
            .call('clipboard_transfer', {
              'operation': 'close',
              'transferId': id,
            })
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        /* A disconnect/idle expiry also releases the PC buffer. */
      }
    }
  }
}

String _digest(Uint8List bytes) => sha256.convert(bytes).toString();
Future<String> _hash(Uint8List bytes) async =>
    bytes.length > 128 * 1024 ? compute(_digest, bytes) : _digest(bytes);
