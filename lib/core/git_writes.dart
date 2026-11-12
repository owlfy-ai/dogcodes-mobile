part of 'mobile_operations.dart';

bool _sameGitValue(dynamic expected, dynamic actual) {
  if (expected is Map) {
    return actual is Map &&
        expected.keys.every((k) => _sameGitValue(expected[k], actual[k]));
  }
  if (expected is List) {
    return actual is List &&
        expected.length == actual.length &&
        List.generate(
          expected.length,
          (i) => i,
        ).every((i) => _sameGitValue(expected[i], actual[i]));
  }
  return expected == actual;
}

String gitResultMessage(Map result) => switch (result['state']) {
  'succeeded' => result['pushed'] == true ? tr("已提交并推送") : tr("Git 操作已完成"),
  'awaiting_next' => tr("已经提交，还不确定是否推送成功，可以重新发送推送。"),
  'push_failed' => tr("提交已完成，推送失败：{0}", [
    displayBackendText('${result['receipt']?['outcome']?['message'] ?? ''}'),
  ]),
  'failed' => tr("Git 操作失败：{0}", [
    displayBackendText('${result['receipt']?['outcome']?['message'] ?? ''}'),
  ]),
  'running' => tr("电脑正在执行 Git 操作，稍后再确认。"),
  'unknown' => tr("Git 操作中途中断了，请在「变更」里看一下仓库现在的状态。"),
  'needs_attention' => tr("Git 操作只完成了一部分，请先在「变更」里看一下再继续。"),
  'closed' => tr("已不再等待这次 Git 操作。"),
  _ => tr("电脑上还查不到这次 Git 操作，可能没收到，可以重新发送。"),
};

extension GitWrites on MobileOperations {
  Map<String, dynamic> _expectedIndex(Map saved) {
    final request = saved['request'] as Map;
    return {
      'operationId': request['operationId'],
      'taskId': request['taskId'],
      'command': 'core_review_index',
      'arguments': {
        for (final entry in request.entries)
          if (entry.key != 'operationId') entry.key: entry.value,
      },
    };
  }

  Future<Map<String, dynamic>?> indexWrite(
    HostApi client, {
    required String taskId,
    required String snapshotId,
    required String rootId,
    required List<String> paths,
    bool unstage = false,
  }) async {
    final saved = <String, dynamic>{
      'kind': 'index',
      'request': {
        'operationId': uuid(),
        'taskId': taskId,
        'snapshotId': snapshotId,
        'rootId': rootId,
        'paths': List<String>.of(paths),
        'action': unstage ? 'unstage' : 'stage',
      },
    };
    await _storeNew(saved);
    return sendIndex(client, saved);
  }

  Future<Map<String, dynamic>?> sendIndex(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    await _gitWrite(client, 'index', saved['request'] as Map, saved);
    final found = await verifyIndex(client, saved);
    if (found == null || found['state'] != 'succeeded') {
      throw ProtocolException(
        found == null ? tr("还不确定文件是否已暂存，所以没有继续提交。") : gitResultMessage(found),
      );
    }
    return found;
  }

  Future<Map<String, dynamic>?> verifyIndex(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final receipt = await _gitCall(client, 'file_operation', {
      'taskId': saved['request']['taskId'],
      'operationId': saved['request']['operationId'],
    });
    if (receipt == null) return null;
    if (receipt is! Map ||
        !_sameGitValue(_expectedIndex(saved), receipt['request'])) {
      throw ProtocolException(tr("暂存回执与原文件选择不一致，未重新执行。"));
    }
    final state = receipt['closed'] == true
        ? 'closed'
        : receipt['outcome']?['status'];
    if (['succeeded', 'failed', 'closed'].contains(state)) {
      await _clearIfCurrent(saved);
    }
    return {'state': state, 'receipt': receipt};
  }

  Future<dynamic> _gitCall(HostApi client, String operation, Map arguments) =>
      client.call('review', {'operation': operation, 'arguments': arguments});

  Future<dynamic> _gitWrite(
    HostApi client,
    String operation,
    Map arguments,
    Map<String, dynamic> saved, {
    bool closing = false,
  }) => _write(
    client,
    'review',
    {'operation': operation, 'arguments': arguments},
    saved: saved,
    closing: closing,
  );

  Future<Map<String, dynamic>?> gitWrite(
    HostApi client, {
    required String taskId,
    required String rootId,
    required String action,
    String message = '',
    String? snapshotId,
    bool stageAll = false,
    bool push = false,
  }) async {
    if (!['commit', 'push', 'pull', 'sync'].contains(action) ||
        (push && action != 'commit')) {
      throw ProtocolException(tr("Git 操作无效。"));
    }
    final saved = <String, dynamic>{
      'kind': 'git',
      'request': {
        'operationId': uuid(),
        'taskId': taskId,
        'rootId': rootId,
        'action': action,
        'message': message,
        'stageAll': stageAll,
        'snapshotId': snapshotId,
        'workflow': push
            ? {'nextOperationId': uuid(), 'parentOperationId': null}
            : null,
      },
    };
    await _storeNew(saved);
    return _sendGit(client, saved, advance: push);
  }

