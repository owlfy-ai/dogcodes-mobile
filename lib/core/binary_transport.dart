import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Each message is one Noise packet. Implementations must preserve order and
/// bound their native send queue. Identity/authentication belongs to Noise.
abstract interface class BinaryTransport {
  Stream<List<int>> get messages;
  Future<void> send(Uint8List packet);
  Future<void> close();
}

class WebSocketTransport implements BinaryTransport {
  WebSocketTransport(this.socket);
  final WebSocket socket;
  @override
  Stream<List<int>> get messages => socket.map((message) {
    if (message is! List<int>) throw const FormatException('Binary required');
    return message;
  });
  @override
  Future<void> send(Uint8List packet) async => socket.add(packet);
  @override
  Future<void> close() async {
    socket.pingInterval = null;
    await socket.close().timeout(
      const Duration(seconds: 2),
      onTimeout: () => null,
    );
  }
}
