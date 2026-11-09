import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../ui/theme.dart';
import '../../ui/scope_picker.dart';
import '../../ui/widgets.dart';
import '../conversation/conversation_page.dart';
import '../conversation/new_session_page.dart';
import 'fork_tree.dart';
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
  bool showArchived = false;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
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
        final byTask = {
          for (final s in hub.sessions) '${s.host.id}/${s.taskId}': s,
        };
        final scope = hub.sessions.where((s) {
          if (s.hiddenByRemovedProject) return false;
          if (effectiveHost != null && s.host.id != effectiveHost) return false;
          // A worktree fork has its own project but belongs with its source.
          if (projectFilter != null &&
              _sourceProject(s, byTask) != projectFilter) {
            return false;
          }
          return true;
        }).toList();
        final sessions = scope.where((s) {
          if (query.isEmpty) return true;
          return s.title.toLowerCase().contains(query) ||
              s.projectName.toLowerCase().contains(query);
        }).toList();
        final canCreate = hub.hosts.any(
          (h) => h.online || h.projects.isNotEmpty,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RootHeader(
              title: tr("会话"),
              actions: [
                IconButton(
                  tooltip: tr("搜索历史正文"),
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
                  tooltip: tr("新会话"),
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

  static String _sourceProject(SessionRef s, Map<String, SessionRef> byTask) {
    var current = s;
    final seen = {s.taskId};
    for (var next = s.forkedFrom; next != null; next = current.forkedFrom) {
      final source = byTask['${s.host.id}/$next'];
      if (source == null || !seen.add(source.taskId)) break;
      current = source;
    }
    return current.projectId;
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
        title: tr("会话将从电脑同步"),
        body: tr("连接自己的电脑后，在这里查看和续接各项目的会话。网络中断时，电脑上的任务会继续执行。"),
        action: OutlinedButton(
          onPressed: () => HomeShell.select(context, 3),
          child: Text(tr("去连接电脑")),
        ),
      );
    }
    final pending = hub.pendingCount;
    final offline = hub.hosts.where((h) => !h.online).toList();
    final small = Theme.of(context).textTheme.bodySmall;
    // Archived sessions leave the main list but stay reachable: collapsed at
    // the bottom, and still matched by search (where their row says 已归档).
    final archived = query.isEmpty
        ? sessions.where((s) => s.archived).toList()
        : <SessionRef>[];
    final listed = query.isEmpty
        ? sessions.where((s) => !s.archived).toList()
        : sessions;
    // Forks follow their source session instead of standing on their own.
    final forks = ForkTree(sessions);
    Iterable<Widget> rows(Iterable<SessionRef> top) => [
      for (final s in top)
        if (!forks.isNested(s))
          for (final (row, depth) in forks.branch(s))
            SessionRow(session: row, depth: depth),
    ];
    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: DcSpace.page),
        child: TextField(
          controller: search,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: tr("搜索会话"),
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
                Expanded(child: Text(tr("{0} 项等待处理", [pending]))),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      for (final h in offline)
        InlineNotice(
          h.status == LinkStatus.connecting
              ? tr("{0} 连接中…", [h.name])
              : h.syncedAt == null
              ? tr("{0} 离线", [h.name])
              : tr("{0} 离线 · 显示 {1} 同步的内容", [h.name, shortTime(h.syncedAt)]),
        ),
    ];
    if (listed.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.all(40),
          child: Text(
            query.isNotEmpty
                ? tr("没有匹配的会话")
                : archived.isNotEmpty
                ? tr("没有未归档的会话")
                : hub.hosts.any((h) => h.snapshot != null)
                ? tr("还没有会话，点右上角 + 开始新任务")
                : tr("正在从电脑同步会话…"),
            textAlign: TextAlign.center,
            style: TextStyle(color: context.dc.secondary),
          ),
        ),
      );
    } else {
      final pinned = listed.where((s) => s.pinned).toList();
      if (pinned.isNotEmpty) {
        children.add(SectionLabel(tr("置顶")));
        children.addAll(rows(pinned));
      }
      // Day → computer → project; each level ordered by its newest session.
      final days = <String, List<SessionRef>>{};
      for (final s in listed) {
        if (s.pinned || forks.isNested(s)) continue;
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
            children.addAll(rows(project));
          }
        }
      }
    }
    if (archived.isNotEmpty) {
      children.add(
        ListTile(
          key: const ValueKey('archived-sessions'),
          contentPadding: const EdgeInsets.symmetric(horizontal: DcSpace.page),
          leading: const Icon(Icons.archive_outlined, size: 20),
          title: Text(tr("已归档 ({0})", [archived.length])),
          trailing: Icon(showArchived ? Icons.expand_less : Icons.expand_more),
          onTap: () => setState(() => showArchived = !showArchived),
        ),
      );
      if (showArchived) {
        children.addAll(rows(archived));
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
  const SessionRow({super.key, required this.session, this.depth = 0});
  final SessionRef session;

  /// How many forks deep this row sits under the session it came from.
  final int depth;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final s = session;
    final status = s.needsAttention
        ? StatusLabel(tr("待处理"), tone: Tone.warning)
        : s.running
        ? StatusLabel(tr("进行中"), tone: Tone.accent)
        : StatusLabel(tr("空闲"));
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ConversationPage(hostId: s.host.id, taskId: s.taskId),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          DcSpace.page + (depth > 0 ? 12.0 + 22 * (depth - 1) : 0),
          10,
          DcSpace.page,
          10,
        ),
        child: Row(
          children: [
            if (depth > 0) ...[
              Icon(
                Icons.subdirectory_arrow_right,
                size: 18,
                color: context.dc.secondary,
              ),
              const SizedBox(width: 6),
            ],
            AgentGlyph(providerId: s.providerId),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    depth > 0
                        ? s.title.replaceFirst(RegExp(r' · Fork$'), '')
                        : s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    depth > 0 ? tr("分叉 · {0}", [s.agent]) : s.agent,
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
                if (s.archived)
                  Text(tr("已归档"), style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            SessionMenu(session: s),
          ],
        ),
      ),
    );
  }
}
