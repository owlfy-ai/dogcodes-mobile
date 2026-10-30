part of 'mobile_operations.dart';

bool _sameRecoveryValue(dynamic a, dynamic b) {
  if (a is Map) {
    return b is Map &&
        a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _sameRecoveryValue(a[k], b[k]));
  }
  if (a is List) {
    return b is List &&
        a.length == b.length &&
        List.generate(
          a.length,
          (i) => i,
        ).every((i) => _sameRecoveryValue(a[i], b[i]));
  }
  return a == b;
}

extension RecoveryJournals on MobileOperations {
  void _requireJournalActive() {
    if (_journalsForgotten) throw ProtocolException(tr("这台电脑已移除，未再发送请求。"));
    if (_scope.cleanupPending) {
      throw ProtocolException(tr("原电脑记录尚未清理完成，请重试移除电脑后再连接。"));
    }
  }

  Future<void> forgetRecoveryJournals() {
    // Invalidate every old owner synchronously, even if storage is still busy.
    // A new owner joins the next generation behind this cleanup in the queue.
    if (bindingEpoch != null) {
      return _scope.serial(() async {
        if (_journalsForgotten || !await _scope.matches(bindingEpoch)) return;
        _scope.generation++;
        _scope.cleanupPending = true;
        await _scope.clearJournals();
        _scope.cleanupPending = false;
      });
    }
    if (_scope.hasRecord == true) return Future<void>.value();
    if (_journalsForgotten) {
      if (!_scope.cleanupPending || _scope.generation != _scopeGeneration + 1) {
        return Future<void>.value();
      }
    } else {
      _scope.generation++;
      _scope.cleanupPending = true;
    }
    final cleanupGeneration = _scope.generation;
    return _journalSerial(() async {
      if (!_scope.cleanupPending || _scope.generation != cleanupGeneration) {
        return;
      }
      final store = storage;
      for (final item in [key, '$key.side', _cancelKey, _stopsKey]) {
        if (store is ErasableSecretStorage) {
          await store.delete(item);
        } else {
          await store.write(item, 'null');
        }
      }
      if (_scope.generation == cleanupGeneration) _scope.cleanupPending = false;
    });
  }

  Future<T> _journalSerial<T>(Future<T> Function() action) =>
      _scope.serial(action);

  Future<void> _requireBindingActive() async {
    _requireJournalActive();
    if (!await _scope.matches(bindingEpoch)) {
      throw ProtocolException(tr("电脑绑定已变化，未发送原操作；请重新连接后确认。"));
    }
    _requireJournalActive();
  }

  Future<Map<String, dynamic>?> _tracked(Map<String, dynamic> saved) async {
    if (bindingEpoch != null && saved['localBindingEpoch'] != bindingEpoch) {
      return null;
    }
    if (saved['kind'] == 'cancel') {
      final value = (await _readCancels())[_cancelTarget(saved)];
      return value is Map ? Map<String, dynamic>.from(value) : null;
    }
    if (saved['kind'] == 'terminal_stop' &&
        saved['journal'] == 'terminal-stops') {
      final value = (await _readStops())[_stopId(saved)];
      return value is Map ? Map<String, dynamic>.from(value) : null;
    }
    return _current(saved);
  }

  Future<Map<String, dynamic>> _beginClosing(Map<String, dynamic> saved) async {
    if (saved['phase'] == 'closing') return saved;
    final next = {...saved, 'phase': 'closing'};
    await _replaceCurrent(saved, next);
    return next;
  }

  Future<dynamic> _write(
    HostApi client,
    String method,
    dynamic args, {
    Map<String, dynamic>? saved,
    bool closing = false,
  }) async {
    Future<({dynamic value, Object? error, StackTrace? stack})>? dispatched;
    await _journalSerial(() async {
      await _requireBindingActive();
      if (saved != null) {
        final current = await _tracked(saved);
        _requireJournalActive();
        if (!_sameRecoveryValue(current, saved) ||
            saved['phase'] == 'closing' && !closing) {
          throw ProtocolException(tr("原操作已结束或已更新，请刷新后操作。"));
        }
      }
      // Freeze arguments, start the RPC under admission, then release the gate
      // before waiting for the network. Forget cannot retract an admitted RPC.
      dispatched = client
          .call(method, jsonDecode(jsonEncode(args)))
          .then(
            (value) => (value: value, error: null, stack: null),
            onError: (Object error, StackTrace stack) =>
                (value: null, error: error, stack: stack),
          );
    });
    final result = await dispatched!;
    if (result.error != null) {
      Error.throwWithStackTrace(result.error!, result.stack!);
    }
    return result.value;
  }
}
