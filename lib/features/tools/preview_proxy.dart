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
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle, onError: (Object _) {});
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
      final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
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
      response.statusCode = HttpStatus.badGateway;
      response.headers.contentType = ContentType.html;
      response.write(
        '<meta name="viewport" content="width=device-width">'
        '<p style="font-family:sans-serif;padding:16px">预览请求失败：${const HtmlEscape().convert('$e')}</p>',
      );
    }
    await response.close();
  }

  Future<void> _socket(HttpRequest request, String path) async {
    final protocols =
        request.headers['sec-websocket-protocol']
            ?.expand((v) => v.split(','))
            .map((v) => v.trim())
            .where((v) => v.isNotEmpty)
            .toList() ??
        const <String>[];
    Map<String, dynamic> opened;
    try {
      opened = Map<String, dynamic>.from(
        await link.call('preview_ws_open', {
              'previewId': previewId,
              'path': path,
              'protocols': protocols,
            })
            as Map,
      );
    } catch (_) {
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
      return;
    }
    final id = opened['socketId'] as String;
    final protocol = opened['protocol'] as String?;
    final socket = await WebSocketTransformer.upgrade(
      request,
      protocolSelector: protocol == null ? null : (_) => protocol,
    );
    _sockets.add(socket);
    var sequence = 0;
    var open = true;
    socket.listen(
      (data) async {
        sequence++;
        try {
          await link.call('preview_ws_write', {
            'socketId': id,
            'sequence': '$sequence',
            'text': data is String ? data : null,
            'bytes': data is List<int> ? base64.encode(data) : null,
          });
        } catch (_) {
          await socket.close();
        }
      },
      onDone: () {
        open = false;
        link.call('preview_ws_close', id).catchError((Object _) => null);
        _sockets.remove(socket);
      },
    );
    // Long-poll the PC side until either end closes.
    while (open) {
      try {
        final m = await link.call('preview_ws_read', id) as Map;
        switch (m['type']) {
          case 'text':
            socket.add(m['text'] as String);
          case 'binary':
            socket.add(base64.decode(m['bytes'] as String));
          case 'closed':
            await socket.close();
            open = false;
        }
      } catch (_) {
        await socket.close();
        open = false;
      }
    }
  }

  Future<void> stop() async {
    for (final s in _sockets.toList()) {
      await s.close();
    }
    await _server?.close(force: true);
    await link.previewClose(previewId).catchError((Object _) => null);
  }
}
