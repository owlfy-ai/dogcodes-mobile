import 'dart:async';
import 'dart:convert';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';

class Api implements HostApi {
  Api(this.handler);
  final Future<dynamic> Function(String, dynamic) handler;
  @override
  Future<dynamic> call(String method, dynamic args) => handler(method, args);
}

class HeldStorage extends MemorySecretStorage {
  final entered = Completer<void>(), release = Completer<void>();
  bool held = false;
  @override
  Future<void> write(String key, String value) async {
    if (!held && key == 'dogcodes.pending.v1.pc' && value != 'null') {
      held = true;
      entered.complete();
      await release.future;
    }
    await super.write(key, value);
  }
}

Future<Object?> outcome(Future<dynamic> future) =>
    future.then<Object?>((value) => value, onError: (Object error) => error);
Future<dynamic> review(MobileOperations ops, HostApi api, String task) =>
    ops.startReview(
      api,
      taskId: task,
      turnId: 'turn',
      kind: 'code',
      executor: {'providerId': 'fake', 'installationId': 'owned'},
    );

void main() {
  test(
    'forget serializes with an admitted journal write and prevents its later dispatch',
    () async {
      final storage = HeldStorage();
      // Use one controlled storage and one computer; no real transport is opened.
      final active = MobileOperations(storage, 'pc');
      var calls = 0;
      final api = Api((_, _) async {
        calls++;
        throw StateError('lost reply');
      });
      final sending = outcome(review(active, api, 'old'));
      await storage.entered.future;
      final forgetting = active.forgetRecoveryJournals();
      storage.release.complete();
      await sending;
      await forgetting;
      expect(calls, 0);
      expect(await storage.read(active.key), isNull);
      expect(await active.pending(), isNull);
    },
  );

  test(
    'independent operation owners cannot overwrite the same durable lane',
    () async {
      final storage = MemorySecretStorage();
      final first = MobileOperations(storage, 'pc'),
          second = MobileOperations(storage, 'pc');
      var calls = 0;
      final api = Api((_, _) async {
        calls++;
        throw StateError('lost reply');
      });
      await Future.wait([
        outcome(review(first, api, 'first')),
        outcome(review(second, api, 'second')),
      ]);
      expect(calls, 1);
      expect((await first.pending())!['request']['taskId'], 'first');
    },
  );

  test(
    'an old review retry cannot execute after tracking was replaced',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      var starts = 0;
      final api = Api((method, _) async {
        if (method == 'turn_reviews') return [];
        if (method == 'start_turn_review') {
          starts++;
          throw StateError('lost reply');
        }
        throw StateError(method);
      });
      await outcome(review(ops, api, 'old'));
      final saved = (await ops.pending())!;
      await ops.finishSessionTracking(saved);
      await outcome(review(ops, api, 'new'));
      final replacement = await ops.pending();
      await outcome(ops.retryReviewWrite(api, saved));
      expect(starts, 2);
      expect(await ops.pending(), replacement);
    },
  );

  test(
    'network replies never hold the journal gate or block the independent workspace lane',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      final entered = Completer<void>(), release = Completer<void>();
      var gitCalls = 0;
      final api = Api((method, args) async {
        if (method == 'submission_intents') {
          entered.complete();
          await release.future;
          throw StateError('lost reply');
        }
        if (method == 'review') {
          gitCalls++;
          return null;
        }
        throw StateError(method);
      });
      final sending = outcome(
        ops.send(api, {
          'input': {'prompt': 'owned'},
        }),
      );
      await entered.future;
      try {
        await ops
            .gitWrite(api, taskId: 't', rootId: 'r', action: 'push')
            .timeout(const Duration(seconds: 1));
        expect(gitCalls, 2);
        expect(await ops.pending(), isNotNull);
        expect(await ops.sidePending(), isNotNull);
      } finally {
        release.complete();
        await sending;
      }
    },
  );
  test(
    'forget invalidates every old owner; queued rebind survives duplicate cleanup',
    () async {
      final storage = HeldStorage();
      final old = MobileOperations(storage, 'pc'),
          other = MobileOperations(storage, 'pc');
      final sent = <String>[];
      final api = Api((method, args) async {
        if (method == 'start_turn_review') {
          sent.add(args[0]['taskId'] as String);
        }
        throw StateError('lost reply');
      });
      final first = outcome(review(old, api, 'old'));
      await storage.entered.future;
      final forgotten = old.forgetRecoveryJournals();
      final fresh = MobileOperations(storage, 'pc');
      final replacement = outcome(review(fresh, api, 'fresh'));
      storage.release.complete();
      await Future.wait([first, forgotten, replacement]);
      expect(sent, ['fresh']);
      expect(
        await outcome(review(other, api, 'obsolete')),
        isA<ProtocolException>(),
      );
      await old.forgetRecoveryJournals();
      await other.forgetRecoveryJournals();
      expect((await fresh.pending())!['request']['taskId'], 'fresh');
      expect(await old.pending(), isNull);
    },
  );

  test(
    'one computer holding storage never blocks a different computer',
    () async {
      final storage = HeldStorage();
      final first = MobileOperations(storage, 'pc'),
          second = MobileOperations(storage, 'other');
      final api = Api((_, _) async => throw StateError('lost reply'));
      final sending = outcome(review(first, api, 'first'));
      await storage.entered.future;
      try {
        await outcome(
          review(second, api, 'second'),
        ).timeout(const Duration(seconds: 1));
        expect(await second.pending(), isNotNull);
      } finally {
        storage.release.complete();
        await sending;
      }
    },
  );

  test(
    'delayed project verification cannot clear a replacement with identical inputs',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      final entered = Completer<void>(), reply = Completer<dynamic>();
      final api = Api((method, args) async {
        if (method == 'host_directories') return {'path': '/project'};
        if (method == 'register_project') throw StateError('lost reply');
        if (method == 'bootstrap') {
          entered.complete();
          return reply.future;
        }
        throw StateError(method);
      });
      await outcome(ops.addProject(api, path: '/project'));
      final old = (await ops.pending())!;
      final verifying = ops.verifyProject(api, old);
      await entered.future;
      await ops.finishSessionTracking(old);
      await outcome(ops.addProject(api, path: '/project'));
      final fresh = (await ops.pending())!;
      expect(fresh['localTrackingId'], isNot(old['localTrackingId']));
      reply.complete({
        'projects': [
          {'projectId': 'p', 'path': '/project'},
        ],
      });
      await verifying;
      expect(await ops.pending(), fresh);
    },
  );

  test(
    'forget during directory verification cannot register the project afterwards',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      final entered = Completer<void>(), reply = Completer<dynamic>();
      var registrations = 0;
      final api = Api((method, _) async {
        if (method == 'host_directories') {
          entered.complete();
          return reply.future;
        }
        registrations++;
        throw StateError(method);
      });
      final adding = outcome(ops.addProject(api, path: '/project'));
      await entered.future;
      await ops.forgetRecoveryJournals();
      reply.complete({'path': '/project'});
      expect(await adding, isA<ProtocolException>());
      expect(registrations, 0);
    },
  );

  test(
    'failed persistence never dispatches and does not wedge later journal actions',
    () async {
      final storage = RejectOnceStorage();
      final ops = MobileOperations(storage, 'pc');
      var starts = 0;
      final api = Api((_, _) async {
        starts++;
        throw StateError('lost reply');
      });
      expect(await outcome(review(ops, api, 'failed')), isA<StateError>());
      expect(starts, 0);
      await outcome(review(ops, api, 'next'));
      expect(starts, 1);
      expect((await ops.pending())!['request']['taskId'], 'next');
    },
  );

  test(
    'closing Git persists across restart and cannot auto push a late commit',
    () async {
      final storage = MemorySecretStorage();
      final ops = MobileOperations(storage, 'pc');
      final entered = Completer<void>(), reply = Completer<dynamic>();
      Map<String, dynamic>? commit;
      var pushes = 0, closes = 0;
      final api = Api((method, params) async {
        expect(method, 'review');
        final args = params['arguments'] as Map;
        switch (params['operation']) {
          case 'git_action':
            commit = jsonDecode(jsonEncode(args)) as Map<String, dynamic>;
            entered.complete();
            return reply.future;
          case 'git_operation':
            return args['operationId'] == commit!['operationId']
                ? {
                    'request': commit,
                    'outcome': {'status': 'succeeded', 'completed': true},
                    'closed': false,
                  }
                : null;
          case 'git_close':
            closes++;
            if (closes == 1) throw StateError('lost close reply');
            return {'request': commit, 'closed': true};
          case 'git_advance':
            pushes++;
            return null;
        }
        throw StateError(params['operation']);
      });
      final sending = outcome(
        ops.gitWrite(
          api,
          taskId: 't',
          rootId: 'r',
          action: 'commit',
          push: true,
        ),
      );
      await entered.future;
      final saved = (await ops.sidePending())!;
      await outcome(ops.finishGitTracking(api, saved));
      expect((await ops.sidePending())!['phase'], 'closing');
      reply.complete(true);
      await sending;
      expect(pushes, 0);
      final restarted = MobileOperations(storage, 'pc');
      expect((await restarted.retry(api))['state'], 'closed');
      expect(closes, 2);
      expect(pushes, 0);
      expect(await restarted.sidePending(), isNull);
    },
  );

  test('closing an unknown launch can only retire after restart', () async {
    final storage = MemorySecretStorage();
    var ops = MobileOperations(storage, 'pc');
    var starts = 0, retires = 0;
    String? id;
    final api = Api((method, args) async {
      if (method == 'remote_capabilities') {
        return {'terminalLaunchRecovery': true};
      }
      if (method == 'terminal_start') {
        starts++;
        id = args['operationId'];
        throw StateError('lost launch reply');
      }
      if (method == 'terminal_launch_intents' && args['type'] == 'retire') {
        retires++;
        if (retires == 1) throw StateError('lost close reply');
        return {'operationId': id, 'state': 'retired'};
      }
      throw StateError('$method $args');
    });
    await outcome(ops.terminalStart(api, projectId: 'p', cwd: '/p'));
    await outcome(ops.finishLaunchTracking(api, (await ops.sidePending())!));
    ops = MobileOperations(storage, 'pc');
    expect((await ops.sidePending())!['phase'], 'closing');
    await ops.retry(api);
    expect(starts, 1);
    expect(retires, 2);
    expect(await ops.sidePending(), isNull);
  });

  test(
    'closing a launch that already ran reports its terminal instead of claiming cancellation',
    () async {
      final storage = MemorySecretStorage();
      var ops = MobileOperations(storage, 'pc');
      Map<String, dynamic>? launch;
      var retires = 0, starts = 0;
      final api = Api((method, args) async {
        if (method == 'remote_capabilities') {
          return {'terminalLaunchRecovery': true};
        }
        if (method == 'terminal_start') {
          starts++;
          launch = jsonDecode(jsonEncode(args)) as Map<String, dynamic>;
          throw StateError('lost launch reply');
        }
        if (method == 'terminal_launch_intents') {
          if (args['type'] == 'retire' && ++retires == 1) {
            throw StateError('lost retire reply');
          }
          return {
            'state': 'accepted',
            'operationId': launch!['operationId'],
            'intent': launch,
            'terminal': {
              'id': launch!['operationId'],
              'projectId': 'p',
              'status': 'running',
            },
          };
        }
        throw StateError(method);
      });
      await outcome(ops.terminalStart(api, projectId: 'p', cwd: '/p'));
      await outcome(ops.finishLaunchTracking(api, (await ops.sidePending())!));
      ops = MobileOperations(storage, 'pc');
      final result = await ops.retry(api);
      expect(result['state'], 'confirmed');
      expect(result['terminal']['id'], launch!['operationId']);
      expect(starts, 1);
      expect(await ops.sidePending(), isNull);
    },
  );

  test(
    'closing an unknown submission never resends the task after restart',
    () async {
      final storage = MemorySecretStorage();
      var ops = MobileOperations(storage, 'pc');
      var starts = 0, retires = 0;
      final api = Api((method, args) async {
        expect(method, 'submission_intents');
        if (args['type'] == 'start') {
          starts++;
          throw StateError('lost start reply');
        }
        if (args['type'] == 'retire') {
          retires++;
          if (retires == 1) throw StateError('lost retire reply');
          return {'state': 'closed'};
        }
        throw StateError(args['type']);
      });
      await outcome(
        ops.send(api, {
          'input': {'prompt': 'task'},
        }),
      );
      await outcome(ops.abandon(api));
      ops = MobileOperations(storage, 'pc');
      expect((await ops.pending())!['phase'], 'closing');
      await ops.retry(api);
      expect(starts, 1);
      expect(retires, 2);
      expect(await ops.pending(), isNull);
    },
  );
  test(
    'failed removal blocks fresh owners until cleanup is successfully retried',
    () async {
      final storage = FailedRemovalStorage();
      final old = MobileOperations(storage, 'pc');
      var writes = 0;
      final api = Api((_, _) async {
        writes++;
        throw StateError('lost reply');
      });
      await outcome(review(old, api, 'old'));
      expect(await outcome(old.forgetRecoveryJournals()), isA<StateError>());
      final fresh = MobileOperations(storage, 'pc');
      expect(
        await outcome(review(fresh, api, 'blocked')),
        isA<ProtocolException>(),
      );
      expect(writes, 1);
      await old.forgetRecoveryJournals();
      await outcome(review(fresh, api, 'fresh'));
      expect(writes, 2);
      await old.forgetRecoveryJournals();
      expect((await fresh.pending())!['request']['taskId'], 'fresh');
    },
  );

  test(
    'obsolete cancellation cannot replay or clear a newer stop for the same run',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      final task = <String, dynamic>{
        'taskId': 't',
        'streamVersion': '1',
        'activePrimaryRun': {'runId': 'r', 'turnId': 'turn'},
      };
      var stops = 0;
      final api = Api((method, _) async {
        if (method == 'execute') {
          stops++;
          throw StateError('lost reply');
        }
        if (method == 'command_receipt') return null;
        if (method == 'bootstrap') {
          return {
            'tasks': [task],
          };
        }
        throw StateError(method);
      });
      await outcome(ops.cancel(api, task));
      final old = (await ops.pendingCancellations()).single;
      await ops.finishCancelTracking(api, old);
      await outcome(ops.cancel(api, task));
      final current = (await ops.pendingCancellations()).single;
      expect(
        await outcome(ops.retryCancel(api, old)),
        isA<ProtocolException>(),
      );
      expect(stops, 2);
      await ops.finishCancelTracking(api, old);
      expect((await ops.pendingCancellations()).single, current);
    },
  );

  test(
    'obsolete terminal close cannot replay against replacement tracking',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      final terminal = <String, dynamic>{
        'id': 'term',
        'epoch': 'e',
        'status': 'running',
      };
      var stops = 0;
      final api = Api((method, _) async {
        if (method == 'remote_capabilities') return {'terminalStopEpoch': true};
        if (method == 'terminal_stop') {
          stops++;
          throw StateError('lost reply');
        }
        if (method == 'terminal_get') return terminal;
        throw StateError(method);
      });
      await outcome(ops.terminalStop(api, terminal));
      final old = (await ops.pendingTerminalStops()).single;
      await ops.finishTerminalStopTracking(api, old);
      await outcome(ops.terminalStop(api, terminal));
      final current = (await ops.pendingTerminalStops()).single;
      expect(
        await outcome(ops.retryTerminalStop(api, old)),
        isA<ProtocolException>(),
      );
      expect(stops, 2);
      await ops.finishTerminalStopTracking(api, old);
      expect((await ops.pendingTerminalStops()).single, current);
    },
  );
}

class RejectOnceStorage extends MemorySecretStorage {
  bool failed = false;
  @override
  Future<void> write(String key, String value) async {
    if (!failed) {
      failed = true;
      throw StateError('disk write failed');
    }
    await super.write(key, value);
  }
}

class FailedRemovalStorage extends MemorySecretStorage {
  bool failed = false;
  @override
  Future<void> delete(String key) async {
    if (!failed && key.endsWith('.side')) {
      failed = true;
      throw StateError('delete failed');
    }
    await super.delete(key);
  }
}
