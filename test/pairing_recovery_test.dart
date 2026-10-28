import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/mobile_runtime.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/security/noise_endpoint.dart';
import 'package:dogcodes_app/core/security/pairing_recovery.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';

import 'package:dogcodes_app/core/secure_host_client.dart';

class MemorySecrets implements SecretStorage {
  final values = <String, String>{};
  bool failPairWrite = false, dropPairWrite = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (key == PairingJournal.key && failPairWrite) {
      throw StateError('storage locked');
    }
    if (key != PairingJournal.key || !dropPairWrite) values[key] = value;
  }
}

const phoneKey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
PairingInvitation invitation({
  String id = 'invitation',
  int hostByte = 7,
}) => PairingInvitation.parse(
  'dogcodes://pair#${base64Url.encode(utf8.encode(jsonEncode({'version': 1, 'hostId': 'test-pc', 'hostKey': base64Url.encode(List.filled(32, hostByte)), 'secret': base64Url.encode(List.filled(32, 9)), 'invitationId': id, 'phoneTicket': List.filled(64, 'b').join(), 'service': 'https://test.example.invalid', 'expiresAt': (DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + 120).toString()})))}',
  trustedService: Uri.parse('https://test.example.invalid'),
  now: DateTime.now().toUtc(),
);
void main() {
  test(
    'restart retains original pins and ticket, but not the pairing PSK',
    () async {
      final storage = MemorySecrets(), scan = invitation();
      final original = PairingRecovery.fromInvitation(
        scan,
        phoneKey,
        bindingEpoch: testEpoch,
      );
      await PairingJournal(storage).begin(original);
      final raw = storage.values[PairingJournal.key]!;
      expect(raw, isNot(contains('"secret"')));
      expect(raw, isNot(contains(scan.secret)));
      final restored = (await PairingJournal(storage).list()).single;
      expect(restored.sameAttempt(original), isTrue);
      expect(restored.phonePublicKey, phoneKey);
      expect('$restored', 'PairingRecovery(<redacted>)');
    },
  );
  test('unconfirmed storage writes fail closed', () async {
    final storage = MemorySecrets()..dropPairWrite = true;
    await expectLater(
      PairingJournal(storage).begin(
        PairingRecovery.fromInvitation(
          invitation(),
          phoneKey,
          bindingEpoch: testEpoch,
        ),
      ),
      throwsA(isA<ProtocolException>()),
    );
    expect(await PairingJournal(storage).list(), isEmpty);
  });
  test('corrupt recovery data is never silently replaced', () async {
    final storage = MemorySecrets()..values[PairingJournal.key] = 'broken';
    final journal = PairingJournal(storage);
    await expectLater(
      journal.begin(
        PairingRecovery.fromInvitation(
          invitation(),
          phoneKey,
          bindingEpoch: testEpoch,
        ),
      ),
      throwsA(isA<ProtocolException>()),
    );
    expect(storage.values[PairingJournal.key], 'broken');
  });
  test('late confirmation cannot erase a newer invitation', () async {
    final journal = PairingJournal(MemorySecrets());
    final first = PairingRecovery.fromInvitation(
      invitation(id: 'first'),
      phoneKey,
      bindingEpoch: testEpoch,
    );
    final second = PairingRecovery.fromInvitation(
      invitation(id: 'second'),
      phoneKey,
      bindingEpoch: testEpoch,
    );
    await journal.begin(first);
    await journal.begin(second);
    await journal.clear(first);
    expect((await journal.list()).single.invitationId, 'second');
    await journal.clear(second);
    expect(await journal.list(), isEmpty);
  });
  test('a pending computer pin cannot be silently replaced', () async {
    final journal = PairingJournal(MemorySecrets());
    await journal.begin(
      PairingRecovery.fromInvitation(
        invitation(),
        phoneKey,
        bindingEpoch: testEpoch,
      ),
    );
    await expectLater(
      journal.begin(
        PairingRecovery.fromInvitation(
          invitation(hostByte: 8),
          phoneKey,
          bindingEpoch: testEpoch,
        ),
      ),
      throwsA(isA<ProtocolException>()),
    );
    expect((await journal.list()).single.hostKey, invitation().hostKey);
  });
  test('concurrent writes preserve different computers', () async {
    final journal = PairingJournal(MemorySecrets());
    final first = PairingRecovery.fromInvitation(
      invitation(),
      phoneKey,
      bindingEpoch: testEpoch,
    );
    final data = {...first.toJson(), 'hostId': 'another-pc'};
    await Future.wait([
      journal.begin(first),
      journal.begin(
        PairingRecovery.fromJson(data, allowLocalDevelopment: false),
      ),
    ]);
    expect(await journal.list(), hasLength(2));
  });
  for (final change in <Map<String, dynamic>>[
    {'service': 'http://untrusted.invalid'},
    {'service': 'https://name:password@test.invalid'},
    {'service': 'https://test.invalid/path'},
    {'phonePublicKey': 'bad'},
    {'phoneTicket': 'bad'},
    {'hostKey': 'bad'},
  ]) {
    test('restored recovery records reject invalid ${change.keys.single}', () {
      final original = PairingRecovery.fromInvitation(
        invitation(),
        phoneKey,
        bindingEpoch: testEpoch,
      );
      expect(
        () => PairingRecovery.fromJson({
          ...original.toJson(),
          ...change,
        }, allowLocalDevelopment: false),
        throwsA(isA<ProtocolException>()),
      );
    });
  }
  final library = Platform.environment['DOGCODES_ENDPOINT_LIBRARY'];
  group(
    'native identity guard',
    () {
      late NoiseEndpoint endpoint;
      setUp(() => endpoint = NoiseEndpoint(DynamicLibrary.open(library!)));
      test(
        'pairing cannot contact the PC before its recovery information is saved',
        () async {
          final storage = MemorySecrets()..failPairWrite = true;
          final runtime = MobileRuntime(
            storage: storage,
            noiseEndpoint: endpoint,
          );
          await expectLater(runtime.pair(invitation()), throwsStateError);
          expect(await runtime.hosts.list(), isEmpty);
        },
      );
      test('a different phone identity cannot request recovery', () async {
        final original = PairingRecovery.fromInvitation(
          invitation(),
          phoneKey,
          bindingEpoch: testEpoch,
        );
        await expectLater(
          SecureHostClient.recoverPairing(
            original,
            endpoint.createIdentity(),
            endpoint,
          ),
          throwsA(isA<ProtocolException>()),
        );
      });
      test('expired recovery never starts a new pairing', () async {
        final phone = endpoint.createIdentity();
        final original = PairingRecovery.fromInvitation(
          invitation(),
          phone.publicHex,
          bindingEpoch: testEpoch,
        );
        final expired = PairingRecovery.fromJson({
          ...original.toJson(),
          'recoverUntil': '2020-01-01T00:00:00Z',
        }, allowLocalDevelopment: false);
        await expectLater(
          SecureHostClient.recoverPairing(expired, phone, endpoint),
          throwsA(isA<ProtocolException>()),
        );
      });
    },
    skip: library == null
        ? 'Set DOGCODES_ENDPOINT_LIBRARY to validate native identities.'
        : false,
  );
}

const testEpoch = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
