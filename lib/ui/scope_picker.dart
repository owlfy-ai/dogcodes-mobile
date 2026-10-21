import 'package:flutter/material.dart';
import '../core/host_hub.dart';
import 'theme.dart';
import 'widgets.dart';

/// Computer first, then a project on that computer. Projects are never merged
/// across computers: each is a directory registered on one PC.
///
/// With [allowAll] (筛选) both levels offer 「全部」 and the project level is
/// only available once a computer is chosen. Without it (执行对象) both levels
/// must be chosen.
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
                  tooltip: '选择电脑',
                  onSelected: (id) => onChanged(id == _all ? null : id, null),
                  itemBuilder: (_) => [
                    if (allowAll)
                      const PopupMenuItem<String>(
                        value: _all,
                        child: Text('全部电脑'),
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
                    label: host?.name ?? '全部电脑',
                    trailing: host == null ? null : _status(host),
                    menu: true,
                  ),
                ),
        ),
        const SizedBox(width: 8),
        Flexible(
          // Unsynced (offline before first load) reads like 「全部」, not empty.
          child: host == null || (host.snapshot == null && allowAll)
              ? _Field(icon: Icons.folder_outlined, label: '全部项目', muted: true)
              : PopupMenuButton<String>(
                  tooltip: '选择项目',
                  enabled: projects.isNotEmpty,
                  onSelected: (id) =>
                      onChanged(host.id, id == _all ? null : id),
                  itemBuilder: (_) => [
                    if (allowAll)
                      const PopupMenuItem<String>(
                        value: _all,
                        child: Text('全部项目'),
                      ),
                    for (final p in projects)
                      PopupMenuItem<String>(
                        value: p['projectId'] as String,
                        child: Text(projectLabel(p) ?? '项目'),
                      ),
                  ],
                  child: _Field(
                    icon: Icons.folder_outlined,
                    label: project != null
                        ? projectLabel(project)!
                        : projects.isEmpty
                        ? '没有项目'
                        : '全部项目',
                    menu: projects.isNotEmpty,
                    strong: project != null,
                  ),
                ),
        ),
      ],
    );
  }

  static Widget _status(HostState h) => StatusLabel(switch (h.status) {
    LinkStatus.online => '在线',
    LinkStatus.connecting => '连接中',
    LinkStatus.offline => '离线',
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
  });
  final IconData icon;
  final String label;
  final Widget? trailing;
  final bool menu, muted, strong;
  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return Panel(
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
  }
}
