import 'dart:convert';
import 'dart:math';
import 'host_api.dart';
import 'security/secret_storage.dart';
import 'protocol.dart';

part 'session_writes.dart';

String operationId() {
  var value = BigInt.from(DateTime.now().millisecondsSinceEpoch) << 80;
  final random = Random.secure();
  for (var i = 0; i < 10; i++) {
    value |= BigInt.from(random.nextInt(256)) << (8 * i);
  }
  const chars = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  var result = '';
  for (var i = 0; i < 26; i++) {
    result = chars[(value & BigInt.from(31)).toInt()] + result;
    value >>= 5;
  }
  return 'cmd_$result';
}

class MobileOperations {
  MobileOperations(this.storage, this.hostId);
  final SecretStorage storage;
  final String hostId;
  bool _saving = false;
  String get key => 'dogcodes.pending.v1.$hostId';
  Future<void> _storeNew(Map<String, dynamic> value) async {
    if (_saving) throw const ProtocolException('请先核实上一项待确认操作。');
    _saving = true;
    try {
      if (await pending() != null) {
        throw const ProtocolException('请先核实上一项待确认操作。');
      }
      await storage.write(key, jsonEncode(value));
    } finally {
      _saving = false;
    }
  }

  Future<Map<String, dynamic>?> pending() async {
    final value = await storage.read(key);
    return value == null || value == 'null'
        ? null
        : jsonDecode(value) as Map<String, dynamic>;
  }

  Future<dynamic> send(HostApi client, Map<String, dynamic> original) async {
    if (await pending() != null) throw const ProtocolException('请先核实上一项待确认操作。');
    final request = {...original, 'operationId': operationId()};
    await _storeNew({'kind': 'send', 'request': request});
    return _send(client, request);
  }

  Future<dynamic> _send(HostApi client, Map<String, dynamic> request) async {
    final value = await client.call('submission_intents', {
      'type': 'start',
      ...request,
    });
    if (value is Map && value['state'] == 'closed') {
      await storage.write(key, 'null');
    }
    return value;
  }

  Future<dynamic> verify(HostApi client) async {
    final saved = await pending();
    if (saved == null) return null;
    if (saved['kind'] == 'history' || saved['kind'] == 'fork') {
      return verifySession(client, saved);
    }
    if (saved['kind'] == 'approval') {
      final value = await client.call('approval_receipt', [saved['query']]);
      if (value != null && value['delivery'] == 'sent') {
        await storage.write(key, 'null');
      }
      if (value == null) {
        final envelope = Map<String, dynamic>.from(saved['envelope'] as Map);
        final fresh = await client.call('bootstrap', null);
        final task = (fresh['tasks'] as List).where(
          (t) => t['taskId'] == saved['query']['taskId'],
        );
        if (task.isEmpty ||
            parseSequence(task.first['streamVersion'].toString()) >
                parseSequence(envelope['expectedStreamVersion'].toString())) {
          final resolved = await client.call('invalidate_approval_response', [
            saved['query'],
            envelope['expectedStreamVersion'],
          ]);
          if (resolved['status'] == 'invalidated') {
            await storage.write(key, 'null');
          }
          return resolved;
        }
      }
      return value;
    }
    final request = Map<String, dynamic>.from(saved['request'] as Map);
    final value = await client.call('submission_intents', {
      'type': 'get_start',
      'operationId': request['operationId'],
      'request': request,
    });
    if (value is Map && value['state'] == 'closed') {
      await storage.write(key, 'null');
    }
    return value;
  }

  Future<dynamic> retry(HostApi client) async {
    final saved = await pending();
    if (saved == null) return null;
    if (saved['kind'] == 'history' || saved['kind'] == 'fork') {
      final receipt = await verifySession(client, saved);
      if (await pending() == null) return receipt;
      if (receipt is Map && receipt['status'] == 'running') {
        throw const ProtocolException('Fork 正在电脑上执行，请等待并核实。');
      }
      return sendSession(client, saved);
    }
    if (saved['kind'] == 'approval') {
      final found = await verify(client);
      if (await pending() == null) return found;
      if (found != null) throw const ProtocolException('原决定已受理，正在核实交付结果。');
      await client.call('execute', [saved['envelope']]);
      return verify(client);
    }
    final request = Map<String, dynamic>.from(saved['request'] as Map);
    final verified = await verify(client);
    if (verified is Map && verified['state'] == 'closed') return verified;
    return _send(client, request);
  }

  Future<dynamic> abandon(HostApi client) async {
    final saved = await pending();
    if (saved == null) return null;
    if (saved['kind'] != 'send') throw const ProtocolException('请先核实原审批决定。');
    final result = await client.call('submission_intents', {
      'type': 'retire',
      'operationId': saved['request']['operationId'],
    });
    if (result is Map && result['state'] == 'closed') {
      await storage.write(key, 'null');
    }
    return result;
  }

  Future<void> approval(
    HostApi client,
    Map<String, dynamic> task,
    Map<String, dynamic> approval,
    String optionId, {
    Map<String, dynamic>? answer,
  }) async {
    if (await pending() != null) throw const ProtocolException('请先核实上一项待确认操作。');
    final id = operationId();
    final envelope = {
      'schemaVersion': 1,
      'commandId': id,
      'idempotencyKey': id,
      'actor': {'kind': 'local_user'},
      'expectedStreamVersion': task['streamVersion'],
      'issuedAt': DateTime.now().toUtc().toIso8601String(),
      'payload': {
        'type': 'respond_to_approval',
        'data': {
          'taskId': task['taskId'],
          'turnId': approval['turnId'],
          'requestedAtSequence': approval['requestedAtSequence'],
          'approvalId': approval['approvalId'],
          'optionId': optionId,
          'answer': ?answer,
        },
      },
    };
    final query = await client.call('prepare_approval_response', [envelope]);
    await _storeNew({'kind': 'approval', 'query': query, 'envelope': envelope});
    await client.call('execute', [envelope]);
    await verify(client);
  }
}

extension CancelTurn on MobileOperations {
  /// Stops the run the user saw. A running Agent keeps advancing the task
  /// stream, so a version conflict re-reads the task and retries for that
  /// same run only; a run that already ended or changed is left alone.
  Future<void> cancel(HostApi client, Map<String, dynamic> task) async {
    final run = task['activePrimaryRun'];
    if (run is! Map) throw const ProtocolException('任务当前没有在运行。');
    var current = task;
    for (var attempt = 0; ; attempt++) {
      final id = operationId();
      try {
        await client.call('execute', [
          {
            'schemaVersion': 1,
            'commandId': id,
            'idempotencyKey': id,
            'actor': {'kind': 'local_user'},
            'expectedStreamVersion': current['streamVersion'],
            'issuedAt': DateTime.now().toUtc().toIso8601String(),
            'payload': {
              'type': 'cancel_turn',
              'data': {
                'taskId': task['taskId'],
                'turnId': run['turnId'],
                'runId': run['runId'],
              },
            },
          },
        ]);
        return;
      } on ProtocolException catch (e) {
        if (!e.message.contains('Conflict') || attempt >= 4) rethrow;
      }
      final fresh = await client.call('bootstrap', null);
      final match = (fresh['tasks'] as List).where(
        (t) => t['taskId'] == task['taskId'],
      );
      if (match.isEmpty) return;
      current = Map<String, dynamic>.from(match.first as Map);
      final active = current['activePrimaryRun'];
      if (active is! Map || active['runId'] != run['runId']) return;
    }
  }
}
