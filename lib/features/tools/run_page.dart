import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/pc_api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'preview_page.dart';
import 'terminal_pane.dart';
import 'tool_context.dart';

/// 09 运行与预览: project run configurations shared with the PC, start/stop,
/// output, and an in-app preview of the dev server.
class RunPage extends StatefulWidget {
  const RunPage({super.key, required this.tool});
  final ToolContext tool;
  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> {
  Map<String, dynamic>? catalog;
  List<Map<String, dynamic>> runs = [];
  String? commandId;
  TerminalSession? session;
  bool loading = true, busy = false;
  String? error;
  int? port;
  Timer? _portScan;

  ToolContext get tool => widget.tool;

  List<({int dir, Map<String, dynamic> cmd})> get commands => [
    for (final (i, d)
        in ((catalog?['directories'] as List?) ?? const []).indexed)
      for (final c in ((d as Map)['commands'] as List? ?? const []))
        (dir: i, cmd: Map<String, dynamic>.from(c as Map)),
  ];
  ({int dir, Map<String, dynamic> cmd})? get selected =>
      commands.where((c) => c.cmd['id'] == commandId).firstOrNull;
  Map<String, dynamic>? get running => runs
      .where((r) => r['commandId'] == commandId && terminalActive(r))
      .firstOrNull;

  @override
  void initState() {
    super.initState();
    _load();
    _portScan = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _detectPort(),
    );
  }

  @override
  void dispose() {
    _portScan?.cancel();
    session?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final link = tool.link, task = tool.taskId;
    if (link == null || task == null) return setState(() => loading = false);
    try {
      final results = await Future.wait([
        link.projectRuns(task),
        link.terminals(tool.projectId),
      ]);
      if (!mounted) return;
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
        commandId ??=
            runs.where(terminalActive).firstOrNull?['commandId'] as String? ??
            commands
                    .where((c) => c.cmd['pinned'] == true)
                    .firstOrNull
                    ?.cmd['id']
                as String? ??
            commands.firstOrNull?.cmd['id'] as String?;
      });
      _attach();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  /// Shows the latest run of the selected command (running or finished).
  void _attach() {
    final link = tool.link;
    final latest = runs.where((r) => r['commandId'] == commandId).firstOrNull;
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
    if (link == null || task == null || sel == null) return;
    setState(() => busy = true);
    try {
      await link.projectRunStart(
        taskId: task,
        generation: '${catalog!['generation']}',
        directoryIndex: sel.dir,
        commandId: sel.cmd['id'] as String,
      );
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _stop() async {
    final r = running;
    if (r == null) return;
    setState(() => busy = true);
    try {
      await tool.link?.terminalStop(r['id'] as String);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _restart() async {
    await _stop();
    await _start();
  }

  Future<void> _askPort() async {
    final controller = TextEditingController(text: port?.toString() ?? '');
    final value = await showDialog<int>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('预览端口'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '例如 5173'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(d, int.tryParse(controller.text.trim())),
            child: const Text('打开'),
          ),
        ],
      ),
    );
    controller.dispose();
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
    final c = context.dc;
    final sel = selected;
    final active = running != null;
    return Scaffold(
      appBar: DetailBar(
        title: '运行与预览',
        subtitle: '${tool.host.name} · ${tool.projectName}',
      ),
      body: tool.link == null || tool.taskId == null
          ? ToolUnavailable(tool: tool)
          : loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (error != null) InlineNotice(error!, danger: true),
                if (commands.isEmpty)
                  const InlineNotice('这个项目还没有运行配置。可在电脑上分析项目或添加运行方式。')
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(DcSpace.page, 4, 12, 4),
                    child: Row(
                      children: [
                        const Icon(Icons.play_circle_outline, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: PopupMenuButton<String>(
                            tooltip: '选择运行配置',
                            onSelected: (id) {
                              commandId = id;
                              _attach();
                            },
                            itemBuilder: (_) => [
                              for (final x in commands)
                                PopupMenuItem(
                                  value: x.cmd['id'] as String,
                                  child: Text('${x.cmd['label']}'),
                                ),
                            ],
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    '${sel?.cmd['label'] ?? '选择配置'}',
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
                          active ? '运行中' : '未运行',
                          tone: active ? Tone.accent : Tone.muted,
                        ),
                        IconButton(
                          tooltip: active ? '停止' : '启动',
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
                            tooltip: '重启',
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
                          _Field('启动命令', '${sel.cmd['command']}'),
                          _Field(
                            '项目目录',
                            '${((catalog!['directories'] as List)[sel.dir] as Map)['path']}',
                          ),
                        ],
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(DcSpace.page, 10, 12, 4),
                  child: Row(
                    children: [
                      Text(
                        '项目预览',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      if (port != null)
                        FilledButton.icon(
                          onPressed: () => _preview(port!),
                          icon: const Icon(Icons.open_in_browser, size: 18),
                          label: Text('打开 localhost:$port'),
                        ),
                      TextButton(
                        onPressed: _askPort,
                        child: Text(port == null ? '指定端口' : '其他端口'),
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
                        '输出',
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
                            '尚未运行过此配置',
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
  Widget build(BuildContext context) => Padding(
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
