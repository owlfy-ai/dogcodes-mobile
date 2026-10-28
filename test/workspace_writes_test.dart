import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/features/tools/terminal_pane.dart';

class MemorySecrets implements SecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

Map<String, dynamic> copy(Map value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

class WorkspacePc implements HostLink {
  final launches = <String, Map<String, dynamic>>{};
  final retired = <String>{};
  final receipts = <String, Map<String, dynamic>>{};
  final writes = <Map<String, dynamic>>[];
  bool drop = false, notAccepted = false, dropRetire = false;
  bool recovery = true;
  Map<String, dynamic>? reject;
  Completer<dynamic>? reading;
  @override
  String get hostId => 'pc';
  @override
  String? get hostName => null;
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<void> close() async {}
  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'remote_capabilities') {
      return {
        'terminalLaunchRecovery': recovery,
        'runOperationRequest': recovery,
      };
    }
    if (method == 'terminal_read') return reading!.future;
    if (method == 'terminal_launch_intents') {
      final id = params['operationId'] as String;
      if (params['type'] == 'retire' && !launches.containsKey(id)) {
        retired.add(id);
      }
      if (params['type'] == 'retire' && dropRetire) {
        throw const RemoteOutcomeUnknown();
      }
      return launches[id] ??
          (retired.contains(id)
              ? {'operationId': id, 'state': 'retired'}
              : null);
    }
    if (method == 'project_run_operation') return receipts[params[1]];
    final request = copy(params as Map), id = request['operationId'] as String;
    writes.add(request);
    if (notAccepted) {
      notAccepted = false;
      throw const RemoteOutcomeUnknown();
    }
    if (method == 'terminal_start' || method == 'project_run_start') {
      if (retired.contains(id)) throw const ProtocolException('原启动已取消');
      launches.putIfAbsent(
        id,
        () => {
          'operationId': id,
          'state': 'accepted',
          'intent': method == 'terminal_start'
              ? request
              : {'projectLaunch': request},
          'terminal': {'id': id, 'projectId': 'project', 'status': 'running'},
        },
      );
      if (drop) {
        drop = false;
        throw const RemoteOutcomeUnknown();
      }
      return launches[id]!['terminal'];
    }
    if (reject != null) return {'Err': reject};
    receipts.putIfAbsent(
      id,
      () => {
        'operationId': id,
        'request': request,
        'generation': 'next',
        'status': method == 'project_runs_analyze' ? 'running' : 'succeeded',
        'error': null,
      },
    );
    if (drop) {
      drop = false;
      throw const RemoteOutcomeUnknown();
    }
    return {
      'Ok': {'generation': 'next'},
    };
  }
}

