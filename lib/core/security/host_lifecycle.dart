import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import '../protocol.dart';
import 'secret_storage.dart';

String hostStorageKey(String host) =>
    'dogcodes.host.v1.${sha256.convert(utf8.encode(host))}';
String newBindingEpoch() {
  final random = Random.secure();
  return base64Url.encode(List.generate(24, (_) => random.nextInt(256)));
}

bool validBindingEpoch(Object? value) =>
    value is String && RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(value);

class _Serial {
  Future<void>? tail;
  Future<T> run<T>(Future<T> Function() action) {
    final previous = tail ?? Future<void>.value(), gate = Completer<void>();
    tail = gate.future;
    return () async {
      await previous;
      try {
        return await action();
      } finally {
        if (identical(tail, gate.future)) tail = null;
        gate.complete();
      }
    }();
  }
}

/// All registry instances using this storage share the index queue. Operations
/// use only their computer's queue; a slow network never holds either queue.
class HostRegistry {
  HostRegistry._(this.storage);
  static final _registries = Expando<HostRegistry>('host-lifecycle');
  factory HostRegistry(SecretStorage storage) =>
      _registries[storage] ??= HostRegistry._(storage);
  final SecretStorage storage;
  final _index = _Serial();
  final _hosts = <String, HostLifecycle>{};
  HostLifecycle host(String id) =>
      _hosts.putIfAbsent(id, () => HostLifecycle._(storage, id));
  Future<T> serial<T>(Future<T> Function() action) => _index.run(action);
}

class HostLifecycle {
  HostLifecycle._(this.storage, this.hostId);
  final SecretStorage storage;
  final String hostId;
  final _queue = _Serial();
  int generation = 0;
  bool cleanupPending = false;
  bool? hasRecord;
  Future<T> serial<T>(Future<T> Function() action) => _queue.run(action);
  List<String> get journalKeys => [
    'dogcodes.pending.v1.$hostId',
    'dogcodes.pending.v1.$hostId.side',
    'dogcodes.cancel.v1.$hostId',
    'dogcodes.terminal-stops.v1.$hostId',
  ];

  Future<Map<String, dynamic>?> record() async {
    final raw = await storage.read(hostStorageKey(hostId));
    hasRecord = raw != null && raw != 'null';
    if (raw == null || raw == 'null') return null;
    try {
      final value = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (value['version'] != 1 ||
          value['hostId'] != hostId ||
          (value.containsKey('bindingEpoch') &&
              !validBindingEpoch(value['bindingEpoch'])) ||
          (value.containsKey('unpaired') && value['unpaired'] is! bool) ||
          (value.containsKey('previousEpoch') &&
              !validBindingEpoch(value['previousEpoch']))) {
        throw const FormatException();
      }
      return value;
    } catch (_) {
      throw const ProtocolException('电脑绑定状态无法读取，请先检查系统安全存储。');
    }
  }

  Future<void> persist(Map<String, dynamic> value) async {
    final raw = jsonEncode(value), key = hostStorageKey(hostId);
    await storage.write(key, raw);
    final confirmed = await storage.read(key);
    hasRecord = confirmed != null && confirmed != 'null';
    if (confirmed != raw) {
      throw const ProtocolException('电脑绑定状态未能安全保存，请核实原操作。');
    }
  }

  Future<bool> matches(String? epoch) async {
    final current = await record();
    // Unbound owners exist only for offline/development clients. Once a real
    // registry record exists they cannot bypass the authenticated binding.
    if (epoch == null) return current == null;
    return current != null &&
        current['unpaired'] != true &&
        current['bindingEpoch'] == epoch;
  }

  Future<void> clearJournals() async {
    for (final key in journalKeys) {
      final store = storage;
      if (store is ErasableSecretStorage) {
        await store.delete(key);
      } else {
        await store.write(key, 'null');
      }
    }
  }
}
