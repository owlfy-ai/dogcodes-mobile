import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../core/host_api.dart';
import '../../core/pc_api.dart';

/// Loopback-only HTTP/WebSocket server on the phone that forwards the
/// in-app WebView's requests to the PC dev server through the encrypted
/// channel. Nothing listens beyond 127.0.0.1 and it stops with the page.
class PreviewProxy {
  PreviewProxy(this.link, this.previewId);
  final HostLink link;
  final String previewId;
  HttpServer? _server;
  bool _stopped = false;
  Future<void>? _stopping;
  final _sockets = <WebSocket>{};

  int get port => _server!.port;

  static const _hopByHop = {
    'host',
    'connection',
    'upgrade',
    'keep-alive',
    'transfer-encoding',
    'te',
    'trailer',
    'content-length',
    'proxy-authorization',
    'proxy-authenticate',
    'accept-encoding',
  };

  Future<void> start() async {
    if (_stopped) throw StateError('预览已关闭');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_stopped) {
      await server.close(force: true);
      throw StateError('预览已关闭');
    }
    _server = server;
    server.listen(_handle, onError: (Object _) {});
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.hasQuery
        ? '${request.uri.path}?${request.uri.query}'
        : request.uri.path;
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      return _socket(request, path);
    }
    final response = request.response;
    try {
      if (_stopped) {
        response.statusCode = HttpStatus.serviceUnavailable;
        return;
      }
      final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
      if (_stopped) return;
      final headers = <String, String>{};
      request.headers.forEach((name, values) {
        if (!_hopByHop.contains(name.toLowerCase())) {
          headers[name] = values.join(', ');
        }
      });
      final r = await link.previewHttp(
        previewId,
        path,
        method: request.method,
        headers: headers,
        body: body,
      );
      response.statusCode = (r['status'] as num?)?.toInt() ?? 502;
      for (final h in (r['headers'] as List? ?? const [])) {
        final name = '${(h as List)[0]}';
        final lower = name.toLowerCase();
        if (_hopByHop.contains(lower) || lower == 'content-encoding') continue;
        response.headers.add(name, '${h[1]}', preserveHeaderCase: true);
      }
      final bytes = base64.decode('${r['body'] ?? ''}');
      response.contentLength = bytes.length;
      response.add(bytes);
    } catch (e) {
      try {
        response.statusCode = HttpStatus.badGateway;
        response.headers.contentType = ContentType.html;
        response.write(
          '<meta name="viewport" content="width=device-width">'
          '<p style="font-family:sans-serif;padding:16px">预览请求失败：${const HtmlEscape().convert('$e')}</p>',
        );
      } catch (_) {
        // The WebView or page may already have closed this response.
      }
    } finally {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> _socket(HttpRequest request, String path) async {
    final protocols =
        request.headers['sec-websocket-protocol']
            ?.expand((v) => v.split(','))
            .map((v) => v.trim())
            .where((v) => v.isNotEmpty)
            .toList() ??
        const <String>[];
    String? id;
    WebSocket? local;
    var open = true;
    Future<void>? retiring;
    Future<void> retire() {
      open = false;
      return retiring ??= () async {
        final socket = local;
        if (socket != null) {
          _sockets.remove(socket);
          unawaited(socket.close().catchError((Object _) {}));
        }
        final remote = id;
        if (remote != null) {
          try {
            await link.call('preview_ws_close', remote);
          } catch (_) {}
        }
      }();
    }

    try {
      if (_stopped) throw StateError('预览已关闭');
      final opened = Map<String, dynamic>.from(
        await link.call('preview_ws_open', {
              'previewId': previewId,
              'path': path,
              'protocols': protocols,
            })
            as Map,
      );
      id = opened['socketId'] as String;
      if (_stopped) throw StateError('预览已关闭');
      final protocol = opened['protocol'] as String?;
      final socket = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: protocol == null ? null : (_) => protocol,
      );
      local = socket;
      if (_stopped) return;
      _sockets.add(socket);
      var sequence = 0;
      // Stream.asyncMap pauses delivery until this frame's RPC completes.
      // A lost reply closes this stream; neither this frame nor queued later
      // messages are replayed on another connection.
      socket
          .asyncMap((data) async {
            if (!open || _stopped) return;
            sequence++;
            try {
              final reply = await link.call('preview_ws_write', {
                'socketId': id,
                'sequence': '$sequence',
                'text': data is String ? data : null,
                'bytes': data is List<int> ? base64.encode(data) : null,
              });
              if (reply is! Map || reply['sequence'] != '$sequence') {
                throw StateError('项目 WebSocket 写入未获确认');
              }
            } catch (_) {
              await retire();
            }
          })
          .listen(
            (_) {},
            onDone: () => unawaited(retire()),
            onError: (Object _) => unawaited(retire()),
          );
      // Reading proceeds independently while outgoing frames stay ordered.
      while (open && !_stopped) {
        final m = await link.call('preview_ws_read', id) as Map;
        if (!open || _stopped) break;
        switch (m['type']) {
          case 'text':
            socket.add(m['text'] as String);
          case 'binary':
            socket.add(base64.decode(m['bytes'] as String));
          case 'closed':
            return;
        }
      }
    } catch (_) {
      if (local == null) {
        try {
          request.response.statusCode = HttpStatus.badGateway;
          await request.response.close();
        } catch (_) {}
      }
    } finally {
      await retire();
    }
  }

  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    _stopped = true;
    for (final socket in _sockets.toList()) {
      unawaited(socket.close().catchError((Object _) {}));
    }
    _sockets.clear();
    final server = _server;
    _server = null;
    try {
      await server?.close(force: true);
    } finally {
      try {
        await link.previewClose(previewId);
      } catch (_) {}
    }
  }
}
