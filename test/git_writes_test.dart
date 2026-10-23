import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';

class GitPc implements HostApi {
  GitPc(this.ops);
  MobileOperations ops;
  final receipts = <String, Map<String, dynamic>>{};
  final sent = <Map<String, dynamic>>[];
  final advances = <String>[];
  bool lose = false, accept = true, failPush = false, closeAllowed = true;
  int next = 0;
  @override
  Future<dynamic> call(String method, dynamic params) async {
    expect(method, 'review');
    final args = Map<String, dynamic>.from(params['arguments'] as Map);
    final id = args['operationId'] as String;
    switch (params['operation']) {
      case 'git_action':
        expect(await ops.sidePending(), isNotNull);
        sent.add(jsonDecode(jsonEncode(args)) as Map<String, dynamic>);
        if (accept) {
          receipts.putIfAbsent(
            id,
            () => {
              'request': args,
              'outcome': {'status': 'succeeded', 'completed': true},
              'closed': false,
            },
          );
        }
        if (lose) throw const RemoteOutcomeUnknown();
        return true;
      case 'git_operation':
        return receipts[id];
      case 'git_advance':
        advances.add(id);
        final parent = receipts[id]!['request'] as Map;
        final child = parent['workflow']['nextOperationId'] as String;
        return receipts.putIfAbsent(
          child,
          () => {
            'request': {
              'operationId': child,
              'taskId': parent['taskId'],
              'rootId': parent['rootId'],
              'action': 'push',
              'message': '',
              'snapshotId': null,
              'stageAll': false,
              'workflow': {
                'parentOperationId': id,
                'nextOperationId': 'reserved-${++next}',
              },
            },
            'outcome': failPush
                ? {'status': 'failed', 'message': 'offline'}
                : {'status': 'succeeded', 'completed': true},
            'closed': false,
          },
        );
      case 'git_close':
        if (closeAllowed) receipts[id]!['closed'] = true;
        return receipts[id];
    }
    throw StateError('${params['operation']}');
  }
}

Future<Map<String, dynamic>?> start(GitPc pc, {bool push = true}) =>
    pc.ops.gitWrite(
      pc,
      taskId: 't',
      rootId: 'repo',
      action: 'commit',
      snapshotId: 'snapshot',
      message: 'original message',
      stageAll: false,
      push: push,
    );
