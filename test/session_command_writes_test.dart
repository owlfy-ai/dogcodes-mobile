import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';

/// One session on the PC; replies can be lost before or after the change.
class SessionPc implements HostApi {
  Map<String, dynamic>? task = {
    'taskId': 'task-a',
    'title': 'Original',
    'streamVersion': '3',
  };
  final receipts = <String, Map<String, dynamic>>{};
  final writes = <Map<String, dynamic>>[];
  bool loseBefore = false, loseAfter = false;
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method == 'bootstrap') {
      return {
        'tasks': [?task],
      };
    }
    final envelope = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(args[0])) as Map,
    );
    final id = envelope['commandId'] as String;
    if (method == 'command_receipt') return receipts[id];
    expect(method, 'execute');
    writes.add(envelope);
    if (loseBefore) throw const RemoteOutcomeUnknown();
    if (receipts[id] == null) {
      if (task == null ||
          envelope['expectedStreamVersion'] != task!['streamVersion']) {
        throw const ProtocolException('Conflict: stale version');
      }
      final data = envelope['payload']['data'] as Map;
      task = envelope['payload']['type'] == 'delete_task'
          ? null
          : {
              ...task!,
              'title': data['title'],
              'streamVersion': '${int.parse(task!['streamVersion']) + 1}',
            };
      receipts[id] = {'commandId': id, 'accepted': true};
    }
    if (loseAfter) throw const RemoteOutcomeUnknown();
    return receipts[id];
  }
}

Map<String, dynamic> original() => {
  'taskId': 'task-a',
  'title': 'Original',
  'streamVersion': '3',
};

void main() {
  test(
    'a lost rename reply is settled by the receipt, not a second rename',
    () async {
      final storage = MemorySecretStorage(), pc = SessionPc()..loseAfter = true;
      await expectLater(
        MobileOperations(storage, 'pc').renameSession(pc, original(), 'New'),
        throwsA(isA<RemoteOutcomeUnknown>()),
      );
      final ops = MobileOperations(storage, 'pc');
      expect((await ops.verify(pc))['state'], 'accepted');
      expect(pc.writes, hasLength(1));
      expect(pc.task!['title'], 'New');
      expect(await ops.pending(), isNull);
    },
  );

  test('a rename that never arrived is sent again', () async {
    final ops = MobileOperations(MemorySecretStorage(), 'pc');
    final pc = SessionPc()..loseBefore = true;
    await expectLater(
      ops.renameSession(pc, original(), 'New'),
      throwsA(isA<RemoteOutcomeUnknown>()),
    );
    expect(await ops.verify(pc), isNull);
    pc.loseBefore = false;
    expect((await ops.retry(pc))['state'], 'accepted');
    expect(pc.task!['title'], 'New');
  });

  test(
    'a session edited elsewhere gets the rename on its current version',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      final pc = SessionPc()..task!['streamVersion'] = '5';
      expect(
        (await ops.renameSession(pc, original(), 'New'))['state'],
        'accepted',
      );
      expect(pc.writes.map((w) => w['expectedStreamVersion']), ['3', '5']);
      expect(pc.task!['title'], 'New');
      expect(await ops.pending(), isNull);
    },
  );

  test('a delete whose session is already gone is done', () async {
    final ops = MobileOperations(MemorySecretStorage(), 'pc');
    final pc = SessionPc()..loseBefore = true;
    await expectLater(
      ops.deleteSession(pc, original()),
      throwsA(isA<RemoteOutcomeUnknown>()),
    );
    pc.task = null;
    expect((await ops.verify(pc))['state'], 'accepted');
    expect(await ops.pending(), isNull);
  });

  test('not waiting any more only drops the phone record', () async {
    final ops = MobileOperations(MemorySecretStorage(), 'pc');
    final pc = SessionPc()..loseBefore = true;
    await expectLater(
      ops.deleteSession(pc, original()),
      throwsA(isA<RemoteOutcomeUnknown>()),
    );
    final saved = (await ops.pending())!;
    final writes = pc.writes.length;
    expect(
      (await ops.finishSessionCommandTracking(pc, saved))['state'],
      'abandoned',
    );
    expect(pc.writes.length, writes);
    expect(await ops.pending(), isNull);
  });
}
