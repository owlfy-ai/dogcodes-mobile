import 'package:flutter/material.dart';
import '../../core/pc_api.dart';
import '../../core/secure_host_client.dart' show RemoteOutcomeUnknown;
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../conversation/agent_picker.dart' show defaultExecutor;
import 'line_diff.dart';
import 'tool_context.dart';

/// 06 变更: Git changes of the project, single-column diff, stage/unstage and
/// commit / commit & push. Every Git write carries an operation ID; a lost
/// reply is checked against the PC's receipt, never re-sent blindly.
class ChangesPage extends StatefulWidget {
  const ChangesPage({super.key, required this.tool});
  final ToolContext tool;
  @override
  State<ChangesPage> createState() => _ChangesPageState();
}

const _modes = {'uncommitted': '未提交变更', 'staged': '已暂存', 'unstaged': '未暂存'};

class _ChangesPageState extends State<ChangesPage> {
  final message = TextEditingController();
  String mode = 'uncommitted';
  Map<String, dynamic>? snapshot;
  Map<String, dynamic>? workspace;
  int staged = 0;
  final selected = <String>{};
  String? expanded;
  bool loading = true, busy = false;
  String? error;

  ToolContext get tool => widget.tool;
  Map<String, dynamic>? get root =>
      (snapshot?['roots'] as List?)?.isNotEmpty == true
      ? Map<String, dynamic>.from((snapshot!['roots'] as List).first as Map)
      : null;
  String? get rootId => (root?['root'] as Map?)?['id'] as String?;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    message.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final link = tool.link, task = tool.taskId;
    if (link == null || task == null) return setState(() => loading = false);
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final results = await Future.wait([
        link.changes(task, mode: mode),
        link.changes(task, mode: 'staged'),
        link.gitWorkspaces(task),
      ]);
      final stagedSnap = results[1] as Map<String, dynamic>;
      final ws = results[2] as List<Map<String, dynamic>>;
      if (!mounted) return;
      setState(() {
        snapshot = results[0] as Map<String, dynamic>;
        staged =
            ((stagedSnap['roots'] as List?)?.firstOrNull as Map?)?['files']
                ?.length ??
            0;
        workspace =
            ws.where((w) => w['current'] == true).firstOrNull ?? ws.firstOrNull;
        selected.clear();
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  List<Map<String, dynamic>> get files => [
    for (final f in (root?['files'] as List? ?? const []))
      Map<String, dynamic>.from(f as Map),
  ];

  Future<void> _stage({required bool unstage}) async {
    final link = tool.link, task = tool.taskId, id = rootId;
    if (link == null || task == null || id == null || selected.isEmpty) return;
    setState(() => busy = true);
    try {
      await link.stage(
        task,
        snapshot!['id'] as String,
        id,
        selected.toList(),
        unstage: unstage,
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => busy = false);
    await _load();
  }

  Future<void> _commit({required bool push}) async {
    final link = tool.link, task = tool.taskId, id = rootId;
    final text = message.text.trim();
    if (link == null || task == null || id == null) return;
    if (text.isEmpty) return showError(context, '请填写提交说明');
    var stageAll = false;
    if (staged == 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('暂存全部并提交？'),
          content: Text('当前没有已暂存的文件，将暂存全部 ${files.length} 个变更后提交。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('暂存并提交'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      stageAll = true;
    }
    setState(() => busy = true);
    String? opId;
    try {
      final result = await link.commit(
        taskId: task,
        rootId: id,
        snapshotId: snapshot!['id'] as String,
        message: text,
        stageAll: stageAll,
        push: push,
      );
      opId = result.operationId;
      if (push && result.completed) await link.gitAdvance(task, opId);
      message.clear();
      if (mounted) showError(context, push ? '已提交并推送' : '已提交');
    } on RemoteOutcomeUnknown {
      final receipt = opId == null ? null : await _receipt(task, opId);
      if (mounted) showError(context, receipt ?? 'Git 操作结果待核实，请刷新查看，不要重复提交');
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => busy = false);
    await _load();
  }

  Future<String?> _receipt(String task, String opId) async {
    try {
      final r = await tool.link!.gitReceipt(task, opId);
      final outcome = (r as Map?)?['outcome'] as Map?;
      return switch (outcome?['status']) {
        'succeeded' => '电脑已完成该 Git 操作',
        'failed' => '电脑执行失败：${outcome?['message']}',
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> _summary() async {
    final link = tool.link, task = tool.taskId, id = rootId;
    final executor = defaultExecutor(tool.host, tool.host.task(task));
    if (link == null || task == null || id == null || executor == null) return;
    setState(() => busy = true);
    try {
      message.text = (await link.commitSummary(task, id, executor)).trim();
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _plain(String action) async {
    final link = tool.link, task = tool.taskId, id = rootId;
    if (link == null || task == null || id == null) return;
    setState(() => busy = true);
    try {
      await link.gitPlain(task, id, action);
      if (mounted) showError(context, '已完成');
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final stats = Map<String, dynamic>.from(root?['statistics'] as Map? ?? {});
    final untracked = {
      for (final u in (root?['untracked'] as List? ?? const [])) '$u',
    };
    return Scaffold(
      appBar: DetailBar(
        title: '变更',
        subtitle: tool.subtitle,
        actions: [
          PopupMenuButton<String>(
            tooltip: '更多 Git 操作',
            enabled: !busy && rootId != null,
            onSelected: _plain,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'push', child: Text('推送')),
              PopupMenuItem(value: 'pull', child: Text('拉取')),
              PopupMenuItem(value: 'sync', child: Text('同步')),
            ],
          ),
        ],
      ),
      body: tool.link == null || tool.taskId == null
          ? ToolUnavailable(tool: tool)
          : Column(
              children: [
                if (busy) const LinearProgressIndicator(minHeight: 2),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    DcSpace.page,
                    4,
                    DcSpace.page,
                    4,
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.call_split, size: 18),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '${workspace?['branch'] ?? (workspace?['git'] == false ? '非 Git 目录' : '—')}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Spacer(),
                      PopupMenuButton<String>(
                        tooltip: '比较范围',
                        initialValue: mode,
                        onSelected: (m) => setState(() {
                          mode = m;
                          expanded = null;
                          _load();
                        }),
                        itemBuilder: (_) => [
                          for (final e in _modes.entries)
                            PopupMenuItem(value: e.key, child: Text(e.value)),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _modes[mode]!,
                                style: const TextStyle(fontSize: 14),
                              ),
                              const Icon(Icons.expand_more, size: 18),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: DcSpace.page),
                  child: Row(
                    children: [
                      Text(
                        '${files.length} 个文件 · 已暂存 $staged',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const Spacer(),
                      if (selected.isNotEmpty) ...[
                        TextButton(
                          onPressed: busy ? null : () => _stage(unstage: true),
                          child: const Text('取消暂存'),
                        ),
                        TextButton(
                          onPressed: busy ? null : () => _stage(unstage: false),
                          child: const Text('暂存'),
                        ),
                      ],
                    ],
                  ),
                ),
                if (error != null) InlineNotice(error!, danger: true),
                if ((root?['error'] as String?) != null)
                  InlineNotice('${root!['error']}', danger: true),
                Expanded(
                  child: loading && snapshot == null
                      ? const Center(child: CircularProgressIndicator())
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: files.isEmpty
                              ? ListView(
                                  children: const [
                                    Padding(
                                      padding: EdgeInsets.all(40),
                                      child: Center(child: Text('没有变更')),
                                    ),
                                  ],
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.fromLTRB(
                                    DcSpace.page,
                                    4,
                                    DcSpace.page,
                                    12,
                                  ),
                                  itemCount: files.length,
                                  itemBuilder: (_, i) {
                                    final f = files[i];
                                    final p = '${f['path']}';
                                    return _ChangedFile(
                                      file: f,
                                      stats: stats[p] as Map?,
                                      untracked: untracked.contains(p),
                                      selected: selected.contains(p),
                                      open: expanded == p,
                                      onSelect: (v) => setState(
                                        () => v
                                            ? selected.add(p)
                                            : selected.remove(p),
                                      ),
                                      onToggle: () => setState(
                                        () =>
                                            expanded = expanded == p ? null : p,
                                      ),
                                      tool: tool,
                                      snapshotId: snapshot!['id'] as String,
                                      rootId: rootId!,
                                    );
                                  },
                                ),
                        ),
                ),
                SafeArea(
                  top: false,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(
                      DcSpace.page,
                      8,
                      DcSpace.page,
                      8,
                    ),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: c.line)),
                    ),
                    child: Column(
                      children: [
                        TextField(
                          controller: message,
                          minLines: 1,
                          maxLines: 4,
                          decoration: InputDecoration(
                            hintText: '提交说明',
                            suffixIcon: IconButton(
                              tooltip: 'AI 生成提交说明',
                              onPressed: busy || files.isEmpty
                                  ? null
                                  : _summary,
                              icon: const Icon(Icons.auto_awesome_outlined),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: busy || files.isEmpty
                                    ? null
                                    : () => _commit(push: false),
                                child: const Text('提交'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton(
                                onPressed: busy || files.isEmpty
                                    ? null
                                    : () => _commit(push: true),
                                child: const Text('提交并推送'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ChangedFile extends StatefulWidget {
  const _ChangedFile({
    required this.file,
    required this.stats,
    required this.untracked,
    required this.selected,
    required this.open,
    required this.onSelect,
    required this.onToggle,
    required this.tool,
    required this.snapshotId,
    required this.rootId,
  });
  final Map<String, dynamic> file;
  final Map? stats;
  final bool untracked, selected, open;
  final ValueChanged<bool> onSelect;
  final VoidCallback onToggle;
  final ToolContext tool;
  final String snapshotId, rootId;
  @override
  State<_ChangedFile> createState() => _ChangedFileState();
}

class _ChangedFileState extends State<_ChangedFile> {
  List<DiffLine>? diff;
  String? note;

  @override
  void didUpdateWidget(_ChangedFile old) {
    super.didUpdateWidget(old);
    if (widget.open && diff == null && note == null) _loadDiff();
  }

  Future<void> _loadDiff() async {
    final link = widget.tool.link, task = widget.tool.taskId;
    if (link == null || task == null) return;
    try {
      final r = await link.changedFile(
        task,
        widget.snapshotId,
        widget.rootId,
        '${widget.file['path']}',
      );
      if (r['binary'] == true) {
        note = '二进制文件，无法显示差异';
      } else {
        final text = r['text'] as Map?;
        List<String> lines(Object? v) => [
          for (final l in (v as List? ?? const [])) '$l',
        ];
        diff = hunks(diffLines(lines(text?['before']), lines(text?['after'])));
      }
    } catch (e) {
      note = '$e';
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final f = widget.file;
    final path = '${f['path']}';
    final name = path.split('/').last;
    final dir = path.contains('/')
        ? path.substring(0, path.lastIndexOf('/'))
        : '';
    final kind = widget.untracked ? 'untracked' : '${f['kind']}';
    final (label, color) = switch (kind) {
      'added' || 'untracked' => (kind == 'untracked' ? 'U' : 'A', c.added),
      'deleted' => ('D', c.removed),
      'renamed' => ('R', c.secondary),
      _ => ('M', c.warning),
    };
    final adds = widget.stats?['additions'], dels = widget.stats?['deletions'];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(DcSpace.control),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: widget.onToggle,
            onLongPress: () => widget.onSelect(!widget.selected),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                children: [
                  Checkbox(
                    value: widget.selected,
                    activeColor: c.accent,
                    checkColor: c.onAccent,
                    onChanged: (v) => widget.onSelect(v == true),
                  ),
                  Container(
                    width: 18,
                    alignment: Alignment.center,
                    child: Text(
                      label,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                        ),
                        if (dir.isNotEmpty)
                          Text(
                            dir,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  if (adds is num)
                    Text(
                      '+$adds',
                      style: TextStyle(color: c.added, fontSize: 12),
                    ),
                  if (dels is num) ...[
                    const SizedBox(width: 6),
                    Text(
                      '−$dels',
                      style: TextStyle(color: c.removed, fontSize: 12),
                    ),
                  ],
                  Icon(
                    widget.open ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: c.secondary,
                  ),
                ],
              ),
            ),
          ),
          if (widget.open)
            diff != null
                ? UnifiedDiff(lines: diff!)
                : Padding(
                    padding: const EdgeInsets.all(12),
                    child: note != null
                        ? Text(
                            note!,
                            style: Theme.of(context).textTheme.bodySmall,
                          )
                        : const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                  ),
        ],
      ),
    );
  }
}

/// Single-column diff with old/new line numbers; scrolls horizontally.
class UnifiedDiff extends StatelessWidget {
  const UnifiedDiff({super.key, required this.lines});
  final List<DiffLine> lines;
  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    if (lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          '内容无差异（可能仅权限或换行变化）',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    const style = TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
      fontSize: 12,
      height: 1.5,
    );
    final shown = lines.take(1500).toList();
    return Container(
      color: c.code,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final l in shown)
              Container(
                color: l.kind == '+'
                    ? c.added.withValues(alpha: 0.12)
                    : l.kind == '-'
                    ? c.removed.withValues(alpha: 0.12)
                    : null,
                padding: const EdgeInsets.only(right: 16),
                child: Row(
                  children: [
                    SizedBox(
                      width: 72,
                      child: Text(
                        l.kind == '@'
                            ? ''
                            : '${l.oldNo ?? ''}'.padLeft(4) +
                                  ' ${l.newNo ?? ''}'.padLeft(5),
                        style: style.copyWith(color: c.secondary),
                      ),
                    ),
                    Text(
                      l.kind == '@' ? '  ⋯' : '${l.kind} ${l.text}',
                      style: style.copyWith(
                        color: l.kind == '+'
                            ? c.added
                            : l.kind == '-'
                            ? c.removed
                            : l.kind == '@'
                            ? c.secondary
                            : c.text,
                      ),
                    ),
                  ],
                ),
              ),
            if (lines.length > shown.length)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('… 差异过长，已截断'),
              ),
          ],
        ),
      ),
    );
  }
}
