part of 'mobile_operations.dart';

/// Keep awake is a single on/off value and setting it twice is harmless, so a
/// lost reply is settled by reading the value back; nothing is tracked.
extension PowerWrites on MobileOperations {
  Future<Map<String, dynamic>> setKeepAwake(
    HostApi client,
    bool enabled,
  ) async {
    try {
      return _keepAwakePolicy(
        await _write(client, 'power_preferences_set', {'enabled': enabled}),
      );
    } on ProtocolException {
      rethrow;
    } catch (_) {
      final now = _keepAwakePolicy(
        await client.call('power_preferences', null),
      );
      if (now['enabled'] == enabled) return now;
      throw ProtocolException(tr("电脑没有收到这次设置，请再试一次。"));
    }
  }

  Map<String, dynamic> _keepAwakePolicy(dynamic value) {
    if (value is! Map || value['enabled'] is! bool) {
      throw ProtocolException(tr("电脑返回的保持唤醒状态无效。"));
    }
    return Map<String, dynamic>.from(value);
  }
}
