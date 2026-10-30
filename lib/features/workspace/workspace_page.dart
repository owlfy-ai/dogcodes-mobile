import 'package:dogcodes_app/l10n/strings.dart';
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
import 'add_project_page.dart';
import '../projects/project_sheet.dart';

/// 05 项目: always bound to one PC and one of its real projects (never 无项目).
/// Choosing and managing projects happens in the bottom sheet behind the
/// project field; this page is the chosen project's tools and sessions.
class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key});
  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  String? hostId, projectId;
  Future<void> _addProject() async {
    final result = await showAddProject(context, hostId: hostId);
    if (result != null && mounted) {
      setState(() {
        hostId = result.hostId;
        projectId = result.projectId;
      });
    }
  }

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
    final listed = h.listedProjects;
    final project =
        listed.where((p) => p['projectId'] == projectId).firstOrNull ??
        listed.firstOrNull;
    projectId = project?['projectId'] as String?;
    return (h, project);
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final hub = AppScope.of(context).hub;
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final selected = _resolve(hub);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RootHeader(
              title: tr("项目"),
              actions: [
                if (selected?.$2 case final project?)
                  IconButton(
                    tooltip: tr("项目操作"),
                    onPressed: () =>
                        showProjectActions(context, selected!.$1, project),
                    icon: const Icon(Icons.more_horiz),
                  ),
              ],
            ),
            Expanded(
              child: selected == null
                  ? EmptyNote(
                      icon: Icons.folder_open_outlined,
                      title: tr("还没有连接电脑"),
                      body: tr("连接电脑后，在这里查看项目及其会话。"),
                      action: OutlinedButton(
                        onPressed: () => HomeShell.select(context, 3),
                        child: Text(tr("去连接电脑")),
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
                ? tr("{0} 尚未同步项目；电脑在线时会自动同步。", [h.name])
                : tr("{0} 上还没有项目。新建项目时选择电脑上的已有目录。", [h.name]),
          ),
          if (h.snapshot != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DcSpace.page),
              child: FilledButton.icon(
                onPressed: h.online ? _addProject : null,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: Text(tr("新建项目")),
              ),
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
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DcSpace.page - 4),
          child: Row(
            children: [
              _Tool(
                Icons.insert_drive_file_outlined,
                tr("文件"),
                tr("浏览项目文件"),
                (t) => FilesPage(tool: t),
                tool,
              ),
              _Tool(
                Icons.call_split,
                tr("变更"),
                tr("查看代码变更"),
                (t) => ChangesPage(tool: t),
                tool,
              ),
              _Tool(
                Icons.terminal,
                tr("终端"),
                tr("远程终端"),
                (t) => TerminalPage(tool: t),
                tool,
              ),
              _Tool(
                Icons.play_arrow_outlined,
                tr("运行"),
                tr("启动开发服务"),
                (t) => RunPage(tool: t),
                tool,
              ),
            ],
          ),
        ),
        _GitRow(key: ValueKey('${h.id}/$projectId/${h.revision}'), tool: tool),
        _Directories(project: project),
        SectionLabel(
          tr("最近会话"),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () {
                  // Explicit jump: filter 会话 to this computer and project.
                  hub.sessionScope.value = (h.id, projectId);
                  HomeShell.select(context, 0);
                },
                child: Text(tr("查看全部")),
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
                child: Text(tr("新会话")),
              ),
            ],
          ),
        ),
        if (sessions.isEmpty)
          InlineNotice(tr("这个项目还没有会话。"))
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
    watchAppLanguage(context);
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
    watchAppLanguage(context);
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
                '${w['branch'] ?? tr("分离 HEAD")} · ${changed == 0 ? tr("没有未提交的更改") : tr("{0} 个文件待提交", [changed])}',
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

/// The project's directories; the first is where sessions start.
class _Directories extends StatelessWidget {
  const _Directories({required this.project});
  final Map<String, dynamic> project;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final dirs = [
      '${project['path']}',
      for (final d in (project['additionalDirectories'] as List? ?? const []))
        '$d',
    ];
    final home = RegExp(r'^(/Users|/home)/[^/]+');
    return Padding(
      padding: const EdgeInsets.fromLTRB(DcSpace.page, 12, DcSpace.page, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < dirs.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 16,
                    color: i == 0 ? c.text : c.secondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      dirs[i].replaceFirstMapped(home, (_) => '~'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: c.secondary),
                    ),
                  ),
                  if (i == 0 && dirs.length > 1)
                    Text(
                      tr("主目录"),
                      style: TextStyle(fontSize: 12, color: c.secondary),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
