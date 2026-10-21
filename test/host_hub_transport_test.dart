import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';

class ManyProjectsLink extends SwitchingLink {
  final active = <String, String>{};
  var nextId = 0;
  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'bootstrap') {
      return {
        ...SwitchingLink.snapshot(1),
        'projects': [
          for (var i = 0; i < 40; i++) {'projectId': 'p$i'},
        ],
      };
    }
    if (method == 'subscribe_project') {
      final id = 'subscription-${nextId++}';
      active[id] = params[1] as String;
      return {'subscriptionId': id};
    }
    if (method == 'unsubscribe') {
      active.remove(params);
      return {'unsubscribed': true};
    }
    return super.call(method, params);
  }
}

class SwitchingLink implements HostLink {
  @override
  String get hostId => 'pc';
  @override
  String? get hostName => null;
  final source = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get events => source.stream;
  final subscribed = <dynamic>[];
  Completer<dynamic>? delayed;
  int version = 1;
  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'bootstrap') {
      final pending = delayed;
      delayed = null;
      return pending != null ? pending.future : snapshot(version);
    }
    if (method == 'subscribe_project') subscribed.add(params);
    return switch (method) {
      'registered_executors' || 'quota_snapshots_for' => [],
      'agent_preferences' => {'disabled': []},
      _ => null,
    };
  }

  static Map<String, dynamic> snapshot(int version) => {
    'projects': [
      {'projectId': 'p'},
    ],
    'tasks': [],
    'installations': [],
    'lastSequence': version,
  };
  @override
  Future<void> close() async => source.close();
}

void main() {
  test(
    'open projects beyond the overview budget stay streamed without leaking subscriptions',
    () async {
      final hub = HostHub(storage: MemorySecretStorage());
      final host = HostState({'hostId': 'pc'}, hub.storage);
      hub.hosts.add(host);
      final link = ManyProjectsLink();
      await hub.attach(host, link);
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(link.active.length, 16);
      hub.followProject(host, 'p39');
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(link.active.values, contains('p39'));
      expect(link.active.length, 16);
      hub.followProject(host, 'p38');
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(link.active.values, contains('p38'));
      expect(link.active.values, isNot(contains('p39')));
      expect(link.active.length, 16);
      hub.dispose();
    },
  );
  test(
    'physical switch reboots snapshot/subscriptions and ignores old response',
    () async {
      final hub = HostHub(storage: MemorySecretStorage());
      final host = HostState({'hostId': 'pc'}, hub.storage);
      hub.hosts.add(host);
      final link = SwitchingLink();
      await hub.attach(host, link);
      expect(link.subscribed, [
        [1, 'p'],
      ]);
      final old = Completer<dynamic>();
      link.delayed = old;
      final refresh = hub.refresh(host);
      link.version = 2;
      link.source.add({'type': 'transport_changing'});
      await Future<void>.delayed(Duration.zero);
      expect(host.online, false);
      link.source.add({'type': 'transport_changed'});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(host.online, true);
      expect(link.subscribed, [
        [1, 'p'],
        [2, 'p'],
      ]);
      old.complete(SwitchingLink.snapshot(0));
      await refresh;
      expect(host.snapshot!['lastSequence'], 2);
      hub.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );
  test('disconnect during a relay dial closes the late link', () async {
    final pending = Completer<HostLink>();
    final hub = HostHub(
      storage: MemorySecretStorage(),
      connector: (_) => pending.future,
    );
    final host = HostState({'hostId': 'pc'}, hub.storage);
    hub.hosts.add(host);
    final connection = hub.connect(host);
    await hub.disconnect(host);
    final link = SwitchingLink();
    pending.complete(link);
    await connection;
    expect(host.status, LinkStatus.offline);
    expect(host.link, isNull);
    expect(link.source.isClosed, true);
    hub.dispose();
  });
}