void main() {
  test(
    'index change receipt survives a lost reply and preserves exact paths',
    () async {
      final storage = MemorySecretStorage();
      var ops = MobileOperations(storage, 'pc');
      Map<String, dynamic>? original;
      Map<String, dynamic>? receipt;
      var writes = 0;
      final pc = IndexPc((op, args) async {
        if (op == 'index') {
          writes++;
          original = Map<String, dynamic>.from(args);
          receipt = {
            'request': {
              'operationId': args['operationId'],
              'taskId': args['taskId'],
              'command': 'core_review_index',
              'arguments': {
                for (final e in args.entries)
                  if (e.key != 'operationId') e.key: e.value,
              },
            },
            'outcome': {'status': 'succeeded', 'result': null},
            'closed': false,
          };
          throw const RemoteOutcomeUnknown();
        }
        return receipt;
      });
      await expectLater(
        ops.indexWrite(
          pc,
          taskId: 't',
          snapshotId: 'frozen',
          rootId: 'repo',
          paths: ['a.txt'],
        ),
        throwsException,
      );
      ops = MobileOperations(storage, 'pc');
      expect((await ops.retry(pc))['state'], 'succeeded');
      expect(writes, 1);
      expect(original!['paths'], ['a.txt']);
      expect(await ops.sidePending(), isNull);
    },
  );

  test(
    'lost commit reply survives restart; verify never starts its push',
    () async {
      final storage = MemorySecretStorage();
      final pc = GitPc(MobileOperations(storage, 'pc'))..lose = true;
      await expectLater(start(pc), throwsA(isA<RemoteOutcomeUnknown>()));
      final original = pc.sent.single;
      pc.ops = MobileOperations(storage, 'pc');
      expect((await pc.ops.verify(pc))['state'], 'awaiting_next');
      expect(pc.advances, isEmpty);
      final result = await pc.ops.retry(pc);
      expect(result['state'], 'succeeded');
      expect(result['pushed'], true);
      expect(pc.sent, [original]);
      expect(pc.advances, [original['operationId']]);
      expect(await pc.ops.sidePending(), isNull);
    },
  );
  test(
    'an unaccepted write retries its original message, snapshot and IDs',
    () async {
      final pc = GitPc(MobileOperations(MemorySecretStorage(), 'pc'))
        ..lose = true
        ..accept = false;
      await expectLater(
        start(pc, push: false),
        throwsA(isA<RemoteOutcomeUnknown>()),
      );
      final first = pc.sent.single;
      pc.lose = false;
      pc.accept = true;
      expect((await pc.ops.retry(pc))['state'], 'succeeded');
      expect(pc.sent, [first, first]);
      expect(await pc.ops.sidePending(), isNull);
    },
  );
  test(
    'failed push advances the reserved next identity without another commit',
    () async {
      final pc = GitPc(MobileOperations(MemorySecretStorage(), 'pc'))
        ..failPush = true;
      expect((await start(pc))!['state'], 'push_failed');
      expect(await pc.ops.sidePending(), isNotNull);
      final failed =
          pc.receipts.values.firstWhere(
                (r) => r['request']['action'] == 'push',
              )['request']
              as Map;
      pc.failPush = false;
      expect((await pc.ops.retry(pc))['state'], 'succeeded');
      expect(pc.sent.length, 1);
      expect(pc.advances.last, failed['operationId']);
      expect(
        pc.receipts.containsKey(failed['workflow']['nextOperationId']),
        true,
      );
    },
  );
  test(
    'unknown outcomes stay tracked and cannot repeat Git side effects',
    () async {
      final pc = GitPc(MobileOperations(MemorySecretStorage(), 'pc'))
        ..lose = true;
      await expectLater(start(pc), throwsException);
      pc.receipts.values.single['outcome'] = {'status': 'unknown'};
      expect((await pc.ops.retry(pc))['state'], 'unknown');
      expect(pc.sent.length, 1);
      expect(pc.advances, isEmpty);
      final saved = (await pc.ops.sidePending())!;
      await pc.ops.finishGitTracking(pc, saved);
      expect(pc.receipts.values.single['closed'], true);
      expect(await pc.ops.sidePending(), isNull);
    },
  );
  test(
    'wrong repository receipt cannot authorize a push or clear tracking',
    () async {
      final pc = GitPc(MobileOperations(MemorySecretStorage(), 'pc'))
        ..lose = true;
      await expectLater(start(pc), throwsException);
      pc.receipts.values.single['request'] = {
        ...pc.sent.single,
        'rootId': 'other',
      };
      await expectLater(pc.ops.verify(pc), throwsException);
      expect(pc.advances, isEmpty);
      expect(await pc.ops.sidePending(), isNotNull);
    },
  );
  test('a failed closure acknowledgement preserves the local record', () async {
    final pc = GitPc(MobileOperations(MemorySecretStorage(), 'pc'))
      ..lose = true
      ..closeAllowed = false;
    await expectLater(start(pc), throwsException);
    await expectLater(
      pc.ops.finishGitTracking(pc, (await pc.ops.sidePending())!),
      throwsException,
    );
    expect(await pc.ops.sidePending(), isNotNull);
  });
}

class IndexPc implements HostApi {
  IndexPc(this.respond);
  final Future<dynamic> Function(String, Map<String, dynamic>) respond;
  @override
  Future<dynamic> call(String method, dynamic params) => respond(
    params['operation'] as String,
    Map<String, dynamic>.from(params['arguments'] as Map),
  );
}
