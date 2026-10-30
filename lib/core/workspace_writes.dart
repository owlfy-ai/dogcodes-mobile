part of 'mobile_operations.dart';

/// Launch IDs are the PC terminal identities. Persist before sending; checking
/// a receipt never runs a command, and retry always reuses the frozen recipe.
extension WorkspaceWrites on MobileOperations {
  Future<void> _requireWorkspaceRecovery(HostApi client, String feature) async {
    final caps = await client.call('remote_capabilities', null);
    if (caps is! Map || caps[feature] != true) {
      throw ProtocolException(tr("请更新电脑端后再操作，尚未启动或修改配置。"));
    }
  }

  Future<Map<String, dynamic>?> terminalStart(
    HostApi client, {
    required String projectId,
    required String cwd,
    int directoryIndex = 0,
  }) async {
    await _requireWorkspaceRecovery(client, 'terminalLaunchRecovery');
    final saved = <String, dynamic>{
      'kind': 'terminal',
      'projectId': projectId,
      'method': 'terminal_start',
      'request': {
        'projectLaunch': null,
        'operationId': uuid(),
        'projectId': projectId,
        'directoryIndex': directoryIndex,
        'taskId': null,
        'commandId': null,
        'label': tr("终端"),
        'cwd': cwd,
        'command': null,
        'cols': 80,
        'rows': 24,
      },
    };
    await _storeNew(saved);
    return sendWorkspace(client, saved);
  }

  Future<Map<String, dynamic>?> runStart(
    HostApi client, {
    required String projectId,
    required String taskId,
    required String generation,
    required int directoryIndex,
    required String commandId,
  }) async {
    await _requireWorkspaceRecovery(client, 'terminalLaunchRecovery');
    await _guardRunStops(client, projectId, directoryIndex, commandId);
    final saved = <String, dynamic>{
      'kind': 'terminal',
      'projectId': projectId,
      'method': 'project_run_start',
      'request': {
        'operationId': uuid(),
        'taskId': taskId,
        'generation': generation,
        'directoryIndex': directoryIndex,
        'commandId': commandId,
        'cols': 80,
        'rows': 24,
      },
    };
    await _storeNew(saved);
    return sendWorkspace(client, saved);
  }

  Future<Map<String, dynamic>?> runEdit(
    HostApi client, {
    required String taskId,
    required String generation,
    required int directoryIndex,
    required String commandId,
    required Map<String, dynamic> edit,
  }) async {
    return _runWrite(client, 'project_run_edit', {
      'operationId': uuid(),
      'taskId': taskId,
      'generation': generation,
      'directoryIndex': directoryIndex,
      'commandId': commandId,
      'edit': edit,
    });
  }

  Future<Map<String, dynamic>?> runAnalyze(
    HostApi client, {
    required String taskId,
    required String generation,
    Map<String, dynamic>? executor,
    bool overwrite = false,
  }) async {
    return _runWrite(client, 'project_runs_analyze', {
      'operationId': uuid(),
      'taskId': taskId,
      'expectedGeneration': generation,
      'executor': executor,
      'overwriteGeneration': overwrite ? generation : null,
    });
  }

  Future<Map<String, dynamic>?> _runWrite(
    HostApi client,
    String method,
    Map<String, dynamic> request,
  ) async {
    await _requireWorkspaceRecovery(client, 'runOperationRequest');
    final saved = <String, dynamic>{
      'kind': 'run_config',
      'method': method,
      'request': request,
    };
    await _storeNew(saved);
    return sendWorkspace(client, saved);
  }

