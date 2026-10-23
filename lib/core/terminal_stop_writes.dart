part of 'mobile_operations.dart';

extension TerminalStopWrites on MobileOperations {
  String get _stopsKey => 'dogcodes.terminal-stops.v1.$hostId';
  String _stopId(Map saved) => saved['request']['operationId'] as String;
  String _stopTarget(Map saved) => jsonEncode([
    saved['request']['terminalId'],
    saved['request']['expectedEpoch'],
  ]);
  Future<Map<String, dynamic>> _readStops() async {
    final raw = await storage.read(_stopsKey);
    return raw == null || raw == 'null'
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<List<Map<String, dynamic>>> pendingTerminalStops() => _journalSerial(
    () async => [
      for (final value in (await _readStops()).values)
        Map<String, dynamic>.from(value as Map),
    ],
  );
  Future<void> _storeStop(Map<String, dynamic> saved) => _journalSerial(
    () async {
      final all = await _readStops();
      if (_journalsForgotten) throw const ProtocolException('这台电脑已移除，未发送关闭请求。');
      if (all.values.any(
        (old) => _stopTarget(old as Map) == _stopTarget(saved),
      )) {
        throw const ProtocolException('这个终端已经有一个关闭请求在等待确认。');
      }
      if (all.length >= 64) {
        throw const ProtocolException('等待确认的关闭请求太多，请先处理待处理页里的卡片。');
      }
      all[_stopId(saved)] = saved;
      await storage.write(_stopsKey, jsonEncode(all));
      if (_journalsForgotten) throw const ProtocolException('这台电脑已移除，未发送关闭请求。');
    },
  );
  Future<void> _clearStop(Map<String, dynamic> saved) async {
    if (_journalsForgotten) return;
    // Preserve recovery for requests saved by the previous app version.
    if (saved['journal'] != 'terminal-stops') {
      await _clearIfCurrent(saved);
      return;
    }
    await _journalSerial(() async {
      if (_journalsForgotten) return;
      final all = await _readStops(), id = _stopId(saved);
      if (_sameGitValue(all[id], saved)) {
        all.remove(id);
        await storage.write(_stopsKey, jsonEncode(all));
      }
    });
  }

  Future<void> forgetTerminalStops() {
    _journalsForgotten = true;
    return _journalSerial(() async {
      final store = storage;
      if (store is ErasableSecretStorage) {
        await store.delete(_stopsKey);
      } else {
        await store.write(_stopsKey, 'null');
      }
    });
  }

  Future<void> _guardRunStops(
    HostApi client,
    String projectId,
    int directoryIndex,
    String commandId,
  ) async {
    final stops = await pendingTerminalStops();
    for (final stop in stops.where(
      (s) =>
          s['projectId'] == projectId &&
          s['directoryIndex'] == directoryIndex &&
          s['commandId'] == commandId,
    )) {
      final result = await verifyTerminalStop(client, stop);
      if (result?['state'] != 'stopped') {
        throw const ProtocolException('原终端关闭结果尚未确认，请核实结束后再启动这个运行配置。');
      }
    }
  }

  Future<Map<String, dynamic>> terminalStop(
    HostApi client,
    Map<String, dynamic> terminal,
  ) async {
    if (terminal['id'] is! String || terminal['epoch'] is! String) {
      throw const ProtocolException('终端身份不完整，请刷新后再关闭。');
    }
    final saved = <String, dynamic>{
      'kind': 'terminal_stop',
      'journal': 'terminal-stops',
      'projectId': terminal['projectId'],
      'label': terminal['label'],
      'taskId': terminal['taskId'],
      'commandId': terminal['commandId'],
      'directoryIndex': terminal['directoryIndex'],
      'request': {
        'operationId': uuid(),
        'terminalId': terminal['id'],
        'expectedEpoch': terminal['epoch'],
      },
    };
    // Pressing close again for the same terminal resends the earlier close.
    final earlier = (await pendingTerminalStops())
        .where((s) => _stopTarget(s) == _stopTarget(saved))
        .firstOrNull;
    if (earlier != null) {
      return (await retryTerminalStop(client, earlier)) ?? const {};
    }
    await _storeStop(saved);
    var result = await sendTerminalStop(client, saved);
    // Most exits are seen on the next round trip; slow ones stay recoverable.
    for (var i = 0; i < 10 && result['state'] == 'stopping'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final found = await verifyTerminalStop(client, saved);
      if (found == null) break;
      result = found;
    }
    return result;
  }

  /// Closing a terminal twice is harmless: the PC returns its current state.
  /// A terminal that is gone, has exited or belongs to another background
  /// generation needs no further stop, so the record clears.
  Future<Map<String, dynamic>> _stopResult(
    Map<String, dynamic> saved,
    dynamic info,
  ) async {
    final request = saved['request'] as Map;
    final String state;
    if (info is! Map) {
      state = 'stopped';
    } else if (info['id'] != request['terminalId'] ||
        info['epoch'] != request['expectedEpoch']) {
      state = 'rejected';
    } else {
      state = switch (info['status']) {
        'exited' || 'failed' => 'stopped',
        'unknown' => 'unknown',
        _ => 'stopping',
      };
    }
    if (state != 'stopping' && state != 'unknown') await _clearStop(saved);
    return {
      'stopRequest': request,
      'state': state,
      'terminal': ?info,
      if (state == 'rejected') 'error': '终端已经重新启动过，没有关闭新的终端。',
    };
  }

  static bool _gone(ProtocolException e) => e.message.contains('终端不存在');

  Future<Map<String, dynamic>> sendTerminalStop(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    if (_journalsForgotten) throw const ProtocolException('这台电脑已移除，未发送关闭请求。');
    try {
      return await _stopResult(
        saved,
        await client.call('terminal_stop', saved['request']['terminalId']),
      );
    } on ProtocolException catch (e) {
      if (_gone(e)) return _stopResult(saved, null);
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> verifyTerminalStop(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    try {
      return await _stopResult(
        saved,
        await client.call('terminal_get', saved['request']['terminalId']),
      );
    } on ProtocolException catch (e) {
      if (_gone(e)) return _stopResult(saved, null);
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> retryTerminalStop(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final found = await verifyTerminalStop(client, saved);
    if (found != null && found['state'] != 'stopping') return found;
    return sendTerminalStop(client, saved);
  }

  /// Stop waiting locally. A close that already reached the PC still applies.
  Future<Map<String, dynamic>> finishTerminalStopTracking(
    HostApi client,
    Map<String, dynamic> original,
  ) async {
    if (original['kind'] != 'terminal_stop') {
      throw const ProtocolException('没有待确认的终端关闭操作。');
    }
    await _clearStop(original);
    return {'stopRequest': original['request'], 'state': 'abandoned'};
  }
}

String terminalStopMessage(Map result) => switch (result['state']) {
  'stopped' => '终端已经关闭。',
  'abandoned' => '已不再等待。如果电脑收到了关闭请求，终端仍会关闭。',
  'rejected' => '${result['error'] ?? '终端已改变，关闭请求未执行。'}',
  'stopping' => '电脑已收到关闭请求，正在等终端结束。',
  _ => '${result['error'] ?? '还不确定终端是否已关闭，可以稍后再确认。'}',
};
