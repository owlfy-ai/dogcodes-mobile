import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'mobile_operations_test.dart' show Api;

void main() {
  const path = r'C:\Work\my app';
  test(
    'late registration verification cannot erase a newer pending task',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      final reply = Completer<dynamic>();
      final api = Api((method, args) async {
        if (method == 'host_directories') return {'path': path};
        if (method == 'bootstrap') return reply.future;
        throw const RemoteOutcomeUnknown();
      });
      await expectLater(ops.addProject(api, path: path), throwsException);
      final checking = ops.verify(api);
      await Future<void>.delayed(Duration.zero);
      await ops.finishSessionTracking();
      await expectLater(
        ops.send(api, {
          'input': {'prompt': 'keep new task'},
        }),
        throwsException,
      );
      reply.complete({
        'projects': [
          {'projectId': 'prj_old', 'path': path, 'additionalDirectories': []},
        ],
      });
      expect((await checking)['projectId'], 'prj_old');
      expect(
        (await ops.pending())!['request']['input']['prompt'],
        'keep new task',
      );
    },
  );
  test(
    'lost registration reply is verified after restart without registering twice',
    () async {
      final storage = MemorySecretStorage();
      var ops = MobileOperations(storage, 'pc');
      final projects = <Map<String, dynamic>>[];
      var registrations = 0;
      final api = Api((method, args) async {
        if (method == 'host_directories') return {'path': path, 'entries': []};
        if (method == 'bootstrap') return {'projects': projects};
        expect(method, 'register_project');
        expect(await ops.pending(), isNotNull);
        registrations++;
        expect(args[0], {
          'path': path,
          'displayName': 'My App',
          'additionalDirectories': [],
        });
        projects.add({
          'projectId': 'prj_new',
          ...Map<String, dynamic>.from(args[0] as Map),
        });
        throw const RemoteOutcomeUnknown();
      });
      await expectLater(
        ops.addProject(api, path: path, displayName: '  My App  '),
        throwsA(isA<RemoteOutcomeUnknown>()),
      );
      ops = MobileOperations(storage, 'pc');
      final result = await ops.retry(api);
      expect(result['projectId'], 'prj_new');
      expect(registrations, 1);
      expect(await ops.pending(), isNull);
    },
  );
  test(
    'explicit retry retains the canonical request; missing verification never auto-registers',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      final requests = <dynamic>[];
      final api = Api((method, args) async {
        if (method == 'host_directories') return {'path': path};
        if (method == 'bootstrap') return {'projects': []};
        requests.add(jsonDecode(jsonEncode(args[0])));
        throw const RemoteOutcomeUnknown();
      });
      await expectLater(ops.addProject(api, path: path), throwsException);
      expect(await ops.verify(api), isNull);
      expect(requests.length, 1);
      await expectLater(
        ops.addProject(api, path: '/different'),
        throwsException,
      );
      await expectLater(ops.retry(api), throwsException);
      expect(requests, [requests.first, requests.first]);
      expect((await ops.pending())!['request']['path'], path);
    },
  );
  test(
    'verification follows PC duplicate semantics including names and extra roots',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      var projects = <dynamic>[];
      final api = Api((method, args) async {
        if (method == 'host_directories') return {'path': path};
        if (method == 'bootstrap') return {'projects': projects};
        throw const RemoteOutcomeUnknown();
      });
      await expectLater(ops.addProject(api, path: path), throwsException);
      projects = [
        {
          'projectId': 'prj_other',
          'path': path,
          'displayName': 'Renamed',
          'additionalDirectories': ['/other'],
        },
      ];
      expect(await ops.verify(api), isNull);
      projects.single['additionalDirectories'] = [];
      expect((await ops.verify(api))['projectId'], 'prj_other');
      expect(await ops.pending(), isNull);
      await expectLater(
        ops.addProject(api, path: path, displayName: 'Custom'),
        throwsException,
      );
      expect(await ops.verify(api), isNull);
    },
  );
  test(
    'a changed canonical target or wrong registration result remains unconfirmed',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc');
      var redirected = true, calls = 0;
      final api = Api((method, args) async {
        if (method == 'host_directories') {
          return {'path': redirected ? '/elsewhere' : path};
        }
        if (method == 'bootstrap') {
          return {
            'projects': [
              {
                'projectId': 'prj_other',
                'path': path,
                'additionalDirectories': [],
              },
            ],
          };
        }
        calls++;
        return {'projectId': 'prj_wrong', 'created': true};
      });
      await expectLater(ops.addProject(api, path: path), throwsException);
      expect(calls, 0);
      await ops.finishSessionTracking();
      redirected = false;
      expect(await ops.addProject(api, path: path), isNull);
      expect(await ops.pending(), isNotNull);
    },
  );
}
