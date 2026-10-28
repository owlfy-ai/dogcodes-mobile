import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/push_notifications.dart';
import 'notification_settings_test.dart'
    show NotificationFixture, notificationHost;

Map<String, dynamic> notice([
  String id = 'notice-1',
  String host = notificationHost,
]) => {
  'notificationId': id,
  'hostId': host,
  'taskId': 't1',
  'kind': 'approval',
};

class FakePushAdapter implements PushAdapter {
  @override
  bool configured = true;
  String providerId = 'emas_ios';
  String deviceId = 'emas-device-id';
  Completer<String>? gate;
  final permissions = <bool>[];
  void Function(Map<dynamic, dynamic>)? opened;
  Map<dynamic, dynamic>? initial;
  void Function()? changed;
  @override
  void listen(
    void Function(Map<dynamic, dynamic>) onOpen, {
    void Function()? onRegistrationChanged,
  }) {
    changed = onRegistrationChanged;
    opened = onOpen;
    if (initial != null) onOpen(initial!);
  }

  @override
  Future<PushRegistration> register({required bool requestPermission}) async {
    permissions.add(requestPermission);
    return PushRegistration(
      providerId,
      await (gate?.future ?? Future.value(deviceId)),
    );
  }
}

Future<(NotificationFixture, HostHub, PushNotifications, FakePushAdapter)>
pushFixture({bool enabled = false}) async {
  final fixture = NotificationFixture();
  await fixture.init();
  if (enabled) await fixture.storage.write('dogcodes.push.enabled.v1', 'true');
  final hub = HostHub(storage: fixture.storage, lister: fixture.hosts.list);
  await hub.load(connect: false);
  final adapter = FakePushAdapter();
  final push = PushNotifications(
    fixture.storage,
    fixture.hosts,
    fixture.api,
    adapter,
  );
  await push.initialize(hub);
  addTearDown(() {
    push.dispose();
    hub.dispose();
  });
  return (fixture, hub, push, adapter);
}

void main() {
  test(
    'registration is explicit, preserves muted preferences and refreshes changed device IDs',
    () async {
      final (fixture, _, push, adapter) = await pushFixture();
      expect(adapter.permissions, isEmpty);
      fixture.value = {
        ...fixture.value,
        'muted': true,
        'enabledKinds': ['failed'],
      };
      await push.enable();
      expect(adapter.permissions, [true]);
      expect(push.ready, isTrue);
      expect(fixture.value['providerId'], 'emas_ios');
      expect(fixture.value['token'], 'emas-device-id');
      expect(fixture.value['muted'], isTrue);
      expect(fixture.value['mutedTasks'], ['other-task']);
      expect(fixture.value['enabledKinds'], ['failed']);
      await push.refresh();
      expect(fixture.calls.where((c) => c['method'] == 'PUT'), hasLength(1));
      adapter.deviceId = 'changed-device-id';
      await push.refresh();
      expect(fixture.calls.where((c) => c['method'] == 'PUT'), hasLength(2));
      expect(fixture.value['token'], 'changed-device-id');
    },
  );

  test(
    'provider switches replace the phone target and keep mute preferences',
    () async {
      final (fixture, _, push, adapter) = await pushFixture();
      await push.enable();
      adapter.providerId = 'fcm';
      adapter.deviceId = 'google-token';
      adapter.changed!();
      await push.refresh();
      expect(fixture.value['providerId'], 'fcm');
      expect(fixture.value['token'], 'google-token');
      expect(fixture.value['mutedTasks'], ['other-task']);
      expect(fixture.calls.where((c) => c['method'] == 'PUT'), hasLength(2));
    },
  );

  test(
    'restoring enabled reminders does not request system permission again',
    () async {
      final (_, _, push, adapter) = await pushFixture(enabled: true);
      expect(push.enabled, isTrue);
      expect(adapter.permissions, [false]);
    },
  );

  test(
    'failed registration waits for an explicit refresh and preserves newer settings',
    () async {
      final (fixture, _, push, _) = await pushFixture();
      fixture.conflict = true;
      await push.enable();
      expect(push.error, isNotNull);
      expect(fixture.calls.where((c) => c['method'] == 'PUT'), hasLength(1));
      fixture.conflict = false;
      fixture.value = {
        ...fixture.value,
        'revision': '9007199254740995',
        'muted': true,
        'enabledKinds': ['question'],
      };
      await push.refresh();
      expect(push.error, isNull);
      expect(fixture.value['muted'], isTrue);
      expect(fixture.value['enabledKinds'], ['question']);
      expect(fixture.calls.where((c) => c['method'] == 'PUT'), hasLength(2));
    },
  );

  test('direct APNs envelopes reach the common click controller', () async {
    final (_, _, push, adapter) = await pushFixture();
    adapter.opened!({
      'aps': {
        'alert': {'title': 'DogCodes', 'body': '有任务需要你处理'},
      },
      'dogcodes': notice('native-apple-notice'),
    });
    expect(push.takeOpen()?.id, 'native-apple-notice');
    expect(push.takeOpen(), isNull);
  });

  test(
    'notification envelopes are hints and duplicate click callbacks open only once',
    () async {
      final (fixture, _, push, adapter) = await pushFixture();
      for (final input in [
        notice(),
        {'extraMap': jsonEncode(notice())},
        {'extMap': notice()},
        {'dogcodes': notice()},
      ]) {
        adapter.opened!(input);
      }
      expect(push.takeOpen()?.taskId, 't1');
      expect(push.takeOpen(), isNull);
      adapter.opened!({
        ...notice('second'),
        'kind': 'run_command',
        'command': 'unsafe',
      });
      expect(push.takeOpen(), isNull);
      adapter.opened!({'extraMap': 'invalid json'});
      expect(push.takeOpen(), isNull);
      expect(fixture.calls, isEmpty);
    },
  );

  test(
    'disposing during SDK registration never registers a late target',
    () async {
      final fixture = NotificationFixture();
      await fixture.init();
      final hub = HostHub(storage: fixture.storage, lister: fixture.hosts.list);
      await hub.load(connect: false);
      final gate = Completer<String>();
      final adapter = FakePushAdapter()..gate = gate;
      final push = PushNotifications(
        fixture.storage,
        fixture.hosts,
        fixture.api,
        adapter,
      );
      await push.initialize(hub);
      final enabling = push.enable();
      push.dispose();
      gate.complete('late-device');
      await enabling;
      expect(fixture.calls, isEmpty);
      expect(await fixture.storage.read('dogcodes.push.enabled.v1'), isNull);
      hub.dispose();
    },
  );
}
