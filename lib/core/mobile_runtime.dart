import 'dart:convert';
import 'host_api.dart';
import 'adaptive_host_link.dart';
import 'rtc_transport.dart';
import 'protocol.dart';
import 'secure_host_client.dart';
import 'security/noise_endpoint.dart';
import 'security/identity_store.dart';
import '../data/local_workspace.dart';
import 'task_attachments.dart';
import 'security/pairing_recovery.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;

class MobileRuntime {
  MobileRuntime({
    SecretStorage? storage,
    this.rtcConnector = connectRtc,
    NoiseEndpoint? noiseEndpoint,
  }) : storage = storage ?? PlatformSecretStorage(),
       _endpoint = noiseEndpoint;
  final SecretStorage storage;
  final RtcConnector rtcConnector;
  final local = LocalWorkspace.platform();
  Future<void> initialize() async {
    try {
      await TaskAttachmentPicker.recover(local);
    } catch (e) {
      local.cacheError = '上次附件选择未能恢复：$e';
    }
  }

  NoiseEndpoint? _endpoint;
  NoiseEndpoint get endpoint => _endpoint ??= NoiseEndpoint.bundled();
  DeviceIdentityStore? _identity;
  DeviceIdentityStore get identity =>
      _identity ??= DeviceIdentityStore(storage, endpoint.createIdentity);
  late final TrustedHostStore hosts = TrustedHostStore(storage);
  late final PairingJournal pairingJournal = PairingJournal(
    storage,
    allowLocalDevelopment: !kReleaseMode,
  );
  final _pairingHosts = <String>{};
  Future<HostLink> pair(PairingInvitation invitation) async {
    if (!_pairingHosts.add(invitation.hostId)) {
      throw const ProtocolException('正在处理这台电脑的原配对，请稍后核实。');
    }
    try {
      return await _pair(invitation);
    } finally {
      _pairingHosts.remove(invitation.hostId);
    }
  }

  Future<HostLink> _pair(PairingInvitation invitation) async {
    final phone = await identity.get();
    final old = await hosts.read(invitation.hostId);
    final peer = hexBytes(
      base64Url.decode(base64Url.normalize(invitation.hostKey)),
    );
    if (old != null &&
        (old['publicKey'] != peer ||
            old['service'] != invitation.service.toString())) {
      throw const ProtocolException('电脑身份已发生变化，需要先解除旧配对。');
    }
    final original = PairingRecovery.fromInvitation(
      invitation,
      phone.publicHex,
    );
    final previous = (await pairingJournal.list())
        .where((p) => p.hostId == original.hostId)
        .firstOrNull;
    if (previous?.sameAttempt(original) == true) {
      return await _recoverOriginal(original, phone);
    }
    await pairingJournal.begin(original);
    final (client, ack) = await SecureHostClient.pair(
      invitation,
      phone,
      endpoint,
    );
    try {
      await hosts.confirm(
        invitation: invitation,
        session: client.session,
        phone: phone,
        acknowledgement: ack,
      );
      await pairingJournal.clear(original);
      return _routed(client, (await hosts.read(invitation.hostId))!, phone);
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  Future<HostLink> recoverPairing(PairingRecovery original) async {
    if (!_pairingHosts.add(original.hostId)) {
      throw const ProtocolException('正在处理这台电脑的原配对，请稍后核实。');
    }
    try {
      final saved = (await pairingJournal.list())
          .where((p) => p.hostId == original.hostId)
          .firstOrNull;
      if (saved?.sameAttempt(original) != true) {
        throw const ProtocolException('原配对恢复记录已改变，请刷新后核实。');
      }
      final phone = await identity.get();
      return await _recoverOriginal(original, phone);
    } finally {
      _pairingHosts.remove(original.hostId);
    }
  }

  Future<HostLink> _recoverOriginal(
    PairingRecovery original,
    EndpointIdentity phone,
  ) async {
    final (client, ack) = await SecureHostClient.recoverPairing(
      original,
      phone,
      endpoint,
    );
    try {
      await hosts.confirm(
        invitation: original,
        session: client.session,
        phone: phone,
        acknowledgement: ack,
      );
      await pairingJournal.clear(original);
      return _routed(client, (await hosts.read(original.hostId))!, phone);
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  Future<HostLink> reconnect(Map<String, dynamic> host) async {
    final phone = await identity.get();
    return _routed(
      await SecureHostClient.reconnect(host, phone, endpoint),
      host,
      phone,
    );
  }

  AdaptiveHostLink _routed(
    HostLink relay,
    Map<String, dynamic> host,
    EndpointIdentity phone,
  ) => AdaptiveHostLink(
    relay: relay,
    relayDialer: () => SecureHostClient.reconnect(host, phone, endpoint),
    directDialer: (relay) => rtcConnector(
      relay: relay,
      host: host,
      phone: phone,
      endpoint: endpoint,
    ),
    desktopDialer: (signalling) => connectDesktopRtc(
      relay: signalling,
      host: host,
      phone: phone,
      endpoint: endpoint,
    ),
  );
}
