import 'host_api.dart';
import 'adaptive_host_link.dart';
import 'rtc_transport.dart';
import 'protocol.dart';
import 'secure_host_client.dart';
import 'security/noise_endpoint.dart';
import 'security/identity_store.dart';

class MobileRuntime {
  MobileRuntime({SecretStorage? storage, this.rtcConnector = connectRtc})
    : storage = storage ?? PlatformSecretStorage();
  final SecretStorage storage;
  final RtcConnector rtcConnector;
  NoiseEndpoint? _endpoint;
  NoiseEndpoint get endpoint => _endpoint ??= NoiseEndpoint.bundled();
  DeviceIdentityStore? _identity;
  DeviceIdentityStore get identity =>
      _identity ??= DeviceIdentityStore(storage, endpoint.createIdentity);
  late final TrustedHostStore hosts = TrustedHostStore(storage);
  Future<HostLink> pair(PairingInvitation invitation) async {
    final phone = await identity.get();
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
      return _routed(client, (await hosts.read(invitation.hostId))!, phone);
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
  );
}