void main() {
  late MemorySecrets storage;
  late MobileOperations ops;
  late WorkspacePc pc;
  setUp(() {
    storage = MemorySecrets();
    ops = MobileOperations(storage, 'pc');
    pc = WorkspacePc();
  });
  Future<dynamic> terminal() =>
      ops.terminalStart(pc, projectId: 'project', cwd: '/project');
  Future<dynamic> run() => ops.runStart(
    pc,
    projectId: 'project',
    taskId: 'task',
    generation: 'original',
    directoryIndex: 2,
    commandId: 'dev',
  );
  Future<dynamic> edit() => ops.runEdit(
    pc,
    taskId: 'task',
    generation: 'original',
    directoryIndex: 2,
    commandId: 'dev',
    edit: {'action': 'rename', 'label': 'My server'},
  );

  test(
    'PC without recovery support is rejected before a write or pending slot',
    () async {
      pc.recovery = false;
      await expectLater(terminal(), throwsA(isA<ProtocolException>()));
      await expectLater(edit(), throwsA(isA<ProtocolException>()));
      expect(pc.writes, isEmpty);
      expect(await ops.sidePending(), isNull);
    },
  );
  test(
    'lost terminal reply is recovered after restart without launching twice',
    () async {
      pc.drop = true;
      await expectLater(terminal(), throwsA(isA<RemoteOutcomeUnknown>()));
      final saved = await ops.sidePending();
      final result = await MobileOperations(storage, 'pc').verify(pc);
      expect(result['terminal']['id'], saved!['request']['operationId']);
      expect(pc.writes, hasLength(1));
      expect(await ops.sidePending(), isNull);
    },
  );
  test(
    'an additional-directory launch keeps its original recipe after a lost reply',
    () async {
      pc.drop = true;
      await expectLater(
        ops.terminalStart(
          pc,
          projectId: 'project',
          directoryIndex: 2,
          cwd: '/project/extra',
        ),
        throwsA(isA<RemoteOutcomeUnknown>()),
      );
      final saved = await ops.sidePending();
      expect(saved!['request']['directoryIndex'], 2);
      expect(saved['request']['cwd'], '/project/extra');
      final recovered = await MobileOperations(storage, 'pc').retry(pc);
      expect(recovered?['terminal']['id'], saved['request']['operationId']);
      expect(pc.writes, hasLength(1));
      expect(await ops.sidePending(), isNull);
    },
  );
  test(
    'an unaccepted launch retries the same ID and recipe after restart',
    () async {
      pc.notAccepted = true;
      await expectLater(run(), throwsA(isA<RemoteOutcomeUnknown>()));
      final original = copy((await ops.sidePending())!['request']);
      expect(await ops.verify(pc), isNull);
      expect(pc.writes, hasLength(1));
      await MobileOperations(storage, 'pc').retry(pc);
      expect(pc.writes, hasLength(2));
      expect(pc.writes.last, original);
      expect(pc.launches, hasLength(1));
    },
  );
  test('finding an admitted run never invokes the current recipe', () async {
    pc.drop = true;
    await expectLater(run(), throwsA(isA<RemoteOutcomeUnknown>()));
    await ops.retry(pc);
    expect(pc.writes, hasLength(1));
    expect(pc.writes.single['generation'], 'original');
  });
  test(
    'lost rename reply verifies the frozen configuration without another edit',
    () async {
      pc.drop = true;
      await expectLater(edit(), throwsA(isA<RemoteOutcomeUnknown>()));
      final result = await MobileOperations(storage, 'pc').retry(pc);
      expect(result['state'], 'succeeded');
      expect(pc.writes, hasLength(1));
      expect(await ops.sidePending(), isNull);
    },
  );
  test(
    'structured pre-commit rejection releases the slot only without a receipt',
    () async {
      pc.reject = {
        'kind': 'rejected',
        'code': 'version_conflict',
        'message': '配置已更新',
      };
      await expectLater(edit(), throwsA(isA<ProtocolException>()));
      expect(await ops.sidePending(), isNull);
    },
  );
  test('uncertain storage result remains pending', () async {
    pc.reject = {'kind': 'unknown', 'message': '写入待核实'};
    await expectLater(edit(), throwsA(isA<ProtocolException>()));
    expect(await ops.sidePending(), isNotNull);
  });
  test(
    'durably admitted background analysis does not block other phone writes',
    () async {
      final result = await ops.runAnalyze(
        pc,
        taskId: 'task',
        generation: 'original',
        executor: {'providerId': 'fixture'},
        overwrite: true,
      );
      expect(result!['state'], 'running');
      expect(await ops.sidePending(), isNull);
      expect(pc.writes.single['overwriteGeneration'], 'original');
    },
  );
  test(
    'a receipt for different original command or generation stays pending',
    () async {
      pc.drop = true;
      await expectLater(run(), throwsA(isA<RemoteOutcomeUnknown>()));
      pc.launches.values.single['intent']['projectLaunch']['generation'] =
          'other';
      await expectLater(ops.verify(pc), throwsA(isA<ProtocolException>()));
      expect(await ops.sidePending(), isNotNull);
    },
  );
  test(
    'ending launch tracking fences late launches and survives a lost retire reply',
    () async {
      pc.notAccepted = true;
      await expectLater(terminal(), throwsA(isA<RemoteOutcomeUnknown>()));
      final saved = (await ops.sidePending())!;
      pc.dropRetire = true;
      await expectLater(
        ops.finishLaunchTracking(pc, saved),
        throwsA(isA<RemoteOutcomeUnknown>()),
      );
      expect(await ops.sidePending(), isNotNull);
      expect((await ops.verify(pc))['state'], 'retired');
      expect(await ops.sidePending(), isNull);
      await expectLater(
        pc.call('terminal_start', saved['request']),
        throwsA(isA<ProtocolException>()),
      );
      expect(pc.launches, isEmpty);
    },
  );
  test('ending tracking of an admitted terminal keeps its process', () async {
    pc.drop = true;
    await expectLater(terminal(), throwsA(isA<RemoteOutcomeUnknown>()));
    await ops.finishLaunchTracking(pc, (await ops.sidePending())!);
    expect(pc.launches.values.single['terminal']['status'], 'running');
    expect(pc.retired, isEmpty);
    expect(await ops.sidePending(), isNull);
  });
  test('late terminal reader errors do not write disposed notifiers', () async {
    pc.reading = Completer<dynamic>();
    final session = TerminalSession(pc, 'terminal')..start();
    session.dispose();
    pc.reading!.completeError(const RemoteOutcomeUnknown());
    await Future<void>.delayed(Duration.zero);
  });
}
