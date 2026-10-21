import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/binary_transport.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'package:dogcodes_app/core/security/noise_endpoint.dart';
import 'package:dogcodes_app/core/protocol.dart';

class NoisePeer implements BinaryTransport {
  NoisePeer(this.noise, {this.ackHost = 'pc'});
  final NoiseSession noise;
  final String ackHost;
  final input = StreamController<List<int>>();
  final requests = <Map<String, dynamic>>[];
  final lengths = <int>[];
  final buffer = <int>[];
  var stage = 0;
  bool closed = false;
  @override
  Stream<List<int>> get messages => input.stream;
  @override
  Future<void> send(Uint8List packet) async {
    // Native channel sends are asynchronous. Two callers must not interleave
    // encrypted chunks belonging to different framed JSON messages.
    await Future<void>.delayed(Duration.zero);
    lengths.add(packet.length);
    if (stage == 0) {
      noise.readHandshake(packet);
      input.add(noise.writeHandshake());
      stage++;
    } else if (stage == 1) {
      noise.readHandshake(packet);
      stage++;
      frame({
        'type': 'connected',
        'hostId': ackHost,
        'binding': noise.binding,
        'transport': 'webrtc',
        'connectionId': 'connection',
        'purpose': 'business',
      });
    } else {
      buffer.addAll(noise.open(packet));
      while (buffer.length >= 4) {
        final size = ByteData.sublistView(
          Uint8List.fromList(buffer.sublist(0, 4)),
        ).getUint32(0);
        if (buffer.length < size + 4) return;
        final request =
            jsonDecode(utf8.decode(buffer.sublist(4, size + 4)))
                as Map<String, dynamic>;
        buffer.removeRange(0, size + 4);
        requests.add(request);
        frame({
          'type': 'response',
          'requestId': request['requestId'],
          'result': request['params'],
        });
      }
    }
  }

  void frame(Map<String, dynamic> value) {
    final bytes = utf8.encode(jsonEncode(value));
    final frame = Uint8List(bytes.length + 4);
    ByteData.sublistView(frame).setUint32(0, bytes.length);
    frame.setRange(4, frame.length, bytes);
    for (var i = 0; i < frame.length; i += 16000) {
      input.add(
        noise.seal(
          Uint8List.sublistView(frame, i, (i + 16000).clamp(0, frame.length)),
        ),
      );
    }
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    noise.close();
    unawaited(input.close());
  }
}

void main() {
  final library = Platform.environment['DOGCODES_ENDPOINT_LIBRARY'];
  group('transport-neutral authenticated client', skip: library == null, () {
    late NoiseEndpoint endpoint;
    setUp(() => endpoint = NoiseEndpoint(DynamicLibrary.open(library!)));
    Future<(SecureHostClient, NoisePeer)> connect({
      String ackHost = 'pc',
      String purpose = 'business',
    }) async {
      final phone = endpoint.createIdentity(), pc = endpoint.createIdentity();
      final context = jsonEncode([
        'dogcodes-direct',
        1,
        'pc',
        'connection',
        'business',
      ]);
      final peer = NoisePeer(
        endpoint.session(
          identity: pc,
          initiator: false,
          context: context,
          peerHex: phone.publicHex,
        ),
        ackHost: ackHost,
      );
      addTearDown(peer.close);
      final client = await SecureHostClient.direct(
        hostId: 'pc',
        connectionId: 'connection',
        purpose: purpose,
        transport: peer,
        noise: endpoint.session(
          identity: phone,
          initiator: true,
          context: context,
          peerHex: pc.publicHex,
        ),
        peerHex: pc.publicHex,
      );
      addTearDown(client.close);
      return (client, peer);
    }

    test(
      'concurrent large frames preserve Noise order and SCTP message bounds',
      () async {
        final (client, peer) = await connect();
        final a = List.filled(40000, 'a').join(),
            b = List.filled(40000, 'b').join();
        final results = await Future.wait([
          client.call('echo', a),
          client.call('echo', b),
        ]);
        expect(results, [a, b]);
        expect(peer.requests.length, 2);
        expect(peer.lengths.every((length) => length <= 16384), true);
      },
    );
    test(
      'encrypted acknowledgement must match the pinned host and purpose',
      () async {
        await expectLater(
          connect(ackHost: 'wrong-pc'),
          throwsA(isA<ProtocolException>()),
        );
        await expectLater(
          connect(purpose: 'desktop'),
          throwsA(isA<ProtocolException>()),
        );
      },
    );
    test(
      'tampered ciphertext disconnects and prevents further writes',
      () async {
        final (client, peer) = await connect();
        final disconnected = client.events.firstWhere(
          (e) => e['type'] == 'disconnected',
        );
        peer.input.add(Uint8List.fromList([1, 2, 3]));
        await disconnected;
        await expectLater(
          client.call('execute', {'operationId': 'original'}),
          throwsA(isA<RemoteOutcomeUnknown>()),
        );
        expect(peer.requests, isEmpty);
      },
    );
  });
}
