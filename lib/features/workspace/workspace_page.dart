import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../ui/theme.dart';
import '../../ui/scope_picker.dart';
import '../../ui/widgets.dart';
import '../conversation/new_session_page.dart';
import '../sessions/sessions_page.dart';
import '../../core/pc_api.dart';
import '../tools/changes_page.dart';
import '../tools/files_page.dart';
import '../tools/run_page.dart';
import '../tools/terminal_page.dart';
import '../tools/tool_context.dart';

/// 05 工作区: always bound to one PC and one of its projects.
class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key});
  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  String? hostId, projectId;

  /// Keeps the chosen computer and project; falls back only when they
  /// disappear (unpaired / project removed), never on page switches.
  (HostState, Map<String, dynamic>?)? _resolve(HostHub hub) {
    var h = hostId == null ? null : hub.host(hostId!);
    if (h == null) {
      h =
          hub.hosts.where((x) => x.projects.isNotEmpty).firstOrNull ??
          hub.hosts.firstOrNull;
      if (h == null) return null;
      hostId = h.id;
      projectId = null;
    }
    final project = h.project(projectId) ?? h.projects.firstOrNull;
    projectId = project?['projectId'] as String?;
    return (h, project);
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context).hub;
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final selected = _resolve(hub);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const RootHeader(title: '工作区'),
            Expanded(
              child: selected == null
                  ? EmptyNote(
                      icon: Icons.folder_open_outlined,
                      title: '还没有连接电脑',
                      body: '连接电脑后，在这里查看项目及其会话。',
                      action: OutlinedButton(
                        onPressed: () => HomeShell.select(context, 3),
                        child: const Text('去连接电脑'),
                      ),
                    )
                  : _content(context, hub, selected.$1, selected.$2),
            ),
          ],
        );
      },
    );
  }

  Widget _content(
    BuildContext context,
    HostHub hub,
    HostState h,
    Map<String, dynamic>? project,
  ) {
    final picker = Padding(
      padding: const EdgeInsets.symmetric(horizontal: DcSpace.page),
      child: ScopePicker(
        hosts: hub.hosts,
        hostId: h.id,
        projectId: projectId,
        onChanged: (host, p) => setState(() {
          hostId = host;
          projectId = p;
        }),
      ),
    );
    if (project == null) {
      return ListView(
        children: [
          picker,
          const SizedBox(height: 24),
          InlineNotice(
            h.snapshot == null
                ? '${h.name} 尚未同步项目；电脑在线时会自动同步。'
                : '${h.name} 上还没有项目。请先在电脑上添加项目目录。',
          ),
        ],
      );
    }
    final tool = ToolContext(h, project);
    final sessions = hub.sessions
        .where((s) => s.host == h && s.projectId == projectId)
        .take(5)
        .toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        picker,
        Padding(
          padding: const EdgeInsets.fromLTRB(DcSpace.page, 6, DcSpace.page, 0),
          child: Text(
            project['path'] as String? ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DcSpace.page - 4),
          child: Row(
            children: [
              _Tool(
                Icons.insert_drive_file_outlined,
                '文件',
                '浏览项目文件',
                (t) => FilesPage(tool: t),
                tool,
              ),
              _Tool(
                Icons.call_split,
                '变更',
                '查看代码变更',
                (t) => ChangesPage(tool: t),
                tool,
              ),
              _Tool(
                Icons.terminal,
                '终端',
                '远程终端',
                (t) => TerminalPage(tool: t),
                tool,
              ),
              _Tool(
                Icons.play_arrow_outlined,
                '运行',
                '启动开发服务',
                (t) => RunPage(tool: t),
                tool,
              ),
            ],
          ),
        ),
        _GitRow(key: ValueKey('${h.id}/$projectId/${h.revision}'), tool: tool),
        SectionLabel(
          '最近会话',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () {
                  // Explicit jump: filter 会话 to this computer and project.
                  hub.sessionScope.value = (h.id, projectId);
                  HomeShell.select(context, 0);
                },
                child: const Text('查看全部'),
              ),
              TextButton(
                onPressed: h.online
                    ? () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => NewSessionPage(
                            hostId: h.id,
                            projectId: projectId,
                          ),
                        ),
                      )
                    : null,
                child: const Text('新会话'),
              ),
            ],
          ),
        ),
        if (sessions.isEmpty)
          const InlineNotice('这个项目还没有会话。')
        else
          for (final s in sessions) SessionRow(session: s),
      ],
    );
  }
}

/// Entry to a project tool on the PC; needs the PC online.
class _Tool extends StatelessWidget {
  const _Tool(this.icon, this.label, this.caption, this.page, this.tool);
  final IconData icon;
  final String label, caption;
  final Widget Function(ToolContext) page;
  final ToolContext tool;
  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final enabled = tool.host.online;
    return Expanded(
      child: Semantics(
        button: true,
        enabled: enabled,
        label: '$label，$caption',
        child: InkWell(
          borderRadius: BorderRadius.circular(DcSpace.control),
          onTap: enabled
              ? () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => page(tool)))
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Column(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: enabled ? c.text : c.secondary),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(color: enabled ? c.text : c.secondary),
                ),
                Text(
                  caption,
                  style: TextStyle(fontSize: 11, color: c.secondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "branch · N 个文件待提交", opening 变更.
class _GitRow extends StatefulWidget {
  const _GitRow({super.key, required this.tool});
  final ToolContext tool;
  @override
  State<_GitRow> createState() => _GitRowState();
}

class _GitRowState extends State<_GitRow> {
  Map<String, dynamic>? ws;
  @override
  void initState() {
    super.initState();
    final link = widget.tool.link, task = widget.tool.taskId;
    if (link == null || task == null) return;
    link
        .gitWorkspaces(task)
        .then((list) {
          if (mounted) {
            setState(
              () => ws =
                  list.where((w) => w['current'] == true).firstOrNull ??
                  list.firstOrNull,
            );
          }
        })
        .catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final w = ws;
    if (w == null || w['git'] != true) return const SizedBox.shrink();
    final changed = (w['changedFiles'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(DcSpace.page, 12, DcSpace.page, 0),
      child: Panel(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChangesPage(tool: widget.tool),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.call_split, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${w['branch'] ?? '分离 HEAD'} · ${changed == 0 ? '工作区干净' : '$changed 个文件待提交'}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}
