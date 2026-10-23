import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'dart:typed_data';
import 'host_channel.dart';
import 'binary_transport.dart';
import 'frame_reader.dart';
import 'host_api.dart';
import 'network_address.dart';
import 'protocol.dart';
import 'security/noise_endpoint.dart';
import 'security/pairing_recovery.dart';

Future<Map<String, dynamic>> routeRequest(
  Uri service,
  String path,
  String token, {
  String method = 'POST',
  Map<String, dynamic>? body,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client
        .openUrl(method, reachable(service).resolve(path))
        .timeout(const Duration(seconds: 8));
    request.followRedirects = false;
    request.headers.set('Authorization', 'Bearer $token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw ProtocolException(
        response.statusCode == 503 ? '电脑暂时离线，请稍后重连。' : '连接请求未被接受，请核实设备授权。',
      );
    }
    final data = <int>[];
    await for (final part in response.timeout(const Duration(seconds: 8))) {
      data.addAll(part);
      if (data.length > 16384) throw const ProtocolException('连接响应过大。');
    }
    return jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

class RemoteOutcomeUnknown implements Exception {
  const RemoteOutcomeUnknown();
  @override
  String toString() => '连接中断，操作结果待核实；请勿重复发送。';
}

class SecureHostClient implements AuthenticatedHostChannel, HostLink {
  SecureHostClient._(this.hostId, this._transport, this._noise) {
    // Failures can arrive before the caller has started awaiting the handshake.
    unawaited(
      _handshake.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    _subscription = _transport.messages.listen(
      _receive,
      onError: (Object _, StackTrace _) {
        _fail();
      },
      onDone: _fail,
    );
  }
  @override
  final String hostId;
  final BinaryTransport _transport;
  Future<void> _sendTail = Future.value();
  Future<void>? _closing;
  bool get isClosed => _closed;
  final NoiseSession _noise;
  late final StreamSubscription<List<int>> _subscription;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _waiting = <String, Completer<Map<String, dynamic>>>{};
  final _handshake = Completer<Map<String, dynamic>>();
  late final _frames = FrameReader(onFragment: _ackFragment);
  final _fragmentAcks = <String, int>{};
  bool _flushingFragments = false;
  bool _closed = false;
  int _next = 0;
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  @override
  String? hostName;

  static Future<(SecureHostClient, Map<String, dynamic>)> pair(
    PairingInvitation invitation,
    EndpointIdentity phone,
    NoiseEndpoint endpoint,
  ) async {
    if (invitation.phoneTicket == null) {
      throw const ProtocolException('请在电脑上生成新版配对二维码。');
    }
    final psk = hexBytes(
      base64Url.decode(base64Url.normalize(invitation.secret)),
    );
    final peer = hexBytes(
      base64Url.decode(base64Url.normalize(invitation.hostKey)),
    );
    final noise = endpoint.session(
      identity: phone,
      initiator: true,
      context: pairingContext(invitation),
      peerHex: peer,
      pairingSecretHex: psk,
    );
    final client = await _connect(
      invitation.service,
      invitation.hostId,
      invitation.invitationId,
      invitation.phoneTicket!,
      noise,
    );
    try {
      return (
        client,
        await client._handshake.future.timeout(const Duration(seconds: 20)),
      );
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  static Future<SecureHostClient> reconnect(
    Map<String, dynamic> host,
    EndpointIdentity phone,
    NoiseEndpoint endpoint,
  ) async {
    final id = host['hostId'] as String;
    final service = Uri.parse(host['service'] as String);
    final route = await routeRequest(
      service,
      '/v1/hosts/$id/connections',
      host['routeToken'] as String,
    );
    final session = route['sessionId'] as String;
    final noise = endpoint.session(
      identity: phone,
      initiator: true,
      context: jsonEncode(['dogcodes-reconnect', 1, id, session]),
      peerHex: host['publicKey'] as String,
    );
    final client = await _connect(
      service,
      id,
      session,
      route['phoneTicket'] as String,
      noise,
    );
    try {
      final ack = await client._handshake.future.timeout(
        const Duration(seconds: 20),
      );
      client.hostName = displayHostName(ack['hostName']);
      if (ack['type'] != 'connected' ||
          ack['hostId'] != id ||
          ack['binding'] != noise.binding ||
          noise.authenticatedPeer != host['publicKey']) {
        throw const ProtocolException('电脑连接身份不一致。');
      }
      return client;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  /// The old invitation ticket grants transport only. A new IK session must
  /// prove both original endpoint identities before the PC returns its receipt.
  static Future<(SecureHostClient, Map<String, dynamic>)> recoverPairing(
    PairingRecovery original,
    EndpointIdentity phone,
    NoiseEndpoint endpoint,
  ) async {
    if (phone.publicHex != original.phonePublicKey) {
      throw const ProtocolException('手机身份与原配对不一致，未重新申请授权。');
    }
    if (!original.recoverUntil.isAfter(DateTime.now().toUtc())) {
      throw const ProtocolException('原配对恢复期限已过，请在电脑核实授权后重新扫码。');
    }
    final route = await routeRequest(
      original.service,
      '/v1/hosts/${original.hostId}/pairing-recovery',
      original.phoneTicket,
      body: {'invitationId': original.invitationId},
    );
    final session = route['sessionId'] as String;
    final peer = hexBytes(
      base64Url.decode(base64Url.normalize(original.hostKey)),
    );
    final noise = endpoint.session(
      identity: phone,
      initiator: true,
      context: jsonEncode(['dogcodes-reconnect', 1, original.hostId, session]),
      peerHex: peer,
    );
    final client = await _connect(
      original.service,
      original.hostId,
      session,
      route['phoneTicket'] as String,
      noise,
    );
    try {
      final connected = await client._handshake.future.timeout(
        const Duration(seconds: 20),
      );
      if (connected['type'] != 'connected' ||
          connected['hostId'] != original.hostId ||
          connected['binding'] != noise.binding ||
          noise.authenticatedPeer != peer) {
        throw const ProtocolException('电脑连接身份与原配对不一致。');
      }
      final receipt = await client.call(
        'pairing_receipt',
        original.invitationId,
      );
      if (receipt is! Map) throw const ProtocolException('电脑未返回原配对回执。');
      client.hostName = displayHostName(receipt['hostName']);
      return (client, Map<String, dynamic>.from(receipt));
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  static Future<SecureHostClient> _connect(
    Uri service,
    String hostId,
    String session,
    String token,
    NoiseSession noise,
  ) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    WebSocket? socket;
    try {
      final url = reachable(service).replace(
        scheme: service.scheme == 'https' ? 'wss' : 'ws',
        path: '/v1/relay/$session',
      );
      socket = await WebSocket.connect(
        url.toString(),
        headers: {'Authorization': 'Bearer $token'},
        customClient: http,
      ).timeout(const Duration(seconds: 10));
      socket.pingInterval = const Duration(seconds: 20);
      final client = SecureHostClient._(
        hostId,
        WebSocketTransport(socket),
        noise,
      );
      await client._transport.send(noise.writeHandshake());
      return client;
    } catch (_) {
      noise.close();
      await socket?.close();
      rethrow;
    } finally {
      http.close(force: true);
    }
  }

  /// Starts a fresh, pinned Noise session on an already open binary channel.
  /// The answer and acknowledgement must bind this exact negotiated connection.
  static Future<SecureHostClient> direct({
    required String hostId,
    required String connectionId,
    required String purpose,
    required BinaryTransport transport,
    required NoiseSession noise,
    required String peerHex,
  }) async {
    final client = SecureHostClient._(hostId, transport, noise);
    try {
      await transport.send(noise.writeHandshake());
      final ack = await client._handshake.future.timeout(
        const Duration(seconds: 10),
      );
      if (noise.authenticatedPeer != peerHex ||
          ack['type'] != 'connected' ||
          ack['hostId'] != hostId ||
          ack['binding'] != noise.binding ||
          ack['transport'] != 'webrtc' ||
          ack['connectionId'] != connectionId ||
          ack['purpose'] != purpose) {
        throw const ProtocolException('直连身份验证失败。');
      }
      client.hostName = displayHostName(ack['hostName']);
      return client;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  bool _noiseReady = false;
  void _receive(dynamic message) {
    if (_closed) return;
    try {
      if (message is! List<int> || message.length > 65535) {
        throw const ProtocolException('加密数据格式无效。');
      }
      if (!_noiseReady) {
        _noise.readHandshake(Uint8List.fromList(message));
        final reply = _noise.writeHandshake();
        unawaited(_transport.send(reply).catchError((Object _) => _fail()));
        _noiseReady = true;
        return;
      }
      _frames.add(_noise.open(Uint8List.fromList(message)));
      while (true) {
        final value = _frames.next();
        if (value == null) return;
        if (!_handshake.isCompleted) {
          _handshake.complete(value);
        } else if (value['type'] == 'response') {
          final waiting = _waiting.remove(value['requestId']);
          if (waiting != null) {
            if (value['error'] != null) {
              waiting.completeError(
                ProtocolException((value['error'] as Map)['message'] as String),
              );
            } else {
              waiting.complete(value);
            }
          }
        } else {
          _events.add(value);
        }
      }
    } catch (_) {
      _fail();
    }
  }

  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> envelope) async {
    if (_closed) throw const RemoteOutcomeUnknown();
    if (_waiting.length >= 16) throw const ProtocolException('请求较多，请稍后重试。');
    final id = 'request-${++_next}';
    final message = {
      ...envelope,
      'version': 1,
      'hostId': hostId,
      'requestId': id,
    };
    final bytes = utf8.encode(jsonEncode(message));
    if (bytes.length > 8 * 1024 * 1024) {
      throw const ProtocolException('请求过大。');
    }
    final framed = Uint8List(bytes.length + 4);
    ByteData.sublistView(framed).setUint32(0, bytes.length);
    framed.setRange(4, framed.length, bytes);
    final completer = Completer<Map<String, dynamic>>();
    _waiting[id] = completer;
    // Attach the reply listener before an asynchronous native send can fail.
    final reply = completer.future.timeout(
      Zone.current[replyTimeoutKey] as Duration? ?? const Duration(seconds: 30),
      onTimeout: () => throw const RemoteOutcomeUnknown(),
    );
    unawaited(reply.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    final send = _sendFrame(framed);
    try {
      await send;
      return await reply;
    } catch (error) {
      if (error is ProtocolException && !_closed) rethrow;
      _fail();
      throw const RemoteOutcomeUnknown();
    } finally {
      _waiting.remove(id);
    }
  }

  Future<void> _sendFrame(Uint8List framed) {
    final send = _sendTail.then((_) async {
      if (_closed) throw const RemoteOutcomeUnknown();
      for (var i = 0; i < framed.length; i += 16000) {
        await _transport.send(
          _noise.seal(
            Uint8List.sublistView(
              framed,
              i,
              (i + 16000).clamp(0, framed.length),
            ),
          ),
        );
      }
    });
    // Entire frames, including Noise nonces, are serialized across native sends.
    _sendTail = send.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        _fail();
      },
    );
    return send;
  }

  void _ackFragment(String id, int offset) {
    if (_closed) return;
    _fragmentAcks[id] = offset;
    if (_flushingFragments) return;
    _flushingFragments = true;
    scheduleMicrotask(() {
      unawaited(_flushFragmentAcks());
    });
  }

  Future<void> _flushFragmentAcks() async {
    try {
      while (!_closed && _fragmentAcks.isNotEmpty) {
        final entries = _fragmentAcks.entries.take(16).toList();
        for (final entry in entries) {
          _fragmentAcks.remove(entry.key);
        }
        final bytes = utf8.encode(
          jsonEncode({
            'type': 'fragment_ack',
            'version': 1,
            'hostId': hostId,
            'acks': [
              for (final entry in entries)
                {'id': entry.key, 'offset': entry.value},
            ],
          }),
        );
        final framed = Uint8List(bytes.length + 4);
        ByteData.sublistView(framed).setUint32(0, bytes.length);
        framed.setRange(4, framed.length, bytes);
        await _sendFrame(framed);
      }
    } catch (_) {
      _fail();
    } finally {
      _flushingFragments = false;
    }
  }

  @override
  Future<dynamic> call(String method, dynamic params) async =>
      (await request({'method': method, 'params': params}))['result'];
  NoiseSession get session => _noise;
  void _fail() {
    if (_closed) return;
    _closed = true;
    unawaited(_transport.close().catchError((Object _) {}));
    _noise.close();
    _frames.clear();
    _fragmentAcks.clear();
    if (!_handshake.isCompleted) {
      _handshake.completeError(const ProtocolException('配对连接中断，结果需要核实。'));
    }
    for (final c in _waiting.values) {
      c.completeError(const RemoteOutcomeUnknown());
    }
    _waiting.clear();
    _events.add({'type': 'disconnected'});
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _fail();
    await _subscription.cancel();
    await _transport.close();
    await _events.close();
  }
}

/// PC-reported display name; shown only, never used for identity.
String? displayHostName(Object? value) {
  if (value is! String) return null;
  final name = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  if (name.isEmpty) return null;
  return name.length > 64 ? name.substring(0, 64) : name;
}

String phoneDeviceId(EndpointIdentity identity) =>
    sha256.convert(fromHex(identity.publicHex)).toString();
