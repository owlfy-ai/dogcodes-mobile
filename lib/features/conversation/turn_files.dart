import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../core/host_api.dart';
import '../../core/host_hub.dart' show agentLabel;
import '../../core/pc_api.dart';
import '../../core/mobile_operations.dart';
import '../../core/turn_changes.dart';
import '../../ui/theme.dart';
import '../tools/changes_page.dart' show UnifiedDiff;
import '../tools/line_diff.dart';

/// What a turn summary needs from the open conversation: the PC link, the
/// task and the Agent that writes commit messages.
class TurnScope extends InheritedWidget {
  const TurnScope({
    super.key,
    required this.link,
    required this.taskId,
    required this.executor,
    this.executors = const [],
    this.loadFullItem,
    this.operations,
    this.onOperationChanged,
    required super.child,
  });
  final HostApi? link;
  final MobileOperations? operations;
  final Future<void> Function()? onOperationChanged;
  final String taskId;
  final Map<String, dynamic>? executor;

  /// The PC's ready Agents, any of which can write the commit message.
  final List<Map<String, dynamic>> executors;

  /// Reads one item the PC trimmed to fit a page, and shows it in full.
  final Future<void> Function(String itemId)? loadFullItem;
  static TurnScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TurnScope>();
  @override
  bool updateShouldNotify(TurnScope old) =>
      old.link != link ||
      old.taskId != taskId ||
      old.executor != executor ||
      old.executors != executors ||
      old.loadFullItem != loadFullItem;
}

/// 本轮文件变更: the files a turn changed with their line counts and saved
/// diff, plus one-tap commit of just these files (same flow as the PC).
class TurnFilesCard extends StatefulWidget {
  const TurnFilesCard({super.key, required this.metadata});
  final Map<String, dynamic> metadata;
  @override
  State<TurnFilesCard> createState() => _TurnFilesCardState();
}

class _TurnFilesCardState extends State<TurnFilesCard> {
  Future<TurnChanges>? future;
  bool expanded = false;
  String? done;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  void _load({bool retry = false}) {
    final scope = TurnScope.of(context);
    if (scope?.link == null || (future != null && !retry)) return;
    future = scope!.link!.turnChanges(scope.taskId, widget.metadata);
  }

