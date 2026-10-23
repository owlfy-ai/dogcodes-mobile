import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'adaptive_host_link.dart';
import 'binary_transport.dart';
import 'host_api.dart';
import 'protocol.dart';
import 'secure_host_client.dart';
import 'security/noise_endpoint.dart';

/// One ordered, reliable DataChannel; no camera/microphone/media permissions.
class RtcBinaryTransport implements BinaryTransport {
  RtcBinaryTransport(this.peer, this.channel) {
    channel.onMessage = (message) {
      if (_closed) return;
      if (!message.isBinary || message.binary.length > 16384) {
        _fail();
      } else {
        _queuedBytes += message.binary.length;
        if (_queuedBytes > 1024 * 1024) {
          _fail();
        } else {
          _messages.add(message.binary);
        }
      }
    };
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        if (!_opened.isCompleted) _opened.complete();
      } else if (state == RTCDataChannelState.RTCDataChannelClosed ||
          state == RTCDataChannelState.RTCDataChannelClosing) {
        _fail();
      }
    };
    peer.onConnectionState = (state) {
      _disconnected?.cancel();
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _fail();
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _disconnected = Timer(const Duration(seconds: 8), _fail);
      }
    };
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _opened.complete();
    }
    unawaited(
      _opened.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }
  final RTCPeerConnection peer;
  final RTCDataChannel channel;
  final _messages = StreamController<List<int>>();
  final _opened = Completer<void>();
  Timer? _disconnected;
  bool _closed = false;
  int _queuedBytes = 0;
  Future<void>? _closing;
  @override
  Stream<List<int>> get messages => _messages.stream.map((packet) {
    _queuedBytes -= packet.length;
    return packet;
  });
  Future<void> waitOpen() =>
      _opened.future.timeout(const Duration(seconds: 15));
  @override
  Future<void> send(Uint8List packet) async {
    if (_closed || packet.length > 16384) throw const RemoteOutcomeUnknown();
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    // Bound native SCTP buffering rather than queueing an entire attachment.
    while (!_closed &&
        await channel.getBufferedAmount().timeout(const Duration(seconds: 8)) >
            256 * 1024) {
      if (DateTime.now().isAfter(deadline)) {
        _fail();
        throw const RemoteOutcomeUnknown();
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (_closed) throw const RemoteOutcomeUnknown();
    await channel
        .send(RTCDataChannelMessage.fromBinary(packet))
        .timeout(const Duration(seconds: 8));
  }

  void _fail() {
    if (_closed) return;
    _closed = true;
    if (!_opened.isCompleted) {
      _opened.completeError(const RemoteOutcomeUnknown());
    }
    // Stream done wakes SecureHostClient and its pending operations.
    unawaited(_messages.close());
    unawaited(close().catchError((Object _) {}));
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _disconnected?.cancel();
    if (!_opened.isCompleted) {
      _opened.completeError(const RemoteOutcomeUnknown());
    }
    channel.onMessage = null;
    channel.onDataChannelState = null;
    peer.onConnectionState = null;
    // Don't await controller.close before a listener exists (failed negotiation).
    unawaited(_messages.close());
    try {
      await channel.close();
    } finally {
      await peer.dispose();
    }
  }
}

/// SDP is exchanged on authenticated Noise, not on the public signalling API.
/// WebRTC/DTLS establishes reachability; a second Noise handshake establishes
/// the same pinned PC and phone identities with fresh counters.
typedef RtcConnector =
    Future<DirectConnection> Function({
      required HostLink relay,
      required Map<String, dynamic> host,
      required EndpointIdentity phone,
      required NoiseEndpoint endpoint,
    });

Future<DirectConnection> connectRtc({
  required HostLink relay,
  required Map<String, dynamic> host,
  required EndpointIdentity phone,
  required NoiseEndpoint endpoint,
}) async {
  final dial = await _dial(
    relay: relay,
    host: host,
    phone: phone,
    endpoint: endpoint,
    purpose: 'business',
    video: false,
  );
  try {
    final status = await dial.client.call('transport_status', null) as Map;
    final hasTurn = (dial.ice['iceServers'] as List).any(
      (server) => (server['urls'] as List).any(
        (url) =>
            (url as String).startsWith('turn:') || url.startsWith('turns:'),
      ),
    );
    return DirectConnection(
      dial.client,
      ConnectionRoute.fromStatus(status),
      expiresAt: hasTurn
          ? DateTime.fromMillisecondsSinceEpoch(
              int.parse(dial.ice['expiresAt'] as String) * 1000,
              isUtc: true,
            )
          : null,
    );
  } catch (_) {
    await dial.client.close();
    rethrow;
  }
}

/// A connection of its own for 远程桌面: desktop RPCs go over its data
/// channel (so the PC's control lease ends with it), and when the PC can,
/// the screen arrives as an H.264 track on the same peer connection,
/// decoded in hardware by WebRTC instead of as JPEG pulls.
class DesktopConnection {
  DesktopConnection(
    this.link,
    this.peer,
    this.stream, {
    required this.video,
    this.expiresAt,
  });
  final HostLink link;
  final RTCPeerConnection peer;

  /// Completes when the screen track arrives (only if [video]).
  final Future<MediaStream> stream;

  /// The PC negotiated the screen track.
  final bool video;
  final DateTime? expiresAt;
  Future<void> close() => link.close();
}

typedef DesktopConnector =
    Future<DesktopConnection> Function(HostLink signalling);

Future<DesktopConnection> connectDesktopRtc({
  required HostLink relay,
  required Map<String, dynamic> host,
  required EndpointIdentity phone,
  required NoiseEndpoint endpoint,
}) async {
  final dial = await _dial(
    relay: relay,
    host: host,
    phone: phone,
    endpoint: endpoint,
    purpose: 'desktop',
    video: true,
  );
  return DesktopConnection(
    dial.client,
    dial.peer,
    dial.stream,
    video: dial.video,
    expiresAt: (dial.ice['expiresAt'] is String)
        ? DateTime.fromMillisecondsSinceEpoch(
            int.parse(dial.ice['expiresAt']) * 1000,
            isUtc: true,
          )
        : null,
  );
}

Future<
  ({
    SecureHostClient client,
    RTCPeerConnection peer,
    Map<String, dynamic> ice,
    Future<MediaStream> stream,
    bool video,
  })
>
_dial({
  required HostLink relay,
  required Map<String, dynamic> host,
  required EndpointIdentity phone,
  required NoiseEndpoint endpoint,
  required String purpose,
  required bool video,
}) async {
  final id = host['hostId'] as String;
  final ice = await routeRequest(
    Uri.parse(host['service'] as String),
    '/v1/hosts/$id/ice',
    host['routeToken'] as String,
    method: 'GET',
  );
  final peer = await createPeerConnection({
    'iceServers': ice['iceServers'] as List,
    'iceTransportPolicy': 'all',
    'sdpSemantics': 'unified-plan',
  });
  RtcBinaryTransport? transport;
  SecureHostClient? client;
  final stream = Completer<MediaStream>();
  unawaited(stream.future.then<void>((_) {}, onError: (Object _) {}));
  try {
    final gathered = Completer<void>();
    peer.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !gathered.isCompleted) {
        gathered.complete();
      }
    };
    if (video) {
      peer.onTrack = (event) {
        if (event.track.kind != 'video' || stream.isCompleted) return;
        if (event.streams.isNotEmpty) {
          stream.complete(event.streams.first);
        } else {
          createLocalMediaStream('dogcodes-screen').then((s) async {
            await s.addTrack(event.track);
            if (!stream.isCompleted) stream.complete(s);
          });
        }
      };
      // Receive-only: no camera, microphone or capture permission involved.
      await peer.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
    }
    final channel = await peer.createDataChannel(
      'dogcodes-v1',
      RTCDataChannelInit()..ordered = true,
    );
    transport = RtcBinaryTransport(peer, channel);
    await peer.setLocalDescription(
      await peer.createOffer({
        'mandatory': {
          'OfferToReceiveAudio': false,
          'OfferToReceiveVideo': video,
        },
        'optional': [],
      }),
    );
    if (peer.iceGatheringState !=
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      await gathered.future.timeout(const Duration(seconds: 10));
    }
    final offer = await peer.getLocalDescription();
    final answer =
        await relay.call('direct_open', {
              'offer': {'type': 'offer', 'sdp': offer!.sdp},
              'purpose': purpose,
            })
            as Map;
    final connectionId = answer['connectionId'];
    final context = ['dogcodes-direct', 1, id, connectionId, purpose];
    if (connectionId is! String ||
        connectionId.isEmpty ||
        connectionId.length > 128 ||
        answer['transport'] != 'webrtc-datachannel' ||
        answer['purpose'] != purpose ||
        jsonEncode(answer['noiseContext']) != jsonEncode(context) ||
        (answer['answer'] as Map)['type'] != 'answer') {
      throw const ProtocolException('直连协商响应无效。');
    }
    await peer.setRemoteDescription(
      RTCSessionDescription(answer['answer']['sdp'] as String, 'answer'),
    );
    await transport.waitOpen();
    final noise = endpoint.session(
      identity: phone,
      initiator: true,
      context: jsonEncode(context),
      peerHex: host['publicKey'] as String,
    );
    client = await SecureHostClient.direct(
      hostId: id,
      connectionId: connectionId,
      purpose: purpose,
      transport: transport,
      noise: noise,
      peerHex: host['publicKey'] as String,
    );
    return (
      client: client,
      peer: peer,
      ice: ice,
      stream: stream.future,
      video: video && answer['video'] == true,
    );
  } catch (_) {
    if (client != null) {
      await client.close();
    } else if (transport != null) {
      await transport.close();
    } else {
      await peer.dispose();
    }
    rethrow;
  }
}
