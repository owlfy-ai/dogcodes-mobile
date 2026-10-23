import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';

/// Keep awake on the PC: one value; replies can be lost either side of it.
class PowerApi implements HostApi {
  bool enabled = true, loseBefore = false, loseAfter = false;
  final calls = <String>[];
  Map<String, dynamic> get snapshot => {'enabled': enabled, 'active': false};
  @override
  Future<dynamic> call(String method, dynamic args) async {
    calls.add(method);
    if (method == 'power_preferences') return snapshot;
    expect(method, 'power_preferences_set');
    if (loseBefore) throw const RemoteOutcomeUnknown();
    enabled = args['enabled'] as bool;
    if (loseAfter) throw const RemoteOutcomeUnknown();
    return snapshot;
  }
}

void main() {
  test(
    'setting keep awake returns the confirmed value and tracks nothing',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc'),
          pc = PowerApi();
      expect((await ops.setKeepAwake(pc, false))['enabled'], false);
      expect(await ops.pending(), isNull);
      expect(await ops.sidePending(), isNull);
    },
  );

  test('a lost reply is settled by reading the value back', () async {
    final ops = MobileOperations(MemorySecretStorage(), 'pc');
    final pc = PowerApi()..loseAfter = true;
    expect((await ops.setKeepAwake(pc, false))['enabled'], false);
    expect(pc.calls, ['power_preferences_set', 'power_preferences']);
  });

  test('a setting that never arrived asks the user to try again', () async {
    final ops = MobileOperations(MemorySecretStorage(), 'pc');
    final pc = PowerApi()..loseBefore = true;
    await expectLater(
      ops.setKeepAwake(pc, false),
      throwsA(isA<ProtocolException>()),
    );
    expect(pc.enabled, true);
    expect(await ops.sidePending(), isNull);
    pc.loseBefore = false;
    expect((await ops.setKeepAwake(pc, false))['enabled'], false);
  });
}
