import 'package:dogcodes_app/l10n/strings.dart';
import 'pc_api.dart' show uuid;
import 'protocol.dart';
import 'secure_host_client.dart';
import 'security/identity_store.dart';

Map<String, String> get notificationKinds => {
  'approval': tr("待审批"),
  'question': tr("待回答"),
  'completed': tr("任务完成"),
  'failed': tr("执行失败"),
};

class NotificationSettings {
  NotificationSettings({
    required this.revision,
    required this.registered,
    required this.muted,
    this.providerId,
    required Set<String> mutedTasks,
    required Set<String> enabledKinds,
  }) : mutedTasks = Set.unmodifiable(mutedTasks),
       enabledKinds = Set.unmodifiable(enabledKinds);
  final String revision;
  final bool registered, muted;
  final String? providerId;
  final Set<String> mutedTasks, enabledKinds;

  factory NotificationSettings.parse(Map<String, dynamic> value) {
    try {
      final revision = value['revision'] as String;
      if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(revision)) {
        throw const FormatException();
      }
      final tasks = (value['mutedTasks'] as List).cast<String>().toSet();
      final kinds = (value['enabledKinds'] as List).cast<String>().toSet();
      if (tasks.length > 2048 ||
          kinds.any((k) => !notificationKinds.containsKey(k))) {
        throw const FormatException();
      }
      return NotificationSettings(
        revision: revision,
        registered: value['registered'] as bool,
        muted: value['muted'] as bool,
        providerId: value['providerId'] as String?,
        mutedTasks: tasks,
        enabledKinds: kinds,
      );
    } catch (_) {
      throw ProtocolException(tr("通知设置响应无效，请重新读取。"));
    }
  }

  NotificationSettings copyWith({
    bool? muted,
    Set<String>? mutedTasks,
    Set<String>? enabledKinds,
  }) => NotificationSettings(
    revision: revision,
    registered: registered,
    providerId: providerId,
    muted: muted ?? this.muted,
    mutedTasks: mutedTasks ?? this.mutedTasks,
    enabledKinds: enabledKinds ?? this.enabledKinds,
  );

  bool samePreferences(NotificationSettings other) =>
      muted == other.muted &&
      mutedTasks.length == other.mutedTasks.length &&
      mutedTasks.containsAll(other.mutedTasks) &&
      enabledKinds.length == other.enabledKinds.length &&
      enabledKinds.containsAll(other.enabledKinds);
}

typedef NotificationRequest =
    Future<Map<String, dynamic>> Function(
      Uri service,
      String path,
      String token,
      String method,
      Map<String, dynamic>? body,
    );

/// Notification preferences belong to this phone's saved binding. They use the
/// service directly, including when the PC is offline; no token enters the UI.
class NotificationSettingsApi {
  NotificationSettingsApi(this.hosts, {NotificationRequest? request})
    : _request = request ?? _send;
  final TrustedHostStore hosts;
  final NotificationRequest _request;
  static Future<Map<String, dynamic>> _send(
    Uri service,
    String path,
    String token,
    String method,
    Map<String, dynamic>? body,
  ) => routeRequest(
    service,
    path,
    token,
    method: method,
    body: body,
    // Server permits 2048 IDs of up to 128 bytes, including JSON escapes.
    maxResponseBytes: 2 * 1024 * 1024,
  );

  Future<NotificationSettings> read(String hostId, String epoch) =>
      _call(hostId, epoch, 'GET', null);

  Future<NotificationSettings> save(
    String hostId,
    String epoch,
    NotificationSettings desired,
  ) => _call(hostId, epoch, 'PUT', {
    'operationId': uuid(),
    'expectedRevision': desired.revision,
    'muted': desired.muted,
    'mutedTasks': desired.mutedTasks.toList()..sort(),
    'enabledKinds': desired.enabledKinds.toList()..sort(),
    // Omitted provider/token preserve the current push registration.
  });

  Future<NotificationSettings> register(
    String hostId,
    String epoch,
    NotificationSettings current, {
    required String providerId,
    required String deviceId,
  }) => _call(hostId, epoch, 'PUT', {
    'operationId': uuid(),
    'expectedRevision': current.revision,
    'providerId': providerId,
    'token': deviceId,
    'muted': current.muted,
    'mutedTasks': current.mutedTasks.toList()..sort(),
    'enabledKinds': current.enabledKinds.toList()..sort(),
  });

  Future<NotificationSettings> _call(
    String hostId,
    String epoch,
    String method,
    Map<String, dynamic>? body,
  ) async {
    final record = await hosts.read(hostId);
    if (record == null || record['bindingEpoch'] != epoch) {
      throw ProtocolException(tr("电脑绑定已改变，请返回设备列表。"));
    }
    Map<String, dynamic> response;
    try {
      response = await _request(
        Uri.parse(record['service'] as String),
        '/v1/hosts/${Uri.encodeComponent(hostId)}/notification-settings',
        record['routeToken'] as String,
        method,
        body,
      );
    } on RouteRequestRejected catch (e) {
      throw ProtocolException(switch (e.statusCode) {
        401 || 403 => tr("设备授权已失效，请核实电脑绑定。"),
        409 => tr("通知设置已改变，请重新读取后修改。"),
        429 => tr("操作过于频繁，请稍后重试。"),
        _ => tr("通知服务暂时不可用，请稍后重试。"),
      });
    } on ProtocolException {
      rethrow;
    } catch (_) {
      throw ProtocolException(tr("无法确认通知设置，请检查网络后重新读取。"));
    }
    final current = await hosts.read(hostId);
    if (current == null || current['bindingEpoch'] != epoch) {
      throw ProtocolException(tr("电脑绑定已改变，请返回设备列表。"));
    }
    return NotificationSettings.parse(response);
  }
}
