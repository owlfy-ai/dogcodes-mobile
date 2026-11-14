import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/pc_api.dart';
import '../../core/host_hub.dart';
import '../../core/mobile_operations.dart';
import '../../core/protocol.dart';
import 'workspace_recovery.dart';
import 'workspace_connection.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'preview_page.dart';
import 'terminal_pane.dart';
import 'tool_context.dart';
import 'workspace_directory_picker.dart';

/// 09 运行与预览: project run configurations shared with the PC, start/stop,
/// output, and an in-app preview of the dev server.
class RunPage extends StatefulWidget {
  const RunPage({super.key, required this.tool});
  final ToolContext tool;
  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> with WorkspaceConnection<RunPage> {
  @override
  HostState get workspaceHost => tool.host;
  int _loadOrder = 0;
  int? directoryIndex;
  String? directoryPath;
  @override
  void onWorkspaceConnectionChanged() {
    _loadOrder++;
    session?.dispose();
    session = null;
    port = null;
    if (tool.host.online) _load();
  }

  Map<String, dynamic>? catalog;
  List<Map<String, dynamic>> runs = [];
  String? commandId;
  TerminalSession? session;
  bool loading = true, busy = false;
  String? error;
  int? port;
  Timer? _portScan;
  bool _pollLoading = false;

  ToolContext get tool => widget.tool;

  List<Map<String, dynamic>> get directories => [
    for (final d in (catalog?['directories'] as List? ?? const []))
      Map<String, dynamic>.from(d as Map),
  ];
  List<({int dir, Map<String, dynamic> cmd})> get allCommands => [
    for (final (i, d)
        in ((catalog?['directories'] as List?) ?? const []).indexed)
      for (final c in ((d as Map)['commands'] as List? ?? const []))
        (dir: i, cmd: Map<String, dynamic>.from(c as Map)),
  ];
  List<({int dir, Map<String, dynamic> cmd})> get commands =>
      allCommands.where((c) => c.dir == directoryIndex).toList();
  ({int dir, Map<String, dynamic> cmd})? get selected => commands
      .where((c) => c.cmd['id'] == commandId && c.dir == directoryIndex)
      .firstOrNull;
  Map<String, dynamic>? get running => runs
      .where(
        (r) =>
            r['commandId'] == commandId &&
            r['directoryIndex'] == selected?.dir &&
            terminalActive(r),
      )
      .firstOrNull;

  @override
  void initState() {
    super.initState();
    _load();
    _portScan = Timer.periodic(const Duration(seconds: 1), (timer) {
      _detectPort();
      if (timer.tick % 2 == 0 && tool.host.online && !busy && !_pollLoading) {
        _pollLoading = true;
        _load().whenComplete(() => _pollLoading = false);
      }
    });
  }

  @override
  void dispose() {
    _portScan?.cancel();
    session?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final link = tool.link, task = tool.taskId;
    final order = ++_loadOrder, epoch = tool.host.connectionEpoch;
    if (link == null || task == null || !tool.host.online) {
      return setState(() => loading = false);
    }
    try {
      final results = await Future.wait([
        link.projectRuns(task),
        link.terminals(tool.projectId),
      ]);
      if (!mounted ||
          order != _loadOrder ||
          epoch != tool.host.connectionEpoch ||
          link != tool.link ||
          task != tool.taskId) {
        return;
      }
      final cat = results[0] as Map<String, dynamic>;
      final terms = results[1] as List<Map<String, dynamic>>;
      setState(() {
        catalog = cat;
        runs = terms.where((t) => t['commandId'] != null).toList()
          ..sort(
            (a, b) => ((b['createdAt'] as num?) ?? 0).compareTo(
              (a['createdAt'] as num?) ?? 0,
            ),
          );
        error = null;
        final previous = directories.indexWhere(
          (d) => d['path'] == directoryPath,
        );
        if (previous >= 0) {
          directoryIndex = previous;
        } else {
          final active = runs.where(terminalActive).firstOrNull;
          final next =
              allCommands
                  .where(
                    (c) =>
                        c.cmd['id'] == active?['commandId'] &&
                        c.dir == active?['directoryIndex'],
                  )
                  .firstOrNull ??
              allCommands.where((c) => c.cmd['pinned'] == true).firstOrNull ??
              allCommands.firstOrNull;
          directoryIndex = next?.dir ?? (directories.isEmpty ? null : 0);
          commandId = null;
        }
        directoryPath = directoryIndex == null
            ? null
            : directories[directoryIndex!]['path'] as String?;
        if (selected == null) {
          commandId = _preferredCommand();
        }
      });
      _attach();
    } catch (e) {
      if (mounted && order == _loadOrder) setState(() => error = '$e');
    } finally {
      if (mounted && order == _loadOrder) setState(() => loading = false);
    }
  }

  String? _preferredCommand() {
    final next =
        commands
            .where(
              (c) => runs.any(
                (r) =>
                    terminalActive(r) &&
                    r['directoryIndex'] == c.dir &&
                    r['commandId'] == c.cmd['id'],
              ),
            )
            .firstOrNull ??
        commands.where((c) => c.cmd['pinned'] == true).firstOrNull ??
        commands.firstOrNull;
    return next?.cmd['id'] as String?;
  }

  void _selectDirectory(int index) {
    setState(() {
      directoryIndex = index;
      directoryPath = directories[index]['path'] as String?;
      commandId = _preferredCommand();
    });
    _attach();
  }

  /// Shows the latest run of the selected command (running or finished).
  void _attach() {
    final link = tool.link;
    final latest = runs
        .where(
          (r) =>
              r['commandId'] == commandId &&
              r['directoryIndex'] == selected?.dir,
        )
        .firstOrNull;
    final id = latest?['id'] as String?;
    if (link == null || id == session?.id) return;
    session?.dispose();
    port = null;
    session = id == null ? null : (TerminalSession(link, id)..start());
    setState(() {});
  }

  /// Dev servers print their URL; the first local one becomes the preview.
  void _detectPort() {
    final s = session;
    if (s == null || port != null || !terminalActive(s.info.value)) return;
    final buffer = s.terminal.buffer;
    final text = StringBuffer();
    for (var i = 0; i < buffer.lines.length; i++) {
      text.writeln(buffer.lines[i].toString());
    }
    final m = RegExp(
      r'https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):(\d{2,5})',
    ).firstMatch(text.toString());
    if (m != null && mounted) setState(() => port = int.tryParse(m.group(1)!));
  }

  Future<void> _start() async {
    final link = tool.link, task = tool.taskId, sel = selected;
    if (busy ||
        !tool.host.online ||
        link == null ||
        task == null ||
        sel == null) {
      return;
    }
    setState(() => busy = true);
    try {
      final result = await tool.host.operations.runStart(
        link,
        projectId: tool.projectId,
        taskId: task,
        generation: '${catalog!['generation']}',
        directoryIndex: sel.dir,
        commandId: sel.cmd['id'] as String,
      );
      if (result == null) throw ProtocolException(tr("启动结果待核实，请使用原操作恢复。"));
      if (mounted) await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      await workspaceHub?.refreshOperation(tool.host);
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> _stop() async {
    final r = running, link = tool.link;
    if (r == null || link == null || busy || !tool.host.online) return false;
    setState(() => busy = true);
    try {
      final result = await tool.host.operations.terminalStop(
        link,
        Map<String, dynamic>.from(r),
      );
      if (result['state'] != 'stopped') {
        throw ProtocolException(terminalStopMessage(result));
      }
      if (mounted) await _load();
      return true;
    } catch (e) {
      if (mounted) showError(context, e);
      return false;
    } finally {
      await workspaceHub?.refreshOperation(tool.host);
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _restart() async {
    final original = selected, generation = catalog?['generation'];
    if (await _stop() && mounted && running == null) {
      if (original?.dir != selected?.dir ||
          original?.cmd['id'] != selected?.cmd['id'] ||
          generation != catalog?['generation']) {
        showError(context, tr("运行配置已改变，请确认后再启动。"));
        return;
      }
      await _start();
    }
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: Text(tr("取消")),
            ),
            TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: Text(tr("继续")),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _edit(String action) async {
    final sel = selected,
        task = tool.taskId,
        link = tool.link,
        generation = catalog?['generation'];
    if (busy ||
        sel == null ||
        task == null ||
        link == null ||
        generation == null) {
      return;
    }
    Map<String, dynamic> edit = {'action': action};
    if (action == 'rename') {
      var labelText = '${sel.cmd['label']}';
      final label = await showDialog<String>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(tr("重命名运行配置")),
          content: TextFormField(
            initialValue: labelText,
            onChanged: (value) => labelText = value,
            autofocus: true,
            maxLength: 60,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d),
              child: Text(tr("取消")),
            ),
            TextButton(
              onPressed: () => Navigator.pop(d, labelText.trim()),
              child: Text(tr("保存")),
            ),
          ],
        ),
      );
      if (label == null || label.isEmpty || !mounted) return;
      edit['label'] = label;
    } else if (action == 'pin') {
      edit['pinned'] = sel.cmd['pinned'] != true;
    } else if (action == 'delete') {
      if (!await _confirm(
            tr("删除运行配置？"),
            tr("移除“{0}”的启动配置，已运行的进程不会停止。", [sel.cmd['label']]),
          ) ||
          !mounted) {
        return;
      }
    }
    if (!mounted || busy || !tool.host.online) return;
    setState(() => busy = true);
    try {
      await tool.host.operations.runEdit(
        link,
        taskId: task,
        generation: '$generation',
        directoryIndex: sel.dir,
        commandId: sel.cmd['id'] as String,
        edit: edit,
      );
      if (mounted) await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      await workspaceHub?.refreshOperation(tool.host);
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _analyze() async {
    final link = tool.link,
        task = tool.taskId,
        generation = catalog?['generation'];
    if (busy || link == null || task == null || generation == null) return;
    final overwrite = (catalog?['directories'] as List? ?? []).any(
      (d) =>
          d['userModified'] == true ||
          (d['commands'] as List? ?? []).any(
            (c) => c['pinned'] == true || c['userRenamed'] == true,
          ),
    );
    if (overwrite &&
        (!await _confirm(tr("重新分析项目？"), tr("将重新生成运行配置，覆盖未固定的自定义修改，固定项会保留。")) ||
            !mounted)) {
      return;
    }
    if (!mounted) return;
    final agent = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (d) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(tr("选择分析项目的 Agent"))),
            for (final e in tool.host.executors)
              ListTile(
                title: Text(agentLabel(e['providerId'] as String?)),
                onTap: () => Navigator.pop(d, Map<String, dynamic>.from(e)),
              ),
            if (tool.host.executors.isEmpty)
              ListTile(title: Text(tr("没有可用 Agent，请先在电脑上连接。"))),
          ],
        ),
      ),
    );
    if (agent == null || !mounted || busy || !tool.host.online) return;
    setState(() => busy = true);
    try {
      await tool.host.operations.runAnalyze(
        link,
        taskId: task,
        generation: '$generation',
        executor: agent,
        overwrite: overwrite,
      );
      if (mounted) await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      await workspaceHub?.refreshOperation(tool.host);
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _askPort() async {
    var portText = port?.toString() ?? '';
    final value = await showDialog<int>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr("预览端口")),
        content: TextFormField(
          initialValue: portText,
          onChanged: (value) => portText = value,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: tr("例如 5173")),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(tr("取消"))),
          TextButton(
            onPressed: () => Navigator.pop(d, int.tryParse(portText.trim())),
            child: Text(tr("打开")),
          ),
        ],
      ),
    );
    if (value != null && mounted) _preview(value);
  }

  void _preview(int p) {
    final task = tool.taskId, link = tool.link;
    if (task == null || link == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PreviewPage(link: link, taskId: task, port: p),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final sel = selected;
    final active = running != null;
    final directory = directoryIndex == null
        ? null
        : directories[directoryIndex!];
    return Scaffold(
      appBar: DetailBar(
        title: tr("运行与预览"),
        subtitle: '${tool.host.placeName(tool.project)} · ${tool.projectName}',
      ),
      body: !tool.host.online || tool.taskId == null
          ? ToolUnavailable(tool: tool)
          : loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                WorkspaceDirectoryPicker<int>(
                  tooltip: tr("选择运行目录"),
                  directories: [
                    for (final (i, d) in directories.indexed)
                      (value: i, path: '${d['path']}'),
                  ],
                  value: directoryIndex,
                  onChanged: busy ? null : _selectDirectory,
                ),
                WorkspaceRecoveryCards(
                  host: tool.host,
                  projectId: tool.projectId,
                  onRecovered: () => _load(),
                ),
                if (error != null) InlineNotice(error!, danger: true),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: busy || catalog == null ? null : _analyze,
                      icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                      label: Text(tr("分析项目")),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: tr("刷新运行配置"),
                      onPressed: busy ? null : _load,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                if (directory?['status'] == 'analyzing')
                  InlineNotice(tr("Agent 正在分析项目，可稍后刷新查看。")),
                if (directory?['error'] != null)
                  InlineNotice('${directory!['error']}', danger: true),
                if (commands.isEmpty)
                  InlineNotice(
                    directories.isEmpty
                        ? tr("这个项目尚未关联目录。")
                        : tr("当前目录还没有运行配置，点击「分析项目」生成启动方式。"),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(DcSpace.page, 4, 12, 4),
                    child: Row(
                      children: [
                        const Icon(Icons.play_circle_outline, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: PopupMenuButton<({int dir, String id})>(
                            enabled: !busy,
                            tooltip: tr("选择运行配置"),
                            onSelected: (value) {
                              setState(() {
                                commandId = value.id;
                                directoryIndex = value.dir;
                              });
                              _attach();
                            },
                            itemBuilder: (_) => [
                              for (final x in commands)
                                PopupMenuItem(
                                  value: (
                                    dir: x.dir,
                                    id: x.cmd['id'] as String,
                                  ),
                                  child: Text('${x.cmd['label']}'),
                                ),
                            ],
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    '${sel?.cmd['label'] ?? tr("选择配置")}',
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                                const Icon(Icons.expand_more, size: 18),
                              ],
                            ),
                          ),
                        ),
                        StatusLabel(
                          active ? tr("运行中") : tr("未运行"),
                          tone: active ? Tone.accent : Tone.muted,
                        ),
                        if (sel != null)
                          PopupMenuButton<String>(
                            tooltip: tr("管理运行配置"),
                            enabled: !busy,
                            onSelected: _edit,
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'rename',
                                child: Text(tr("重命名")),
                              ),
                              PopupMenuItem(
                                value: 'pin',
                                child: Text(
                                  sel.cmd['pinned'] == true
                                      ? tr("取消固定")
                                      : tr("固定配置"),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text(tr("删除配置")),
                              ),
                            ],
                          ),
                        IconButton(
                          tooltip: active ? tr("停止") : tr("启动"),
                          onPressed: busy || sel == null
                              ? null
                              : (active ? _stop : _start),
                          icon: Icon(
                            active
                                ? Icons.stop_rounded
                                : Icons.play_arrow_rounded,
                          ),
                        ),
                        if (active)
                          IconButton(
                            tooltip: tr("重启"),
                            onPressed: busy ? null : _restart,
                            icon: const Icon(Icons.restart_alt),
                          ),
                      ],
                    ),
                  ),
                if (sel != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: DcSpace.page,
                    ),
                    child: Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Field(tr("启动命令"), '${sel.cmd['command']}'),
                          _Field(
                            tr("项目目录"),
                            '${((catalog!['directories'] as List)[sel.dir] as Map)['path']}',
                          ),
                        ],
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(DcSpace.page, 10, 12, 4),
                  // Narrow phones and long translations put the buttons on
                  // their own line instead of overflowing.
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Text(
                        tr("项目预览"),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (port != null)
                            FilledButton.icon(
                              onPressed: () => _preview(port!),
                              icon: const Icon(Icons.open_in_browser, size: 18),
                              label: Text(tr("打开 localhost:{0}", [port])),
                            ),
                          TextButton(
                            onPressed: _askPort,
                            child: Text(port == null ? tr("指定端口") : tr("其他端口")),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    DcSpace.page,
                    6,
                    DcSpace.page,
                    6,
                  ),
                  child: Row(
                    children: [
                      Text(
                        tr("输出"),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(width: 8),
                      if (session != null)
                        ValueListenableBuilder(
                          valueListenable: session!.info,
                          builder: (_, info, _) => Text(
                            terminalStatus(info),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: session == null
                      ? Center(
                          child: Text(
                            tr("尚未运行过此配置"),
                            style: TextStyle(color: c.secondary),
                          ),
                        )
                      : TerminalPane(
                          key: ValueKey(session!.id),
                          session: session!,
                          keys: false,
                        ),
                ),
                const SizedBox(height: 8),
              ],
            ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 68,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontFamily: monoFamily,
                fontFamilyFallback: monoFallback,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