  Future<void> _commit(TurnChanges changes) async {
    final scope = TurnScope.of(context)!;
    if (scope.operations == null) return;
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => TurnCommitSheet(
        link: scope.link!,
        operations: scope.operations!,
        onOperationChanged: scope.onOperationChanged,
        taskId: scope.taskId,
        changes: changes,
        executor: scope.executor,
        executors: scope.executors,
      ),
    );
    if (result != null && mounted) setState(() => done = result);
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    return FutureBuilder<TurnChanges>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) {
          return Row(
            children: [
              Flexible(
                child: Text(
                  kDebugMode
                      ? tr("本轮变更加载失败：{0}", [snap.error])
                      : tr("本轮变更加载失败"),
                  style: TextStyle(fontSize: 13, color: c.secondary),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _load(retry: true)),
                child: Text(tr("重试")),
              ),
            ],
          );
        }
        final changes = snap.data;
        // Like the PC: no temporary row while loading, none for empty turns.
        if (changes == null || changes.files.isEmpty) {
          return const SizedBox.shrink();
        }
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(DcSpace.control),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(DcSpace.control),
                onTap: () => setState(() => expanded = !expanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
                  child: Row(
                    children: [
                      Icon(
                        expanded ? Icons.expand_more : Icons.chevron_right,
                        size: 18,
                        color: c.secondary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                tr("{0} 个文件已更改", [changes.files.length]),
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _Counts(changes.additions, changes.deletions),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        onPressed:
                            done != null || TurnScope.of(context)?.link == null
                            ? null
                            : () => _commit(changes),
                        icon: done != null
                            ? const Icon(Icons.check, size: 16)
                            : const Icon(Icons.commit, size: 16),
                        label: Text(done ?? tr("提交")),
                      ),
                    ],
                  ),
                ),
              ),
              if (expanded) ...[
                Divider(height: 1, color: c.line),
                if (changes.recovered)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Text(
                      tr("连接中断后的恢复快照 · 仅反映检查时的文件变化，外部工具可能仍在写入"),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                for (final f in changes.files) _FileRow(file: f),
                const SizedBox(height: 4),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Counts extends StatelessWidget {
  const _Counts(this.additions, this.deletions);
  final int additions, deletions;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    const style = TextStyle(fontSize: 12, fontFamily: monoFamily);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('+$additions', style: style.copyWith(color: c.added)),
        const SizedBox(width: 4),
        Text('−$deletions', style: style.copyWith(color: c.removed)),
      ],
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.file});
  final TurnFile file;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final f = file;
    final color = switch (f.status) {
      'A' => c.added,
      'D' => c.removed,
      _ => c.secondary,
    };
    return InkWell(
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => _FileDiffSheet(file: f),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              child: Text(
                f.status.isEmpty ? 'M' : f.status.substring(0, 1),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  fontFamily: monoFamily,
                  color: color,
                ),
              ),
            ),
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: f.name),
                    if (f.directory.isNotEmpty)
                      TextSpan(
                        text: '  ${f.directory}',
                        style: TextStyle(fontSize: 12, color: c.secondary),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
            ),
            const SizedBox(width: 8),
            if (f.binary)
              Text(
                tr("二进制"),
                style: TextStyle(fontSize: 12, color: c.secondary),
              )
            else
              _Counts(f.additions, f.deletions),
          ],
        ),
      ),
    );
  }
}

class _FileDiffSheet extends StatelessWidget {
  const _FileDiffSheet({required this.file});
  final TurnFile file;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text(file.display, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            tr("本轮保存的历史 Diff"),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          file.binary
              ? Text(tr("二进制文件，无法显示差异"))
              : file.before == null && file.after == null
              ? Text(tr("这一轮未保存该文件的内容"))
              : UnifiedDiff(lines: hunks(file.lines)),
        ],
      ),
    );
  }
}

enum _Phase { preparing, summarizing, ready, committing, empty, committed }

/// Stages only this turn's files, has the PC's Agent write a message from
/// exactly that staged diff, then commits (optionally pushes). Closing
/// without committing unstages what this sheet staged. Pops with the result
/// label when committed.
class TurnCommitSheet extends StatefulWidget {
  const TurnCommitSheet({
    super.key,
    required this.link,
    required this.taskId,
    required this.changes,
    required this.operations,
    this.onOperationChanged,
    required this.executor,
    this.executors = const [],
  });
  final HostApi link;
  final String taskId;
  final TurnChanges changes;
  final MobileOperations operations;
  final Future<void> Function()? onOperationChanged;
  final Map<String, dynamic>? executor;
  final List<Map<String, dynamic>> executors;
  @override
  State<TurnCommitSheet> createState() => _TurnCommitSheetState();
}

class _TurnCommitSheetState extends State<TurnCommitSheet> {
  final message = TextEditingController();
  var phase = _Phase.preparing;
  List<TurnCommitTarget> targets = [];
  TurnCommitTarget? target;
  String? snapshotId, error, done;
  int files = 0, extra = 0, _run = 0;
  ({String rootId, List<String> paths})? _added;

