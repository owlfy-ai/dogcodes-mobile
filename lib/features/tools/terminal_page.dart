import 'package:flutter/material.dart';
import '../../core/pc_api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'terminal_pane.dart';
import 'tool_context.dart';

/// 08 终端: the project's persistent PC terminals. Leaving the page keeps them
/// running; × closes the current terminal on the PC.
class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, required this.tool});
  final ToolContext tool;
  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  List<Map<String, dynamic>> terminals = [];
  final sessions = <String, TerminalSession>{};
  String? current;
  bool loading = true;
  String? error;

  ToolContext get tool => widget.tool;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final s in sessions.values) {
      s.dispose();
    }
    super.dispose();
  }

  Future<void> _load({String? select}) async {
    final link = tool.link;
    if (link == null) return setState(() => loading = false);
    try {
      final list =
          (await link.terminals(tool.projectId))
              .where((t) => t['commandId'] == null && terminalActive(t))
              .toList()
            ..sort(
              (a, b) => ((a['createdAt'] as num?) ?? 0).compareTo(
                (b['createdAt'] as num?) ?? 0,
              ),
            );
      if (!mounted) return;
      setState(() {
        terminals = list;
        error = null;
        current =
            select ??
            (list.any((t) => t['id'] == current)
                ? current
                : list.lastOrNull?['id'] as String?);
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  TerminalSession? _session(String? id) {
    final link = tool.link;
    if (id == null || link == null) return null;
    return sessions.putIfAbsent(id, () => TerminalSession(link, id)..start());
  }

  Future<void> _new() async {
    final link = tool.link;
    if (link == null) return;
    try {
      final info = await link.terminalStart(
        projectId: tool.projectId,
        cwd: tool.path,
      );
      await _load(select: info['id'] as String?);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _close(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('关闭这个终端？'),
        content: const Text('将在电脑上结束该终端及其中运行的命令。离开页面不会关闭终端。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('关闭终端'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await tool.link?.terminalStop(id);
      sessions.remove(id)?.dispose();
      if (current == id) current = null;
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final session = _session(current);
    return Scaffold(
      appBar: DetailBar(
        title: '终端',
        subtitle: '${tool.host.name} · ${tool.projectName}',
      ),
      body: tool.link == null
          ? ToolUnavailable(tool: tool)
          : Column(
              children: [
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (var i = 0; i < terminals.length; i++)
                        _Tab(
                          label: '终端 ${i + 1}',
                          selected: terminals[i]['id'] == current,
                          onTap: () => setState(
                            () => current = terminals[i]['id'] as String,
                          ),
                          onClose: () => _close(terminals[i]['id'] as String),
                        ),
                      IconButton(
                        tooltip: '新建终端',
                        onPressed: _new,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ),
                Divider(color: c.line),
                if (error != null) InlineNotice(error!, danger: true),
                Expanded(
                  child: loading
                      ? const Center(child: CircularProgressIndicator())
                      : session == null
                      ? Center(
                          child: OutlinedButton.icon(
                            onPressed: _new,
                            icon: const Icon(Icons.terminal),
                            label: const Text('新建终端'),
                          ),
                        )
                      : TerminalPane(
                          key: ValueKey(session.id),
                          session: session,
                        ),
                ),
              ],
            ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap, onClose;
  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return Padding(
      padding: const EdgeInsets.only(right: 6, top: 6, bottom: 6),
      child: Material(
        color: selected ? c.surface : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: c.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : null,
                  ),
                ),
                IconButton(
                  tooltip: '关闭终端',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
