import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../core/pc_api.dart';
import '../../core/host_hub.dart';
import '../../core/mobile_operations.dart';
import '../../core/protocol.dart';
import 'workspace_recovery.dart';
import 'workspace_connection.dart';
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

class _TerminalPageState extends State<TerminalPage>
    with WorkspaceConnection<TerminalPage> {
  @override
  HostState get workspaceHost => tool.host;
  int _loadOrder = 0;
  bool busy = false;
  @override
  void onWorkspaceConnectionChanged() {
    _loadOrder++;
    for (final s in sessions.values) {
      s.dispose();
    }
    sessions.clear();
    terminals = [];
    loading = tool.host.online;
    error = null;
    if (tool.host.online) _load();
  }

  List<Map<String, dynamic>> terminals = [];
  final sessions = <String, TerminalSession>{};
  String? current;
  bool loading = true;
  String? error;

  ToolContext get tool => widget.tool;
  List<String> get directories {
    final project = tool.host.project(tool.projectId);
    if (project == null) return [];
    return [
      if (project['path'] is String) project['path'] as String,
      for (final path
          in (project['additionalDirectories'] as List? ?? const []))
        path as String,
    ];
  }

  String directoryName(String path) =>
      path
          .split(RegExp(r'[\\/]'))
          .where((part) => part.isNotEmpty)
          .lastOrNull ??
      path;

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
    final order = ++_loadOrder, epoch = tool.host.connectionEpoch;
    if (link == null || !tool.host.online) {
      return setState(() => loading = false);
    }
    try {
      final list =
          (await link.terminals(tool.projectId))
              .where(
                (t) =>
                    t['commandId'] == null &&
                    (terminalActive(t) || t['status'] == 'unknown'),
              )
              .toList()
            ..sort(
              (a, b) => ((a['createdAt'] as num?) ?? 0).compareTo(
                (b['createdAt'] as num?) ?? 0,
              ),
            );
      if (!mounted ||
          order != _loadOrder ||
          epoch != tool.host.connectionEpoch ||
          link != tool.link) {
        return;
      }
      setState(() {
        terminals = list;
        error = null;
        current =
            (list.any((t) => t['id'] == select) ? select : null) ??
            (list.any((t) => t['id'] == current)
                ? current
                : list.lastOrNull?['id'] as String?);
      });
    } catch (e) {
      if (mounted && order == _loadOrder) setState(() => error = '$e');
    } finally {
      if (mounted && order == _loadOrder) setState(() => loading = false);
    }
  }

  TerminalSession? _session(String? id) {
    final link = tool.link;
    if (id == null ||
        link == null ||
        loading ||
        !tool.host.online ||
        !terminals.any((terminal) => terminal['id'] == id)) {
      return null;
    }
    return sessions.putIfAbsent(id, () => TerminalSession(link, id)..start());
  }

  Future<void> _new() async {
    final link = tool.link, epoch = tool.host.connectionEpoch;
    if (link == null || busy || !tool.host.online) return;
    final paths = directories;
    if (paths.isEmpty) return showError(context, tr("项目目录不可用，请刷新项目后重试。"));
    final index = paths.length == 1
        ? 0
        : await showModalBottomSheet<int>(
            context: context,
            builder: (sheet) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(title: Text(tr("选择终端目录"))),
                  for (var i = 0; i < paths.length; i++)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(directoryName(paths[i])),
                      subtitle: Text(paths[i]),
                      onTap: () => Navigator.pop(sheet, i),
                    ),
                ],
              ),
            ),
          );
    if (!mounted || index == null) return;
    final latest = directories;
    if (!tool.host.online ||
        link != tool.link ||
        epoch != tool.host.connectionEpoch ||
        index >= latest.length ||
        latest[index] != paths[index]) {
      showError(context, tr("连接或项目目录已改变，请重新选择终端目录。"));
      return;
    }
    setState(() => busy = true);
    try {
      final result = await tool.host.operations.terminalStart(
        link,
        projectId: tool.projectId,
        directoryIndex: index,
        cwd: paths[index],
      );
      if (result == null) throw ProtocolException(tr("启动结果待核实，请使用原操作恢复。"));
      if (mounted && link == tool.link && epoch == tool.host.connectionEpoch) {
        await _load(select: result['terminal']?['id'] as String?);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      await workspaceHub?.refreshOperation(tool.host);
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _close(String id) async {
    final link = tool.link, epoch = tool.host.connectionEpoch;
    final target = terminals.where((t) => t['id'] == id).firstOrNull;
    if (link == null || target == null || busy || !tool.host.online) return;
    final terminal = Map<String, dynamic>.from(target);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr("关闭这个终端？")),
        content: Text(tr("将在电脑上结束该终端及其中运行的命令。离开页面不会关闭终端。")),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text(tr("取消")),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text(tr("关闭终端")),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (link != tool.link || epoch != tool.host.connectionEpoch) {
      showError(context, tr("连接已改变，请刷新后重新确认关闭。"));
      return;
    }
    setState(() => busy = true);
    try {
      final result = await tool.host.operations.terminalStop(link, terminal);
      if (!mounted || link != tool.link || epoch != tool.host.connectionEpoch) {
        return;
      }
      if (result['state'] == 'stopped') {
        sessions.remove(id)?.dispose();
        if (current == id) current = null;
      } else {
        showError(context, terminalStopMessage(result));
      }
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      await workspaceHub?.refreshOperation(tool.host);
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final session = _session(current);
    return Scaffold(
      appBar: DetailBar(
        title: tr("终端"),
        subtitle: '${tool.host.name} · ${tool.projectName}',
      ),
      body: !tool.host.online
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
                          label: directories.length > 1
                              ? '${directoryName('${terminals[i]['cwd'] ?? ''}')} · ${i + 1}'
                              : tr("终端 {0}", [i + 1]),
                          selected: terminals[i]['id'] == current,
                          onTap: () => setState(
                            () => current = terminals[i]['id'] as String,
                          ),
                          onClose: () => _close(terminals[i]['id'] as String),
                        ),
                      IconButton(
                        tooltip: tr("新建终端"),
                        onPressed: busy ? null : _new,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ),
                Divider(color: c.line),
                WorkspaceRecoveryCards(
                  host: tool.host,
                  projectId: tool.projectId,
                  onRecovered: () => _load(),
                ),
                if (error != null) InlineNotice(error!, danger: true),
                Expanded(
                  child: loading
                      ? const Center(child: CircularProgressIndicator())
                      : session == null
                      ? Center(
                          child: OutlinedButton.icon(
                            onPressed: busy ? null : _new,
                            icon: const Icon(Icons.terminal),
                            label: Text(tr("新建终端")),
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
    watchAppLanguage(context);
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
                  tooltip: tr("关闭当前终端"),
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
