import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import '../protocol.dart';
import 'noise_endpoint.dart';
import '../secure_host_client.dart' show displayHostName;
import 'secret_storage.dart';
export 'secret_storage.dart';

class PlatformSecretStorage implements ErasableSecretStorage {
  final _storage = const FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// App owns one store. Concurrent callers share the same identity load/create.
/// A read/decode failure never silently rotates a device's existing identity.
class DeviceIdentityStore {
  DeviceIdentityStore(this.storage, this.create);
  final SecretStorage storage;
  final EndpointIdentity Function() create;
  Future<EndpointIdentity>? _loading;
  Future<EndpointIdentity> get() => _loading ??= _load();
  Future<EndpointIdentity> _load() async {
    final encoded = await storage.read('dogcodes.phone.identity.v1');
    if (encoded != null) {
      try {
        final data = jsonDecode(encoded) as Map<String, dynamic>;
        if (data['version'] != 1) throw const FormatException();
        return EndpointIdentity(
          secretHex: data['secret'] as String,
          publicHex: data['public'] as String,
        );
      } catch (_) {
        throw const ProtocolException('本机设备身份无法读取，请先恢复安全存储。');
      }
    }
    final identity = create();
    final value = jsonEncode({
      'version': 1,
      'secret': identity.secretHex,
      'public': identity.publicHex,
    });
    await storage.write('dogcodes.phone.identity.v1', value);
    if (await storage.read('dogcodes.phone.identity.v1') != value) {
      throw const ProtocolException('设备身份未能安全保存，尚未开始配对。');
    }
    return identity;
  }
}

class TrustedHostStore {
  TrustedHostStore(this.storage);
  final SecretStorage storage;
  Future<void> _pending = Future.value();
  String _key(String hostId) =>
      'dogcodes.host.v1.${sha256.convert(utf8.encode(hostId))}';

  /// Call only for an acknowledgement decrypted on this exact Noise session.
  /// Persist before displaying paired or sending the first business operation.
  Future<void> confirm({
    required PairingInvitation invitation,
    required NoiseSession session,
    required EndpointIdentity phone,
    required Map<String, dynamic> acknowledgement,
  }) {
    final pending = _pending.then((_) async {
      final hostHex = hexBytes(
        base64Url.decode(base64Url.normalize(invitation.hostKey)),
      );
      if (session.authenticatedPeer != hostHex ||
          acknowledgement['type'] != 'paired' ||
          acknowledgement['hostId'] != invitation.hostId ||
          acknowledgement['invitationId'] != invitation.invitationId ||
          acknowledgement['phonePublicKey'] != phone.publicHex ||
          acknowledgement['hostPublicKey'] != hostHex ||
          acknowledgement['binding'] != session.binding ||
          acknowledgement['routeToken'] is! String ||
          !RegExp(
            r'^[0-9a-f]{64}$',
          ).hasMatch(acknowledgement['routeToken'] as String) ||
          acknowledgement['grantRevision'] is! String ||
          parseSequence(acknowledgement['grantRevision'] as String) ==
              BigInt.zero) {
        throw const ProtocolException('配对回执与当前连接不一致。');
      }
      final old = await read(invitation.hostId);
      if (old != null &&
          (old['publicKey'] != hostHex ||
              old['service'] != invitation.service.toString())) {
        throw const ProtocolException('电脑身份已发生变化，需要先解除旧配对。');
      }
      final value = jsonEncode({
        'version': 1,
        'hostId': invitation.hostId,
        'service': invitation.service.toString(),
        'publicKey': hostHex,
        'grantRevision': acknowledgement['grantRevision'],
        'routeToken': acknowledgement['routeToken'],
        'displayName': ?displayHostName(acknowledgement['hostName']),
      });
      await storage.write(_key(invitation.hostId), value);
      final ids =
          jsonDecode(await storage.read('dogcodes.host.index.v1') ?? '[]')
              as List;
      if (!ids.contains(invitation.hostId)) {
        ids.add(invitation.hostId);
        await storage.write('dogcodes.host.index.v1', jsonEncode(ids));
      }
      if (await storage.read(_key(invitation.hostId)) != value) {
        throw const ProtocolException('配对身份未能安全保存，请核实原配对结果。');
      }
    });
    _pending = pending.then((_) {}, onError: (Object _, StackTrace _) {});
    return pending;
  }

  /// Forgets a computer on this phone only: its pinned key and route token are
  /// erased. Revoking this phone's access is done on the computer.
  Future<void> forget(String hostId) {
    final pending = _pending.then((_) async {
      final ids =
          jsonDecode(await storage.read('dogcodes.host.index.v1') ?? '[]')
              as List;
      ids.remove(hostId);
      await storage.write('dogcodes.host.index.v1', jsonEncode(ids));
      final store = storage;
      if (store is ErasableSecretStorage) {
        await store.delete(_key(hostId));
        await store.delete('dogcodes.pending.v1.$hostId');
      }
    });
    _pending = pending.then((_) {}, onError: (Object _, StackTrace _) {});
    return pending;
  }

  Future<List<Map<String, dynamic>>> list() async {
    final ids =
        jsonDecode(await storage.read('dogcodes.host.index.v1') ?? '[]')
            as List;
    final hosts = <Map<String, dynamic>>[];
    for (final id in ids) {
      final host = await read(id as String);
      if (host != null) hosts.add(host);
    }
    return hosts;
  }

  Future<Map<String, dynamic>?> read(String hostId) async {
    final value = await storage.read(_key(hostId));
    if (value == null) return null;
    try {
      final data = jsonDecode(value) as Map<String, dynamic>;
      if (data['version'] != 1 ||
          data['hostId'] != hostId ||
          data['publicKey'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(data['publicKey'] as String) ||
          !validSavedService(data['service'] as String)) {
        throw const FormatException();
      }
      parseSequence(data['grantRevision'] as String);
      return data;
    } catch (_) {
      throw const ProtocolException('已保存的电脑身份无法读取，请先核实配对。');
    }
  }
}

bool validSavedService(String value) {
  final uri = Uri.parse(value);
  return (uri.scheme == 'https' ||
          (!kReleaseMode && uri.scheme == 'http' && uri.host == '127.0.0.1')) &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      (uri.path.isEmpty || uri.path == '/');
}