  late Map<String, dynamic>? executor = widget.executor;
  HostApi get link => widget.link;
  String get task => widget.taskId;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _run++;
    if (done == null) unawaited(_restore());
    message.dispose();
    super.dispose();
  }

  List<String> _paths(Map<String, dynamic> snapshot, String rootId) {
    for (final r in (snapshot['roots'] as List? ?? const [])) {
      if (r is Map && (r['root'] as Map?)?['id'] == rootId) {
        return [
          for (final f in (r['files'] as List? ?? const []))
            if (f is Map) '${f['path']}',
        ];
      }
    }
    return const [];
  }

  Future<Map<String, dynamic>> _query(String mode, [String? rootId]) async =>
      Map<String, dynamic>.from(
        await link.review('query', {
              'taskId': task,
              'rootId': rootId,
              'mode': mode,
              'reference': null,
              'parent': null,
            })
            as Map,
      );

  Future<void> _start() async {
    final id = ++_run;
    try {
      final snapshot = await _query('uncommitted');
      final list = widget.changes.commitTargets(snapshot);
      if (!mounted || id != _run) return;
      setState(() => targets = list);
      if (list.isEmpty) return setState(() => phase = _Phase.empty);
      await _prepare(list.first, id);
    } catch (e) {
      _fail(id, e, empty: targets.isEmpty);
    } finally {
      await widget.onOperationChanged?.call();
    }
  }

  void _fail(int id, Object e, {bool empty = false}) {
    if (!mounted || id != _run) return;
    setState(() {
      error = '$e'.replaceFirst('Exception: ', '');
      phase = empty && message.text.isEmpty ? _Phase.empty : _Phase.ready;
    });
  }

  Future<void> _prepare(TurnCommitTarget t, int id) async {
    setState(() {
      target = t;
      phase = _Phase.preparing;
      error = null;
      snapshotId = null;
    });
    final before = _paths(await _query('staged', t.rootId), t.rootId);
    final missing = t.paths.where((p) => !before.contains(p)).toList();
    if (missing.isNotEmpty) {
      final current = await _query('uncommitted', t.rootId);
      await widget.operations.indexWrite(
        link,
        taskId: task,
        snapshotId: current['id'] as String,
        rootId: t.rootId,
        paths: missing,
      );
      _added = (rootId: t.rootId, paths: missing);
    }
    final staged = await _query('staged', t.rootId);
    final paths = _paths(staged, t.rootId);
    if (!mounted || id != _run) return;
    setState(() {
      snapshotId = staged['id'] as String;
      files = paths.length;
      extra = paths.where((p) => !t.paths.contains(p)).length;
      phase = _Phase.summarizing;
    });
    final executor = this.executor;
    if (executor == null) throw StateError(tr("没有可用于生成提交说明的 Agent"));
    final text = await link.commitSummary(task, t.rootId, executor);
    if (!mounted || id != _run) return;
    setState(() {
      message.text = text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
      phase = _Phase.ready;
    });
  }

  Future<void> _restore() async {
    final added = _added;
    _added = null;
    if (added == null) return;
    try {
      final staged = await _query('staged', added.rootId);
      await widget.operations.indexWrite(
        link,
        taskId: task,
        snapshotId: staged['id'] as String,
        rootId: added.rootId,
        paths: added.paths,
        unstage: true,
      );
    } catch (_) {
      // Still visible as staged in 变更; nothing is lost.
    } finally {
      await widget.onOperationChanged?.call();
    }
  }

  Future<void> _switch(String rootId) async {
    final t = targets.firstWhere((x) => x.rootId == rootId);
    if (t == target) return;
    await _restore();
    final id = ++_run;
    try {
      await _prepare(t, id);
    } catch (e) {
      _fail(id, e);
    }
  }

  Future<void> _regenerate() async {
    final t = target;
    if (t == null) return;
    final id = ++_run;
    try {
      await _prepare(t, id);
    } catch (e) {
      _fail(id, e);
    }
  }

  Future<void> _commit({required bool push}) async {
    final t = target, text = message.text.trim();
    if (t == null || snapshotId == null || text.isEmpty) return;
    setState(() {
      phase = _Phase.committing;
      error = null;
    });
    try {
      final result = await widget.operations.gitWrite(
        link,
        taskId: task,
        rootId: t.rootId,
        action: 'commit',
        snapshotId: snapshotId!,
        message: text,
        push: push,
      );
      if (result?['state'] == 'succeeded') {
        _added = null;
        _finish(push ? tr("已提交并推送") : tr("已提交"));
      } else {
        _fail(
          _run,
          result == null
              ? tr("提交结果待核实，请到待处理页面核实原操作")
              : gitResultMessage(result),
        );
      }
    } catch (e) {
      _fail(_run, e);
    } finally {
      await widget.onOperationChanged?.call();
    }
  }

  void _finish(String label) {
    done = label;
    if (mounted) setState(() => phase = _Phase.committed);
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final busy =
        phase == _Phase.preparing ||
        phase == _Phase.summarizing ||
        phase == _Phase.committing;
    final status = switch (phase) {
      _Phase.preparing => tr("正在暂存本轮文件…"),
      _Phase.summarizing => tr("正在生成提交说明…"),
      _Phase.committing => tr("正在提交…"),
      _ => null,
    };
    final canCommit = phase == _Phase.ready && message.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr("提交本轮修改"), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          if (targets.length > 1) ...[
            SegmentedButton<String>(
              segments: [
                for (final t in targets)
                  ButtonSegment(value: t.rootId, label: Text(t.name)),
              ],
              selected: {target?.rootId ?? targets.first.rootId},
              onSelectionChanged: busy ? null : (v) => _switch(v.first),
            ),
            const SizedBox(height: 12),
          ],
          if (phase == _Phase.empty && error == null)
            Text(tr("本轮修改已没有未提交的内容（可能已提交或已撤销）。")),
          if (snapshotId != null || phase == _Phase.committed)
            Text(
              tr("将提交 {0} 个文件{1}。", [
                files,
                extra > 0 ? tr("，其中 {0} 个是此前已暂存的其他更改", [extra]) : '',
              ]),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (phase != _Phase.empty && phase != _Phase.preparing) ...[
            const SizedBox(height: 8),
            TextField(
              controller: message,
              enabled: !busy && phase != _Phase.committed,
              minLines: 2,
              maxLines: 5,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: tr("提交说明"),
                border: OutlineInputBorder(),
              ),
            ),
          ],
          if (status != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(status, style: TextStyle(color: c.secondary)),
              ],
            ),
          ],
          if (done != null) ...[
            const SizedBox(height: 10),
            Text(done!, style: TextStyle(color: c.accent)),
          ],
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(error!, style: TextStyle(color: c.removed)),
          ],
          const SizedBox(height: 16),
          if (phase == _Phase.committed || phase == _Phase.empty)
            FilledButton(
              onPressed: () => Navigator.pop(context, done),
              child: Text(tr("完成")),
            )
          else
            Row(
              children: [
                IconButton(
                  tooltip: tr("重新生成"),
                  onPressed: busy || target == null ? null : _regenerate,
                  icon: const Icon(Icons.auto_awesome_outlined),
                ),
                if (widget.executors.length > 1)
                  Flexible(
                    child: PopupMenuButton<Map<String, dynamic>>(
                      tooltip: tr("编写提交说明的 Agent"),
                      // Switching while one writes abandons that attempt.
                      enabled:
                          phase == _Phase.ready || phase == _Phase.summarizing,
                      onSelected: (e) {
                        setState(() => executor = e);
                        _regenerate();
                      },
                      itemBuilder: (_) => [
                        for (final e in widget.executors)
                          PopupMenuItem(
                            value: e,
                            child: Text(agentLabel(e['providerId'] as String?)),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                agentLabel(executor?['providerId'] as String?),
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: c.secondary),
                              ),
                            ),
                            Icon(
                              Icons.expand_more,
                              size: 18,
                              color: c.secondary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                OutlinedButton(
                  onPressed: canCommit ? () => _commit(push: false) : null,
                  child: Text(tr("提交")),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: canCommit ? () => _commit(push: true) : null,
                  child: Text(tr("提交并推送")),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
