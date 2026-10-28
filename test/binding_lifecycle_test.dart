import 'dart:async';
import 'dart:convert';
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/security/host_lifecycle.dart';
import 'package:dogcodes_app/core/security/noise_endpoint.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/security/identity_store.dart';

const pc = 'binding-test-pc';
String get hostKey => 'dogcodes.host.v1.${sha256.convert(utf8.encode(pc))}';
List<String> get journals => [
  'dogcodes.pending.v1.$pc',
  'dogcodes.pending.v1.$pc.side',
  'dogcodes.cancel.v1.$pc',
  'dogcodes.terminal-stops.v1.$pc',
];
Map<String, String> seed() => {
  'dogcodes.host.index.v1': jsonEncode([pc]),
  hostKey: jsonEncode({
    'version': 1,
    'hostId': pc,
    'service': 'https://fixture.invalid',
    'publicKey': List.filled(64, 'a').join(),
    'grantRevision': '1',
    'routeToken': List.filled(64, 'b').join(),
  }),
  for (final key in journals) key: jsonEncode({'original': key}),
};

class RestartableSecrets implements ErasableSecretStorage {
  RestartableSecrets([Map<String, String>? initial]) : values = {...?initial};
  final Map<String, String> values;
  bool failIndex = false;
  String? failDelete, failWrite;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failIndex && key == 'dogcodes.host.index.v1') {
      throw StateError('index unavailable');
    }
    if (key == failWrite) throw StateError('write unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (key == failDelete) throw StateError('delete unavailable');
    values.remove(key);
  }
}

class WriteOnlySecrets implements SecretStorage {
  WriteOnlySecrets(this.inner);
  final RestartableSecrets inner;
  @override
  Future<String?> read(String key) => inner.read(key);
  @override
  Future<void> write(String key, String value) => inner.write(key, value);
}

