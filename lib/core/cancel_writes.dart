part of 'mobile_operations.dart';

extension CancelWrites on MobileOperations {
  String get _cancelKey => 'dogcodes.cancel.v1.$hostId';
  String _cancelTarget(Map saved) => jsonEncode([
    saved['taskId'],
    saved['envelope']['payload']['data']['runId'],
  ]);
  Future<Map<String, dynamic>> _readCancels() async {
    if (_journalsForgotten || _scope.cleanupPending) return {};
    if (!await _scope.matches(bindingEpoch)) return {};
    final raw = await storage.read(_cancelKey);
    if (_journalsForgotten || _scope.cleanupPending) return {};
    if (!await _scope.matches(bindingEpoch)) return {};
    if (raw == null || raw == 'null') return {};
    final all = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    if (bindingEpoch == null) return all;
    return {
      for (final entry in all.entries)
        if (entry.value is Map &&
            entry.value['localBindingEpoch'] == bindingEpoch)
          entry.key: entry.value,
    };
  }

  Future<List<Map<String, dynamic>>> pendingCancellations() => _journalSerial(
    () async => [
      for (final value in (await _readCancels()).values)
        Map<String, dynamic>.from(value as Map),
    ],
  );
  Future<Map<String, dynamic>?> pendingCancellation() =>
      _journalSerial(() async {
        final all = await _readCancels();
        return all.isEmpty
            ? null
            : Map<String, dynamic>.from(all.values.first as Map);
      });
  Future<void> _storeCancel(Map<String, dynamic> saved) => _journalSerial(
    () async {
      await _requireBindingActive();
      final all = await _readCancels(), target = _cancelTarget(saved);
      if (_journalsForgotten) throw const ProtocolException('这台电脑已移除，未发送停止请求。');
      if (all.containsKey(target)) {
        throw const ProtocolException('这个任务已经有一个停止请求在等待确认。');
      }
      if (all.length >= 64) {
        throw const ProtocolException('等待确认的停止请求太多，请先处理待处理页里的卡片。');
      }
      if (bindingEpoch != null) saved['localBindingEpoch'] = bindingEpoch;
      all[target] = saved;
      await storage.write(_cancelKey, jsonEncode(all));
      if (_journalsForgotten) throw const ProtocolException('这台电脑已移除，未发送停止请求。');
    },
  );
  Future<void> _clearCancel(Map<String, dynamic> saved) =>
      _journalSerial(() async {
        if (_journalsForgotten) return;
        final all = await _readCancels(), target = _cancelTarget(saved);
        if (_sameGitValue(all[target], saved)) {
          all.remove(target);
          await storage.write(_cancelKey, jsonEncode(all));
        }
      });
  Future<void> forgetCancellations() => forgetRecoveryJournals();

