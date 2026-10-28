import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/notification_settings.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'package:dogcodes_app/core/security/identity_store.dart';
import 'package:dogcodes_app/core/security/host_lifecycle.dart';

const notificationHost = 'notification-pc';
const notificationEpoch = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

Future<TrustedHostStore> notificationBinding(
  MemorySecretStorage storage, {
  String service = 'https://notification.invalid',
}) async {
  await HostRegistry(storage).host(notificationHost).persist({
    'version': 1,
    'hostId': notificationHost,
    'displayName': 'Test PC',
    'bindingEpoch': notificationEpoch,
    'service': service,
    'publicKey': List.filled(64, 'a').join(),
    'grantRevision': '1',
    'routeToken': 'fixture-route-token',
  });
  await storage.write('dogcodes.host.index.v1', jsonEncode([notificationHost]));
  return TrustedHostStore(storage);
}

class NotificationFixture {
  final storage = MemorySecretStorage();
  late TrustedHostStore hosts;
  late NotificationSettingsApi api;
  Map<String, dynamic> value = {
    'revision': '9007199254740993',
    'registered': false,
    'providerId': null,
    'muted': false,
    'mutedTasks': ['other-task'],
    'enabledKinds': ['approval', 'question', 'completed', 'failed'],
  };
  final calls = <Map<String, dynamic>>[];
  final started = Completer<void>();
  bool loseAfter = false, loseBefore = false, offline = false, conflict = false;
  Completer<Map<String, dynamic>>? readGate;
  Future<void> init() async {
    hosts = await notificationBinding(storage);
    api = NotificationSettingsApi(hosts, request: request);
  }

  Future<Map<String, dynamic>> request(
    Uri service,
    String path,
    String token,
    String method,
    Map<String, dynamic>? body,
  ) async {
    calls.add({
      'service': service.toString(),
      'path': path,
      'token': token,
      'method': method,
      'body': body,
    });
    if (!started.isCompleted) started.complete();
    if (offline) throw const SocketException('fixture offline');
    if (method == 'PUT') {
      if (conflict || body!['expectedRevision'] != value['revision']) {
        throw const RouteRequestRejected(409, 'raw service error');
      }
      if (loseBefore) throw const SocketException('lost before save');
      value = {
        ...value,
        ...body,
        'registered': body.containsKey('token') ? true : value['registered'],
        'revision': (BigInt.parse(value['revision']) + BigInt.one).toString(),
      };
      if (loseAfter) throw const SocketException('lost after save');
    } else if (readGate != null) {
      return readGate!.future;
    }
    return jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  }
}

void main() {
  test(
    'settings use the saved origin and binding token and preserve push registration',
    () async {
      final fixture = NotificationFixture();
      await fixture.init();
      final old = await fixture.api.read(notificationHost, notificationEpoch);
      expect(old.revision, '9007199254740993');
      final now = await fixture.api.save(
        notificationHost,
        notificationEpoch,
        old.copyWith(muted: true),
      );
      expect(now.muted, isTrue);
      expect(now.mutedTasks, {'other-task'});
      final put = fixture.calls.last;
      expect(put['service'], 'https://notification.invalid');
      expect(put['path'], '/v1/hosts/notification-pc/notification-settings');
      expect(put['token'], 'fixture-route-token');
      final body = put['body'] as Map;
      expect(body['expectedRevision'], '9007199254740993');
      expect(body.containsKey('token'), isFalse);
      expect(body.containsKey('providerId'), isFalse);
      expect(body.containsKey('clearTarget'), isFalse);
      expect(body['operationId'], matches(RegExp(r'^[0-9a-f-]{36}$')));
    },
  );

  test('revision conflict is friendly and does not retry the write', () async {
    final fixture = NotificationFixture();
    await fixture.init();
    final old = await fixture.api.read(notificationHost, notificationEpoch);
    fixture.conflict = true;
    await expectLater(
      fixture.api.save(
        notificationHost,
        notificationEpoch,
        old.copyWith(muted: true),
      ),
      throwsA(
        isA<ProtocolException>().having(
          (e) => e.message,
          'message',
          '通知设置已改变，请重新读取后修改。',
        ),
      ),
    );
    expect(fixture.calls.where((c) => c['method'] == 'PUT'), hasLength(1));
  });

  test(
    'removed or replaced binding rejects requests and late results',
    () async {
      final fixture = NotificationFixture();
      await fixture.init();
      fixture.readGate = Completer<Map<String, dynamic>>();
      final reading = fixture.api.read(notificationHost, notificationEpoch);
      final checked = expectLater(reading, throwsA(isA<ProtocolException>()));
      await fixture.started.future;
      final record = (await fixture.hosts.read(notificationHost))!;
      await HostRegistry(fixture.storage).host(notificationHost).persist({
        ...record,
        'bindingEpoch': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
      });
      fixture.readGate!.complete(fixture.value);
      await checked;
      final before = fixture.calls.length;
      await expectLater(
        fixture.api.read(notificationHost, notificationEpoch),
        throwsA(isA<ProtocolException>()),
      );
      expect(fixture.calls, hasLength(before));
    },
  );

  test(
    'notification responses can contain all muted tasks without raising the route default',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final fixture = NotificationFixture();
      final response = {
        ...fixture.value,
        'mutedTasks': [
          for (var i = 0; i < 2048; i++)
            'task-${i.toString().padLeft(40, '0')}',
        ],
      };
      server.listen((request) async {
        expect(
          request.headers.value('authorization'),
          'Bearer fixture-route-token',
        );
        expect(
          request.uri.path,
          '/v1/hosts/notification-pc/notification-settings',
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(response));
        await request.response.close();
      });
      final storage = MemorySecretStorage();
      final origin = Uri.parse('http://127.0.0.1:${server.port}');
      final hosts = await notificationBinding(
        storage,
        service: origin.toString(),
      );
      expect(
        (await NotificationSettingsApi(
          hosts,
        ).read(notificationHost, notificationEpoch)).mutedTasks,
        hasLength(2048),
      );
      await expectLater(
        routeRequest(
          origin,
          '/v1/hosts/notification-pc/notification-settings',
          'fixture-route-token',
          method: 'GET',
        ),
        throwsA(isA<ProtocolException>()),
      );
    },
  );
}