void main() {
  test(
    'forget alone removes all four operation journals before a new binding',
    () async {
      final storage = RestartableSecrets(seed());
      await TrustedHostStore(storage).forget(pc);
      for (final key in journals) {
        expect(await storage.read(key), anyOf(isNull, 'null'), reason: key);
      }
      expect(
        await TrustedHostStore(RestartableSecrets(storage.values)).read(pc),
        isNull,
      );
    },
  );
  test(
    'storage without delete cannot retain a readable trusted host after forget',
    () async {
      final storage = RestartableSecrets(seed());
      await TrustedHostStore(WriteOnlySecrets(storage)).forget(pc);
      expect(
        await TrustedHostStore(
          WriteOnlySecrets(RestartableSecrets(storage.values)),
        ).read(pc),
        isNull,
      );
    },
  );
  test(
    'a persisted removal survives restart even if the host index update fails',
    () async {
      final storage = RestartableSecrets(seed())..failIndex = true;
      await expectLater(
        TrustedHostStore(storage).forget(pc),
        throwsA(isA<StateError>()),
      );
      final restarted = TrustedHostStore(RestartableSecrets(storage.values));
      expect(await restarted.read(pc), isNull);
      expect(await restarted.list(), isEmpty);
    },
  );
  test(
    'late pairing acknowledgement cannot resurrect a removed binding',
    () async {
      final storage = RestartableSecrets(), store = TrustedHostStore(storage);
      final first = await store.beginPairing(pc);
      await store.forget(pc);
      await expectLater(
        confirm(store, first),
        throwsA(isA<ProtocolException>()),
      );
      expect(await store.read(pc), isNull);
      final next = await store.beginPairing(pc);
      expect(next, isNot(first));
      await confirm(store, next);
      expect((await store.read(pc))!['bindingEpoch'], next);
    },
  );

  test(
    'new binding never inherits old journals and old objects cannot send through it',
    () async {
      final storage = RestartableSecrets(), store = TrustedHostStore(storage);
      final first = await store.beginPairing(pc);
      await confirm(store, first);
      final old = MobileOperations(storage, pc, bindingEpoch: first);
      final api = UnknownApi();
      await failure(review(old, api));
      expect((await old.pending())!['localBindingEpoch'], first);
      final saved = (await old.pending())!;
      await store.forget(pc, first);
      final restartedStorage = RestartableSecrets(storage.values),
          restarted = TrustedHostStore(restartedStorage);
      final next = await restarted.beginPairing(pc);
      await confirm(restarted, next);
      final fresh = MobileOperations(restartedStorage, pc, bindingEpoch: next);
      expect(await fresh.pending(), isNull);
      await failure(fresh.retryReviewWrite(api, saved));
      await failure(
        MobileOperations(restartedStorage, pc, bindingEpoch: first).startReview(
          api,
          taskId: 'old',
          turnId: 'turn',
          kind: 'code',
          executor: {'providerId': 'fake', 'installationId': 'owned'},
        ),
      );
      await failure(review(MobileOperations(restartedStorage, pc), api));
      expect(api.starts, 1);
      await failure(review(fresh, api));
      expect(api.starts, 2);
      expect((await fresh.pending())!['localBindingEpoch'], next);
    },
  );

  test('a stale forget cannot remove or invalidate a fresh binding', () async {
    final storage = RestartableSecrets(), store = TrustedHostStore(storage);
    final first = await store.beginPairing(pc);
    await confirm(store, first);
    await store.forget(pc, first);
    final next = await store.beginPairing(pc);
    await confirm(store, next);
    final ops = MobileOperations(storage, pc, bindingEpoch: next),
        api = UnknownApi();
    await expectLater(
      store.forget(pc, first),
      throwsA(isA<ProtocolException>()),
    );
    await failure(review(ops, api));
    expect(api.starts, 1);
    expect(await ops.pending(), isNotNull);
  });

  test(
    'failed cleanup stays unpaired across restart; a fresh confirmation resumes cleanup',
    () async {
      final storage = RestartableSecrets(seed())..failDelete = journals[1];
      await expectLater(
        TrustedHostStore(storage).forget(pc),
        throwsA(isA<StateError>()),
      );
      final tombstone = jsonDecode(storage.values[hostKey]!) as Map;
      expect(tombstone.containsKey('routeToken'), isFalse);
      expect(tombstone.containsKey('publicKey'), isFalse);
      final restartedStorage = RestartableSecrets(storage.values),
          store = TrustedHostStore(restartedStorage);
      expect(await store.read(pc), isNull);
      final epoch = await store.beginPairing(pc);
      await confirm(store, epoch);
      for (final key in journals) {
        expect(await restartedStorage.read(key), anyOf(isNull, 'null'));
      }
      expect((await store.read(pc))!['bindingEpoch'], epoch);
    },
  );

  test(
    'a foreign journal is not recovered or cleared by the current binding',
    () async {
      final storage = RestartableSecrets(), store = TrustedHostStore(storage);
      final epoch = await store.beginPairing(pc);
      await confirm(store, epoch);
      final raw = jsonEncode({
        'kind': 'review',
        'localBindingEpoch': newBindingEpoch(),
        'request': {'runId': 'other'},
      });
      await storage.write(journals[0], raw);
      final ops = MobileOperations(storage, pc, bindingEpoch: epoch);
      expect(await ops.pending(), isNull);
      expect(await storage.read(journals[0]), raw);
      final api = UnknownApi();
      await failure(
        ops.retryReviewWrite(api, jsonDecode(raw) as Map<String, dynamic>),
      );
      expect(api.starts, 0);
    },
  );

  test('different registry instances preserve the shared index', () async {
    final storage = RestartableSecrets(),
        a = TrustedHostStore(storage),
        b = TrustedHostStore(storage);
    final ids = await Future.wait([
      a.beginPairing(pc),
      b.beginPairing('other-pc'),
    ]);
    await Future.wait([
      confirm(a, ids[0]),
      confirm(b, ids[1], host: 'other-pc'),
    ]);
    expect((await a.list()).map((h) => h['hostId']).toSet(), {pc, 'other-pc'});
  });

  test(
    'publishing a new credential failure never exposes a partially cleaned binding',
    () async {
      final storage = RestartableSecrets(), store = TrustedHostStore(storage);
      final epoch = await store.beginPairing(pc);
      storage.failWrite = hostKey;
      await expectLater(confirm(store, epoch), throwsA(isA<StateError>()));
      final restartedStorage = RestartableSecrets(storage.values),
          restarted = TrustedHostStore(restartedStorage);
      expect(await restarted.list(), isEmpty);
      await confirm(restarted, epoch);
      expect((await restarted.list()).single['bindingEpoch'], epoch);
    },
  );

  test(
    'Hub replaces stale state objects instead of updating their binding in place',
    () async {
      final storage = RestartableSecrets(), store = TrustedHostStore(storage);
      final first = await store.beginPairing(pc);
      await confirm(store, first);
      final hub = HostHub(storage: storage, lister: store.list);
      try {
        await hub.load(connect: false);
        final old = hub.hosts.single;
        await store.forget(pc, first);
        final next = await store.beginPairing(pc);
        await confirm(store, next);
        await hub.load(connect: false);
        expect(identical(old, hub.hosts.single), isFalse);
        expect(hub.hosts.single.record['bindingEpoch'], next);
        final api = UnknownApi();
        await failure(review(old.operations, api));
        expect(api.starts, 0);
      } finally {
        hub.dispose();
      }
    },
  );
  test(
    'removing a computer closes new calls before waiting for slow transport cleanup',
    () async {
      final storage = RestartableSecrets();
      final entered = Completer<void>(), released = Completer<void>();
      var connections = 0, removals = 0;
      final link = ClosingLink();
      final hub = HostHub(
        storage: storage,
        connector: (_) async {
          connections++;
          return ClosingLink()..release.complete();
        },
        forgetter: (_, _) async {
          removals++;
          entered.complete();
          await released.future;
        },
      );
      final h = HostState({'hostId': pc}, storage)
        ..link = link
        ..status = LinkStatus.online;
      hub.hosts.add(h);
      try {
        final first = hub.forget(h);
        final checked = failure(first);
        expect(identical(first, hub.forget(h)), isTrue);
        await entered.future;
        expect(h.online, isFalse);
        expect(h.link, isNull);
        expect(link.closed, isTrue);
        await expectLater(
          link.call('unsafe', null),
          throwsA(isA<ProtocolException>()),
        );
        await hub.connect(h);
        expect(connections, 0);
        expect(removals, 1);
        released.complete();
        link.release.complete();
        await checked;
        expect(hub.hosts, isEmpty);
      } finally {
        if (!link.release.isCompleted) link.release.complete();
        hub.dispose();
      }
    },
  );

  test(
    'removal failure leaves the transport closed and permits an explicit retry',
    () async {
      final storage = RestartableSecrets();
      var attempts = 0;
      final link = ClosingLink()..release.complete();
      final hub = HostHub(
        storage: storage,
        forgetter: (_, _) async {
          if (attempts++ == 0) throw StateError('storage locked');
        },
      );
      final h = HostState({'hostId': pc}, storage)
        ..link = link
        ..status = LinkStatus.online;
      hub.hosts.add(h);
      try {
        await expectLater(hub.forget(h), throwsA(isA<StateError>()));
        expect(h.online, isFalse);
        expect(link.closed, isTrue);
        expect(h.error, contains('移除未完成'));
        await hub.forget(h);
        expect(attempts, 2);
        expect(hub.hosts, isEmpty);
      } finally {
        hub.dispose();
      }
    },
  );

  test(
    'a failed removal with no durable tombstone can recover without reusing retired UI state',
    () async {
      final storage = RestartableSecrets(), store = TrustedHostStore(storage);
      final epoch = await store.beginPairing(pc);
      await confirm(store, epoch);
      final hub = HostHub(storage: storage, lister: store.list);
      try {
        await hub.load(connect: false);
        final old = hub.hosts.single;
        storage.failWrite = hostKey;
        await expectLater(store.forget(pc, epoch), throwsA(isA<StateError>()));
        expect(old.operations.retired, isTrue);
        storage.failWrite = null;
        await confirm(store, epoch);
        await hub.load(connect: false);
        expect(identical(old, hub.hosts.single), isFalse);
        final api = UnknownApi();
        await failure(review(hub.hosts.single.operations, api));
        expect(api.starts, 1);
      } finally {
        hub.dispose();
      }
    },
  );
}

