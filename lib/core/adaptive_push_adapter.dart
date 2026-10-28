import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'emas_push_adapter.dart';
import 'protocol.dart';
import 'push_notifications.dart';

class AdaptivePushAdapter implements PushAdapter {
  AdaptivePushAdapter({
    PushAdapter? fallback,
    MethodChannel? channel,
    bool? isIOS,
  }) : _fallback = fallback ?? EmasPushAdapter(),
       _channel = channel ?? const MethodChannel('dogcodes_push_permissions'),
       _isIOS = isIOS ?? Platform.isIOS;
  final PushAdapter _fallback;
  final MethodChannel _channel;
  final bool _isIOS;
  Map<String, dynamic> _capabilities = {};
  Future<void>? _loading;
  @override
  bool get configured =>
      _isIOS ||
      _capabilities['configured'] == true ||
      _capabilities['fcm'] == true ||
      _capabilities['hms'] == true ||
      _fallback.configured;

  Future<void> _load() => _loading ??= () async {
    try {
      _capabilities =
          await _channel
              .invokeMapMethod<String, dynamic>('capabilities')
              .timeout(const Duration(seconds: 3)) ??
          {};
    } catch (_) {
      _capabilities = {};
    }
  }();

  @override
  void listen(
    void Function(Map<dynamic, dynamic>) onOpen, {
    void Function()? onRegistrationChanged,
  }) {
    if (!_isIOS) _fallback.listen(onOpen);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'opened' && call.arguments is Map) {
        onOpen(call.arguments as Map);
      }
      if (call.method == 'registrationChanged') onRegistrationChanged?.call();
    });
    unawaited(_load().then((_) => onRegistrationChanged?.call()));
    unawaited(
      _channel
          .invokeMapMethod<dynamic, dynamic>('initialNotification')
          .then<void>((value) {
            if (value != null) onOpen(value);
          }, onError: (Object _) {}),
    );
  }

  @override
  Future<PushRegistration> register({required bool requestPermission}) async {
    _loading = null;
    await _load();
    if (await _channel.invokeMethod<bool>(
          requestPermission ? 'authorize' : 'allowed',
        ) !=
        true) {
      throw const ProtocolException('系统通知权限尚未开启。');
    }
    // Huawei with HMS is the explicit exception to the FCM-first preference.
    final providers = _isIOS
        ? ['apns']
        : [
            if (_capabilities['hms'] == true) 'hms',
            if (_capabilities['fcm'] == true) 'fcm',
          ];
    for (final provider in providers) {
      try {
        final token = await _channel
            .invokeMethod<String>('register_$provider')
            .timeout(const Duration(seconds: 25));
        if (token != null && token.isNotEmpty && token.length <= 8192) {
          return PushRegistration(provider, token);
        }
      } on PlatformException {
        continue;
      } on TimeoutException {
        continue;
      }
    }
    if (!_isIOS && _fallback.configured) {
      return _fallback.register(requestPermission: false);
    }
    throw const ProtocolException('暂时无法连接可用的通知服务，请稍后重试。');
  }
}
