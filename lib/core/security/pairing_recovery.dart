import 'dart:convert';
import '../protocol.dart';
import 'secret_storage.dart';
import 'host_lifecycle.dart';

/// Stored before contacting the PC. Deliberately excludes the pairing PSK:
/// this can only recover an existing grant for the phone's original identity.
class PairingRecovery implements PairingPins {
  PairingRecovery._(
    this.hostId,
    this.hostKey,
    this.invitationId,
    this.service,
    this.phoneTicket,
    this.phonePublicKey,
    this.recoverUntil,
    this.bindingEpoch,
  );
  factory PairingRecovery.fromInvitation(
    PairingInvitation invitation,
    String phonePublicKey, {
    required String bindingEpoch,
  }) {
    if (invitation.phoneTicket == null) {
      throw const ProtocolException('请在电脑上生成新版配对二维码。');
    }
    return PairingRecovery._(
      invitation.hostId,
      invitation.hostKey,
      invitation.invitationId,
      invitation.service,
      invitation.phoneTicket!,
      phonePublicKey,
      invitation.expiresAt.add(const Duration(minutes: 15)),
      bindingEpoch,
    );
  }
  factory PairingRecovery.fromJson(
    Map data, {
    required bool allowLocalDevelopment,
  }) {
    try {
      final service = Uri.parse(data['service'] as String);
      final key = data['hostKey'] as String;
      final phone = data['phonePublicKey'] as String;
      final ticket = data['phoneTicket'] as String;
      final host = data['hostId'] as String,
          invitation = data['invitationId'] as String;
      if (!validBindingEpoch(data['bindingEpoch']) ||
          data['version'] != 1 ||
          base64Url.decode(base64Url.normalize(key)).length != 32 ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(phone) ||
          !RegExp(r'^[A-Za-z0-9_-]{32,256}$').hasMatch(ticket) ||
          !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(host) ||
          !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(invitation) ||
          (service.scheme != 'https' &&
              !(allowLocalDevelopment &&
                  service.scheme == 'http' &&
                  service.host == '127.0.0.1')) ||
          service.host.isEmpty ||
          service.userInfo.isNotEmpty ||
          service.hasQuery ||
          service.hasFragment ||
          (service.path.isNotEmpty && service.path != '/')) {
        throw const FormatException();
      }
      return PairingRecovery._(
        host,
        key,
        invitation,
        service,
        ticket,
        phone,
        DateTime.parse(data['recoverUntil'] as String).toUtc(),
        data['bindingEpoch'] as String,
      );
    } catch (_) {
      throw const ProtocolException('配对恢复记录无法读取，请先核实手机安全存储。');
    }
  }
  @override
  final String hostId, hostKey, invitationId;
  @override
  final Uri service;
  final String phoneTicket, phonePublicKey;
  final String bindingEpoch;
  final DateTime recoverUntil;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'hostId': hostId,
    'hostKey': hostKey,
    'invitationId': invitationId,
    'service': service.toString(),
    'phoneTicket': phoneTicket,
    'phonePublicKey': phonePublicKey,
    'recoverUntil': recoverUntil.toIso8601String(),
    'bindingEpoch': bindingEpoch,
  };
  bool sameAttempt(PairingRecovery other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());
  @override
  String toString() => 'PairingRecovery(<redacted>)';
}

class PairingJournal {
  PairingJournal(this.storage, {this.allowLocalDevelopment = false})
    : _registry = HostRegistry(storage);
  final SecretStorage storage;
  final bool allowLocalDevelopment;
  final HostRegistry _registry;
  static const key = 'dogcodes.pairing.pending.v1';
  Future<T> _serial<T>(Future<T> Function() work) => _registry.serial(work);

  Future<Map<String, PairingRecovery>> _load() async {
    final raw = await storage.read(key);
    if (raw == null || raw == 'null') return {};
    try {
      final data = jsonDecode(raw) as Map;
      if (data.length > 128) throw const FormatException();
      return {
        for (final entry in data.entries)
          entry.key as String: _entry(entry.key, entry.value),
      };
    } catch (_) {
      throw const ProtocolException('配对恢复记录无法读取，请先核实手机安全存储。');
    }
  }

  PairingRecovery _entry(Object? id, Object? value) {
    final record = PairingRecovery.fromJson(
      value as Map,
      allowLocalDevelopment: allowLocalDevelopment,
    );
    if (id != record.hostId) throw const FormatException();
    return record;
  }

  Future<void> _write(Map<String, PairingRecovery> records) async {
    final raw = jsonEncode({
      for (final entry in records.entries) entry.key: entry.value.toJson(),
    });
    await storage.write(key, raw);
    if (await storage.read(key) != raw) {
      throw const ProtocolException('配对恢复信息未能安全保存。');
    }
  }

  Future<List<PairingRecovery>> list() =>
      _serial(() async => (await _load()).values.toList());
  Future<void> begin(PairingRecovery record) => _serial(() async {
    final records = await _load(), old = records[record.hostId];
    if (old != null &&
        (old.hostKey != record.hostKey ||
            old.service != record.service ||
            old.phonePublicKey != record.phonePublicKey)) {
      throw const ProtocolException('待核实电脑的身份发生变化，请先核实原配对。');
    }
    if (old == null && records.length >= 128) {
      throw const ProtocolException('待核实配对过多，请先核实原记录。');
    }
    records[record.hostId] = record;
    await _write(records);
  });
  Future<void> clear(PairingRecovery record) => _serial(() async {
    final records = await _load();
    if (records[record.hostId]?.sameAttempt(record) != true) return;
    records.remove(record.hostId);
    await _write(records);
  });
}
