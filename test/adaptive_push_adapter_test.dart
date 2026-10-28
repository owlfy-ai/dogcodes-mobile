import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/adaptive_push_adapter.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'push_notifications_test.dart' show FakePushAdapter;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test_adaptive_push');
  final calls = <String>[];
  var capabilities = <String, dynamic>{};
  var permission = true;
  final failing = <String>{};
  final tokens = {
    'apns': 'apple-token',
    'fcm': 'google-token',
    'hms': 'huawei-token',
  };
  setUp(() {
    calls.clear();
    failing.clear();
    capabilities = {};
    permission = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'capabilities') return capabilities;
          if (call.method == 'allowed' || call.method == 'authorize') {
            return permission;
          }
          if (call.method == 'initialNotification') return null;
          if (failing.contains(call.method)) {
            throw PlatformException(code: 'unavailable');
          }
          return tokens[call.method.replaceFirst('register_', '')];
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('iOS uses direct APNs and never registers EMAS', () async {
    final fallback = FakePushAdapter();
    final adapter = AdaptivePushAdapter(
      fallback: fallback,
      channel: channel,
      isIOS: true,
    );
    adapter.listen((_) {});
    final result = await adapter.register(requestPermission: true);
    expect(result.providerId, 'apns');
    expect(result.token, 'apple-token');
    expect(fallback.permissions, isEmpty);
    expect(calls.where((c) => c.startsWith('register_')), ['register_apns']);
    expect(fallback.opened, isNull);
  });
  test(
    'FCM capable Android registers directly without touching EMAS',
    () async {
      capabilities = {'fcm': true, 'hms': false};
      final fallback = FakePushAdapter()..configured = false;
      final adapter = AdaptivePushAdapter(
        fallback: fallback,
        channel: channel,
        isIOS: false,
      );
      final ready = Completer<void>();
      adapter.listen(
        (_) {},
        onRegistrationChanged: () {
          if (!ready.isCompleted) ready.complete();
        },
      );
      await ready.future;
      expect(adapter.configured, isTrue);
      final result = await adapter.register(requestPermission: true);
      expect(result.providerId, 'fcm');
      expect(result.token, 'google-token');
      expect(fallback.permissions, isEmpty);
    },
  );
  test(
    'Huawei prioritizes HMS and does not register FCM or EMAS on success',
    () async {
      capabilities = {'fcm': true, 'hms': true};
      final fallback = FakePushAdapter();
      final adapter = AdaptivePushAdapter(
        fallback: fallback,
        channel: channel,
        isIOS: false,
      );
      final result = await adapter.register(requestPermission: false);
      expect(result.providerId, 'hms');
      expect(calls.where((c) => c.startsWith('register_')), ['register_hms']);
      expect(fallback.permissions, isEmpty);
    },
  );
  test(
    'registration failure tries the next provider, then EMAS once',
    () async {
      capabilities = {'fcm': true, 'hms': true};
      failing.addAll(['register_hms', 'register_fcm']);
      final fallback = FakePushAdapter()..providerId = 'emas_android';
      final adapter = AdaptivePushAdapter(
        fallback: fallback,
        channel: channel,
        isIOS: false,
      );
      final result = await adapter.register(requestPermission: true);
      expect(result.providerId, 'emas_android');
      expect(calls.where((c) => c.startsWith('register_')), [
        'register_hms',
        'register_fcm',
      ]);
      expect(fallback.permissions, [false]);
    },
  );
  test('no Google/HMS capability goes directly to EMAS', () async {
    capabilities = {'fcm': false, 'hms': false};
    final fallback = FakePushAdapter()..providerId = 'emas_android';
    final adapter = AdaptivePushAdapter(
      fallback: fallback,
      channel: channel,
      isIOS: false,
    );
    expect(
      (await adapter.register(requestPermission: true)).providerId,
      'emas_android',
    );
    expect(calls.where((c) => c.startsWith('register_')), isEmpty);
  });
  test(
    'denied notification permission never falls through to another SDK',
    () async {
      capabilities = {'fcm': true};
      permission = false;
      final fallback = FakePushAdapter();
      final adapter = AdaptivePushAdapter(
        fallback: fallback,
        channel: channel,
        isIOS: false,
      );
      await expectLater(
        adapter.register(requestPermission: true),
        throwsA(isA<ProtocolException>()),
      );
      expect(calls.where((c) => c.startsWith('register_')), isEmpty);
      expect(fallback.permissions, isEmpty);
    },
  );
  test('APNs failure cannot use EMAS fallback', () async {
    failing.add('register_apns');
    final fallback = FakePushAdapter();
    final adapter = AdaptivePushAdapter(
      fallback: fallback,
      channel: channel,
      isIOS: true,
    );
    await expectLater(
      adapter.register(requestPermission: false),
      throwsA(isA<ProtocolException>()),
    );
    expect(fallback.permissions, isEmpty);
  });
  test(
    'refresh rechecks Google service availability before selecting a route',
    () async {
      capabilities = {'fcm': true};
      final fallback = FakePushAdapter()..providerId = 'emas_android';
      final adapter = AdaptivePushAdapter(
        fallback: fallback,
        channel: channel,
        isIOS: false,
      );
      expect(
        (await adapter.register(requestPermission: true)).providerId,
        'fcm',
      );
      capabilities = {'fcm': false};
      expect(
        (await adapter.register(requestPermission: false)).providerId,
        'emas_android',
      );
      expect(calls.where((c) => c == 'register_fcm'), hasLength(1));
      expect(fallback.permissions, [false]);
    },
  );
}
