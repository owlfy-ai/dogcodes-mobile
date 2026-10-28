import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../core/mobile_operations.dart';
import '../tools/tool_context.dart' show showError;
import 'history_search_page.dart';
import '../settings/notification_settings_page.dart';

/// A session is pinned or archived, never both: an archived one is unarchived
/// before it can be pinned, and archiving a pinned one says it unpins it.
List<PopupMenuEntry<String>> sessionMenuItems(
  SessionRef s, {
  bool notifications = false,
}) => [
  if (!s.archived)
    PopupMenuItem(
      value: 'pin',
      enabled: s.host.online,
      child: Text(s.pinned ? '取消置顶' : '置顶会话'),
    ),
  PopupMenuItem(
    value: 'archive',
    enabled: s.host.online,
    child: Text(
      s.archived
          ? '取消归档'
          : s.pinned
          ? '归档会话（将取消置顶）'
          : '归档会话',
    ),
  ),
  PopupMenuItem(
    value: 'history',
    enabled: s.host.online,
    child: const Text('搜索历史正文'),
  ),
  if (notifications)
    const PopupMenuItem(value: 'notifications', child: Text('通知设置')),
];

Future<void> sessionAction(
  BuildContext context,
  SessionRef s,
  String action,
) async {
  if (action == 'notifications') {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            NotificationSettingsPage(host: s.host, taskId: s.taskId),
      ),
    );
    return;
  }
  if (action == 'history') {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => HistorySearchPage(sessions: [s])),
    );
    return;
  }
  final hub = AppScope.of(context).hub, h = s.host, link = s.host.link;
  if (!h.online || link == null) return;
  try {
    await h.operations.setHistoryState(link, s.taskId, switch (action) {
      'pin' => s.pinned ? null : 'pinned',
      'archive' => s.archived ? null : 'archived',
      _ => throw ArgumentError.value(action),
    });
  } catch (e) {
    if (context.mounted) showError(context, e);
  } finally {
    await hub.refresh(h);
  }
}

class SessionMenu extends StatefulWidget {
  const SessionMenu({super.key, required this.session});
  final SessionRef session;
  @override
  State<SessionMenu> createState() => _SessionMenuState();
}

class _SessionMenuState extends State<SessionMenu> {
  bool busy = false;
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: '会话操作',
    enabled:
        !busy &&
        (widget.session.host.online || AppScope.of(context).runtime != null),
    icon: const Icon(Icons.more_horiz, size: 20),
    itemBuilder: (_) => sessionMenuItems(
      widget.session,
      notifications: AppScope.of(context).runtime != null,
    ),
    onSelected: (action) async {
      setState(() => busy = true);
      await sessionAction(context, widget.session, action);
      if (mounted) setState(() => busy = false);
    },
  );
}
