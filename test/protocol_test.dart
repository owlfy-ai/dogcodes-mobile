import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/host_channel.dart';
import 'package:dogcodes_app/data/draft_store.dart';

void main() {
  test('service fixture matches the Rust service', () {
    final info = ServiceInfo.fromJson(
      jsonDecode(File('test/fixtures/service-info.v1.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    expect(info.version, 1);
    expect(info.capabilities['pairing'], true);
    expect(info.capabilities['business'], false);
  });
  test('remote cursor preserves u64 precision', () {
    expect(
      parseSequence('18446744073709551615').toString(),
      '18446744073709551615',
    );
    for (final invalid in ['1.5', '-1', '01', '18446744073709551616']) {
      expect(() => parseSequence(invalid), throwsA(isA<ProtocolException>()));
    }
  });
  test('mutations require an operation identity', () {
    expect(
      () => HostRequest(
        requestId: 'r',
        hostId: 'h',
        method: 'submission_intents',
        params: {},
        mutating: true,
      ),
      throwsA(isA<ProtocolException>()),
    );
    final request = HostRequest(
      requestId: 'r',
      hostId: 'h',
      method: 'submission_intents',
      params: {'type': 'get_start'},
      operationId: 'original-operation',
    );
    expect(request.toJson()['operationId'], 'original-operation');
  });
  final now = DateTime.utc(2026, 10, 18, 12);
  final trusted = Uri.parse('https://access.example.invalid');
  String invite({String? service, int? expires}) =>
      'dogcodes://pair#${base64Url.encode(utf8.encode(jsonEncode({'version': 1, 'hostId': 'pc-fixture', 'hostKey': base64Url.encode(List.filled(32, 1)), 'invitationId': 'invite-fixture', 'secret': base64Url.encode(List.filled(32, 2)), 'service': service ?? trusted.toString(), 'expiresAt': (expires ?? now.millisecondsSinceEpoch ~/ 1000 + 120).toString()})))}';
  test('QR decoding validates origin, key lengths, version and expiration', () {
    final invitation = PairingInvitation.parse(
      invite(),
      trustedService: trusted,
      now: now,
    );
    expect(invitation.hostId, 'pc-fixture');
    expect(invitation.toString(), isNot(contains(invitation.secret)));
    for (final invalid in [
      invite(service: 'https://attacker.invalid'),
      invite(expires: now.millisecondsSinceEpoch ~/ 1000),
      invite(expires: now.millisecondsSinceEpoch ~/ 1000 + 331),
      'dogcodes://pair?secret=bad',
      'https://access.example.invalid/#x',
    ]) {
      expect(
        () =>
            PairingInvitation.parse(invalid, trustedService: trusted, now: now),
        throwsA(isA<ProtocolException>()),
      );
    }
  });
  test(
    'fresh QR tolerates small clock skew without accepting expired invitations',
    () {
      final seconds = now.millisecondsSinceEpoch ~/ 1000;
      expect(
        PairingInvitation.parse(
          invite(expires: seconds + 300),
          trustedService: trusted,
          now: now.subtract(const Duration(seconds: 5)),
        ).hostId,
        'pc-fixture',
      );
      expect(
        () => PairingInvitation.parse(
          invite(expires: seconds),
          trustedService: trusted,
          now: now,
        ),
        throwsA(isA<ProtocolException>()),
      );
    },
  );
  test(
    'drafts survive restart and remain isolated by host and conversation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'dogcodes-drafts-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = DraftStore(directory);
      await Future.wait([
        store.save('pc1', 'project', 'task', {
          'text': 'first',
          'model': 'model-a',
        }),
        store.save('pc1', 'project', 'task', {
          'text': 'latest',
          'model': 'model-b',
        }),
        store.save('pc2', 'project', 'task', {'text': 'other'}),
      ]);
      final reopened = DraftStore(directory);
      expect(
        (await reopened.read('pc1', 'project', 'task'))!['text'],
        'latest',
      );
      expect((await reopened.read('pc2', 'project', 'task'))!['text'], 'other');
      expect(await reopened.read('pc1', 'project', 'elsewhere'), null);
    },
  );
}
