import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';

class Secrets implements SecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class Api implements HostApi {
  Api(this.handler);
  final Future<dynamic> Function(String, dynamic) handler;
  @override
  Future<dynamic> call(String method, dynamic params) =>
      handler(method, params);
}

void main() {
  test(
    'lost send retains exact original and explicit retry uses the same operation ID',
    () async {
      final operations = MobileOperations(Secrets(), 'host');
      final sent = <Map<String, dynamic>>[];
      var fail = true;
      final api = Api((method, args) async {
        if (args['type'] == 'get_start') return null;
        expect(await operations.pending(), isNotNull);
        sent.add(Map<String, dynamic>.from(args as Map));
        if (fail) throw StateError('lost response');
        return {
          'state': 'closed',
          'resolution': {'status': 'submitted'},
        };
      });
      final original = {
        'scope': 'scope',
        'taskId': null,
        'projectId': 'project',
        'target': {'providerId': 'fake'},
        'input': {
          'prompt': 'keep this message',
          'model': 'model-a',
          'thinking': 'high',
          'attachments': [],
        },
      };
      await expectLater(operations.send(api, original), throwsStateError);
      final pending = await operations.pending();
      expect(pending!['request']['input'], original['input']);
      fail = false;
      await operations.retry(api);
      expect(sent.length, 2);
      expect(sent[0], sent[1]);
      expect(await operations.pending(), null);
    },
  );
  test(
    'unresolved operation blocks a different send without replacing the original',
    () async {
      final operations = MobileOperations(Secrets(), 'host');
      var calls = 0;
      final api = Api((_, _) async {
        calls++;
        throw StateError('disconnected');
      });
      await expectLater(
        operations.send(api, {
          'input': {'prompt': 'original'},
        }),
        throwsStateError,
      );
      final old = await operations.pending();
      await expectLater(
        operations.send(api, {
          'input': {'prompt': 'replacement'},
        }),
        throwsException,
      );
      expect(await operations.pending(), old);
      expect(calls, 1);
    },
  );
  test(
    'stale approval is fenced before clearing its unresolved local record',
    () async {
      final operations = MobileOperations(Secrets(), 'host');
      var fenced = false;
      final api = Api((method, args) async {
        if (method == 'prepare_approval_response') {
          return {'operationId': args[0]['commandId'], 'taskId': 'task'};
        }
        if (method == 'execute') throw StateError('lost response');
        if (method == 'approval_receipt') return null;
        if (method == 'bootstrap') {
          return {
            'tasks': [
              {'taskId': 'task', 'streamVersion': '12'},
            ],
          };
        }
        if (method == 'invalidate_approval_response') {
          fenced = true;
          return {'status': 'invalidated'};
        }
        throw StateError('unexpected');
      });
      await expectLater(
        operations.approval(
          api,
          {'taskId': 'task', 'streamVersion': '9'},
          {'turnId': 'turn', 'approvalId': 'a', 'requestedAtSequence': '8'},
          'allow-once',
        ),
        throwsStateError,
      );
      expect(await operations.pending(), isNotNull);
      await operations.verify(api);
      expect(fenced, true);
      expect(await operations.pending(), null);
    },
  );
}
