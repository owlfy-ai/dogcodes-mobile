import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/core/turn_changes.dart';
import 'package:dogcodes_app/l10n/backend_text.dart';
import 'package:flutter_test/flutter_test.dart';

class Api implements HostApi {
  Api(this.handler);
  final Future<dynamic> Function(String, Map) handler;
  @override
  Future<dynamic> call(String method, dynamic params) =>
      handler(method, params as Map);
}

const meta = {'artifactId': 'art_1', 'payloadSha256': 'abc'};

/// A computer that keeps undo receipts the way the review journal does.
Api computer({String? refusal, List<String>? calls}) {
  final receipts = <String, Map<String, dynamic>>{};
  return Api((method, params) async {
    expect(method, 'review');
    final op = params['operation'] as String;
    final args = params['arguments'] as Map;
    calls?.add(op);
    switch (op) {
      case 'undo':
        receipts[args['operationId'] as String] = {
          'request': {
            'operationId': args['operationId'],
            'taskId': args['request']['taskId'],
            'command': 'core_turn_undo',
            'arguments': {'request': args['request']},
          },
          'outcome': refusal == null
              ? {'status': 'succeeded', 'result': null}
              : {'status': 'failed', 'message': refusal},
        };
        if (refusal != null) throw ProtocolException(refusal);
        return null;
      case 'file_operation':
        return receipts[args['operationId']];
      case 'file_close':
        return {...?receipts[args['operationId']], 'closed': true};
      case 'undo_status':
        return receipts.values.any(
          (r) => r['outcome']['status'] == 'succeeded',
        );
    }
    fail('unexpected $op');
  });
}

void main() {
  test('a turn is undone once and its record is cleared', () async {
    final operations = MobileOperations(MemorySecretStorage(), 'host');
    final calls = <String>[];
    final api = computer(calls: calls);
    expect(await operations.undoStatus(api, 't1', meta), isFalse);

    final result = await operations.undoTurn(api, 't1', meta);
    expect(result['state'], 'succeeded');
    expect(calls, ['undo_status', 'undo', 'file_operation', 'file_close']);
    expect(await operations.sidePending(), isNull);
    expect(await operations.undoStatus(api, 't1', meta), isTrue);
  });

  test(
    'a refused undo explains why in the app language and frees the slot',
    () async {
      final operations = MobileOperations(MemorySecretStorage(), 'host');
      final refusal = 'backendText.undoFileChanged\u001e["src/search.ts"]';
      await expectLater(
        operations.undoTurn(computer(refusal: refusal), 't1', meta),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            'src/search.ts 在本轮结束后又有修改，未撤销任何文件',
          ),
        ),
      );
      expect(await operations.sidePending(), isNull);
    },
  );

  test('desktop message codes are shown as text, plain text is unchanged', () {
    expect(localizeBackendText('backendText.undoNoChanges'), '本轮没有可撤销的文件修改');
    expect(
      displayBackendText('Push failed: backendText.undoNoChanges'),
      'Push failed: 本轮没有可撤销的文件修改',
    );
    expect(
      displayBackendText('remote method unavailable'),
      'remote method unavailable',
    );
    expect(localizeBackendText('backendText.notARealCode'), isNull);
    expect(
      const ProtocolException('backendText.undoNoChanges').message,
      '本轮没有可撤销的文件修改',
    );
  });

  test('a push that needed a password at the computer says what to do', () {
    final text = gitResultMessage({
      'state': 'push_failed',
      'receipt': {
        'outcome': {'message': 'backendText.gitCredentialUnattended'},
      },
    });
    expect(text, startsWith('提交已完成，推送失败：Git 需要输入账号、密码或令牌'));
    expect(text, contains('凭据助手'));
  });

  test('undo is offered only for a complete turn of this conversation', () {
    Map<String, dynamic> capture({
      String attribution = 'workspace_interval',
      bool shared = false,
      bool omitted = false,
    }) => {
      'attribution': attribution,
      'sharedWorkspace': shared,
      'workspacePaths': ['/p'],
      'files': [
        {
          'path': 'a.txt',
          'status': 'M',
          'before': omitted
              ? {'kind': 'file', 'contentOmitted': true}
              : {'kind': 'file', 'hex': '61'},
          'after': {'kind': 'file', 'hex': '62'},
        },
      ],
    };
    expect(TurnChanges.parse(capture()).undoable, isTrue);
    expect(TurnChanges.parse(capture(shared: true)).undoable, isFalse);
    expect(TurnChanges.parse(capture(omitted: true)).undoable, isFalse);
    expect(
      TurnChanges.parse(
        capture(attribution: 'workspace_recovery_interval'),
      ).undoable,
      isFalse,
    );
  });
}