  Future<Map<String, dynamic>?> verifyWorkspace(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final request = saved['request'] as Map;
    if (saved['kind'] == 'terminal') {
      final receipt = await client.call('terminal_launch_intents', {
        'type': 'get',
        'operationId': request['operationId'],
      });
      if (receipt == null) return null;
      if (receipt is! Map || receipt['operationId'] != request['operationId']) {
        throw ProtocolException(tr("原启动回执不匹配。"));
      }
      if (receipt['state'] == 'retired') {
        await _clearIfCurrent(saved);
        return {'state': 'retired'};
      }
      final intent = receipt['intent'];
      final original = saved['method'] == 'project_run_start' && intent is Map
          ? intent['projectLaunch']
          : intent;
      final terminal = receipt['terminal'];
      if (receipt['state'] != 'accepted' ||
          !_sameGitValue(request, original) ||
          terminal is! Map ||
          terminal['id'] != request['operationId'] ||
          terminal['projectId'] != saved['projectId']) {
        throw ProtocolException(tr("原启动记录与项目或运行配置不匹配，未重新执行。"));
      }
      final info = Map<String, dynamic>.from(terminal);
      // Exited, interrupted and failed terminals are still the original launch.
      // Clearing its receipt permits a *new explicit* start, never an auto-run.
      await _clearIfCurrent(saved);
      return {'state': 'confirmed', 'terminal': info};
    }
    final receipt = await client.call('project_run_operation', [
      request['taskId'],
      request['operationId'],
    ]);
    if (receipt == null) return null;
    if (receipt is! Map ||
        receipt['operationId'] != request['operationId'] ||
        !_sameGitValue(request, receipt['request'])) {
      throw ProtocolException(tr("运行配置回执与原操作不匹配，请更新电脑端后核实。"));
    }
    if ([
      'running',
      'succeeded',
      'failed',
      'interrupted',
      'superseded',
    ].contains(receipt['status'])) {
      await _clearIfCurrent(saved);
    }
    return {
      'state': receipt['status'],
      'runReceipt': Map<String, dynamic>.from(receipt),
    };
  }

  Future<Map<String, dynamic>?> sendWorkspace(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final reply = await _write(
      client,
      saved['method'] as String,
      saved['request'],
      saved: saved,
    );
    if (saved['kind'] == 'run_config') {
      if (reply is! Map ||
          (!reply.containsKey('Ok') && !reply.containsKey('Err'))) {
        throw ProtocolException(tr("电脑没有返回可确认的运行配置结果，请核实原操作。"));
      }
      if (reply['Err'] is Map) {
        final err = reply['Err'] as Map;
        // Only a structured pre-commit rejection and no persisted receipt
        // prove no mutation occurred. Storage/transport failures stay pending.
        final found = await verifyWorkspace(client, saved);
        if (found == null && err['kind'] == 'rejected') {
          await _clearIfCurrent(saved);
        }
        throw ProtocolException('${err['message'] ?? tr("运行配置操作未完成，请核实。")}');
      }
    }
    return verifyWorkspace(client, saved);
  }

  Future<Map<String, dynamic>?> retryWorkspace(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    if (saved['phase'] == 'closing') {
      return finishLaunchTracking(client, saved);
    }
    final found = await verifyWorkspace(client, saved);
    if (found != null) return found;
    return sendWorkspace(client, saved);
  }

  Future<Map<String, dynamic>> finishLaunchTracking(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    if (saved['kind'] != 'terminal') {
      throw ProtocolException(tr("没有待核实的启动操作。"));
    }
    saved = await _beginClosing(saved);
    final request = saved['request'] as Map;
    final result = await _write(
      client,
      'terminal_launch_intents',
      {'type': 'retire', 'operationId': request['operationId']},
      saved: saved,
      closing: true,
    );
    if (result is! Map || result['operationId'] != request['operationId']) {
      throw ProtocolException(tr("电脑未确认原启动已关闭，记录仍保留。"));
    }
    if (result['state'] == 'retired') {
      await _clearIfCurrent(saved);
      return {'state': 'retired'};
    }
    // Already admitted: validate its immutable receipt; do not stop the process.
    final found = await verifyWorkspace(client, saved);
    if (found == null) {
      throw ProtocolException(tr("原启动结果尚未确认，记录仍保留。"));
    }
    return found;
  }
}
