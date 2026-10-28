import 'package:flutter/material.dart';
import '../../core/pc_api.dart';
import '../../core/host_hub.dart';
import '../../app.dart';
import '../../core/mobile_operations.dart';
import '../inbox/pending_operation.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../conversation/agent_picker.dart' show defaultExecutor;
import 'line_diff.dart';
import 'tool_context.dart';
import 'workspace_connection.dart';
import 'git_reference_picker.dart';

/// 06 变更: Git changes of the project, single-column diff, stage/unstage and
/// commit / commit & push. Every Git write carries an operation ID; a lost
/// reply is checked against the PC's receipt, never re-sent blindly.
class ChangesPage extends StatefulWidget {
  const ChangesPage({super.key, required this.tool});
  final ToolContext tool;
  @override
  State<ChangesPage> createState() => _ChangesPageState();
}

const _modes = {
  'uncommitted': '未提交变更',
  'staged': '已暂存',
  'unstaged': '未暂存',
  'committed': '历史提交',
  'branch': '分支比较',
};

class _ChangesPageState extends State<ChangesPage>
    with WorkspaceConnection<ChangesPage> {
  @override
  HostState get workspaceHost => tool.host;
  int _loadOrder = 0;
  @override
  void onWorkspaceConnectionChanged() {
    _loadOrder++;
    snapshot = null;
    stagedSnapshot = null;
    workspace = null;
    selected.clear();
    expanded = null;
    error = null;
    loading = false;
    if (tool.host.online) _load();
  }

  final message = TextEditingController();
  String mode = 'uncommitted';
  GitReference? reference;
  int parent = 0;
  bool choosingReference = false;
  bool get historical => mode == 'committed' || mode == 'branch';
  Map<String, dynamic>? snapshot;
  Map<String, dynamic>? stagedSnapshot;
  Map<String, dynamic>? workspace;
  String? selectedRootId;
  final _messages = <String, String>{};
  final selected = <String>{};
  String? expanded;
  bool loading = true, busy = false;
  String? error;

  ToolContext get tool => widget.tool;
  List<Map<String, dynamic>> get roots => [
    for (final value
        in (((historical ? stagedSnapshot : snapshot) ??
                    stagedSnapshot)?['roots']
                as List? ??
            const []))
      Map<String, dynamic>.from(value as Map),
  ];
  Map<String, dynamic>? get root => [
    for (final value in (snapshot?['roots'] as List? ?? const []))
      Map<String, dynamic>.from(value as Map),
  ].where((r) => (r['root'] as Map?)?['id'] == selectedRootId).firstOrNull;
  String? get rootId =>
      roots.any((r) => (r['root'] as Map?)?['id'] == selectedRootId)
      ? selectedRootId
      : null;
  bool get selectedGit => roots.any(
    (r) =>
        (r['root'] as Map?)?['id'] == rootId &&
        (r['root'] as Map?)?['git'] == true,
  );
  bool get canGit =>
      !historical &&
      !loading &&
      error == null &&
      (root?['root'] as Map?)?['git'] == true &&
      root?['error'] == null;
  String rootName(Map value) {
    final path = (value['root'] as Map?)?['path'] as String? ?? '';
    return path
            .split(RegExp(r'[\\/]'))
            .where((part) => part.isNotEmpty)
            .lastOrNull ??
        '目录';
  }

  int get staged =>
      ((stagedSnapshot?['roots'] as List? ?? const [])
                  .where((r) => (r['root'] as Map?)?['id'] == rootId)
                  .firstOrNull?['files']
              as List?)
          ?.length ??
      0;
  void _selectRoot(String? id) {
    if (selectedRootId == id) return;
    if (selectedRootId != null) {
      _messages[selectedRootId!] = message.text;
      message.text = id == null ? '' : _messages[id] ?? '';
    }
    selectedRootId = id;
    selected.clear();
    expanded = null;
  }

  Future<void> _chooseMode(String next) async {
    if (busy || loading || choosingReference) return;
    final isHistory = next == 'committed' || next == 'branch';
    GitReference? picked;
    if (isHistory) {
      final link = tool.link, task = tool.taskId, id = rootId;
      final epoch = tool.host.connectionEpoch, order = _loadOrder;
      if (link == null || task == null || id == null || !selectedGit) return;
      setState(() => choosingReference = true);
      picked = await showModalBottomSheet<GitReference>(
        context: context,
        isScrollControlled: true,
        builder: (_) => GitReferencePicker(
          api: link,
          host: tool.host,
          taskId: task,
          rootId: id,
          commits: next == 'committed',
        ),
      );
      if (!mounted) return;
      setState(() => choosingReference = false);
      if (picked == null) return;
      if (link != tool.link ||
          epoch != tool.host.connectionEpoch ||
          !tool.host.online ||
          task != tool.taskId ||
          id != rootId ||
          order != _loadOrder) {
        showError(context, '连接或目录已改变，请重新选择比较目标。');
        return;
      }
    }
    setState(() {
      mode = next;
      reference = picked;
      parent = 0;
      expanded = null;
      snapshot = null;
      selected.clear();
    });
    await _load();
  }

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
    final order = ++_loadOrder, epoch = tool.host.connectionEpoch;
    bool current() =>
        mounted &&
        order == _loadOrder &&
        epoch == tool.host.connectionEpoch &&
        link == tool.link &&
        task == tool.taskId;
    if (link == null || task == null || !tool.host.online) {
      return setState(() => loading = false);
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final results = await Future.wait([
        link.changes(
          task,
          mode: mode,
          rootId: historical ? selectedRootId : null,
          reference: historical ? reference?.id : null,
          parent: historical ? parent : null,
        ),
        link.changes(task, mode: 'staged'),
        link.gitWorkspaces(task),
      ]);
      final stagedSnap = results[1] as Map<String, dynamic>;
      final ws = results[2] as List<Map<String, dynamic>>;
      if (!current()) return;
      setState(() {
        snapshot = results[0] as Map<String, dynamic>;
        stagedSnapshot = stagedSnap;
        if (rootId == null) {
          final next =
              roots
                  .where((r) => (r['root'] as Map?)?['git'] == true)
                  .firstOrNull ??
              roots.firstOrNull;
          _selectRoot((next?['root'] as Map?)?['id'] as String?);
        }
        workspace =
            ws.where((w) => w['current'] == true).firstOrNull ?? ws.firstOrNull;
        selected.clear();
      });
    } catch (e) {
      if (current()) setState(() => error = '$e');
    } finally {
      if (current()) setState(() => loading = false);
    }
  }

  List<Map<String, dynamic>> get files => [
    for (final f in (root?['files'] as List? ?? const []))
      Map<String, dynamic>.from(f as Map),
  ];

  Future<void> _stage({required bool unstage}) async {
    final link = tool.link, task = tool.taskId, id = rootId;
    if (link == null ||
        task == null ||
        id == null ||
        selected.isEmpty ||
        !canGit ||
        busy ||
        !tool.host.online) {
      return;
    }
    setState(() => busy = true);
    try {
      await tool.host.operations.indexWrite(
        link,
        taskId: task,
        snapshotId: snapshot!['id'] as String,
        rootId: id,
        paths: selected.toList(),
        unstage: unstage,
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) await AppScope.of(context).hub.refreshOperation(tool.host);
    if (mounted) setState(() => busy = false);
    if (mounted) await _load();
  }

  Future<void> _commit({required bool push}) async {
    final link = tool.link, task = tool.taskId, id = rootId;
    final epoch = tool.host.connectionEpoch;
    final snapshotId = snapshot?['id'] as String?;
    final text = message.text.trim();
    if (link == null ||
        task == null ||
        id == null ||
        snapshotId == null ||
        !canGit ||
        busy ||
        !tool.host.online) {
      return;
    }
    if (text.isEmpty) return showError(context, '请填写提交说明');
    var stageAll = false;
    if (staged == 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('暂存全部并提交？'),
          content: Text(
            '${roots.length > 1 ? '目录：${rootName(root!)}。' : ''}当前没有已暂存的文件，将暂存全部 ${files.length} 个变更后提交。',
          ),
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
    if (!mounted) return;
    if (link != tool.link ||
        epoch != tool.host.connectionEpoch ||
        !tool.host.online ||
        id != rootId ||
        snapshotId != snapshot?['id']) {
      showError(context, '连接或变更已更新，请核对后重新提交。');
      return;
    }
    setState(() => busy = true);
    final hub = AppScope.of(context).hub;
    try {
      final result = await tool.host.operations.gitWrite(
        link,
        taskId: task,
        rootId: id,
        action: 'commit',
        snapshotId: snapshotId,
        message: text,
        stageAll: stageAll,
        push: push,
      );
      if (mounted) {
        if (result?['state'] == 'succeeded' && message.text.trim() == text) {
          message.clear();
        }
        showError(
          context,
          result == null ? 'Git 操作结果待核实' : gitResultMessage(result),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      await hub.refreshOperation(tool.host);
      if (mounted) setState(() => busy = false);
    }
    if (mounted) await _load();
  }

  Future<void> _summary() async {
    final link = tool.link, task = tool.taskId, id = rootId;
    final epoch = tool.host.connectionEpoch, previous = message.text;
    final snapshotId = snapshot?['id'];
    final executor = defaultExecutor(tool.host, tool.host.task(task));
    if (link == null ||
        task == null ||
        id == null ||
        executor == null ||
        !canGit ||
        busy ||
        !tool.host.online) {
      return;
    }
    setState(() => busy = true);
    try {
      final summary = (await link.commitSummary(task, id, executor)).trim();
      if (mounted &&
          link == tool.link &&
          epoch == tool.host.connectionEpoch &&
          id == rootId &&
          snapshotId == snapshot?['id'] &&
          previous == message.text) {
        message.text = summary;
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _plain(String action) async {
    final link = tool.link, task = tool.taskId, id = rootId;
    if (link == null ||
        task == null ||
        id == null ||
        !canGit ||
        busy ||
        !tool.host.online) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    final hub = AppScope.of(context).hub;
    try {
      final result = await tool.host.operations.gitWrite(
        link,
        taskId: task,
        rootId: id,
        action: action,
      );
      if (mounted) {
        showError(
          context,
          result == null ? 'Git 操作结果待核实' : gitResultMessage(result),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      await hub.refreshOperation(tool.host);
      if (mounted) setState(() => busy = false);
    }
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final directory = roots
        .where((r) => (r['root'] as Map?)?['id'] == rootId)
        .firstOrNull;
    final stats = Map<String, dynamic>.from(root?['statistics'] as Map? ?? {});
    final untracked = {
      for (final u in (root?['untracked'] as List? ?? const [])) '$u',
    };
    return Scaffold(
      appBar: DetailBar(
        title: '变更',
        subtitle: tool.subtitle,
        actions: [
          if (roots.length > 1)
            PopupMenuButton<String>(
              tooltip: '选择 Git 目录',
              enabled: !busy && !loading && !choosingReference,
              icon: const Icon(Icons.folder_copy_outlined),
              onSelected: (id) {
                if (roots.any((r) => (r['root'] as Map?)?['id'] == id)) {
                  final reset = historical && id != rootId;
                  setState(() {
                    _selectRoot(id);
                    if (reset) {
                      mode = 'uncommitted';
                      reference = null;
                      parent = 0;
                      snapshot = null;
                    }
                  });
                  if (reset) _load();
                }
              },
              itemBuilder: (_) => [
                for (final value in roots)
                  CheckedPopupMenuItem(
                    value: (value['root'] as Map)['id'] as String,
                    checked: (value['root'] as Map)['id'] == rootId,
                    child: Text(
                      '${(value['root'] as Map)['path']}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          PopupMenuButton<String>(
            tooltip: '更多 Git 操作',
            enabled: !busy && tool.host.online && canGit,
            onSelected: _plain,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'push', child: Text('推送')),
              PopupMenuItem(value: 'pull', child: Text('拉取')),
              PopupMenuItem(value: 'sync', child: Text('同步')),
            ],
          ),
        ],
      ),
      body: !tool.host.online || tool.taskId == null
          ? ToolUnavailable(tool: tool)
          : Column(
              children: [
                if (busy) const LinearProgressIndicator(minHeight: 2),
                if (tool.host.sideOperation != null)
                  Padding(
                    padding: const EdgeInsets.all(DcSpace.page),
                    child: PendingOperationCard(
                      host: tool.host,
                      operation: tool.host.sideOperation,
                    ),
                  ),
                if (tool.host.pendingOperation != null)
                  Padding(
                    padding: const EdgeInsets.all(DcSpace.page),
                    child: PendingOperationCard(host: tool.host),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    DcSpace.page,
                    4,
                    DcSpace.page,
                    4,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        roots.length > 1
                            ? Icons.folder_outlined
                            : Icons.call_split,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          roots.length > 1 && directory != null
                              ? rootName(directory)
                              : '${workspace?['branch'] ?? (workspace?['git'] == false ? '非 Git 目录' : '—')}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Spacer(),
                      PopupMenuButton<String>(
                        tooltip: '比较范围',
                        initialValue: mode,
                        enabled: !busy && !loading && !choosingReference,
                        onSelected: _chooseMode,
                        itemBuilder: (_) => [
                          for (final e in _modes.entries)
                            PopupMenuItem(
                              value: e.key,
                              enabled:
                                  (e.key != 'committed' && e.key != 'branch') ||
                                  selectedGit,
                              child: Text(e.value),
                            ),
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
                if (historical)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: DcSpace.page,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            OutlinedButton.icon(
                              onPressed: busy || loading || choosingReference
                                  ? null
                                  : () => _chooseMode(mode),
                              icon: const Icon(Icons.history, size: 16),
                              label: Text(
                                reference?.label ?? '选择比较目标',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (mode == 'committed' &&
                                (reference?.parents.length ?? 0) > 1)
                              PopupMenuButton<int>(
                                tooltip: '选择父提交',
                                enabled: !loading && !choosingReference,
                                onSelected: (value) {
                                  setState(() {
                                    parent = value;
                                    snapshot = null;
                                    expanded = null;
                                  });
                                  _load();
                                },
                                itemBuilder: (_) => [
                                  for (
                                    var i = 0;
                                    i < reference!.parents.length;
                                    i++
                                  )
                                    PopupMenuItem(
                                      value: i,
                                      child: Text(
                                        '父提交 ${i + 1} · ${shortCommit(reference!.parents[i])}',
                                      ),
                                    ),
                                ],
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text('父提交 ${parent + 1} ▾'),
                                ),
                              ),
                          ],
                        ),
                        Text(
                          mode == 'branch'
                              ? '只读 · 当前 HEAD 相对所选分支共同祖先的变更'
                              : reference?.parents.isEmpty == true
                              ? '只读 · 首次提交相对空目录的变更'
                              : '只读 · 此提交相对父提交的变更',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: DcSpace.page),
                  child: Row(
                    children: [
                      Text(
                        historical
                            ? '${files.length} 个文件'
                            : '${files.length} 个文件 · 已暂存 $staged',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const Spacer(),
                      if (!historical && selected.isNotEmpty) ...[
                        TextButton(
                          onPressed: busy || !canGit
                              ? null
                              : () => _stage(unstage: true),
                          child: const Text('取消暂存'),
                        ),
                        TextButton(
                          onPressed: busy || !canGit
                              ? null
                              : () => _stage(unstage: false),
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
                                      key: ValueKey((
                                        snapshot!['id'],
                                        rootId,
                                        p,
                                      )),
                                      file: f,
                                      stats: stats[p] as Map?,
                                      untracked: untracked.contains(p),
                                      readOnly: historical,
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
                if (!historical)
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
                                onPressed: busy || files.isEmpty || !canGit
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
                                  onPressed: busy || files.isEmpty || !canGit
                                      ? null
                                      : () => _commit(push: false),
                                  child: const Text('提交'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton(
                                  onPressed: busy || files.isEmpty || !canGit
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
    super.key,
    required this.file,
    required this.stats,
    required this.untracked,
    required this.readOnly,
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
  final bool untracked, selected, open, readOnly;
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
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    if (widget.open) _loadDiff();
  }

  @override
  void didUpdateWidget(_ChangedFile old) {
    super.didUpdateWidget(old);
    if (widget.open && diff == null && note == null) _loadDiff();
  }

  Future<void> _loadDiff() async {
    final link = widget.tool.link, task = widget.tool.taskId;
    final epoch = widget.tool.host.connectionEpoch;
    if (link == null || task == null || _loading) return;
    _loading = true;
    try {
      final r = await link.changedFile(
        task,
        widget.snapshotId,
        widget.rootId,
        '${widget.file['path']}',
      );
      if (!mounted ||
          link != widget.tool.link ||
          epoch != widget.tool.host.connectionEpoch) {
        return;
      }
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
      if (mounted &&
          link == widget.tool.link &&
          epoch == widget.tool.host.connectionEpoch) {
        note = '$e';
      }
    }
    _loading = false;
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
            onLongPress: widget.readOnly
                ? null
                : () => widget.onSelect(!widget.selected),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                children: [
                  if (!widget.readOnly)
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
