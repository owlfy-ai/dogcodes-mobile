import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';

Map<String, dynamic> task({
  String version = '1',
  String run = 'run-a',
  String state = 'running',
}) => {
  'taskId': 'task',
  'title': 'Original task',
  'streamVersion': version,
  'activePrimaryRun': {'runId': run, 'turnId': 'turn-a', 'state': state},
};
Map<String, dynamic> copy(Map value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

/// The PC side of a stop: receipts by command identity, a task that may have
/// moved on, and replies that can be lost before or after taking effect.
class CancelApi implements HostApi {
  final calls = <String>[],
      writes = <Map<String, dynamic>>[],
      receipts = <String, Map<String, dynamic>>{};
  Map<String, dynamic> current = task(version: '2');
  int conflicts = 0;
  bool loseBefore = false, loseAfter = false;
  @override
  Future<dynamic> call(String method, dynamic args) async {
    calls.add(method);
    if (method == 'bootstrap') {
      return {
        'tasks': [current],
      };
    }
    final envelope = copy(args[0] as Map), id = envelope['commandId'] as String;
    if (method == 'command_receipt') return receipts[id];
    expect(method, 'execute');
    writes.add(envelope);
    if (loseBefore) throw const RemoteOutcomeUnknown();
    if (conflicts-- > 0) {
      throw const ProtocolException('Conflict: stale version');
    }
    receipts.putIfAbsent(id, () => {'commandId': id, 'accepted': true});
    if (loseAfter) throw const RemoteOutcomeUnknown();
    return receipts[id];
  }
}

void main() {
  test(
    'a lost reply is settled by the receipt without stopping again',
    () async {
      final storage = MemorySecretStorage(),
          api = CancelApi()..loseAfter = true;
      await expectLater(
        MobileOperations(storage, 'pc').cancel(api, task()),
        throwsA(isA<RemoteOutcomeUnknown>()),
      );
      final ops = MobileOperations(storage, 'pc');
      final saved = (await ops.pendingCancellations()).single;
      expect((await ops.verifyCancel(api, saved))['state'], 'accepted');
      expect(api.writes, hasLength(1));
      expect(await ops.pendingCancellations(), isEmpty);
    },
  );

  test('a stop that never arrived is simply sent again', () async {
    final ops = MobileOperations(MemorySecretStorage(), 'pc');
    final api = CancelApi()..loseBefore = true;
    await expectLater(
      ops.cancel(api, task()),
      throwsA(isA<RemoteOutcomeUnknown>()),
    );
    final saved = (await ops.pendingCancellations()).single;
    expect(await ops.verifyCancel(api, saved), isNull);
    api.loseBefore = false;
    expect((await ops.retryCancel(api, saved))['state'], 'accepted');
    expect(await ops.pendingCancellations(), isEmpty);
  });

  test('a moved-on task gets a fresh stop for the same run', () async {
    final ops = MobileOperations(MemorySecretStorage(), 'pc');
    final api = CancelApi()..conflicts = 1;
    expect((await ops.cancel(api, task()))['state'], 'accepted');
    expect(api.writes.map((w) => w['expectedStreamVersion']), ['1', '2']);
    expect(api.writes.map((w) => w['payload']['data']['runId']).toSet(), {
      'run-a',
    });
  });

  test('a run that already ended needs no stop', () async {
    final ops = MobileOperations(MemorySecretStorage(), 'pc');
    final api = CancelApi()
      ..conflicts = 1
      ..current = task(version: '3', run: 'run-b');
    expect((await ops.cancel(api, task()))['state'], 'target_finished');
    expect(api.writes, hasLength(1));
    expect(await ops.pendingCancellations(), isEmpty);
  });

  test('pressing Stop again resends the earlier stop', () async {
    final ops = MobileOperations(MemorySecretStorage(), 'pc');
    final api = CancelApi()..loseBefore = true;
    await expectLater(
      ops.cancel(api, task()),
      throwsA(isA<RemoteOutcomeUnknown>()),
    );
    final first = (await ops.pendingCancellations()).single;
    api.loseBefore = false;
    expect((await ops.cancel(api, task(version: '2')))['state'], 'accepted');
    expect(api.writes.map((w) => w['commandId']).toSet(), {
      first['envelope']['commandId'],
    });
  });

  test('not waiting any more only drops the phone record', () async {
    final ops = MobileOperations(MemorySecretStorage(), 'pc');
    final api = CancelApi()..loseBefore = true;
    await expectLater(
      ops.cancel(api, task()),
      throwsA(isA<RemoteOutcomeUnknown>()),
    );
    final saved = (await ops.pendingCancellations()).single;
    final calls = api.calls.length;
    expect((await ops.finishCancelTracking(api, saved))['state'], 'abandoned');
    expect(api.calls.length, calls);
    expect(await ops.pendingCancellations(), isEmpty);
  });

  test('stops never wait behind other unconfirmed operations', () async {
    final ops = MobileOperations(MemorySecretStorage(), 'pc');
    await expectLater(
      ops.send(_Lost(), {
        'input': {'prompt': 'x'},
      }),
      throwsA(isA<RemoteOutcomeUnknown>()),
    );
    expect(await ops.pending(), isNotNull);
    expect((await ops.cancel(CancelApi(), task()))['state'], 'accepted');
  });
}

class _Lost implements HostApi {
  @override
  Future<dynamic> call(String method, dynamic args) async =>
      throw const RemoteOutcomeUnknown();
}
