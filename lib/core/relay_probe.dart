import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'protocol.dart';

/// Transport probe only: this does not authenticate a PC or encrypt payloads.
/// It must never be used as an AuthenticatedHostChannel.
class RelayProbe {
  RelayProbe._(this._socket) {
    // Always drain control frames, including when no payload consumer exists.
    _subscription = _socket.listen(
      (message) {
        if (message is! List<int> ||
            message.isEmpty ||
            message.length > maxFrameBytes ||
            !_frames.hasListener) {
          unawaited(close());
          return;
        }
        _frames.add(Uint8List.fromList(message));
      },
      onError: (Object error, StackTrace stack) {
        if (_frames.hasListener) {
          _frames.addError(const ProtocolException('中继连接中断，操作结果需要核实。'), stack);
        }
      },
      onDone: () {
        if (!_closed.isCompleted) {
          _closed.complete();
        }
        unawaited(_frames.close());
      },
    );
  }
  final WebSocket _socket;
  final _closed = Completer<void>();
  final _frames = StreamController<Uint8List>.broadcast();
  late final StreamSubscription<dynamic> _subscription;
  Future<void>? _closing;

  static Future<RelayProbe> connect(
    Uri origin,
    String sessionId,
    String ticket,
  ) async {
    if (!['127.0.0.1', 'localhost', '::1'].contains(origin.host) ||
        origin.scheme != 'ws' ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        (origin.path.isNotEmpty && origin.path != '/') ||
        !RegExp(r'^[a-zA-Z0-9-]{1,128}$').hasMatch(sessionId)) {
      throw const ProtocolException('中继探针仅供本地开发使用。');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final socket = await WebSocket.connect(
        origin.resolve('/v1/relay/$sessionId').toString(),
        headers: {'Authorization': 'Bearer $ticket'},
        customClient: client,
      ).timeout(const Duration(seconds: 8));
      socket.pingInterval = const Duration(seconds: 20);
      return RelayProbe._(socket);
    } finally {
      // WebSocket owns its detached socket; release the HTTP handshake pool.
      client.close(force: true);
    }
  }

  /// Subscribe before the peer sends data. An absent consumer closes the probe.
  Stream<Uint8List> get frames => _frames.stream;
  void send(Uint8List payload) {
    if (payload.isEmpty || payload.length > maxFrameBytes) {
      throw const ProtocolException('数据帧大小超出范围。');
    }
    if (_socket.readyState != WebSocket.open) {
      throw const ProtocolException('连接已关闭；操作结果需要核实。');
    }
    _socket.add(payload);
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _socket.pingInterval = null;
    try {
      await _socket.close(WebSocketStatus.normalClosure);
      await _closed.future.timeout(const Duration(seconds: 6));
    } finally {
      await _subscription.cancel();
      await _frames.close();
    }
  }
}
