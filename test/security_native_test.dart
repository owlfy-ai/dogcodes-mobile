import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/security/noise_endpoint.dart';
import 'package:dogcodes_app/core/security/identity_store.dart';

class MemorySecrets implements SecretStorage {
  final values = <String, String>{};
  bool failRead = false;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('storage locked');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  final library = Platform.environment['DOGCODES_ENDPOINT_LIBRARY'];
  group(
    'native Noise endpoint',
    () {
      late NoiseEndpoint endpoint;
      setUp(() {
        endpoint = NoiseEndpoint(DynamicLibrary.open(library!));
      });
      test(
        'Dart FFI performs mutual handshake, encrypted roundtrip and rejects replay',
        () {
          final phoneId = endpoint.createIdentity();
          final hostId = endpoint.createIdentity();
          final psk = hexBytes(List.filled(32, 7));
          final phone = endpoint.session(
            identity: phoneId,
            initiator: true,
            context: 'fixture',
            peerHex: hostId.publicHex,
            pairingSecretHex: psk,
          );
          final host = endpoint.session(
            identity: hostId,
            initiator: false,
            context: 'fixture',
            pairingSecretHex: psk,
          );
          addTearDown(phone.close);
          addTearDown(host.close);
          host.readHandshake(phone.writeHandshake());
          phone.readHandshake(host.writeHandshake());
          host.readHandshake(phone.writeHandshake());
          expect(phone.authenticatedPeer, hostId.publicHex);
          expect(host.authenticatedPeer, phoneId.publicHex);
          expect(phone.binding, host.binding);
          final frame = phone.seal(
            Uint8List.fromList(utf8.encode('task fixture')),
          );
          expect(utf8.decode(host.open(frame)), 'task fixture');
          expect(() => host.open(frame), throwsA(isA<ProtocolException>()));
          expect(
            () => host.seal(Uint8List(0)),
            throwsA(isA<ProtocolException>()),
          );
        },
      );
      test(
        'identity creation is single-flight and persistent; read failure never rotates it',
        () async {
          final storage = MemorySecrets();
          var count = 0;
          EndpointIdentity create() {
            count++;
            return endpoint.createIdentity();
          }

          final store = DeviceIdentityStore(storage, create);
          final values = await Future.wait([store.get(), store.get()]);
          expect(count, 1);
          expect(values[0].publicHex, values[1].publicHex);
          expect(
            (await DeviceIdentityStore(storage, create).get()).publicHex,
            values[0].publicHex,
          );
          storage.failRead = true;
          await expectLater(
            DeviceIdentityStore(storage, create).get(),
            throwsStateError,
          );
          expect(count, 1);
          storage.failRead = false;
          storage.values['dogcodes.phone.identity.v1'] = 'broken';
          await expectLater(
            DeviceIdentityStore(storage, create).get(),
            throwsA(isA<ProtocolException>()),
          );
          expect(count, 1);
        },
      );
      test(
        'only authenticated, matching pairing receipt persists a trusted host',
        () async {
          final phoneId = endpoint.createIdentity();
          final hostId = endpoint.createIdentity();
          final now = DateTime.now().toUtc();
          final service = Uri.parse('https://test.example.invalid');
          final raw =
              'dogcodes://pair#${base64Url.encode(utf8.encode(jsonEncode({'version': 1, 'hostId': 'test-pc', 'hostKey': base64Url.encode(fromHex(hostId.publicHex)), 'secret': base64Url.encode(List.filled(32, 7)), 'invitationId': 'invitation', 'service': service.toString(), 'expiresAt': (now.millisecondsSinceEpoch ~/ 1000 + 120).toString()})))}';
          final invitation = PairingInvitation.parse(
            raw,
            trustedService: service,
            now: now,
          );
          final context = pairingContext(invitation);
          final psk = hexBytes(List.filled(32, 7));
          final phone = endpoint.session(
            identity: phoneId,
            initiator: true,
            context: context,
            peerHex: hostId.publicHex,
            pairingSecretHex: psk,
          );
          final host = endpoint.session(
            identity: hostId,
            initiator: false,
            context: context,
            pairingSecretHex: psk,
          );
          addTearDown(phone.close);
          addTearDown(host.close);
          host.readHandshake(phone.writeHandshake());
          phone.readHandshake(host.writeHandshake());
          host.readHandshake(phone.writeHandshake());
          final storage = MemorySecrets();
          final store = TrustedHostStore(storage);
          final ack = <String, dynamic>{
            'type': 'paired',
            'hostId': 'test-pc',
            'invitationId': 'invitation',
            'phonePublicKey': phoneId.publicHex,
            'hostPublicKey': hostId.publicHex,
            'binding': host.binding,
            'grantRevision': '1',
            'routeToken': List.filled(64, 'a').join(),
          };
          final tampered = Map<String, dynamic>.from(ack)
            ..['binding'] = 'wrong';
          await expectLater(
            store.confirm(
              invitation: invitation,
              session: phone,
              phone: phoneId,
              acknowledgement: tampered,
            ),
            throwsA(isA<ProtocolException>()),
          );
          expect(storage.values, isEmpty);
          final encrypted = host.seal(
            Uint8List.fromList(utf8.encode(jsonEncode(ack))),
          );
          final decoded =
              jsonDecode(utf8.decode(phone.open(encrypted)))
                  as Map<String, dynamic>;
          await store.confirm(
            invitation: invitation,
            session: phone,
            phone: phoneId,
            acknowledgement: decoded,
          );
          expect((await store.read('test-pc'))!['publicKey'], hostId.publicHex);
        },
      );
    },
    skip: library == null
        ? 'Build native/endpoint and set DOGCODES_ENDPOINT_LIBRARY.'
        : false,
  );
}
