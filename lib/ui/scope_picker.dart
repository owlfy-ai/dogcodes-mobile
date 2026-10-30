import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../core/host_hub.dart';
import 'theme.dart';
import 'widgets.dart';
import '../features/projects/project_sheet.dart';

/// Computer first, then a project on that computer. Projects are never merged
/// across computers: each is a directory registered on one PC.
///
/// With [allowAll] (会话 filter) both levels offer 「全部」, and the project
/// sheet also offers 不在项目中工作. Without it (项目 tab) a real project must
/// be chosen. The project level opens a bottom sheet once a computer is set.
class ScopePicker extends StatelessWidget {
  const ScopePicker({
    super.key,
    required this.hosts,
    required this.hostId,
    required this.projectId,
    required this.onChanged,
    this.allowAll = false,
  });
  final List<HostState> hosts;
  final String? hostId, projectId;
  final bool allowAll;
  final void Function(String? hostId, String? projectId) onChanged;

  // PopupMenuButton treats a null value as a dismissal and never calls
  // onSelected, so 「全部」 needs a real value.
  static const _all = '\u0000all';

  HostState? get _host {
    for (final h in hosts) {
      if (h.id == hostId) return h;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final host = _host;
    final single = hosts.length == 1;
    final projects = host?.projects ?? const <Map<String, dynamic>>[];
    Map<String, dynamic>? project;
    for (final p in projects) {
      if (p['projectId'] == projectId) project = p;
    }
    return Row(
      children: [
        Flexible(
          child: single
              ? _Field(
                  icon: Icons.computer_outlined,
                  label: hosts.first.name,
                  trailing: _status(hosts.first),
                )
              : PopupMenuButton<String>(
                  tooltip: tr("选择电脑"),
                  onSelected: (id) => onChanged(id == _all ? null : id, null),
                  itemBuilder: (_) => [
                    if (allowAll)
                      PopupMenuItem<String>(
                        value: _all,
                        child: Text(tr("全部电脑")),
                      ),
                    for (final h in hosts)
                      PopupMenuItem<String>(
                        value: h.id,
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                h.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            _status(h),
                          ],
                        ),
                      ),
                  ],
                  child: _Field(
                    icon: Icons.computer_outlined,
                    label: host?.name ?? tr("全部电脑"),
                    trailing: host == null ? null : _status(host),
                    menu: true,
                  ),
                ),
        ),
        const SizedBox(width: 8),
        Flexible(
          // Unsynced (offline before first load) reads like 「全部」, not empty.
          child: host == null || (host.snapshot == null && allowAll)
              ? _Field(
                  icon: Icons.folder_outlined,
                  label: tr("全部项目"),
                  muted: true,
                )
              : _Field(
                  icon: project != null && isScratchProject(project)
                      ? Icons.chat_bubble_outline
                      : Icons.folder_outlined,
                  label: project != null
                      ? projectLabel(project)!
                      : allowAll
                      ? tr("全部项目")
                      : tr("没有项目"),
                  menu: true,
                  strong: project != null,
                  tooltip: tr("选择项目"),
                  onTap: () async {
                    final pick = await showProjectSheet(
                      context,
                      hostId: host.id,
                      selected: projectId,
                      filter: allowAll,
                    );
                    if (pick != null) onChanged(host.id, pick.projectId);
                  },
                ),
        ),
      ],
    );
  }

  static Widget _status(HostState h) => StatusLabel(switch (h.status) {
    LinkStatus.online => tr("在线"),
    LinkStatus.connecting => tr("连接中"),
    LinkStatus.offline => tr("离线"),
  }, tone: h.online ? Tone.accent : Tone.muted);
}

class _Field extends StatelessWidget {
  const _Field({
    required this.icon,
    required this.label,
    this.trailing,
    this.menu = false,
    this.muted = false,
    this.strong = false,
    this.onTap,
    this.tooltip,
  });
  final IconData icon;
  final String label;
  final Widget? trailing;
  final bool menu, muted, strong;
  final VoidCallback? onTap;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final field = Panel(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: muted ? c.secondary : c.text),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: muted ? c.secondary : c.text,
                fontWeight: strong ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 6), trailing!],
          if (menu) Icon(Icons.expand_more, size: 18, color: c.secondary),
        ],
      ),
    );
    return tooltip == null ? field : Tooltip(message: tooltip!, child: field);
  }
}
