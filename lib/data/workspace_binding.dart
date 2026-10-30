part of 'local_workspace.dart';

class _LocalState {
  int cacheEpoch = 0, revision = 0;
  final reserved = <String>{};
  final reservationOwners = <String, String>{};
}

({String host, String? epoch}) _draftOwner(String key) {
  final fields = jsonDecode(key) as List;
  if (fields.length != 4 ||
      fields[0] is! String ||
      fields[1] is! String ||
      (fields[2] != null && fields[2] is! String) ||
      (fields[3] != null && !validBindingEpoch(fields[3]))) {
    throw FormatException(tr("草稿归属不可读取"));
  }
  return (host: fields[0] as String, epoch: fields[3] as String?);
}

String _hostCacheKey(String host, String? epoch) =>
    'host:${jsonEncode([host, epoch])}';
String _timelineKey(String host, String task, String? epoch) =>
    'timeline:${jsonEncode([host, task, epoch])}';
String _approvalHistoryKey(String host, String? epoch) =>
    'approvals:${jsonEncode([host, epoch])}';
bool _cacheBelongs(String key, String host, String? epoch) {
  if (key == _hostCacheKey(host, epoch)) return true;
  if (key == _approvalHistoryKey(host, epoch)) return true;
  if (!key.startsWith('timeline:')) return false;
  try {
    final parts = jsonDecode(key.substring(9)) as List;
    return parts.length == 3 && parts[0] == host && parts[2] == epoch;
  } catch (_) {
    return false;
  }
}

String? _cacheHost(String key) {
  if (key.startsWith('host:')) {
    final value = key.substring(5);
    try {
      return (jsonDecode(value) as List).first as String;
    } catch (_) {
      return null;
    }
  }
  if (key.startsWith('timeline:')) {
    try {
      return (jsonDecode(key.substring(9)) as List).first as String;
    } catch (_) {
      return null;
    }
  }
  return null;
}

extension WorkspaceBinding on LocalWorkspace {
  void attachBindings(SecretStorage storage) {
    if (_bindings != null && !identical(_bindings, storage)) {
      throw StateError(tr("工作区已属于另一份设备存储"));
    }
    _bindings = storage;
  }

  Future<T> _bound<T>(
    String host,
    String? epoch,
    Future<T> Function() action,
    T Function() stale,
  ) async {
    final bindings = _bindings;
    if (bindings == null) {
      if (epoch != null) throw StateError(tr("工作区设备存储尚未初始化"));
      return action();
    }
    final scope = HostRegistry(bindings).host(host);
    return scope.serial(() async {
      if (!await scope.matches(epoch)) return stale();
      if (epoch != null) await _prepare(host, epoch);
      return action();
    });
  }

  Future<void> prepareBinding(String host, String epoch) =>
      _serial(() => _bound<void>(host, epoch, () async {}, () {}));

  Future<List<({String key, Map<String, dynamic> data})>> _records(
    String space,
  ) async {
    final base = await _base();
    if (base == null) {
      return [
        for (final entry in _memoryKeys.entries)
          if (entry.value.space == space && _memory[entry.key] != null)
            (
              key: entry.value.key,
              data: Map<String, dynamic>.from(_memory[entry.key]!),
            ),
      ];
    }
    final result = <({String key, Map<String, dynamic> data})>[];
    await for (final entity in base.list()) {
      if (entity is! File ||
          !entity.path.split('/').last.startsWith('$space-') ||
          !entity.path.endsWith('.json')) {
        continue;
      }
      try {
        final raw = jsonDecode(await entity.readAsString()) as Map;
        final key = raw['key'] as String;
        if (entity.path.split('/').last != '${_id(space, key)}.json') {
          throw FormatException(tr("本机数据归属不一致"));
        }
        result.add((
          key: key,
          data: Map<String, dynamic>.from(raw['data'] as Map),
        ));
      } catch (_) {
        if (space != 'cache') rethrow;
        await entity.delete();
        _state.revision++;
      }
    }
    return result;
  }

  Future<void> _prepare(String host, String epoch) async {
    final markerKey = 'binding:$host';
    final marker = await _get('meta', markerKey);
    if (marker != null &&
        (!validBindingEpoch(marker['bindingEpoch']) ||
            marker['complete'] is! bool)) {
      throw FormatException(tr("本地绑定记录不可读取"));
    }
    if (marker?['bindingEpoch'] == epoch && marker?['complete'] == true) return;
    await _put('meta', markerKey, {'bindingEpoch': epoch, 'complete': false});
    // Drafts and cache of any other binding of this computer (an explicit
    // removal and re-pair) are cleared before this scope is published,
    // including after a crash mid-way.
    for (final item in await _records('draft')) {
      final owner = _draftOwner(item.key);
      if (owner.host == host && owner.epoch != epoch) {
        await _remove('draft', item.key);
      }
    }
    for (final item in await _records('cache')) {
      if (_cacheHost(item.key) == host &&
          !_cacheBelongs(item.key, host, epoch)) {
        await _remove('cache', item.key);
      }
    }
    _dropReservations(host, keepEpoch: epoch);
    final picker = await _get('meta', 'picker');
    if (picker?['key'] is String) {
      final owner = _draftOwner(picker!['key'] as String);
      if (owner.host == host && owner.epoch != epoch) {
        await _remove('meta', 'picker');
      }
    }
    await _pruneBlobs();
    await _put('meta', markerKey, {'bindingEpoch': epoch, 'complete': true});
    _indexed = false;
  }

  Future<void> _requireDraft(String key, Future<void> Function() action) {
    final owner = _draftOwner(key);
    return _bound(
      owner.host,
      owner.epoch,
      action,
      () => throw ProtocolException(tr("电脑绑定已变化，未覆盖原草稿。")),
    );
  }

  void _dropReservations(
    String host, {
    String? removeEpoch,
    String? keepEpoch,
  }) {
    for (final entry in _state.reservationOwners.entries.toList()) {
      final owner = _draftOwner(entry.value);
      if (owner.host == host &&
          (keepEpoch != null
              ? owner.epoch != keepEpoch
              : owner.epoch == removeEpoch)) {
        _state.reserved.remove(entry.key);
        _state.reservationOwners.remove(entry.key);
      }
    }
  }

  Future<void> clearPicker(Map<String, dynamic> selection) => _serial(() async {
    final id = selection['pickerId'];
    if (id is! String || id.isEmpty) return;
    final current = await _get('meta', 'picker');
    if (current?['pickerId'] == id) {
      await _remove('meta', 'picker');
    }
  });
}
