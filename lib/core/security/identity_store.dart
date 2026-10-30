import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'host_lifecycle.dart';
import '../protocol.dart';
import '../service_origin.dart';
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
        throw ProtocolException(tr("本机设备身份无法读取，请先恢复安全存储。"));
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
      throw ProtocolException(tr("设备身份未能安全保存，尚未开始配对。"));
    }
    return identity;
  }
}

class TrustedHostStore {
  TrustedHostStore(this.storage) : _registry = HostRegistry(storage);
  final SecretStorage storage;
  final HostRegistry _registry;

  Future<List<dynamic>> _ids() async =>
      jsonDecode(await storage.read('dogcodes.host.index.v1') ?? '[]') as List;

  Future<Map<String, dynamic>?> _read(HostLifecycle host) async {
    var data = await host.record();
    if (data == null || data['unpaired'] == true) return null;
    try {
      if (data['publicKey'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(data['publicKey'] as String) ||
          !validSavedService(data['service'] as String)) {
        throw const FormatException();
      }
      parseSequence(data['grantRevision'] as String);
    } catch (_) {
      throw ProtocolException(tr("已保存的电脑身份无法读取，请先核实配对。"));
    }
    if (!validBindingEpoch(data['bindingEpoch'])) {
      throw ProtocolException(tr("已保存的电脑身份无法读取，请先核实配对。"));
    }
    return data;
  }

  /// Capture before contacting the PC; late acknowledgements may not recreate
  /// a computer removed while its handshake or recovery was in flight.
  Future<String> beginPairing(String hostId) => _registry.serial(
    () => _registry.host(hostId).serial(() async {
      final host = _registry.host(hostId);
      var current = await host.record();
      if (current != null && current['unpaired'] != true) {
        current = await _read(host);
      }
      if (current == null) {
        current = {
          'version': 1,
          'hostId': hostId,
          'bindingEpoch': newBindingEpoch(),
          'unpaired': true,
        };
        await host.persist(current);
      }
      return current['bindingEpoch'] as String;
    }),
  );

  /// Call only for an acknowledgement decrypted on this exact Noise session.
  /// The binding epoch was captured before the request, not after its reply.
  Future<void> confirm({
    required PairingPins invitation,
    required NoiseSession session,
    required EndpointIdentity phone,
    required Map<String, dynamic> acknowledgement,
    required String bindingEpoch,
  }) async {
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
      throw ProtocolException(tr("配对回执与当前连接不一致。"));
    }
    await _registry.serial(
      () => _registry.host(invitation.hostId).serial(() async {
        final host = _registry.host(invitation.hostId);
        var current = await host.record();
        if (current == null || current['bindingEpoch'] != bindingEpoch) {
          throw ProtocolException(tr("这项配对已因移除电脑而失效，请重新扫码。"));
        }
        if (current['unpaired'] != true) {
          final ready = await _read(host);
          if (ready == null) throw ProtocolException(tr("电脑绑定已变化，请重新扫码。"));
          current = ready;
        }
        if (current['unpaired'] != true &&
            (current['publicKey'] != hostHex ||
                current['service'] != invitation.service.toString())) {
          throw ProtocolException(tr("电脑身份已发生变化，需要先解除旧配对。"));
        }
        if (current['unpaired'] == true) {
          host.generation++;
          host.cleanupPending = true;
          await host.clearJournals();
        }
        final ids = await _ids();
        if (!ids.contains(invitation.hostId)) {
          ids.add(invitation.hostId);
          await storage.write('dogcodes.host.index.v1', jsonEncode(ids));
        }
        // Publish the active binding last. A crash before this write leaves an
        // unpaired tombstone; retries repeat cleanup before exposing any host.
        await host.persist({
          'version': 1,
          'hostId': invitation.hostId,
          'service': invitation.service.toString(),
          'publicKey': hostHex,
          'bindingEpoch': bindingEpoch,
          'grantRevision': acknowledgement['grantRevision'],
          'routeToken': acknowledgement['routeToken'],
          'displayName': ?displayHostName(acknowledgement['hostName']),
        });
        host.cleanupPending = false;
      }),
    );
  }

  /// A tombstone replaces all credentials before clearing logs or the index.
  /// Keep its epoch: a crash or late pairing reply cannot resurrect the binding.
  Future<void> forget(String hostId, [String? expectedBinding]) =>
      _registry.serial(
        () => _registry.host(hostId).serial(() async {
          final host = _registry.host(hostId), current = await host.record();
          if (expectedBinding != null &&
              current?['bindingEpoch'] != expectedBinding &&
              !(current?['unpaired'] == true &&
                  current?['previousEpoch'] == expectedBinding)) {
            throw ProtocolException(tr("电脑绑定已变化，未移除新的绑定，请刷新后确认。"));
          }
          host.generation++;
          host.cleanupPending = true;
          final tombstone =
              current?['unpaired'] == true && current?['removed'] == true
              ? current!
              : <String, dynamic>{
                  'version': 1,
                  'hostId': hostId,
                  'bindingEpoch': newBindingEpoch(),
                  'previousEpoch': ?current?['bindingEpoch'],
                  'unpaired': true,
                  'removed': true,
                };
          await host.persist(tombstone);
          await host.clearJournals();
          final ids = await _ids();
          ids.remove(hostId);
          await storage.write('dogcodes.host.index.v1', jsonEncode(ids));
          host.cleanupPending = false;
        }),
      );

  Future<List<Map<String, dynamic>>> list() => _registry.serial(() async {
    final hosts = <Map<String, dynamic>>[];
    for (final id in await _ids()) {
      final scope = _registry.host(id as String);
      final host = await scope.serial(() => _read(scope));
      if (host != null) hosts.add(host);
    }
    return hosts;
  });
  Future<Map<String, dynamic>?> read(String hostId) => _registry.serial(
    () => _registry.host(hostId).serial(() => _read(_registry.host(hostId))),
  );
}

bool validSavedService(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      validServiceOrigin(uri, allowLocalDevelopment: !kReleaseMode);
}
