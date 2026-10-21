import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import '../protocol.dart';

typedef _CallNative = Pointer<Utf8> Function(Pointer<Uint8>, UintPtr);
typedef _CallDart = Pointer<Utf8> Function(Pointer<Uint8>, int);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class EndpointIdentity {
  EndpointIdentity({required this.secretHex, required this.publicHex}) {
    if (!_isKey(secretHex) || !_isKey(publicHex)) {
      throw const ProtocolException('设备密钥格式无效，不能继续连接。');
    }
  }
  final String secretHex;
  final String publicHex;
  @override
  String toString() => 'EndpointIdentity(<redacted>)';
}

bool _isKey(String input) => RegExp(r'^[0-9a-f]{64}$').hasMatch(input);
String hexBytes(List<int> bytes) =>
    bytes.map((n) => n.toRadixString(16).padLeft(2, '0')).join();
Uint8List fromHex(String input) {
  if (input.length.isOdd || !RegExp(r'^[0-9a-f]*$').hasMatch(input)) {
    throw const ProtocolException('加密数据格式无效。');
  }
  return Uint8List.fromList([
    for (var i = 0; i < input.length; i += 2)
      int.parse(input.substring(i, i + 2), radix: 16),
  ]);
}

/// Uses Snow for both endpoints. The caller loads only a bundled native library.
/// Never load a library path supplied by a QR code or remote service.
class NoiseEndpoint {
  factory NoiseEndpoint.bundled() => NoiseEndpoint(
    Platform.isAndroid
        ? DynamicLibrary.open('libdogcodes_endpoint.so')
        : DynamicLibrary.process(),
  );
  NoiseEndpoint(DynamicLibrary library)
    : _call = library.lookupFunction<_CallNative, _CallDart>(
        'dogcodes_endpoint_call',
      ),
      _free = library.lookupFunction<_FreeNative, _FreeDart>(
        'dogcodes_endpoint_free',
      );
  final _CallDart _call;
  final _FreeDart _free;

  Map<String, dynamic> _invoke(Map<String, dynamic> request) {
    final bytes = utf8.encode(jsonEncode(request));
    final input = calloc<Uint8>(bytes.length);
    Pointer<Utf8>? output;
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      output = _call(input, bytes.length);
      if (output == nullptr) throw const ProtocolException('加密组件暂时不可用。');
      final response =
          jsonDecode(output.toDartString()) as Map<String, dynamic>;
      if (response['ok'] != true) {
        throw const ProtocolException('设备身份验证或加密状态校验失败，请重新连接。');
      }
      return response['value'] as Map<String, dynamic>;
    } finally {
      input.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      bytes.fillRange(0, bytes.length, 0);
      calloc.free(input);
      if (output != null && output != nullptr) _free(output);
    }
  }

  EndpointIdentity createIdentity() {
    final result = _invoke({'op': 'keypair'});
    return EndpointIdentity(
      secretHex: result['secret'] as String,
      publicHex: result['public'] as String,
    );
  }

  NoiseSession session({
    required EndpointIdentity identity,
    required bool initiator,
    required String context,
    String? peerHex,
    String? pairingSecretHex,
  }) {
    final value = _invoke({
      'op': 'new',
      'initiator': initiator,
      'secret': identity.secretHex,
      'peer': peerHex,
      'psk': pairingSecretHex,
      'context': context,
    });
    return NoiseSession._(this, value['handle'] as int);
  }
}

class NoiseSession {
  NoiseSession._(this._endpoint, this._handle);
  final NoiseEndpoint _endpoint;
  int? _handle;
  Map<String, dynamic> _invoke(String op, [Uint8List? bytes]) {
    if (_handle == null) throw const ProtocolException('加密连接已关闭。');
    try {
      return _endpoint._invoke({
        'op': op,
        'handle': _handle,
        if (bytes != null) 'bytes': hexBytes(bytes),
      });
    } catch (_) {
      close();
      rethrow;
    }
  }

  Uint8List writeHandshake() => fromHex(_invoke('write')['bytes'] as String);
  void readHandshake(Uint8List bytes) {
    _invoke('read', bytes);
  }

  String get authenticatedPeer => _invoke('peer')['public'] as String;
  String get binding => _invoke('peer')['binding'] as String;
  Uint8List seal(Uint8List bytes) =>
      fromHex(_invoke('seal', bytes)['bytes'] as String);
  Uint8List open(Uint8List bytes) =>
      fromHex(_invoke('open', bytes)['bytes'] as String);
  void close() {
    final handle = _handle;
    _handle = null;
    if (handle != null) {
      _endpoint._invoke({'op': 'close', 'handle': handle});
    }
  }
}

/// Stable JSON array avoids ambiguous delimiter concatenation in the prologue.
String pairingContext(PairingInvitation invitation) => jsonEncode([
  'dogcodes-pairing',
  1,
  invitation.service.toString(),
  invitation.hostId,
  invitation.invitationId,
  (invitation.expiresAt.millisecondsSinceEpoch ~/ 1000).toString(),
]);
