import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/service_origin.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/security/identity_store.dart';
import 'package:dogcodes_app/core/security/pairing_recovery.dart';

void main() {
  test('LAN HTTP is allowed only for development with literal private IPs', () {
    for (final host in [
      '192.168.1.161',
      '10.0.2.2',
      '172.16.0.1',
      '172.31.255.254',
      '127.0.0.1',
      'localhost',
      '[::1]',
    ]) {
      final uri = Uri.parse('http://$host:8787');
      expect(validServiceOrigin(uri), false);
      expect(validServiceOrigin(uri, allowLocalDevelopment: true), true);
    }
    for (final origin in [
      'http://8.8.8.8',
      'http://172.32.0.1',
      'http://192.169.1.1',
      'http://example.invalid',
      'http://user@192.168.1.161',
      'http://192.168.1.161/path',
      'http://192.168.1.161?q=1',
      'http://192.168.1.161#fragment',
    ]) {
      expect(
        validServiceOrigin(Uri.parse(origin), allowLocalDevelopment: true),
        false,
      );
    }
    expect(
      validServiceOrigin(Uri.parse('https://access.example.invalid')),
      true,
    );
  });
  test('LAN invitation, saved identity and recovery use the same validation', () {
    final now = DateTime.now().toUtc();
    final origin = Uri.parse('http://192.168.1.161:8787');
    final uri =
        'dogcodes://pair#${base64Url.encode(utf8.encode(jsonEncode({'version': 1, 'hostId': 'fixture-host', 'hostKey': base64Url.encode(List.filled(32, 1)), 'invitationId': 'fixture-invitation', 'secret': base64Url.encode(List.filled(32, 2)), 'service': origin.toString(), 'phoneTicket': 'a' * 32, 'expiresAt': (now.millisecondsSinceEpoch ~/ 1000 + 120).toString()})))}';
    expect(
      () => PairingInvitation.parse(uri, trustedService: origin, now: now),
      throwsA(isA<ProtocolException>()),
    );
    expect(
      () => PairingInvitation.parse(
        uri,
        trustedService: Uri.parse('http://192.168.1.162:8787'),
        now: now,
        allowLocalDevelopment: true,
      ),
      throwsA(isA<ProtocolException>()),
    );
    final invitation = PairingInvitation.parse(
      uri,
      trustedService: origin,
      now: now,
      allowLocalDevelopment: true,
    );
    expect(validSavedService(origin.toString()), true);
    expect(validSavedService('http://8.8.8.8'), false);
    final original = PairingRecovery.fromInvitation(
      invitation,
      '01' * 32,
      bindingEpoch: 'a' * 32,
    );
    final saved = original.toJson();
    expect(
      PairingRecovery.fromJson(saved, allowLocalDevelopment: true).service,
      origin,
    );
    expect(
      () => PairingRecovery.fromJson(saved, allowLocalDevelopment: false),
      throwsA(isA<ProtocolException>()),
    );
  });
}