  Map<String, dynamic> _cancelIntent(Map<String, dynamic> task) {
    final run = task['activePrimaryRun'];
    if (run is! Map ||
        run['runId'] is! String ||
        run['turnId'] is! String ||
        task['taskId'] is! String) {
      throw const ProtocolException('任务当前没有可停止的运行。');
    }
    parseSequence('${task['streamVersion']}');
    final id = operationId();
    return {
      'kind': 'cancel',
      'taskId': task['taskId'],
      'taskTitle': task['title'],
      'envelope': {
        'schemaVersion': 1,
        'commandId': id,
        'idempotencyKey': id,
        'actor': {'kind': 'local_user'},
        'expectedStreamVersion': '${task['streamVersion']}',
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
    };
  }

  Future<dynamic> cancel(HostApi client, Map<String, dynamic> task) async {
    final saved = _cancelIntent(task);
    // Pressing Stop again for the same run just resends the earlier stop.
    final earlier = (await pendingCancellations())
        .where((c) => _cancelTarget(c) == _cancelTarget(saved))
        .firstOrNull;
    if (earlier != null) return retryCancel(client, earlier);
    await _storeCancel(saved);
    return sendCancel(client, saved);
  }

  /// Stopping one run twice is harmless, so recovery never needs a fence:
  /// a receipt means the PC took it; a run that is no longer active needs
  /// no stop; otherwise it is still unknown and can simply be sent again.
  Future<dynamic> verifyCancel(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final envelope = saved['envelope'] as Map;
    final receipt = await client.call('command_receipt', [envelope]);
    if (receipt is Map && receipt['commandId'] == envelope['commandId']) {
      await _clearCancel(saved);
      return {
        'cancelReceipt': Map<String, dynamic>.from(receipt),
        'state': 'accepted',
        'taskId': saved['taskId'],
      };
    }
    if (await _activeRun(client, saved) == null) {
      await _clearCancel(saved);
      return {'cancelReceipt': const {}, 'state': 'target_finished'};
    }
    return null;
  }

  /// The task, while the run this stop targets is still running.
  Future<Map<String, dynamic>?> _activeRun(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final fresh = await client.call('bootstrap', null);
    if (fresh is! Map || fresh['tasks'] is! List) {
      throw const ProtocolException('暂时无法读取任务状态，请稍后再确认。');
    }
    final task = (fresh['tasks'] as List)
        .where((t) => t is Map && t['taskId'] == saved['taskId'])
        .firstOrNull;
    final active = task is Map ? task['activePrimaryRun'] : null;
    final target = saved['envelope']['payload']['data'] as Map;
    return active is Map &&
            active['runId'] == target['runId'] &&
            active['turnId'] == target['turnId']
        ? Map<String, dynamic>.from(task as Map)
        : null;
  }

  Future<dynamic> sendCancel(
    HostApi client,
    Map<String, dynamic> saved, {
    int remaining = 4,
  }) async {
    if (_journalsForgotten) throw const ProtocolException('这台电脑已移除，未发送停止请求。');
    try {
      await _write(client, 'execute', [saved['envelope']], saved: saved);
    } on ProtocolException catch (e) {
      if (!e.message.contains('Conflict') || remaining <= 0) rethrow;
      // The task moved on since this request was built. Stop the same run
      // again with its current version, or finish if it already ended.
      final task = await _activeRun(client, saved);
      if (task == null) {
        await _clearCancel(saved);
        return {'cancelReceipt': const {}, 'state': 'target_finished'};
      }
      final next = _cancelIntent(task);
      await _replaceCancel(saved, next);
      return sendCancel(client, next, remaining: remaining - 1);
    }
    return verifyCancel(client, saved);
  }

  Future<void> _replaceCancel(
    Map<String, dynamic> current,
    Map<String, dynamic> next,
  ) => _journalSerial(() async {
    if (_journalsForgotten) throw const ProtocolException('这台电脑已移除，未重新发送停止请求。');
    await _requireBindingActive();
    final all = await _readCancels(), target = _cancelTarget(current);
    if (!_sameGitValue(all[target], current) || _cancelTarget(next) != target) {
      throw const ProtocolException('原停止请求已改变，请刷新。');
    }
    if (bindingEpoch != null) next['localBindingEpoch'] = bindingEpoch;
    all[target] = next;
    await storage.write(_cancelKey, jsonEncode(all));
    _requireJournalActive();
  });

  Future<dynamic> retryCancel(
    HostApi client,
    Map<String, dynamic> saved,
  ) async => await verifyCancel(client, saved) ?? sendCancel(client, saved);

  /// Stop waiting locally. A stop that already reached the PC still applies.
  Future<dynamic> finishCancelTracking(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    if (saved['kind'] != 'cancel') throw const ProtocolException('没有待确认的停止请求。');
    await _clearCancel(saved);
    return {'cancelReceipt': const {}, 'state': 'abandoned'};
  }
}

String cancelResultMessage(Map result) => switch (result['state']) {
  'accepted' => '电脑已收到停止请求，任务会在停下后更新状态。',
  'target_finished' => '这次运行已经结束，不需要再停止。',
  'abandoned' => '已不再等待。如果电脑收到了这个停止请求，任务仍会停下。',
  _ => '还不确定是否已停止，可以再发一次停止。',
};
