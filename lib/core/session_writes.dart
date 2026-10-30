part of 'mobile_operations.dart';

/// Session writes use the existing durable pending-operation slot. A lost
/// reply never changes the preference revision or generates another Fork ID.
extension SessionWrites on MobileOperations {
  Future<dynamic> renameSession(
    HostApi client,
    Map<String, dynamic> task,
    String title,
  ) => _editSession(client, task, title: title);
  Future<dynamic> deleteSession(HostApi client, Map<String, dynamic> task) =>
      _editSession(client, task);

  Future<dynamic> _editSession(
    HostApi client,
    Map<String, dynamic> task, {
    String? title,
  }) async {
    final taskId = task['taskId'], version = task['streamVersion'];
    final parsed = BigInt.tryParse('$version');
    if (taskId is! String ||
        taskId.isEmpty ||
        parsed == null ||
        parsed.isNegative ||
        parsed > BigInt.parse('18446744073709551615')) {
      throw ProtocolException(tr("会话版本不可用，请刷新后重试。"));
    }
    final clean = title?.trim();
    if (clean != null &&
        (clean.isEmpty ||
            clean.runes.length > 120 ||
            RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(clean))) {
      throw ProtocolException(tr("会话名称需为 1–120 个字符，且不能包含控制字符。"));
    }
    final saved = _sessionIntent(task, clean);
    await _storeNew(saved);
    return sendSession(client, saved);
  }

  Map<String, dynamic> _sessionIntent(
    Map<String, dynamic> task,
    String? clean,
  ) {
    final taskId = task['taskId'], version = task['streamVersion'];
    final id = operationId();
    return <String, dynamic>{
      'kind': 'session',
      'action': clean == null ? 'delete' : 'rename',
      'taskId': taskId,
      'taskTitle': task['title'],
      'envelope': {
        'schemaVersion': 1,
        'commandId': id,
        'idempotencyKey': id,
        'actor': {'kind': 'local_user'},
        'expectedStreamVersion': '$version',
        'issuedAt': DateTime.now().toUtc().toIso8601String(),
        'payload': {
          'type': clean == null ? 'delete_task' : 'rename_task',
          'data': {'taskId': taskId, 'title': ?clean},
        },
      },
    };
  }

  /// Renaming to the same title or deleting a deleted session again changes
  /// nothing, so a lost reply is settled by looking at the session itself.
  Future<Map<String, dynamic>?> _sessionSettled(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final envelope = saved['envelope'] as Map;
    final receipt = await client.call('command_receipt', [envelope]);
    final fresh = receipt == null ? await client.call('bootstrap', null) : null;
    final task = fresh is Map && fresh['tasks'] is List
        ? (fresh['tasks'] as List)
              .where((t) => t is Map && t['taskId'] == saved['taskId'])
              .firstOrNull
        : null;
    final title = envelope['payload']['data']['title'];
    final done =
        receipt != null ||
        (fresh is Map &&
            (saved['action'] == 'delete'
                ? task == null
                : task is Map && task['title'] == title));
    if (!done) return null;
    await _clearIfCurrent(saved);
    return {
      'sessionReceipt': receipt is Map ? receipt : const {},
      'taskId': saved['taskId'],
      'action': saved['action'],
      'state': 'accepted',
    };
  }

  Future<dynamic> setHistoryState(
    HostApi client,
    String taskId,
    String? state,
  ) async {
    if (state != null && state != 'pinned' && state != 'archived') {
      throw ProtocolException(tr("会话状态无效。"));
    }
    return _setHistoryEntry(client, 'tasks', 'taskId', taskId, state);
  }

  /// Pins, removes (hides; sessions and files stay) or restores a project in
  /// the PC's shared project list, exactly as the desktop does.
  Future<dynamic> setProjectState(
    HostApi client,
    String projectId,
    String? state,
  ) async {
    if (state != null && state != 'pinned' && state != 'removed') {
      throw ProtocolException(tr("项目状态无效。"));
    }
    return _setHistoryEntry(client, 'projects', 'projectId', projectId, state);
  }

