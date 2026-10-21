import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/adaptive_host_link.dart';
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';

class Link implements HostLink {
  final controller = StreamController<Map<String, dynamic>>.broadcast();
  final calls = <(String, dynamic)>[];
  bool closed = false, capable = true;
  Future<dynamic> Function(String, dynamic)? respond;
  @override
  String get hostId => 'pc';
  @override
  String get hostName => 'PC';
  @override
  Stream<Map<String, dynamic>> get events => controller.stream;
  @override
  Future<dynamic> call(String method, dynamic params) async {
    calls.add((method, params));
    if (method == 'remote_capabilities') {
      return {
        'transportMethods': [if (capable) 'direct_open'],
      };
    }
    return respond?.call(method, params) ?? 'ok';
  }

  void disconnected() => controller.add({'type': 'disconnected'});
  @override
  Future<void> close() async {
    closed = true;
    await controller.close();
  }
}

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'failed candidate preserves the relay and existing business requests',
    () async {
      final relay = Link();
      var attempts = 0;
      final link = AdaptiveHostLink(
        relay: relay,
        relayDialer: () async => Link(),
        directDialer: (_) async {
          attempts++;
          throw StateError('ICE blocked');
        },
      );
      addTearDown(link.close);
      await Future.wait([link.tryDirect(), link.tryDirect()]);
      expect(attempts, 1);
      expect(relay.closed, false);
      expect(link.route, ConnectionRoute.relay);
      expect(await link.call('execute', {'operationId': 'original'}), 'ok');
    },
  );
  test(
    'upgrade drains an in-flight write receipt before closing old relay',
    () async {
      final relay = Link(), direct = Link();
      final receipt = Completer<dynamic>();
      relay.respond = (_, _) => receipt.future;
      final link = AdaptiveHostLink(
        relay: relay,
        relayDialer: () async => Link(),
        directDialer: (_) async =>
            DirectConnection(direct, ConnectionRoute.direct),
      );
      addTearDown(link.close);
      final write = link.call('execute', {'operationId': 'unchanged'});
      await link.tryDirect();
      expect(link.route, ConnectionRoute.direct);
      expect(relay.closed, false);
      receipt.complete({'accepted': true});
      expect(await write, {'accepted': true});
      await flush();
      expect(relay.closed, true);
      expect(direct.calls, isEmpty, reason: 'Never replay writes on upgrade');
    },
  );
  test(
    'direct disconnect reconnects once and never replays uncertain operation',
    () async {
      final relay = Link(), direct = Link(), fallback = Link();
      final receipt = Completer<dynamic>(), dial = Completer<HostLink>();
      direct.respond = (_, _) => receipt.future;
      var dials = 0;
      final link = AdaptiveHostLink(
        relay: relay,
        relayDialer: () {
          dials++;
          return dial.future;
        },
        directDialer: (_) async =>
            DirectConnection(direct, ConnectionRoute.direct),
      );
      addTearDown(link.close);
      final events = <Map<String, dynamic>>[];
      final sub = link.events.listen(events.add);
      addTearDown(sub.cancel);
      await link.tryDirect();
      final write = link.call('execute', {'operationId': 'original'});
      final failed = expectLater(write, throwsA(isA<RemoteOutcomeUnknown>()));
      direct.disconnected();
      direct.disconnected();
      await flush();
      receipt.completeError(const RemoteOutcomeUnknown());
      await failed;
      expect(dials, 1);
      await expectLater(
        link.call('execute', null),
        throwsA(isA<RemoteOutcomeUnknown>()),
      );
      dial.complete(fallback);
      await flush();
      expect(link.route, ConnectionRoute.relay);
      expect(await link.call('bootstrap', null), 'ok');
      expect(fallback.calls.map((c) => c.$1), ['bootstrap']);
      expect(events.where((e) => e['type'] == 'transport_changed').length, 2);
    },
  );
  test(
    'closing during negotiation closes late candidate and never resurrects link',
    () async {
      final relay = Link(), direct = Link();
      final candidate = Completer<DirectConnection>();
      final link = AdaptiveHostLink(
        relay: relay,
        relayDialer: () async => Link(),
        directDialer: (_) => candidate.future,
      );
      final upgrade = link.tryDirect();
      await flush();
      await link.close();
      candidate.complete(DirectConnection(direct, ConnectionRoute.direct));
      await upgrade;
      expect(direct.closed, true);
      await expectLater(
        link.call('bootstrap', null),
        throwsA(isA<RemoteOutcomeUnknown>()),
      );
    },
  );
  test(
    'older PC without direct capability keeps working through relay',
    () async {
      final relay = Link()..capable = false;
      final link = AdaptiveHostLink(
        relay: relay,
        relayDialer: () async => Link(),
        directDialer: (_) async => throw StateError('Must not negotiate'),
      );
      addTearDown(link.close);
      await link.tryDirect();
      expect(await link.call('bootstrap', null), 'ok');
      expect(relay.closed, false);
    },
  );
  test('TURN and unknown candidate paths are never labelled P2P', () {
    expect(
      ConnectionRoute.fromStatus({
        'route': {'mode': 'turn-relay'},
      }),
      ConnectionRoute.turn,
    );
    expect(
      ConnectionRoute.fromStatus({
        'route': {'mode': 'unknown'},
      }),
      ConnectionRoute.webRtc,
    );
    expect(
      ConnectionRoute.fromStatus({
        'route': {'mode': 'direct'},
      }),
      ConnectionRoute.direct,
    );
  });
  test(
    'short-lived TURN credentials negotiate a replacement before expiry',
    () {
      fakeAsync((time) {
        final relay = Link(), old = Link(), freshRelay = Link(), fresh = Link();
        var attempts = 0;
        final link = AdaptiveHostLink(
          relay: relay,
          relayDialer: () async => freshRelay,
          directDialer: (_) async {
            attempts++;
            return DirectConnection(
              attempts == 1 ? old : fresh,
              ConnectionRoute.turn,
              expiresAt: DateTime.now().add(const Duration(seconds: 61)),
            );
          },
        );
        unawaited(link.tryDirect());
        time.flushMicrotasks();
        expect(link.route, ConnectionRoute.turn);
        time.elapse(const Duration(seconds: 31));
        time.flushMicrotasks();
        expect(attempts, 2);
        expect(old.closed, true);
        expect(freshRelay.closed, true);
        expect(fresh.closed, false);
        unawaited(link.close());
        time.flushMicrotasks();
        expect(time.pendingTimers, isEmpty);
      });
    },
  );
  test('failed credential renewal retains the working encrypted channel', () {
    fakeAsync((time) {
      final relay = Link(), direct = Link();
      final link = AdaptiveHostLink(
        relay: relay,
        relayDialer: () async => throw StateError('Service offline'),
        directDialer: (_) async => DirectConnection(
          direct,
          ConnectionRoute.turn,
          expiresAt: DateTime.now().add(const Duration(seconds: 61)),
        ),
      );
      unawaited(link.tryDirect());
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 31));
      time.flushMicrotasks();
      expect(direct.closed, false);
      expect(link.route, ConnectionRoute.turn);
      unawaited(
        link.call('bootstrap', null).then((value) => expect(value, 'ok')),
      );
      time.flushMicrotasks();
      unawaited(link.close());
      time.flushMicrotasks();
      expect(time.pendingTimers, isEmpty);
    });
  });
}
