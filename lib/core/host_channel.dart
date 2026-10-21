import 'protocol.dart';

/// Implement only after key-pinned E2E handshake and host authorization.
/// Relay tickets are not device identity. Never adapt the loopback daemon token.
abstract interface class AuthenticatedHostChannel {
  String get hostId;
  Future<Map<String, dynamic>> request(Map<String, dynamic> envelope);
  Stream<Map<String, dynamic>> get events;
  Future<void> close();
}

class HostRequest {
  HostRequest({
    required this.requestId,
    required this.hostId,
    required this.method,
    required this.params,
    this.operationId,
    this.mutating = false,
  }) {
    if ([requestId, hostId, method].any((s) => s.isEmpty) ||
        (mutating && (operationId == null || operationId!.isEmpty))) {
      throw const ProtocolException('写操作必须保留原始操作标识。');
    }
  }
  final String requestId;
  final String hostId;
  final String method;
  final Map<String, dynamic> params;
  final String? operationId;
  final bool mutating;

  Map<String, dynamic> toJson() => {
    'version': protocolVersion,
    'type': 'request',
    'requestId': requestId,
    'hostId': hostId,
    'method': method,
    'params': params,
    if (operationId != null) 'operationId': operationId,
  };
}
