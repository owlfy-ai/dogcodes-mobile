import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'host_hub.dart';
import 'notification_settings.dart';
import 'security/identity_store.dart';

abstract interface class PushAdapter {
  bool get configured;
  void listen(
    void Function(Map<dynamic, dynamic>) onOpen, {
    void Function()? onRegistrationChanged,
  });
  Future<PushRegistration> register({required bool requestPermission});
}

class PushRegistration {
  const PushRegistration(this.providerId, this.token);
  final String providerId, token;
}

class NotificationOpen {
  const NotificationOpen(this.id, this.hostId, this.taskId);
  final String id, hostId, taskId;
  static NotificationOpen? parse(Map<dynamic, dynamic> message) {
    try {
      final extra =
          message['dogcodes'] ?? message['extraMap'] ?? message['extMap'];
      final data = extra is String
          ? jsonDecode(extra) as Map
          : extra is Map
          ? extra
          : message;
      bool valid(dynamic v) =>
          v is String &&
          v.isNotEmpty &&
          v.length <= 128 &&
          !RegExp(r'[\x00-\x1f]').hasMatch(v);
      if (!valid(data['notificationId']) ||
          !valid(data['hostId']) ||
          !valid(data['taskId']) ||
          !notificationKinds.containsKey(data['kind'])) {
        return null;
      }
      return NotificationOpen(
        data['notificationId'],
        data['hostId'],
        data['taskId'],
      );
    } catch (_) {
      return null;
    }
  }
}

/// One phone registration, shared by its paired PCs. Preferences remain on the
/// service; refresh never resets mute state or enables a previously disabled kind.
class PushNotifications extends ChangeNotifier {
  PushNotifications(this.storage, this.hosts, this.settings, this.adapter);
  final SecretStorage storage;
  final TrustedHostStore hosts;
  final NotificationSettingsApi settings;
  final PushAdapter adapter;
  HostHub? _hub;
  bool enabled = false, ready = false, _disposed = false;
  bool _restored = false;
  String? error;
  bool get configured => adapter.configured;
  bool get busy => _working != null || !_restored;
  Future<void>? _working;
  String _inventory = '';
  bool _again = false;
  final _registered = <String, String>{};
  final _seen = <String>{};
  NotificationOpen? _pending;
  bool get hasPendingOpen => _pending != null;
  NotificationOpen? takeOpen() {
    final value = _pending;
    _pending = null;
    return value;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize(HostHub hub) async {
    _hub = hub;
    adapter.listen(
      (message) {
        if (_disposed) return;
        final value = NotificationOpen.parse(message);
        if (value == null || !_seen.add(value.id)) return;
        while (_seen.length > 128) {
          _seen.remove(_seen.first);
        }
        _pending = value;
        _notify();
      },
      onRegistrationChanged: () {
        if (_disposed) return;
        _notify();
        if (enabled && configured) unawaited(refresh());
      },
    );
    hub.addListener(_bindingsChanged);
    try {
      enabled = await storage.read('dogcodes.push.enabled.v1') == 'true';
      _restored = true;
      if (!_disposed && enabled && configured) await refresh();
    } catch (_) {
      _restored = true;
      error = tr("无法读取后台提醒设置，请检查系统安全存储后重试。");
    }
    _notify();
  }

  void _bindingsChanged() {
    final inventory = jsonEncode([
      for (final h in _hub!.hosts) [h.id, h.bindingEpoch],
    ]);
    if (inventory == _inventory) return;
    _inventory = inventory;
    if (enabled && configured) unawaited(refresh());
  }

  Future<void> enable() => _run(true);
  Future<void> refresh() => enabled ? _run(false) : Future.value();
  Future<void> _run(bool requestPermission) {
    if (_disposed || !configured) return Future.value();
    if (_working != null) {
      _again = true;
      return _working!;
    }
    final work = _register(requestPermission);
    _working = work;
    _notify();
    return work.whenComplete(() {
      _working = null;
      _notify();
      if (_again && !_disposed) {
        _again = false;
        unawaited(refresh());
      }
    });
  }

  Future<void> _register(bool requestPermission) async {
    error = null;
    try {
      final registration = await adapter.register(
        requestPermission: requestPermission,
      );
      final deviceId = registration.token, providerId = registration.providerId;
      if (_disposed) return;
      await storage.write('dogcodes.push.enabled.v1', 'true');
      enabled = ready = true;
      var failed = false;
      final records = await hosts.list();
      final keys = <String>{};
      for (final record in records) {
        if (_disposed) return;
        final id = record['hostId'] as String,
            epoch = record['bindingEpoch'] as String;
        final key = jsonEncode([id, epoch]);
        keys.add(key);
        try {
          final current = await settings.read(id, epoch);
          if (_disposed) return;
          if (_registered[key] == deviceId &&
              current.registered &&
              current.providerId == providerId) {
            continue;
          }
          final result = await settings.register(
            id,
            epoch,
            current,
            providerId: providerId,
            deviceId: deviceId,
          );
          if (_disposed) return;
          if (result.registered && result.providerId == providerId) {
            _registered[key] = deviceId;
          } else {
            failed = true;
          }
        } catch (_) {
          failed = true;
        }
      }
      _registered.removeWhere((key, _) => !keys.contains(key));
      if (failed) error = tr("部分电脑的通知尚未登记，请检查网络后重新检测。");
    } catch (_) {
      ready = false;
      error = tr("后台提醒尚未启用，请核实系统通知权限和通知服务配置后重试。");
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _hub?.removeListener(_bindingsChanged);
    super.dispose();
  }
}
