import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:integration_test/integration_test.dart';
import 'package:dogcodes_app/core/security/noise_endpoint.dart';
import 'package:dogcodes_app/core/security/identity_store.dart';

class IsolatedSecrets implements SecretStorage {
  final delegate = PlatformSecretStorage();
  @override
  Future<String?> read(String key) => delegate.read('integration-test.$key');
  @override
  Future<void> write(String key, String value) =>
      delegate.write('integration-test.$key', value);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('bundled endpoint and platform identity storage', (tester) async {
    final endpoint = NoiseEndpoint.bundled();
    final storage = IsolatedSecrets();
    addTearDown(
      () => const FlutterSecureStorage(
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      ).delete(key: 'integration-test.dogcodes.phone.identity.v1'),
    );
    final original = await DeviceIdentityStore(
      storage,
      endpoint.createIdentity,
    ).get();
    final restored = await DeviceIdentityStore(
      storage,
      endpoint.createIdentity,
    ).get();
    expect(restored.publicHex, original.publicHex);
    final host = endpoint.createIdentity();
    final psk = endpoint.createIdentity().secretHex;
    final phoneNoise = endpoint.session(
      identity: original,
      initiator: true,
      context: 'integration-test-v1',
      peerHex: host.publicHex,
      pairingSecretHex: psk,
    );
    final hostNoise = endpoint.session(
      identity: host,
      initiator: false,
      context: 'integration-test-v1',
      pairingSecretHex: psk,
    );
    addTearDown(phoneNoise.close);
    addTearDown(hostNoise.close);
    hostNoise.readHandshake(phoneNoise.writeHandshake());
    phoneNoise.readHandshake(hostNoise.writeHandshake());
    hostNoise.readHandshake(phoneNoise.writeHandshake());
    final message = phoneNoise.seal(
      Uint8List.fromList(utf8.encode('native integration fixture')),
    );
    expect(utf8.decode(hostNoise.open(message)), 'native integration fixture');
  });
}
