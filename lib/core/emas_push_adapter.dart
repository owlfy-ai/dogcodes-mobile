import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:io';
import 'package:aliyun_push/aliyun_push.dart';
import 'package:flutter/services.dart';
import 'protocol.dart';
import 'push_notifications.dart';

/// Android fallback only. Direct providers never initialize the EMAS SDK.
class EmasPushAdapter implements PushAdapter {
  final sdk = AliyunPush();
  static const _native = MethodChannel('dogcodes_push_permissions');
  bool _initialized = false;
  String get _key =>
      const String.fromEnvironment('DOGCODES_EMAS_ANDROID_APP_KEY');
  String get _secret =>
      const String.fromEnvironment('DOGCODES_EMAS_ANDROID_APP_SECRET');
  @override
  bool get configured =>
      Platform.isAndroid && _key.isNotEmpty && _secret.isNotEmpty;

  @override
  void listen(
    void Function(Map<dynamic, dynamic>) onOpen, {
    void Function()? onRegistrationChanged,
  }) {
    Future<void> ignore(Map<dynamic, dynamic> _) async {}
    Future<void> opened(Map<dynamic, dynamic> value) async {
      onOpen(value);
    }

    sdk.addMessageReceiver(
      onNotification: ignore,
      onMessage: ignore,
      onNotificationOpened: opened,
      onNotificationRemoved: ignore,
      onAndroidNotificationReceivedInApp: ignore,
      onAndroidNotificationClickedWithNoAction: opened,
      onIOSChannelOpened: ignore,
      onIOSRegisterDeviceTokenSuccess: ignore,
      onIOSRegisterDeviceTokenFailed: ignore,
    );
  }

  void _check(Map<dynamic, dynamic> value) {
    if (value['code'] != kAliyunPushSuccessCode) {
      throw ProtocolException(tr("通知服务初始化失败。"));
    }
  }

  @override
  Future<PushRegistration> register({required bool requestPermission}) async {
    if (!configured) throw ProtocolException(tr("此版本未配置备用通知服务。"));
    if (await _native.invokeMethod<bool>(
          requestPermission ? 'authorize' : 'allowed',
        ) !=
        true) {
      throw ProtocolException(tr("系统通知权限尚未开启。"));
    }
    if (!_initialized) {
      _check(
        await sdk
            .initPush(appKey: _key, appSecret: _secret)
            .timeout(const Duration(seconds: 30)),
      );
      await sdk.setLogLevel(AliyunPushLogLevel.none);
      _check(
        await sdk.createAndroidChannel(
          'dogcodes_tasks',
          tr("任务提醒"),
          3,
          tr("待审批、待回答、完成和失败提醒"),
        ),
      );
      // FCM/HMS tokens and message services belong to the direct providers.
      await _native.invokeMethod<void>('initEmasVendors');
      _initialized = true;
    }
    final device = await sdk.getDeviceId();
    if (device.isEmpty || device.length > 8192) {
      throw ProtocolException(tr("未获取到通知设备身份。"));
    }
    return PushRegistration('emas_android', device);
  }
}
