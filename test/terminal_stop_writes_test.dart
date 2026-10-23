import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';

final target = <String, dynamic>{
  'id': '10000000-0000-4000-8000-000000000001',
  'epoch': '10000000-0000-4000-8000-000000000002',
  'projectId': 'project',
  'label': 'terminal',
};
Map<String, dynamic> clone(Map value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

/// The PC's terminals: stopping one twice just returns its current state.
class StopApi implements HostApi {
  final terminals = <String, Map<String, dynamic>>{
    target['id'] as String: {...target, 'status': 'running'},
  };
  final calls = <String>[];
  bool loseBefore = false, loseAfter = false, slow = false;
  @override
  Future<dynamic> call(String method, dynamic args) async {
    calls.add(method);
    final info = terminals[args];
    if (method == 'terminal_get') {
      if (info == null) throw const ProtocolException('终端不存在或属于已清除的后台实例');
      return clone(info);
    }
    expect(method, 'terminal_stop');
    if (loseBefore) throw const RemoteOutcomeUnknown();
    if (info == null) throw const ProtocolException('终端不存在或属于已清除的后台实例');
    info['status'] = slow ? 'stopping' : 'exited';
    if (loseAfter) throw const RemoteOutcomeUnknown();
    return clone(info);
  }
}

void main() {
  test('a lost close reply is settled by reading the terminal', () async {
    final storage = MemorySecretStorage(), pc = StopApi()..loseAfter = true;
    await expectLater(
      MobileOperations(storage, 'pc').terminalStop(pc, target),
      throwsA(isA<RemoteOutcomeUnknown>()),
    );
    final ops = MobileOperations(storage, 'pc');
    final saved = (await ops.pendingTerminalStops()).single;
    expect((await ops.verifyTerminalStop(pc, saved))!['state'], 'stopped');
    expect(pc.calls.where((c) => c == 'terminal_stop'), hasLength(1));
    expect(await ops.pendingTerminalStops(), isEmpty);
  });

  test('a close that never arrived is sent again', () async {
    final ops = MobileOperations(MemorySecretStorage(), 'pc');
    final pc = StopApi()..loseBefore = true;
    await expectLater(
      ops.terminalStop(pc, target),
      throwsA(isA<RemoteOutcomeUnknown>()),
    );
    final saved = (await ops.pendingTerminalStops()).single;
    expect((await ops.verifyTerminalStop(pc, saved))!['state'], 'stopping');
    expect(await ops.pendingTerminalStops(), hasLength(1));
    pc.loseBefore = false;
    expect((await ops.retryTerminalStop(pc, saved))!['state'], 'stopped');
    expect(await ops.pendingTerminalStops(), isEmpty);
  });

  test('a terminal that is gone needs no close', () async {
    final ops = MobileOperations(MemorySecretStorage(), 'pc');
    final pc = StopApi()..loseBefore = true;
    await expectLater(
      ops.terminalStop(pc, target),
      throwsA(isA<RemoteOutcomeUnknown>()),
    );
    pc.terminals.clear();
    final saved = (await ops.pendingTerminalStops()).single;
    expect((await ops.verifyTerminalStop(pc, saved))!['state'], 'stopped');
    expect(await ops.pendingTerminalStops(), isEmpty);
  });

  test('a restarted terminal with the same id is never closed', () async {
    final ops = MobileOperations(MemorySecretStorage(), 'pc');
    final pc = StopApi()..loseBefore = true;
    await expectLater(
      ops.terminalStop(pc, target),
      throwsA(isA<RemoteOutcomeUnknown>()),
    );
    pc.terminals[target['id'] as String]!['epoch'] = 'another-generation';
    final saved = (await ops.pendingTerminalStops()).single;
    expect((await ops.retryTerminalStop(pc, saved))!['state'], 'rejected');
    expect(pc.terminals.values.single['status'], 'running');
    expect(await ops.pendingTerminalStops(), isEmpty);
  });

  test('a slow exit stays tracked until the terminal ends', () async {
    final ops = MobileOperations(MemorySecretStorage(), 'pc');
    final pc = StopApi()..slow = true;
    expect((await ops.terminalStop(pc, target))['state'], 'stopping');
    expect(await ops.pendingTerminalStops(), hasLength(1));
    pc.terminals.values.single['status'] = 'exited';
    final saved = (await ops.pendingTerminalStops()).single;
    expect((await ops.verifyTerminalStop(pc, saved))!['state'], 'stopped');
  });

  test(
    'pressing close again resends; not waiting only drops the record',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      final pc = StopApi()..loseBefore = true;
      await expectLater(
        ops.terminalStop(pc, target),
        throwsA(isA<RemoteOutcomeUnknown>()),
      );
      await expectLater(
        ops.terminalStop(pc, target),
        throwsA(isA<RemoteOutcomeUnknown>()),
      );
      expect(await ops.pendingTerminalStops(), hasLength(1));
      final saved = (await ops.pendingTerminalStops()).single;
      final calls = pc.calls.length;
      expect(
        (await ops.finishTerminalStopTracking(pc, saved))['state'],
        'abandoned',
      );
      expect(pc.calls.length, calls);
      expect(await ops.pendingTerminalStops(), isEmpty);
    },
  );
}
