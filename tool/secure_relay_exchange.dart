import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:dogcodes_app/core/relay_probe.dart';
import 'package:dogcodes_app/core/security/noise_endpoint.dart';

/// Isolated native endpoint probe. No actual PC daemon or user identity is used.
Future<void> secureExchange(RelayProbe host, RelayProbe phone) async {
  final path = Platform.environment['DOGCODES_ENDPOINT_LIBRARY'];
  if (path == null) {
    throw StateError(
      'Set DOGCODES_ENDPOINT_LIBRARY to the locally built library.',
    );
  }
  final endpoint = NoiseEndpoint(DynamicLibrary.open(path));
  final hostKey = endpoint.createIdentity();
  final phoneKey = endpoint.createIdentity();
  final psk = endpoint.createIdentity().secretHex;
  final hostNoise = endpoint.session(
    identity: hostKey,
    initiator: false,
    context: 'dogcodes-secure-probe-v1',
    pairingSecretHex: psk,
  );
  final phoneNoise = endpoint.session(
    identity: phoneKey,
    initiator: true,
    context: 'dogcodes-secure-probe-v1',
    peerHex: hostKey.publicHex,
    pairingSecretHex: psk,
  );
  Future<Uint8List> next(RelayProbe peer) =>
      peer.frames.first.timeout(const Duration(seconds: 5));
  try {
    var received = next(host);
    phone.send(phoneNoise.writeHandshake());
    hostNoise.readHandshake(await received);
    received = next(phone);
    host.send(hostNoise.writeHandshake());
    phoneNoise.readHandshake(await received);
    received = next(host);
    phone.send(phoneNoise.writeHandshake());
    hostNoise.readHandshake(await received);
    if (hostNoise.authenticatedPeer != phoneKey.publicHex ||
        phoneNoise.authenticatedPeer != hostKey.publicHex ||
        hostNoise.binding != phoneNoise.binding) {
      throw StateError('Endpoint identity mismatch.');
    }
    final plaintext = Uint8List.fromList(
      utf8.encode('synthetic task, never executed'),
    );
    final frame = phoneNoise.seal(plaintext);
    if (base64Encode(frame) == base64Encode(plaintext)) {
      throw StateError('Unencrypted payload.');
    }
    received = next(host);
    phone.send(frame);
    if (base64Encode(hostNoise.open(await received)) !=
        base64Encode(plaintext)) {
      throw StateError('Decrypt mismatch.');
    }
    received = next(phone);
    host.send(hostNoise.seal(Uint8List.fromList([42])));
    if (base64Encode(phoneNoise.open(await received)) != base64Encode([42])) {
      throw StateError('Response mismatch.');
    }
    received = next(host);
    phone.send(frame);
    var rejected = false;
    try {
      hostNoise.open(await received);
    } catch (_) {
      rejected = true;
    }
    if (!rejected) throw StateError('Replay was accepted.');
  } finally {
    hostNoise.close();
    phoneNoise.close();
  }
}
