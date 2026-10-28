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
  bool loseBefore = false,
      loseAfter = false,
      slow = false,
      supportsEpoch = true;
  @override
  Future<dynamic> call(String method, dynamic args) async {
    calls.add(method);
    if (method == 'remote_capabilities') {
      return {'terminalStopEpoch': supportsEpoch};
    }
    final info = terminals[args is Map ? args['terminalId'] : args];
    if (method == 'terminal_get') {
      if (info == null) throw const ProtocolException('终端不存在或属于已清除的后台实例');
      return clone(info);
    }
    expect(method, 'terminal_stop');
    expect(args, {
      'terminalId': target['id'],
      'expectedEpoch': target['epoch'],
    });
    if (loseBefore) throw const RemoteOutcomeUnknown();
    if (info == null) throw const ProtocolException('终端不存在或属于已清除的后台实例');
    if (args['expectedEpoch'] != info['epoch']) return clone(info);
    info['status'] = slow ? 'stopping' : 'exited';
    if (loseAfter) throw const RemoteOutcomeUnknown();
    return clone(info);
  }
}

void main() {
  test(
    'an older PC is rejected before tracking or sending an unsafe bare-ID stop',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      final pc = StopApi()..supportsEpoch = false;
      await expectLater(
        ops.terminalStop(pc, target),
        throwsA(isA<ProtocolException>()),
      );
      expect(pc.calls, ['remote_capabilities']);
      expect(await ops.pendingTerminalStops(), isEmpty);
      expect(pc.terminals.values.single['status'], 'running');
    },
  );

  test(
    'stop sends the frozen epoch; a restart after verification cannot close the replacement',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      final pc = RacingStopApi();
      await expectLater(
        ops.terminalStop(pc, target),
        throwsA(isA<RemoteOutcomeUnknown>()),
      );
      final saved = (await ops.pendingTerminalStops()).single;
      pc.race = true;
      expect((await ops.retryTerminalStop(pc, saved))!['state'], 'rejected');
      expect(pc.current['status'], 'running');
      expect(pc.writes.last, {
        'terminalId': target['id'],
        'expectedEpoch': target['epoch'],
      });
      expect(await ops.pendingTerminalStops(), isEmpty);
    },
  );

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

class RacingStopApi implements HostApi {
  Map<String, dynamic> current = {...target, 'status': 'running'};
  final writes = <dynamic>[];
  bool race = false;
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method == 'remote_capabilities') return {'terminalStopEpoch': true};
    if (method == 'terminal_get') {
      final read = clone(current);
      if (race) {
        current = {...current, 'epoch': 'new-core', 'status': 'running'};
      }
      return read;
    }
    expect(method, 'terminal_stop');
    writes.add(args);
    if (!race) throw const RemoteOutcomeUnknown();
    // A PC enforcing the target checks the epoch; the legacy bare ID stops it.
    if (args is! Map || args['expectedEpoch'] == current['epoch']) {
      current['status'] = 'exited';
    }
    return clone(current);
  }
}