  Future<Map<String, dynamic>?> _sendGit(
    HostApi client,
    Map<String, dynamic> saved, {
    bool advance = false,
  }) async {
    try {
      await _gitWrite(client, 'git_action', saved['request'] as Map, saved);
    } on ProtocolException {
      // An explicit rejection before journal admission cannot have an effect.
      // Transport loss remains tracked with the frozen operation identity.
      try {
        if (await verifyGit(client, saved) == null) {
          await _clearIfCurrent(saved);
        }
      } catch (_) {
        /* Unknown receipt state keeps tracking intact. */
      }
      rethrow;
    }
    final found = await verifyGit(client, saved);
    if (advance && found?['state'] == 'awaiting_next') {
      await _advanceGit(client, saved, found!);
      return verifyGit(client, saved);
    }
    return found;
  }

  /// Read only. Merely checking a completed commit never starts a push.
  Future<Map<String, dynamic>?> verifyGit(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final original = saved['request'] as Map;
    var id = original['operationId'] as String;
    Map? parent;
    final seen = <String>{};
    for (var step = 0; step < 256 && seen.add(id); step++) {
      final raw = await _gitCall(client, 'git_operation', {
        'taskId': original['taskId'],
        'operationId': id,
      });
      if (raw == null) {
        return parent == null
            ? null
            : {
                'state': parent['outcome']['status'] == 'failed'
                    ? 'push_failed'
                    : 'awaiting_next',
                'receipt': parent,
              };
      }
      if (raw is! Map || raw['request'] is! Map || raw['outcome'] is! Map) {
        throw ProtocolException(tr("电脑未返回有效的 Git 操作回执。"));
      }
      final request = raw['request'] as Map;
      final valid = parent == null
          ? _sameGitValue(original, request)
          : request['operationId'] == id &&
                request['taskId'] == original['taskId'] &&
                request['rootId'] == original['rootId'] &&
                request['action'] == 'push' &&
                request['workflow']?['parentOperationId'] ==
                    parent['request']['operationId'];
      if (!valid) throw ProtocolException(tr("Git 回执与原请求不一致，未继续操作。"));
      final status = raw['outcome']['status'];
      String state;
      if (raw['closed'] == true) {
        state = 'closed';
      } else if (status == 'running' || status == 'unknown') {
        state = '$status';
      } else if (status == 'failed') {
        if (parent != null && request['workflow'] is Map) {
          parent = raw;
          id = request['workflow']['nextOperationId'] as String;
          continue;
        }
        state = parent != null ? 'push_failed' : 'failed';
      } else if (status == 'succeeded' && raw['outcome']['completed'] == true) {
        if (request['action'] == 'commit' && request['workflow'] is Map) {
          parent = raw;
          id = request['workflow']['nextOperationId'] as String;
          continue;
        }
        state = 'succeeded';
      } else {
        state = 'needs_attention';
      }
      if (['succeeded', 'failed', 'closed'].contains(state)) {
        await _clearIfCurrent(saved);
      }
      return {
        'state': state,
        'receipt': raw,
        'pushed': parent != null || original['action'] == 'push',
      };
    }
    throw ProtocolException(tr("Git 接续记录过长或存在循环，请在电脑上核实。"));
  }

  Future<void> _advanceGit(
    HostApi client,
    Map<String, dynamic> saved,
    Map result,
  ) async {
    if (!['awaiting_next', 'push_failed'].contains(result['state'])) {
      throw ProtocolException(gitResultMessage(result));
    }
    await _gitWrite(client, 'git_advance', {
      'taskId': saved['request']['taskId'],
      'operationId': result['receipt']['request']['operationId'],
    }, saved);
  }

  Future<Map<String, dynamic>?> retryGit(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    if (saved['phase'] == 'closing') {
      await finishGitTracking(client, saved);
      return {'state': 'closed'};
    }
    final found = await verifyGit(client, saved);
    if (found == null) {
      return _sendGit(
        client,
        saved,
        advance: saved['request']['workflow'] != null,
      );
    }
    if (['awaiting_next', 'push_failed'].contains(found['state'])) {
      await _advanceGit(client, saved, found);
      return verifyGit(client, saved);
    }
    return found;
  }

  Future<void> finishGitTracking(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    saved = await _beginClosing(saved);
    final index = saved['kind'] == 'index';
    final closed = await _gitWrite(
      client,
      index ? 'file_close' : 'git_close',
      {
        'taskId': saved['request']['taskId'],
        'operationId': saved['request']['operationId'],
      },
      saved,
      closing: true,
    );
    if (closed is! Map ||
        closed['closed'] != true ||
        !_sameGitValue(
          index ? _expectedIndex(saved) : saved['request'],
          closed['request'],
        )) {
      throw ProtocolException(tr("电脑尚未确认结束原 Git 跟踪。"));
    }
    await _clearIfCurrent(saved);
  }
}
