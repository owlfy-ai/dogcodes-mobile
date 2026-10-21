import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:dogcodes_app/core/adaptive_host_link.dart';
import 'package:dogcodes_app/core/mobile_runtime.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/core/network_address.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/rtc_transport.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';

const fixture = String.fromEnvironment('DOGCODES_P2P_FIXTURE');
Future<T> until<T>(Future<T?> Function() read) async => await (() async {
  while (true) {
    final result = await read();
    if (result != null) return result;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
})().timeout(const Duration(seconds: 45));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real DataChannel authenticates, controls PC, falls back without replay',
    skip: fixture.isEmpty,
    (tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        // The harness creates a fresh isolated PC only after the native app has
        // built, so the five-minute QR never expires during Xcode/Gradle builds.
        final http = HttpClient();
        final Map<String, dynamic> setup;
        try {
          final response = await (await http.getUrl(
            reachable(Uri.parse(fixture)),
          )).close();
          expect(response.statusCode, 200);
          setup =
              jsonDecode(await utf8.decoder.bind(response).join())
                  as Map<String, dynamic>;
        } finally {
          http.close(force: true);
        }
        DirectConnection? direct;
        Object? negotiationError;
        final storage = MemorySecretStorage();
        final runtime = MobileRuntime(
          storage: storage,
          rtcConnector:
              ({
                required relay,
                required host,
                required phone,
                required endpoint,
              }) async {
                try {
                  return direct = await connectRtc(
                    relay: relay,
                    host: host,
                    phone: phone,
                    endpoint: endpoint,
                  );
                } catch (error) {
                  negotiationError = error;
                  rethrow;
                }
              },
        );
        final invitation = PairingInvitation.parse(
          setup['invitation'] as String,
          trustedService: Uri.parse(setup['service'] as String),
          now: DateTime.now().toUtc(),
          allowLocalDevelopment: true,
        );
        final link = await runtime.pair(invitation) as AdaptiveHostLink;
        final events = <Map<String, dynamic>>[];
        final subscription = link.events.listen(events.add);
        try {
          await until(() async {
            if (negotiationError != null) {
              throw TestFailure(
                'Direct negotiation failed (${negotiationError.runtimeType}): $negotiationError',
              );
            }
            return link.route == ConnectionRoute.direct ? true : null;
          });
          final status = await link.call('transport_status', null) as Map;
          expect(status['transport'], 'webrtc-datachannel');
          expect(status['route']['mode'], 'direct');
          final snapshot = await link.call('bootstrap', null) as Map;
          final project = (snapshot['projects'] as List).single['projectId'];
          final executor =
              (await link.call('registered_executors', null) as List).single;
          await link.call('subscribe_project', [0, project]);
          final ops = MobileOperations(storage, link.hostId);
          // Crosses the 16KB SCTP boundary and exercises serialized Noise chunks.
          final prompt = 'phone p2p ${List.filled(17000, 'x').join()}';
          final sent = await ops.send(link, {
            'scope': 'p2p-acceptance',
            'taskId': null,
            'projectId': project,
            'target': executor,
            'input': {
              'prompt': prompt,
              'model': null,
              'thinking': null,
              'permissionMode': null,
              'attachments': [],
            },
          });
          expect(sent['state'], 'closed');
          final taskId = sent['resolution']['taskId'];
          final approval = await until<Map<String, dynamic>>(() async {
            final list =
                await link.call('pending_approvals', [taskId, 50]) as List;
            return list.isEmpty
                ? null
                : Map<String, dynamic>.from(list.first as Map);
          });
          expect(events.any((e) => e['type'] != 'transport_changed'), isTrue);
          // Close the actual authenticated DataChannel, not a mocked connection.
          await direct!.link.close();
          await until(
            () async =>
                events
                    .where(
                      (e) =>
                          e['type'] == 'transport_changed' &&
                          e['route'] == 'relay',
                    )
                    .isNotEmpty
                ? true
                : null,
          );
          expect(
            (await link.call('transport_status', null))['transport'],
            'wss-relay',
          );
          expect(await ops.pending(), isNull);
          final after = await link.call('bootstrap', null) as Map;
          expect(
            (after['tasks'] as List).length,
            1,
            reason: 'Fallback must not send the task again',
          );
          expect(
            (await link.call('pending_approvals', [taskId, 50]) as List)
                .single['approvalId'],
            approval['approvalId'],
          );
          // Project subscriptions are connection-owned and must be recreated.
          await link.call('subscribe_project', [
            after['lastSequence'] ?? 0,
            project,
          ]);
          debugPrint(
            'P2P acceptance passed: pinned Noise, fragmented task, streaming, real channel close, authenticated relay fallback, no task replay.',
          );
        } finally {
          await subscription.cancel();
          await link.close();
        }
      });
    },
  );
}
