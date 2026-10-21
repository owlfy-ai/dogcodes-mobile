part of 'mobile_operations.dart';

/// Session writes use the existing durable pending-operation slot. A lost
/// reply never changes the preference revision or generates another Fork ID.
extension SessionWrites on MobileOperations {
  Future<dynamic> setHistoryState(
    HostApi client,
    String taskId,
    String? state,
  ) async {
    if (state != null && state != 'pinned' && state != 'archived') {
      throw const ProtocolException('会话状态无效。');
    }
    final current = await client.call('history_preferences', null);
    if (current is! Map ||
        current['preferences'] is! Map ||
        current['revision'] == null) {
      throw const ProtocolException('无法读取电脑的会话设置，请更新电脑端后重试。');
    }
    final preferences = jsonDecode(jsonEncode(current['preferences'])) as Map;
    final tasks = Map<String, dynamic>.from(preferences['tasks'] as Map? ?? {});
    if (state == null) {
      tasks.remove(taskId);
    } else {
      tasks[taskId] = state;
    }
    preferences['tasks'] = tasks;
    final id = operationId();
    final saved = <String, dynamic>{
      'kind': 'history',
      'taskId': taskId,
      'envelope': {
        'schemaVersion': 1,
        'commandId': id,
        'idempotencyKey': id,
        'actor': {'kind': 'local_user'},
        'expectedStreamVersion': current['revision'],
        'issuedAt': DateTime.now().toUtc().toIso8601String(),
        'payload': {'type': 'set_history_preferences', 'data': preferences},
      },
    };
    await _storeNew(saved);
    return sendSession(client, saved);
  }

  Future<dynamic> fork(
    HostApi client,
    String taskId,
    String turnId,
    String environment,
  ) async {
    if (!['workspace', 'worktree'].contains(environment)) {
      throw const ProtocolException('Fork 环境无效。');
    }
    final saved = <String, dynamic>{
      'kind': 'fork',
      'request': {
        'taskId': taskId,
        'turnId': turnId,
        'newTaskId': operationId().replaceFirst('cmd_', 'tsk_'),
        'environment': environment,
      },
    };
    await _storeNew(saved);
    return sendSession(client, saved);
  }

  Future<dynamic> sendSession(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    if (saved['kind'] == 'history') {
      await client.call('execute', [saved['envelope']]);
    } else {
      final request = saved['request'] as Map;
      final id = await withReplyTimeout(
        const Duration(minutes: 2),
        () => client.call('fork_task', [request]),
      );
      if (id != request['newTaskId']) {
        throw const ProtocolException('Fork 返回的会话身份不一致，请核实原操作。');
      }
    }
    return verifySession(client, saved);
  }

  Future<dynamic> verifySession(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final dynamic result;
    if (saved['kind'] == 'history') {
      result = await client.call('command_receipt', [saved['envelope']]);
      if (result != null) await storage.write(key, 'null');
    } else {
      final request = saved['request'] as Map;
      result = await client.call('fork_receipt', [
        request['taskId'],
        request['newTaskId'],
      ]);
      if (result is Map &&
          result['completed'] == true &&
          result['taskAvailable'] == true) {
        // A receipt for another target must never open an unrelated conversation.
        if (jsonEncode(result['request']) != jsonEncode(request)) {
          final actual = result['request'];
          if (actual is! Map ||
              request.keys.any((k) => actual[k] != request[k])) {
            throw const ProtocolException('Fork 回执与原请求不一致。');
          }
        }
        await storage.write(key, 'null');
      }
    }
    return result;
  }

  /// Explicitly end local tracking. This never cancels an accepted command,
  /// removes a worktree, or sends a replacement request.
  Future<void> finishSessionTracking() async {
    final saved = await pending();
    if (saved?['kind'] != 'history' && saved?['kind'] != 'fork') {
      throw const ProtocolException('这项操作需要先核实结果。');
    }
    await storage.write(key, 'null');
  }
}
