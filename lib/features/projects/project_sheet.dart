import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../core/mobile_operations.dart';
import '../../ui/theme.dart';
import '../workspace/add_project_page.dart';
import 'edit_project_page.dart';

/// What the sheet chose. [projectId] null means 全部项目 (filter mode only).
class ProjectPick {
  const ProjectPick(this.projectId);
  final String? projectId;
}

/// Bottom sheet listing one computer's projects.
///
/// [filter] (会话): picks a view filter, offers 全部项目 and 不在项目中工作
/// (the PC's built-in 无项目 project). Otherwise (项目 tab): picks the
/// project to work on and manages the list — edit, pin, remove, restore.
Future<ProjectPick?> showProjectSheet(
  BuildContext context, {
  required String hostId,
  String? selected,
  bool filter = false,
}) => showModalBottomSheet<ProjectPick>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) =>
      ProjectSheet(hostId: hostId, selected: selected, filter: filter),
);

class ProjectSheet extends StatefulWidget {
  const ProjectSheet({
    super.key,
    required this.hostId,
    this.selected,
    this.filter = false,
  });
  final String hostId;
  final String? selected;
  final bool filter;
  @override
  State<ProjectSheet> createState() => _ProjectSheetState();
}

class _ProjectSheetState extends State<ProjectSheet> {
  final query = TextEditingController();

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  bool _matches(Map<String, dynamic> p) {
    final q = query.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [
      projectLabel(p) ?? '',
      p['path'] ?? '',
      ...(p['additionalDirectories'] as List? ?? const []),
    ].any((v) => '$v'.toLowerCase().contains(q));
  }

  Future<void> _create(HostState h) async {
    final added = await showAddProject(context, hostId: h.id);
    if (added != null && mounted) {
      Navigator.of(context).pop(ProjectPick(added.projectId));
    }
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final hub = AppScope.of(context).hub;
    final c = context.dc;
    return ListenableBuilder(
      listenable: Listenable.merge([hub, query]),
      builder: (context, _) {
        final h = hub.host(widget.hostId);
        if (h == null) return const SizedBox(height: 120);
        final listed = h.listedProjects;
        final shown = listed.where(_matches).toList();
        final removed = h.removedProjects;
        final scratch = h.scratchProject;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.62,
          minChildSize: 0.3,
          maxChildSize: 0.94,
          builder: (context, controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  DcSpace.page,
                  0,
                  DcSpace.page,
                  8,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      widget.filter ? tr("选择项目") : tr("项目"),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        h.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.secondary, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              if (listed.length > 8)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    DcSpace.page,
                    0,
                    DcSpace.page,
                    8,
                  ),
                  child: TextField(
                    controller: query,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: tr("搜索项目"),
                      prefixIcon: const Icon(Icons.search),
                    ),
                  ),
                ),
              if (widget.filter)
                _Choice(
                  icon: Icons.folder_copy_outlined,
                  title: tr("全部项目"),
                  selected: widget.selected == null,
                  onTap: () =>
                      Navigator.of(context).pop(const ProjectPick(null)),
                ),
              for (final p in shown)
                _ProjectRow(
                  host: h,
                  project: p,
                  selected: p['projectId'] == widget.selected,
                  manage: !widget.filter,
                  onTap: () => Navigator.of(
                    context,
                  ).pop(ProjectPick(p['projectId'] as String)),
                ),
              if (listed.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DcSpace.page,
                    vertical: 16,
                  ),
                  child: Text(
                    h.snapshot == null
                        ? tr("{0} 尚未同步项目；电脑在线时会自动同步。", [h.name])
                        : tr("这台电脑上还没有项目。"),
                    style: TextStyle(color: c.secondary),
                  ),
                )
              else if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(DcSpace.page),
                  child: Text(
                    tr("没有匹配的项目"),
                    style: TextStyle(color: c.secondary),
                  ),
                ),
              Divider(height: 16, color: c.line),
              if (widget.filter && scratch != null)
                _Choice(
                  icon: Icons.chat_bubble_outline,
                  title: tr("不在项目中工作"),
                  selected: widget.selected == scratch['projectId'],
                  onTap: () => Navigator.of(
                    context,
                  ).pop(ProjectPick(scratch['projectId'] as String)),
                ),
              _Choice(
                icon: Icons.add,
                title: tr("新建项目"),
                selected: false,
                enabled: h.online,
                onTap: () => _create(h),
              ),
              if (!widget.filter && removed.isNotEmpty)
                Theme(
                  data: Theme.of(
                    context,
                  ).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(
                      horizontal: DcSpace.page,
                    ),
                    title: Text(
                      tr("已移除项目（{0}）", [removed.length]),
                      style: TextStyle(color: c.secondary, fontSize: 14),
                    ),
                    children: [
                      for (final p in removed) _RemovedRow(host: h, project: p),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });
  final IconData icon;
  final String title;
  final bool selected, enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: DcSpace.page),
      leading: Icon(icon, color: c.secondary),
      title: Text(
        title,
        style: TextStyle(fontWeight: selected ? FontWeight.w600 : null),
      ),
      trailing: selected ? Icon(Icons.check, color: c.accent) : null,
      enabled: enabled,
      onTap: onTap,
    );
  }
}

