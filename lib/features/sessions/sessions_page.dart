import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../ui/theme.dart';
import '../../ui/scope_picker.dart';
import '../../ui/widgets.dart';
import '../conversation/conversation_page.dart';
import '../conversation/new_session_page.dart';
import 'history_search_page.dart';
import 'session_menu.dart';

/// 01 会话: cross-computer sessions, search, filter, create and resume.
class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key});
  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  final search = TextEditingController();
  bool archived = false;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context).hub;
    return ListenableBuilder(
      listenable: Listenable.merge([hub, search, hub.sessionScope]),
      builder: (context, _) {
        var (hostFilter, projectFilter) = hub.sessionScope.value;
        if (hostFilter != null && hub.host(hostFilter) == null) {
          hostFilter = projectFilter = null;
        }
        // With one computer the computer level is implicit.
        final effectiveHost =
            hostFilter ?? (hub.hosts.length == 1 ? hub.hosts.first.id : null);
        if (projectFilter != null &&
            hub.host(effectiveHost ?? '')?.project(projectFilter) == null) {
          projectFilter = null;
        }
        final query = search.text.trim().toLowerCase();
        final scope = hub.sessions.where((s) {
          if (effectiveHost != null && s.host.id != effectiveHost) return false;
          if (projectFilter != null && s.projectId != projectFilter) {
            return false;
          }
          return true;
        }).toList();
        final sessions = scope.where((s) {
          if (s.archived != archived) return false;
          if (query.isEmpty) return true;
          return s.title.toLowerCase().contains(query) ||
              s.projectName.toLowerCase().contains(query);
        }).toList();
        final canCreate = hub.hosts.any((h) => h.online);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RootHeader(
              title: '会话',
              actions: [
                IconButton(
                  tooltip: '搜索历史正文',
                  icon: const Icon(Icons.manage_search),
                  onPressed: scope.isEmpty
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => HistorySearchPage(
                              sessions: scope,
                              initialQuery: search.text,
                            ),
                          ),
                        ),
                ),
                IconButton.filled(
                  style: accentIconButton(context),
                  tooltip: '新会话',
                  onPressed: canCreate
                      ? () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => NewSessionPage(
                              hostId: effectiveHost,
                              projectId: projectFilter,
                            ),
                          ),
                        )
                      : null,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            if (hub.hosts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  DcSpace.page,
                  0,
                  DcSpace.page,
                  10,
                ),
                child: ScopePicker(
                  hosts: hub.hosts,
                  hostId: effectiveHost,
                  projectId: projectFilter,
                  allowAll: true,
                  onChanged: (h, p) => hub.sessionScope.value = (h, p),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DcSpace.page),
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('当前会话'),
                    selected: !archived,
                    onSelected: (_) => setState(() => archived = false),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('已归档'),
                    selected: archived,
                    onSelected: (_) => setState(() => archived = true),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _body(
                context,
                hub,
                sessions,
                query,
                showHost: effectiveHost == null,
                showProject: projectFilter == null,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    HostHub hub,
    List<SessionRef> sessions,
    String query, {
    required bool showHost,
    required bool showProject,
  }) {
    if (hub.loaded && hub.hosts.isEmpty) {
      return EmptyNote(
        icon: Icons.forum_outlined,
        title: '会话将从电脑同步',
        body: '连接自己的电脑后，在这里查看和续接各项目的会话。网络中断时，电脑上的任务会继续执行。',
        action: OutlinedButton(
          onPressed: () => HomeShell.select(context, 3),
          child: const Text('去连接电脑'),
        ),
      );
    }
    final pending = hub.pendingCount;
    final offline = hub.hosts.where((h) => !h.online).toList();
    final small = Theme.of(context).textTheme.bodySmall;
    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: DcSpace.page),
        child: TextField(
          controller: search,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: '搜索会话',
            prefixIcon: Icon(Icons.search),
          ),
        ),
      ),
      if (pending > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(DcSpace.page, 12, DcSpace.page, 0),
          child: Panel(
            onTap: () => HomeShell.select(context, 2),
            child: Row(
              children: [
                const Icon(Icons.schedule, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text('$pending 项等待处理')),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      for (final h in offline)
        InlineNotice(
          h.status == LinkStatus.connecting
              ? '${h.name} 连接中…'
              : h.syncedAt == null
              ? '${h.name} 离线'
              : '${h.name} 离线 · 显示 ${shortTime(h.syncedAt)} 同步的内容',
        ),
    ];
    if (sessions.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.all(40),
          child: Text(
            query.isNotEmpty
                ? '没有匹配的会话'
                : hub.hosts.any((h) => h.snapshot != null)
                ? archived
                      ? '暂无已归档会话'
                      : '还没有会话，点右上角 + 开始新任务'
                : '正在从电脑同步会话…',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.dc.secondary),
          ),
        ),
      );
    } else {
      final pinned = sessions.where((s) => s.pinned).toList();
      if (pinned.isNotEmpty) {
        children.add(const SectionLabel('置顶'));
        children.addAll(pinned.map((s) => SessionRow(session: s)));
      }
      // Day → computer → project; each level ordered by its newest session.
      final days = <String, List<SessionRef>>{};
      for (final s in sessions) {
        if (s.pinned) continue;
        days.putIfAbsent(dayGroup(s.updatedAt), () => []).add(s);
      }
      for (final day in days.entries) {
        children.add(SectionLabel(day.key));
        final byHost = <HostState, List<SessionRef>>{};
        for (final s in day.value) {
          byHost.putIfAbsent(s.host, () => []).add(s);
        }
        for (final host in byHost.entries) {
          if (showHost) {
            children.add(
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  DcSpace.page,
                  4,
                  DcSpace.page,
                  2,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.computer_outlined,
                      size: 15,
                      color: context.dc.secondary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      host.key.name,
                      style: small?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            );
          }
          final byProject = <String, List<SessionRef>>{};
          for (final s in host.value) {
            byProject.putIfAbsent(s.projectId, () => []).add(s);
          }
          for (final project in byProject.values) {
            if (showProject) {
              children.add(
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    DcSpace.page + (showHost ? 21 : 0),
                    2,
                    DcSpace.page,
                    2,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.folder_outlined,
                        size: 14,
                        color: context.dc.secondary,
                      ),
                      const SizedBox(width: 6),
                      Text(project.first.projectName, style: small),
                    ],
                  ),
                ),
              );
            }
            for (final s in project) {
              children.add(SessionRow(session: s));
            }
          }
        }
      }
    }
    return RefreshIndicator(
      onRefresh: () => Future.wait([
        for (final h in hub.hosts) h.online ? hub.refresh(h) : hub.connect(h),
      ]),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: children,
      ),
    );
  }
}

class SessionRow extends StatelessWidget {
  const SessionRow({super.key, required this.session});
  final SessionRef session;
  @override
  Widget build(BuildContext context) {
    final s = session;
    final status = s.needsAttention
        ? const StatusLabel('待处理', tone: Tone.warning)
        : s.running
        ? const StatusLabel('进行中', tone: Tone.accent)
        : const StatusLabel('空闲');
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ConversationPage(hostId: s.host.id, taskId: s.taskId),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: DcSpace.page,
          vertical: 10,
        ),
        child: Row(
          children: [
            AgentGlyph(providerId: s.providerId),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    s.agent,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  shortTime(s.updatedAt),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                status,
              ],
            ),
            SessionMenu(session: s),
          ],
        ),
      ),
    );
  }
}
