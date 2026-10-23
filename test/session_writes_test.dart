import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'mobile_operations_test.dart' show Api;

void main() {
  test('older preference snapshots cannot undo a streamed PC update', () {
    final host = HostState({'hostId': 'pc'}, MemorySecretStorage());
    host.acceptHistory({
      'revision': '8',
      'preferences': {
        'tasks': {'a': 'archived'},
      },
    });
    host.acceptHistory({
      'revision': '7',
      'preferences': {
        'tasks': {'a': 'pinned'},
      },
    });
    expect(host.history!['preferences']['tasks']['a'], 'archived');
  });
  test(
    'history edit preserves other preferences and retries only the frozen revision',
    () async {
      final storage = MemorySecretStorage();
      var ops = MobileOperations(storage, 'pc');
      final preferences = {
        'tasks': {'other': 'pinned'},
        'projects': {'p': 'removed'},
        'sorts': {'pinned': 'manual'},
        'orders': {
          'pinned': ['other'],
        },
      };
      final sent = <dynamic>[];
      var reject = true, receipt = false;
      final api = Api((method, args) async {
        if (method == 'history_preferences') {
          return {'revision': '5', 'preferences': preferences};
        }
        if (method == 'command_receipt') {
          return receipt ? {'lastSequence': '88'} : null;
        }
        if (method == 'execute') {
          expect(await ops.sidePending(), isNotNull);
          sent.add(jsonDecode(jsonEncode(args[0])));
          if (reject) throw const RemoteOutcomeUnknown();
          receipt = true;
          return {'lastSequence': '88'};
        }
        throw StateError(method);
      });
      await expectLater(
        ops.setHistoryState(api, 'a', 'archived'),
        throwsA(isA<RemoteOutcomeUnknown>()),
      );
      expect(sent.single['expectedStreamVersion'], '5');
      expect(sent.single['payload']['data'], {
        ...preferences,
        'tasks': {'other': 'pinned', 'a': 'archived'},
      });
      expect(preferences['tasks'], {'other': 'pinned'});
      ops = MobileOperations(storage, 'pc');
      // An unconfirmed archive waits in its own slot: messages are not blocked.
      expect(await ops.pending(), isNull);
      final archive = (await ops.sidePending())!;
      expect(await ops.verify(api, archive), isNull);
      reject = false;
      await ops.retry(api, archive);
      expect(sent, [sent.first, sent.first]);
      expect(await ops.sidePending(), isNull);
    },
  );

  test(
    'lost Fork reply is recovered with the same target after app restart',
    () async {
      final storage = MemorySecretStorage();
      var ops = MobileOperations(storage, 'pc');
      Map? request;
      var forks = 0;
      final api = Api((method, args) async {
        if (method == 'fork_task') {
          expect(await ops.pending(), isNotNull);
          forks++;
          request = Map.from(args[0] as Map);
          throw const RemoteOutcomeUnknown();
        }
        if (method == 'fork_receipt') {
          expect(args, ['source', request!['newTaskId']]);
          return {'request': request, 'completed': true, 'taskAvailable': true};
        }
        throw StateError(method);
      });
      await expectLater(
        ops.fork(api, 'source', 'turn', 'worktree'),
        throwsA(isA<RemoteOutcomeUnknown>()),
      );
      expect(request!['newTaskId'], matches(RegExp(r'^tsk_[0-9A-Z]{26}$')));
      ops = MobileOperations(storage, 'pc');
      final result = await ops.retry(api);
      expect(result['request']['environment'], 'worktree');
      expect(forks, 1);
      expect(await ops.pending(), isNull);
    },
  );

  test(
    'Fork retry keeps source/turn/environment; running and mismatched receipts never create another target',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      final requests = <dynamic>[];
      var state = 'missing';
      final api = Api((method, args) async {
        if (method == 'fork_task') {
          requests.add(jsonDecode(jsonEncode(args[0])));
          throw const RemoteOutcomeUnknown();
        }
        final request = requests.first as Map;
        if (state == 'missing') return null;
        return {
          'request': {...request, if (state == 'wrong') 'newTaskId': 'foreign'},
          'completed': state == 'wrong',
          'taskAvailable': state == 'wrong',
          'status': state,
        };
      });
      await expectLater(
        ops.fork(api, 'source', 'turn', 'workspace'),
        throwsException,
      );
      await expectLater(ops.retry(api), throwsException);
      expect(requests, [requests.first, requests.first]);
      state = 'running';
      await expectLater(ops.retry(api), throwsException);
      expect(requests.length, 2);
      state = 'wrong';
      await expectLater(ops.verify(api), throwsException);
      expect(await ops.pending(), isNotNull);
      await ops.finishSessionTracking();
      expect(await ops.pending(), isNull);
      expect(requests.length, 2);
    },
  );

  test(
    'concurrent writes cannot replace an already saved session operation',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      var calls = 0;
      final api = Api((method, args) async {
        calls++;
        throw const RemoteOutcomeUnknown();
      });
      final results = await Future.wait([
        ops
            .fork(api, 'source', 'a', 'workspace')
            .then((_) => false, onError: (_) => true),
        ops
            .fork(api, 'source', 'b', 'workspace')
            .then((_) => false, onError: (_) => true),
      ]);
      expect(results, [true, true]);
      expect(calls, 1);
      expect((await ops.pending())!['request']['turnId'], 'a');
    },
  );
  test(
    'a pin refused for a stale revision frees the slot for other writes',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      var receipts = 0;
      final api = Api((method, args) async {
        if (method == 'history_preferences') {
          return {
            'revision': '5',
            'preferences': {'tasks': {}},
          };
        }
        if (method == 'execute') {
          throw const ProtocolException('会话设置已在电脑上更新，请重试。');
        }
        if (method == 'command_receipt') {
          receipts++;
          return null;
        }
        throw StateError(method);
      });
      await expectLater(
        ops.setHistoryState(api, 'a', 'pinned'),
        throwsA(isA<ProtocolException>()),
      );
      expect(receipts, 1);
      expect(await ops.sidePending(), isNull);
    },
  );

  test('a refused pin that the PC did apply stays verifiable', () async {
    final ops = MobileOperations(MemorySecretStorage(), 'pc');
    final api = Api((method, args) async {
      if (method == 'history_preferences') {
        return {
          'revision': '5',
          'preferences': {'tasks': {}},
        };
      }
      if (method == 'execute') throw const ProtocolException('拒绝');
      if (method == 'command_receipt') return {'lastSequence': '9'};
      throw StateError(method);
    });
    await expectLater(
      ops.setHistoryState(api, 'a', 'pinned'),
      throwsA(isA<ProtocolException>()),
    );
    expect(await ops.sidePending(), isNotNull);
  });
}
