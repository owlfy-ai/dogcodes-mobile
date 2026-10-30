import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../core/notification_settings.dart';
import '../../ui/widgets.dart';
import '../../core/push_notifications.dart';

class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({
    super.key,
    required this.host,
    this.taskId,
    this.api,
  });
  final HostState host;
  final String? taskId;
  final NotificationSettingsApi? api;
  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _PushStatus extends StatelessWidget {
  const _PushStatus({required this.push});
  final PushNotifications? push;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final value = push;
    if (value == null) {
      return InlineNotice(tr("后台提醒暂未启用，静音设置可提前保存。仅影响这部手机，不影响电脑任务和 Agent 审批。"));
    }
    return ListenableBuilder(
      listenable: value,
      builder: (context, _) => Column(
        children: [
          InlineNotice(
            value.ready
                ? tr("通知通道已连接。提醒只影响这部手机，不会直接批准操作。")
                : value.configured
                ? tr("后台提醒暂未启用，可在这里授权系统通知。")
                : tr("此版本未配置后台提醒，静音设置可提前保存。"),
          ),
          if (value.error != null) InlineNotice(value.error!, danger: true),
          if (value.configured)
            TextButton.icon(
              onPressed: value.busy
                  ? null
                  : () => value.ready ? value.refresh() : value.enable(),
              icon: const Icon(Icons.notifications_outlined),
              label: Text(
                value.busy
                    ? tr("正在连接通知服务")
                    : value.enabled
                    ? tr("重新检测后台提醒")
                    : tr("启用后台提醒"),
              ),
            ),
        ],
      ),
    );
  }
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  late final epoch = widget.host.bindingEpoch;
  HostHub? hub;
  NotificationSettingsApi? api;
  NotificationSettings? settings;
  bool loading = false, saving = false, retired = false;
  String? error;
  bool get current => mounted && !retired;
  bool get ready => current && !loading && !saving && settings != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (hub != null) return;
    final scope = AppScope.of(context);
    hub = scope.hub..addListener(_bindingChanged);
    api = widget.api ?? scope.runtime?.notifications;
    _bindingChanged();
    if (!retired) _load();
  }

  void _bindingChanged() {
    if (retired) return;
    if (epoch == null ||
        widget.host.bindingEpoch != epoch ||
        !hub!.hosts.contains(widget.host)) {
      setState(() {
        retired = true;
        settings = null;
        loading = saving = false;
        error = tr("电脑绑定已改变，请返回设备列表。");
      });
    }
  }

  @override
  void dispose() {
    hub?.removeListener(_bindingChanged);
    super.dispose();
  }

  Future<void> _load() async {
    if (!current || loading || saving) return;
    if (api == null) {
      setState(() => error = tr("通知设置暂不可用。"));
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = await api!.read(widget.host.id, epoch!);
      if (current) setState(() => settings = value);
    } catch (e) {
      if (current) {
        setState(() {
          settings = null;
          error = '$e';
        });
      }
    } finally {
      if (current) setState(() => loading = false);
    }
  }

  Future<void> _save(NotificationSettings desired) async {
    if (!ready) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final value = await api!.save(widget.host.id, epoch!, desired);
      if (current) setState(() => settings = value);
    } catch (e) {
      // A preference is a desired value, not an effect to replay. Read the
      // authority after a lost response; never re-send the failed PUT.
      if (!current) return;
      try {
        final value = await api!.read(widget.host.id, epoch!);
        if (current) {
          setState(() {
            settings = value;
            error = value.samePreferences(desired) ? null : '$e';
          });
        }
      } catch (_) {
        if (current) {
          setState(() {
            settings = null;
            error = tr("保存结果未确认，请检查网络后重新读取。");
          });
        }
      }
    } finally {
      if (current) setState(() => saving = false);
    }
  }

  void _muteTask(String id, bool muted) {
    final value = settings;
    if (value == null) return;
    final tasks = {...value.mutedTasks};
    if (muted) {
      tasks.add(id);
    } else {
      tasks.remove(id);
    }
    _save(value.copyWith(mutedTasks: tasks));
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final value = settings, task = widget.taskId;
    return Scaffold(
      appBar: DetailBar(
        title: tr("通知设置"),
        subtitle: task == null
            ? widget.host.name
            : '${widget.host.task(task)?['title'] ?? tr("会话")} · ${widget.host.name}',
        actions: [
          IconButton(
            tooltip: tr("重新读取"),
            onPressed: retired || loading || saving ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        children: [
          if (loading || saving) const LinearProgressIndicator(),
          _PushStatus(push: AppScope.of(context).runtime?.push),
          if (error != null) InlineNotice(error!, danger: true),
          if (value != null) ...[
            if (task == null) ...[
              SwitchListTile(
                title: Text(tr("静音这台电脑")),
                value: value.muted,
                onChanged: ready
                    ? (enabled) => _save(value.copyWith(muted: enabled))
                    : null,
              ),
              SectionLabel(tr("提醒类型")),
              for (final kind in notificationKinds.entries)
                SwitchListTile(
                  title: Text(kind.value),
                  value: value.enabledKinds.contains(kind.key),
                  onChanged: ready
                      ? (enabled) {
                          final kinds = {...value.enabledKinds};
                          if (enabled) {
                            kinds.add(kind.key);
                          } else {
                            kinds.remove(kind.key);
                          }
                          _save(value.copyWith(enabledKinds: kinds));
                        }
                      : null,
                ),
              if (value.mutedTasks.isNotEmpty) ...[
                SectionLabel(tr("已静音会话")),
                for (final id in value.mutedTasks)
                  ListTile(
                    title: Text(
                      widget.host.task(id)?['title'] as String? ?? tr("未加载的会话"),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: tr("取消会话静音"),
                      onPressed: ready ? () => _muteTask(id, false) : null,
                      icon: const Icon(Icons.notifications_active_outlined),
                    ),
                  ),
              ],
            ] else ...[
              if (value.muted) InlineNotice(tr("这台电脑已静音，取消会话静音后仍不会收到提醒。")),
              SwitchListTile(
                title: Text(tr("静音此会话")),
                value: value.mutedTasks.contains(task),
                onChanged: ready ? (enabled) => _muteTask(task, enabled) : null,
              ),
            ],
          ],
        ],
      ),
    );
  }
}