PairingInvitation pins(String host) => PairingInvitation.parse(
  'dogcodes://pair#${base64Url.encode(utf8.encode(jsonEncode({'version': 1, 'hostId': host, 'hostKey': base64Url.encode(List.filled(32, 170)), 'secret': base64Url.encode(List.filled(32, 1)), 'invitationId': 'owned-invitation', 'phoneTicket': List.filled(64, 'b').join(), 'service': 'https://fixture.invalid', 'expiresAt': (DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + 120).toString()})))}',
  trustedService: Uri.parse('https://fixture.invalid'),
  now: DateTime.now().toUtc(),
);

class SessionStub implements NoiseSession {
  @override
  String get authenticatedPeer => List.filled(64, 'a').join();
  @override
  String get binding => 'owned-test-session';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> confirm(TrustedHostStore store, String epoch, {String host = pc}) {
  final session = SessionStub(),
      phone = EndpointIdentity(
        secretHex: List.filled(64, 'c').join(),
        publicHex: List.filled(64, 'b').join(),
      );
  return store.confirm(
    invitation: pins(host),
    session: session,
    phone: phone,
    bindingEpoch: epoch,
    acknowledgement: {
      'type': 'paired',
      'hostId': host,
      'invitationId': 'owned-invitation',
      'phonePublicKey': phone.publicHex,
      'hostPublicKey': session.authenticatedPeer,
      'binding': session.binding,
      'routeToken': List.filled(64, 'd').join(),
      'grantRevision': '1',
    },
  );
}

class UnknownApi implements HostApi {
  int starts = 0;
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method == 'turn_reviews') return [];
    if (method == 'start_turn_review') {
      starts++;
      throw StateError('lost reply');
    }
    throw StateError(method);
  }
}

Future<dynamic> review(MobileOperations ops, HostApi api) => ops.startReview(
  api,
  taskId: 'task',
  turnId: 'turn',
  kind: 'code',
  executor: {'providerId': 'fake', 'installationId': 'owned'},
);
Future<Object?> failure(Future<dynamic> work) =>
    work.then<Object?>((v) => v, onError: (Object e) => e);

class ClosingLink implements HostLink {
  bool closed = false;
  final release = Completer<void>();
  @override
  String get hostId => pc;
  @override
  String? get hostName => null;
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (closed) throw const ProtocolException('closed');
    return null;
  }

  @override
  Future<void> close() {
    closed = true;
    return release.future;
  }
}