  Future<dynamic> _setHistoryEntry(
    HostApi client,
    String section,
    String idKey,
    String id,
    String? state,
  ) async {
    final current = await client.call('history_preferences', null);
    if (current is! Map ||
        current['preferences'] is! Map ||
        current['revision'] == null) {
      throw ProtocolException(tr("无法读取电脑的会话设置，请更新电脑端后重试。"));
    }
    final preferences = jsonDecode(jsonEncode(current['preferences'])) as Map;
    final entries = Map<String, dynamic>.from(
      preferences[section] as Map? ?? {},
    );
    if (state == null) {
      entries.remove(id);
    } else {
      entries[id] = state;
    }
    preferences[section] = entries;
    final command = operationId();
    final saved = <String, dynamic>{
      'kind': 'history',
      idKey: id,
      'envelope': {
        'schemaVersion': 1,
        'commandId': command,
        'idempotencyKey': command,
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
      throw ProtocolException(tr("Fork 环境无效。"));
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
    if (saved['kind'] == 'session') {
      try {
        await _write(client, 'execute', [saved['envelope']], saved: saved);
      } on ProtocolException catch (e) {
        // The session changed since the request was built: done already, or
        // send the same change again on its current version.
        if (!e.message.contains('Conflict')) {
          await _releaseRejectedCommand(client, saved);
          rethrow;
        }
        final settled = await _sessionSettled(client, saved);
        if (settled != null) return settled;
        final fresh = await client.call('bootstrap', null);
        final task = (fresh is Map && fresh['tasks'] is List)
            ? (fresh['tasks'] as List)
                  .where((t) => t is Map && t['taskId'] == saved['taskId'])
                  .firstOrNull
            : null;
        if (task is! Map) rethrow;
        final next = _sessionIntent(
          Map<String, dynamic>.from(task),
          saved['envelope']['payload']['data']['title'] as String?,
        );
        await _replaceCurrent(saved, next);
        await _write(client, 'execute', [next['envelope']], saved: next);
        return verifySession(client, next);
      }
    } else if (saved['kind'] == 'history') {
      try {
        await _write(client, 'execute', [saved['envelope']], saved: saved);
      } on ProtocolException {
        // A definite answer; lost replies stay tracked for verification.
        await _releaseRejectedCommand(client, saved);
        rethrow;
      }
    } else {
      final request = saved['request'] as Map;
      final id = await withReplyTimeout(
        const Duration(minutes: 2),
        () => _write(client, 'fork_task', [request], saved: saved),
      );
      if (id != request['newTaskId']) {
        throw ProtocolException(tr("Fork 返回的会话身份不一致，请核实原操作。"));
      }
    }
    return verifySession(client, saved);
  }

  /// The PC answered and refused (typically a stale preference revision). With
  /// no receipt nothing was applied, so the slot is freed: a frozen envelope
  /// could never succeed on retry and would block every other phone write.
  Future<void> _releaseRejectedCommand(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final dynamic receipt;
    try {
      receipt = await client.call('command_receipt', [saved['envelope']]);
    } catch (_) {
      return;
    }
    if (receipt == null) await _clearIfCurrent(saved);
  }

  /// Stop waiting locally. A change that already reached the PC still applies.
  Future<dynamic> finishSessionCommandTracking(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    if (saved['kind'] != 'session') {
      throw ProtocolException(tr("没有待确认的会话操作。"));
    }
    await _clearIfCurrent(saved);
    return {
      'sessionReceipt': const {},
      'taskId': saved['taskId'],
      'action': saved['action'],
      'state': 'abandoned',
    };
  }

  Future<void> _replaceCurrent(
    Map<String, dynamic> current,
    Map<String, dynamic> next,
  ) => _journalSerial(() async {
    await _requireBindingActive();
    if (!_sameRecoveryValue(await _current(current), current)) {
      throw ProtocolException(tr("原操作已变化，请刷新。"));
    }
    _requireJournalActive();
    next['localTrackingId'] ??= current['localTrackingId'] ?? operationId();
    if (bindingEpoch != null) next['localBindingEpoch'] = bindingEpoch;
    await storage.write(_laneKey(current['kind']), jsonEncode(next));
    _requireJournalActive();
  });

  Future<dynamic> verifySession(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final dynamic result;
    if (saved['kind'] == 'session') return _sessionSettled(client, saved);
    if (saved['kind'] == 'history') {
      result = await client.call('command_receipt', [saved['envelope']]);
      if (result != null) await _clearIfCurrent(saved);
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
            throw ProtocolException(tr("Fork 回执与原请求不一致。"));
          }
        }
        await _clearIfCurrent(saved);
      }
    }
    return result;
  }

  /// Explicitly end local tracking. This never cancels an accepted command,
  /// removes a worktree, or sends a replacement request.
  Future<void> finishSessionTracking([Map<String, dynamic>? operation]) async {
    final saved = operation ?? await pending();
    if (![
      'history',
      'fork',
      'project',
      'review',
      'repair',
    ].contains(saved?['kind'])) {
      throw ProtocolException(tr("这项操作需要先核实结果。"));
    }
    await _clearIfCurrent(saved!);
  }
}