/// `~/…` for home folders, and how many directories the project spans.
String projectSubtitle(Map<String, dynamic> p) {
  final path = '${p['path'] ?? ''}'.replaceFirstMapped(
    RegExp(r'^(/Users|/home)/[^/]+'),
    (_) => '~',
  );
  final extra = (p['additionalDirectories'] as List?)?.length ?? 0;
  return extra == 0 ? path : tr("{0} · {1} 个目录", [path, extra + 1]);
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.host,
    required this.project,
    required this.selected,
    required this.manage,
    required this.onTap,
  });
  final HostState host;
  final Map<String, dynamic> project;
  final bool selected, manage;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final id = project['projectId'] as String;
    final pinned = host.projectState(id) == 'pinned';
    final running = host.tasks
        .where((t) => t['projectId'] == id && t['activePrimaryRun'] != null)
        .length;
    return ListTile(
      contentPadding: EdgeInsets.only(
        left: DcSpace.page,
        right: manage ? 4 : DcSpace.page,
      ),
      leading: Icon(
        pinned ? Icons.push_pin_outlined : Icons.folder_outlined,
        color: selected ? c.accent : c.secondary,
      ),
      title: Text(
        projectLabel(project) ?? tr("未命名项目"),
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontWeight: selected ? FontWeight.w600 : null),
      ),
      subtitle: Text(
        projectSubtitle(project),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (running > 0)
            Tooltip(
              message: tr("{0} 个会话运行中", [running]),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, size: 8, color: c.accent),
                  const SizedBox(width: 3),
                  Text('$running', style: TextStyle(color: c.secondary)),
                ],
              ),
            ),
          if (selected) ...[
            const SizedBox(width: 8),
            Icon(Icons.check, color: c.accent),
          ],
          if (manage)
            IconButton(
              tooltip: tr("项目操作"),
              onPressed: () => showProjectActions(context, host, project),
              icon: const Icon(Icons.more_horiz),
            ),
        ],
      ),
      onTap: onTap,
      onLongPress: manage
          ? () => showProjectActions(context, host, project)
          : null,
    );
  }
}

class _RemovedRow extends StatefulWidget {
  const _RemovedRow({required this.host, required this.project});
  final HostState host;
  final Map<String, dynamic> project;
  @override
  State<_RemovedRow> createState() => _RemovedRowState();
}

class _RemovedRowState extends State<_RemovedRow> {
  bool busy = false;
  @override
  Widget build(BuildContext context) {
    final h = widget.host;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: DcSpace.page),
      leading: Icon(Icons.folder_off_outlined, color: context.dc.secondary),
      title: Text(projectLabel(widget.project) ?? tr("未命名项目")),
      subtitle: Text(
        projectSubtitle(widget.project),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: TextButton(
        onPressed: busy || !h.online
            ? null
            : () async {
                setState(() => busy = true);
                await setProjectState(
                  context,
                  h,
                  widget.project['projectId'] as String,
                  null,
                );
                if (mounted) setState(() => busy = false);
              },
        child: Text(tr("恢复")),
      ),
    );
  }
}

/// Writes the project's list state on the PC (shared with the desktop) and
/// reports failures without leaving the screen. Returns true on success.
Future<bool> setProjectState(
  BuildContext context,
  HostState h,
  String projectId,
  String? state,
) async {
  final hub = AppScope.of(context).hub;
  final link = h.link;
  if (link == null) return false;
  try {
    await h.operations.setProjectState(link, projectId, state);
    await hub.refresh(h);
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))),
      );
    }
    return false;
  } finally {
    await hub.refreshOperation(h);
  }
}

/// 编辑 / 置顶 / 移除 for one project, from the sheet's ⋯, a long press, or
/// the 项目 page header.
Future<void> showProjectActions(
  BuildContext context,
  HostState h,
  Map<String, dynamic> project,
) async {
  final id = project['projectId'] as String;
  final name = projectLabel(project) ?? tr("未命名项目");
  final pinned = h.projectState(id) == 'pinned';
  final action = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheet) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(DcSpace.page, 0, DcSpace.page, 8),
          child: Text(
            name,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(sheet).textTheme.titleMedium,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: Text(tr("编辑项目")),
          subtitle: Text(tr("名称和目录")),
          enabled: h.online,
          onTap: () => Navigator.pop(sheet, 'edit'),
        ),
        ListTile(
          leading: const Icon(Icons.push_pin_outlined),
          title: Text(pinned ? tr("取消置顶") : tr("置顶项目")),
          enabled: h.online,
          onTap: () => Navigator.pop(sheet, 'pin'),
        ),
        ListTile(
          leading: Icon(Icons.remove_circle_outline, color: sheet.dc.removed),
          title: Text(tr("移除项目"), style: TextStyle(color: sheet.dc.removed)),
          subtitle: Text(tr("保留会话和电脑上的文件，可随时恢复")),
          enabled: h.online,
          onTap: () => Navigator.pop(sheet, 'remove'),
        ),
        const SizedBox(height: 12),
      ],
    ),
  );
  if (!context.mounted || action == null) return;
  switch (action) {
    case 'edit':
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => EditProjectPage(hostId: h.id, projectId: id),
        ),
      );
    case 'pin':
      await setProjectState(context, h, id, pinned ? null : 'pinned');
    case 'remove':
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(tr("移除「{0}」？", [name])),
          content: Text(tr("项目会从列表中隐藏。会话和电脑上的文件都会保留，可在「已移除项目」中恢复。")),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: Text(tr("取消")),
            ),
            TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: Text(tr("移除"), style: TextStyle(color: d.dc.removed)),
            ),
          ],
        ),
      );
      if (ok == true && context.mounted) {
        await setProjectState(context, h, id, 'removed');
      }
  }
}
