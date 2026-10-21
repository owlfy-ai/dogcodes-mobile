import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../core/mobile_operations.dart';
import '../tools/tool_context.dart' show showError;
import 'fork_page.dart';
import 'history_search_page.dart';

List<PopupMenuEntry<String>> sessionMenuItems(SessionRef s) => [
  PopupMenuItem(value: 'pin', child: Text(s.pinned ? '取消置顶' : '置顶会话')),
  PopupMenuItem(value: 'archive', child: Text(s.archived ? '取消归档' : '归档会话')),
  PopupMenuItem(
    value: 'fork',
    enabled: !s.running,
    child: const Text('Fork 会话'),
  ),
  const PopupMenuItem(value: 'history', child: Text('搜索历史正文')),
];

Future<void> sessionAction(
  BuildContext context,
  SessionRef s,
  String action,
) async {
  if (action == 'history') {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => HistorySearchPage(sessions: [s])),
    );
    return;
  }
  if (action == 'fork') {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => ForkPage(session: s)));
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
    enabled: widget.session.host.online && !busy,
    icon: const Icon(Icons.more_horiz, size: 20),
    itemBuilder: (_) => sessionMenuItems(widget.session),
    onSelected: (action) async {
      setState(() => busy = true);
      await sessionAction(context, widget.session, action);
      if (mounted) setState(() => busy = false);
    },
  );
}
