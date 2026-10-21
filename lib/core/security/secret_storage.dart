abstract interface class SecretStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Storage that can erase an entry, used to forget a paired computer.
abstract interface class ErasableSecretStorage implements SecretStorage {
  Future<void> delete(String key);
}

/// Process-only storage for unconfigured builds and tests; nothing persists.
class MemorySecretStorage implements ErasableSecretStorage {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}
