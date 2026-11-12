import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../core/live_timeline.dart';
import '../../core/mobile_operations.dart';
import '../../core/protocol.dart';
import '../../data/local_workspace.dart';
import '../../ui/quota_ring.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../inbox/approval_card.dart';
import '../inbox/pending_operation.dart';
import 'agent_picker.dart';
import 'timeline_view.dart';
import 'turn_files.dart';
import 'computer_use_banner.dart';
import 'composer_state.dart';
import 'composer_attachments.dart';
import '../sessions/session_menu.dart';

/// 02 对话: streamed timeline, tool activity, approvals and the composer.
/// Leaving this page never stops the task on the PC.
class ConversationPage extends StatefulWidget {
  const ConversationPage({
    super.key,
    required this.hostId,
    required this.taskId,
    this.focusTurnId,
  });
  final String hostId;
  final String taskId;
  final String? focusTurnId;
  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  late ComposerState draft;
  TextEditingController get prompt => draft.prompt;
  final scroll = ScrollController();
  late HostHub hub;
  late var live = LiveTimeline(widget.taskId);
  List<Map<String, dynamic>> _cachedItems = [];
  bool _cacheLoaded = false,
      _cachedTimeline = false,
      _freshTimeline = false,
      _cacheTruncated = false;
  DateTime? _timelineSyncedAt;
  Timer? _cacheTimer;
  int _timelineCacheEpoch = 0;
  List<Map<String, dynamic>> get timeline =>
      live.loaded ? live.items : _cachedItems;
  StreamSubscription<Map<String, dynamic>>? _stream;
  HostState? _owner;
  AgentChoice? get choice => draft.choice;
  set choice(AgentChoice? value) => draft.choice = value;
  bool loading = true, sending = false, stopping = false;
  String? _sendingProviderId;
  String? error;
  int _epoch = -1;
  bool _tailUnsupported = false, _loadingEarlier = false;
  bool _locating = false, _locateCancelled = false;
  int _locatePages = 0;
  int? _focusIndex;
  int _focusOffset = 0, _entryCount = 0;
  Object? _streamVersion;
  bool _readingTimeline = false, _timelineDirty = false;
  final _focusKey = GlobalKey();
  bool _focused = false;
  bool _ready = false;

  /// Whether the view keeps to the newest output. Only the user's own
  /// scrolling changes it, so content that grows later (a turn's diff, the
  /// composer resizing) keeps the bottom in view. A focused turn starts free.
  late bool _following = widget.focusTurnId == null;

  /// A finger is on the timeline (or a fling it started is running): never
  /// move the view under it.
  bool _userScrolling = false;

  HostState? get host => hub.host(widget.hostId);
  Map<String, dynamic>? get task => host?.task(widget.taskId);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppScope.of(context).hub;
    if (!_ready) {
      _ready = true;
      hub = next;
      draft = ComposerState(hub)..addListener(_draftChanged);
      hub.addListener(_changed);
      hub.local.addListener(_cacheCleared);
      _timelineCacheEpoch = hub.local.cacheEpoch;
      _changed();
    }
  }

  void _changed() {
    if (!mounted) return;
    final h = host;
    if (!identical(h, _owner)) {
      _owner = h;
      _cacheTimer?.cancel();
      unawaited(_stream?.cancel());
      _stream = null;
      draft.pauseUploads();
      if (h == null || draft.host?.bindingEpoch != h.bindingEpoch) {
        unawaited(draft.bind(null, null, null).catchError((Object _) {}));
      }
      live = LiveTimeline(widget.taskId);
      _cachedItems = [];
      _cacheLoaded = false;
      _cachedTimeline = false;
      _freshTimeline = false;
      _cacheTruncated = false;
      _timelineSyncedAt = null;
      _epoch = -1;
      _streamVersion = null;
      _tailUnsupported = false;
      _readingTimeline = false;
      _timelineDirty = false;
      _loadingEarlier = false;
      _locating = false;
      _locateCancelled = true;
      _focused = false;
      _focusIndex = null;
      loading = h != null;
      error = null;
      if (h != null) unawaited(_readCachedTimeline());
    }
    if (h == null) {
      unawaited(draft.bind(null, null, null).catchError((Object _) {}));
      setState(() {});
      return;
    }
    final project = task?['projectId'];
    if (project is String) {
      hub.followProject(h, project);
      if (draft.key !=
          draftKey(
            h.id,
            project,
            widget.taskId,
            bindingEpoch: h.bindingEpoch,
          )) {
        unawaited(
          draft.bind(h, project, widget.taskId).catchError((Object e) {
            if (mounted) setState(() => error = '$e');
          }),
        );
      }
    }
    _stream ??= h.events.listen((event) {
      if (identical(_owner, h)) _streamed(event);
    });
    final version = task?['streamVersion'];
    // Only this task's version (or a new connection) needs a re-read; streamed
    // deltas already keep the view current between them.
    if (h.online &&
        (h.connectionEpoch != _epoch || version != _streamVersion)) {
      _epoch = h.connectionEpoch;
      _streamVersion = version;
      unawaited(loadTimeline());
      if (choice == null) unawaited(_initChoice());
    }
    setState(() {});
  }

  /// Streamed answer text and activity merge in place, without a reload.
  void _streamed(Map<String, dynamic> event) {
    if (!mounted) return;
    final changed = live.apply(event);
    if (live.needsSnapshot) unawaited(loadTimeline());
    if (!changed) return;
    if (_freshTimeline) _scheduleCache();
    setState(() {});
    if (_following) _toEnd();
  }

  Future<void> _readCachedTimeline() async {
    final owner = _owner;
    if (_cacheLoaded || owner == null) return;
    _cacheLoaded = true;
    final epoch = hub.local.cacheEpoch;
    try {
      final cached = await hub.local.cachedTimeline(
        widget.hostId,
        widget.taskId,
        bindingEpoch: owner.bindingEpoch,
      );
      if (!mounted ||
          !identical(_owner, owner) ||
          owner.operations.retired ||
          _freshTimeline ||
          hub.local.cacheEpoch != epoch ||
          cached == null) {
        return;
      }
      setState(() {
        _cachedItems = [
          for (final item in cached['snapshot']['items'] as List)
            Map<String, dynamic>.from(item as Map),
        ];
        _cachedTimeline = true;
        _cacheTruncated = cached['truncated'] == true;
        _timelineSyncedAt = DateTime.tryParse('${cached['syncedAt']}');
        loading = false;
      });
      _toEnd();
    } catch (_) {
      /* An unavailable cache never prevents a live PC read. */
    }
  }

  void _cacheCleared() {
    if (!mounted || !_cachedTimeline || host?.online == true) return;
    setState(() {
      live = LiveTimeline(widget.taskId);
      _cachedItems = [];
      _cachedTimeline = false;
      _freshTimeline = false;
      _timelineSyncedAt = null;
    });
  }

  void _scheduleCache() {
    _timelineSyncedAt = DateTime.now();
    _timelineCacheEpoch = hub.local.cacheEpoch;
    _cacheTimer?.cancel();
    _cacheTimer = Timer(const Duration(milliseconds: 400), _saveTimeline);
  }

  void _saveTimeline() {
    final owner = _owner;
    if (!_freshTimeline ||
        !live.loaded ||
        _timelineSyncedAt == null ||
        owner == null ||
        !identical(host, owner) ||
        owner.operations.retired) {
      return;
    }
    unawaited(
      hub.local
          .cacheTimeline(
            widget.hostId,
            widget.taskId,
            {'items': timeline, 'lastSequence': live.cursor},
            _timelineSyncedAt!,
            _timelineCacheEpoch,
            bindingEpoch: owner.bindingEpoch,
          )
          .catchError((Object e) {
            hub.local.cacheError = tr("离线会话未能保存：{0}", [e]);
          }),
    );
  }

  Future<void> loadTimeline() async {
    if (_readingTimeline) {
      _timelineDirty = true;
      return;
    }
    final h = host, link = host?.link;
    if (link == null) return;
    final epoch = h!.connectionEpoch, reading = live;
    _readingTimeline = true;
    reading.beginRead();
    try {
      final value = await _readTail(link);
      if (!mounted ||
          !identical(_owner, h) ||
          !identical(live, reading) ||
          h.link != link ||
          h.connectionEpoch != epoch ||
          !h.online) {
        return;
      }
      setState(() {
        if (live.reset(Map<String, dynamic>.from(value as Map))) {
          _freshTimeline = true;
          _cachedTimeline = false;
          _cacheTruncated = false;
          _scheduleCache();
        }
        loading = false;
        error = null;
      });
      if (_following) _toEnd();
      if (!_focused && widget.focusTurnId != null) {
        await _pageToFocus();
        _revealFocus(0);
      }
    } catch (e) {
      if (mounted &&
          identical(_owner, h) &&
          identical(live, reading) &&
          h.link == link &&
          h.connectionEpoch == epoch) {
        setState(() {
          loading = false;
          error = '$e';
        });
      }
    } finally {
      reading.endRead();
      if (identical(_owner, h) && identical(live, reading)) {
        _readingTimeline = false;
        if (_timelineDirty && mounted) {
          _timelineDirty = false;
          unawaited(loadTimeline());
        }
      }
    }
  }

  /// The newest turns only; a PC without `timeline_tail` sends everything.
  Future<dynamic> _readTail(HostLink link) async {
    final owner = _owner;
    if (!_tailUnsupported) {
      try {
        return await link.call('timeline_tail', {'taskId': widget.taskId});
      } on ProtocolException catch (e) {
        if (!e.message.contains('remote method unavailable')) rethrow;
        if (identical(_owner, owner)) _tailUnsupported = true;
      }
    }
    return link.call('timeline_snapshot', [widget.taskId]);
  }

  /// Prepends the next older page; with [untilTurn] the PC extends that page
  /// back to the turn. False when nothing was added.
  Future<bool> loadEarlier({String? untilTurn}) async {
    final h = host, link = host?.link, before = live.earlierBefore;
    if (_loadingEarlier || link == null || before == null) return false;
    final epoch = h!.connectionEpoch, reading = live;
    setState(() => _loadingEarlier = true);
    try {
      final page = await link.call('timeline_tail', {
        'taskId': widget.taskId,
        'beforeTurn': before,
        'untilTurn': ?untilTurn,
      });
      if (!mounted ||
          !identical(_owner, h) ||
          !identical(live, reading) ||
          h.link != link ||
          h.connectionEpoch != epoch) {
        return false;
      }
      if (live.earlierBefore != before) return false;
      setState(() => live.prependEarlier(Map<String, dynamic>.from(page)));
      return true;
    } catch (e) {
      if (mounted && identical(_owner, h) && identical(live, reading)) {
        setState(() => error = '$e');
      }
      return false;
    } finally {
      if (mounted && identical(_owner, h) && identical(live, reading)) {
        setState(() => _loadingEarlier = false);
      }
    }
  }

  /// A turn opened from history search may sit far before the first page.
  /// The PC reads back to it in as few pages as fit; the user sees progress
  /// and can stop, and a turn that no longer exists is reported.
  Future<void> _pageToFocus() async {
    final owner = _owner;
    final turn = widget.focusTurnId;
    if (turn == null) return;
    bool present() => live.items.any((i) => i['turnId'] == turn);
    if (present()) return;
    setState(() {
      _locating = true;
      _locateCancelled = false;
      _locatePages = 0;
    });
    try {
      while (mounted &&
          identical(_owner, owner) &&
          !present() &&
          !_locateCancelled &&
          live.earlierBefore != null) {
        if (!await loadEarlier(untilTurn: 'turn:$turn')) break;
        if (mounted && identical(_owner, owner)) setState(() => _locatePages++);
      }
    } finally {
      if (mounted && identical(_owner, owner)) {
        setState(() => _locating = false);
      }
    }
    if (mounted &&
        identical(_owner, owner) &&
        !present() &&
        !_locateCancelled &&
        error == null) {
      setState(() => error = tr("没有找到要打开的这一轮，它可能已被删除。"));
    }
  }

  Future<void> _loadFullItem(String itemId) async {
    final owner = _owner, reading = live, link = host?.link;
    final epoch = owner?.connectionEpoch;
    if (link == null) throw ProtocolException(tr("电脑离线，连接后再查看完整内容。"));
    final item = await link.call('timeline_item', {
      'taskId': widget.taskId,
      'itemId': itemId,
    });
    if (!mounted ||
        item is! Map ||
        !identical(_owner, owner) ||
        !identical(live, reading) ||
        owner?.link != link ||
        owner?.connectionEpoch != epoch) {
      return;
    }
    setState(() => live.replaceItem(Map<String, dynamic>.from(item)));
  }

  /// The focused turn may be outside the lazily built range: jump near its
  /// estimated position until it is built, then align it. A turn that never
  /// appears stops the search, so following new output works again.
  void _revealFocus(int attempt) {
    final owner = _owner;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!identical(_owner, owner)) return;
      if (!mounted || _focused) return;
      final target = _focusKey.currentContext;
      if (target != null) {
        _focused = true;
        Scrollable.ensureVisible(target, alignment: .1);
        return;
      }
      final index = _focusIndex;
      if (index == null || attempt >= 4 || !scroll.hasClients) {
        _focused = true;
        return;
      }
      final position = scroll.position;
      position.jumpTo(
        position.maxScrollExtent *
            ((index + _focusOffset) / (_entryCount == 0 ? 1 : _entryCount)),
      );
      _revealFocus(attempt + 1);
    });
  }

  void _draftChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initChoice() => draft.ensureChoice();

  bool _scrolled(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is UserScrollNotification) {
      _userScrolling = n.direction != ScrollDirection.idle;
    }
    // Any drag toward older content stops following at once; only coming
    // back to rest at the very bottom follows again.
    if (n is ScrollUpdateNotification &&
        n.dragDetails != null &&
        (n.scrollDelta ?? 0) < 0) {
      _following = false;
    } else if (n is ScrollEndNotification) {
      _following = n.metrics.pixels >= n.metrics.maxScrollExtent - 4;
    }
    return false;
  }

  /// Content or viewport size changed without a scroll: stay at the bottom.
  bool _resized(ScrollMetricsNotification n) {
    if (_following &&
        !_userScrolling &&
        n.depth == 0 &&
        n.metrics.pixels < n.metrics.maxScrollExtent) {
      _toEnd();
    }
    return false;
  }

  void _toEnd() {
    if (widget.focusTurnId != null && !_focused) return;
    void jump([int left = 3]) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!scroll.hasClients || !_following || _userScrolling) return;
        final end = scroll.position.maxScrollExtent;
        scroll.jumpTo(end);
        // Building the last rows refines the estimated extent.
        if (left > 0 && scroll.position.maxScrollExtent != end) jump(left - 1);
      });
    }

    jump();
  }

  Future<void> _rename() async {
    final t = task, h = host, link = host?.link;
    final currentHub = hub;
    if (t == null || h == null || link == null) return;
    var inputTitle = t['title'] as String? ?? '';
    final title = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr("重命名会话")),
        content: TextFormField(
          initialValue: inputTitle,
          onChanged: (value) => inputTitle = value,
          autofocus: true,
          maxLength: 120,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(tr("取消"))),
          TextButton(
            onPressed: () => Navigator.pop(d, inputTitle.trim()),
            child: Text(tr("保存")),
          ),
        ],
      ),
    );
    if (!mounted || title == null || title.isEmpty || title == t['title']) {
      return;
    }
    try {
      await h.operations.renameSession(link, t, title);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    await currentHub.refresh(h);
  }

  Future<void> _delete() async {
    final t = task, h = host, link = host?.link;
    final currentHub = hub;
    if (t == null || h == null || link == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr("删除这个会话？")),
        content: Text(
          tr("将在「{0}」上永久删除「{1}」及其记录，无法恢复。项目文件不会被删除。", [h.name, t['title']]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text(tr("取消")),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text(tr("删除"), style: TextStyle(color: context.dc.removed)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    var accepted = false;
    try {
      final result = await h.operations.deleteSession(link, t);
      accepted = result is Map && result['state'] == 'accepted';
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    await currentHub.refresh(h);
    if (accepted && mounted) Navigator.of(context).pop();
  }

  Future<void> stop() async {
    final h = host;
    final link = h?.link;
    final t = task;
    if (h == null || link == null || t == null || stopping) return;
    setState(() => stopping = true);
    try {
      await h.operations.cancel(link, t);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr("停止请求未确认：{0}。请刷新核实任务状态。", [e]))),
        );
      }
    } finally {
      await hub.refresh(h);
      if (mounted) setState(() => stopping = false);
    }
  }

  Future<void> send() async {
    final h = host;
    final link = h?.link;
    final t = task;
    final c = choice;
    final text = prompt.text;
    if (h == null || link == null || t == null || c == null) return;
    if (!draft.hasContent || sending || !h.online || !draft.choiceValid) return;
    _following = true;
    _toEnd();
    setState(() {
      sending = true;
      _sendingProviderId = c.executor['providerId'] as String?;
      error = null;
    });
    try {
      await draft.flush();
      final attachments = draft.attachments.isEmpty
          ? <Map<String, dynamic>>[]
          : await draft.prepareAttachments();
      final identity = draft.identity;
      final value = await h.operations.send(link, {
        'scope': 'mobile:${h.id}:${t['projectId']}:${widget.taskId}',
        'taskId': widget.taskId,
        'projectId': t['projectId'],
        'target': c.executor,
        'input': {
          'prompt': text,
          'model': c.model,
          'thinking': c.thinking,
          'permissionMode': c.effectivePermission,
          'attachments': attachments,
        },
      }, draft: identity);
      if (value is Map &&
          value['state'] == 'closed' &&
          value['resolution']?['status'] == 'submitted') {
        await draft.submitted(identity);
        _toEnd();
      } else if (value is Map && value['state'] == 'closed') {
        error = tr("电脑未受理这次发送，内容已保留。");
      }
    } catch (e) {
      error = '$e';
    } finally {
      await hub.refresh(h);
      if (mounted) {
        setState(() {
          sending = false;
          _sendingProviderId = null;
        });
      }
    }
  }

  @override
  void dispose() {
    _cacheTimer?.cancel();
    _saveTimeline();
    hub.local.removeListener(_cacheCleared);
    hub.removeListener(_changed);
    _stream?.cancel();
    draft.removeListener(_draftChanged);
    draft.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final h = host;
    final t = task;
    if (h == null) {
      return Scaffold(
        appBar: DetailBar(title: tr("会话")),
        body: EmptyNote(
          icon: Icons.link_off,
          title: tr("这台电脑已不在列表中"),
          body: tr("可能已在电脑上撤销配对。"),
        ),
      );
    }
    final projectName = projectLabel(h.project(t?['projectId'] as String?));
    final approvals = [
      for (final a in h.approvals[widget.taskId] ?? const [])
        if (t != null) ApprovalRef(h, t, a),
    ];
    final run = t?['activePrimaryRun'] as Map?;
    final running = run != null;
    final connecting = running
        ? const {'queued', 'starting'}.contains(run['state'])
        : sending;
    final providerId =
        (run?['executor'] as Map?)?['providerId'] as String? ??
        _sendingProviderId ??
        (t?['preferredExecutor'] as Map?)?['providerId'] as String? ??
        choice?.executor['providerId'] as String?;
    final recoveryCards = <Widget>[
      for (final cancellation in h.pendingCancellations.where(
        (c) => c['taskId'] == widget.taskId,
      ))
        Padding(
          padding: const EdgeInsets.fromLTRB(DcSpace.page, 0, DcSpace.page, 8),
          child: PendingOperationCard(
            key: ValueKey(cancellation['envelope']['commandId']),
            host: h,
            operation: cancellation,
          ),
        ),
      if (h.pendingOperation != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(DcSpace.page, 0, DcSpace.page, 8),
          child: PendingOperationCard(
            key: const ValueKey('main-pending-operation'),
            host: h,
            onDraftSubmitted: draft.submitted,
          ),
        ),
    ];
    return Scaffold(
      appBar: DetailBar(
        title: t?['title'] as String? ?? tr("会话"),
        subtitle: [
          ?projectName,
          h.placeName(h.project(t?['projectId'] as String?)),
        ].join(' · '),
        actions: [
          IconButton(
            tooltip: tr("刷新"),
            onPressed: h.online ? () => hub.refresh(h) : null,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            tooltip: tr("更多"),
            enabled:
                t != null && (h.online || AppScope.of(context).runtime != null),
            onSelected: (v) async {
              if (v == 'rename') {
                await _rename();
              } else if (v == 'delete') {
                await _delete();
              } else if (t != null) {
                await sessionAction(context, SessionRef(h, t), v);
              }
            },
            itemBuilder: (_) => [
              if (t != null)
                ...sessionMenuItems(
                  SessionRef(h, t),
                  notifications: AppScope.of(context).runtime != null,
                ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'rename',
                enabled: h.online,
                child: Text(tr("重命名")),
              ),
              PopupMenuItem(
                value: 'delete',
                enabled: h.online,
                child: Text(tr("删除会话")),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (!h.online) _OfflineBar(host: h, onRetry: () => hub.connect(h)),
          if (_cachedTimeline)
            InlineNotice(
              tr("{0} · 内容同步于 {1}{2}。附件原文需电脑在线。", [
                h.online ? tr("正在同步，先显示本机缓存") : tr("离线缓存"),
                _timelineSyncedAt?.toLocal().toString().substring(0, 16) ??
                    tr("未知时间"),
                _cacheTruncated ? tr(" · 仅缓存最近部分内容") : '',
              ]),
            ),
          if (error != null) InlineNotice(error!, danger: true),
          if (draft.error != null) InlineNotice(draft.error!, danger: true),
          Expanded(
            child: loading && timeline.isEmpty
                ? Center(
                    child: h.online
                        ? const CircularProgressIndicator()
                        : Text(
                            tr("电脑离线，暂无已缓存的对话内容。"),
                            style: TextStyle(color: context.dc.secondary),
                          ),
                  )
                : Builder(
                    builder: (context) {
                      final entries = timelineEntries(
                        context,
                        session: t == null ? null : SessionRef(h, t),
                        items: timeline,
                        focusTurnId: widget.focusTurnId,
                        focusKey: _focusKey,
                        activeTurnId:
                            (t?['activePrimaryRun'] as Map?)?['turnId']
                                as String?,
                      );
                      _focusIndex = entries.focusIndex;
                      final head = <Widget>[
                        if (_locating)
                          Row(
                            children: [
                              const SizedBox.square(
                                dimension: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _locatePages == 0
                                      ? tr("正在定位到该轮…")
                                      : tr("正在定位到该轮…已加载 {0} 页", [_locatePages]),
                                ),
                              ),
                              TextButton(
                                onPressed: () => setState(() {
                                  _locateCancelled = true;
                                  _focused = true;
                                }),
                                child: Text(tr("取消")),
                              ),
                            ],
                          ),
                        if (live.loaded && live.earlierBefore != null)
                          Center(
                            child: TextButton.icon(
                              onPressed: _loadingEarlier || !h.online
                                  ? null
                                  : loadEarlier,
                              icon: _loadingEarlier
                                  ? const SizedBox.square(
                                      dimension: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.history, size: 18),
                              label: Text(tr("加载更早的消息")),
                            ),
                          ),
                      ];
                      _focusOffset = head.length;
                      final children = <Widget>[
                        ...head,
                        ...entries.widgets,
                        if ((running || sending) && h.online)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                const SizedBox.square(
                                  dimension: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Flexible(
                                  child: Text(
                                    connecting
                                        ? tr("正在连接{0}", [
                                            agentLabel(providerId),
                                          ])
                                        : tr("正在响应"),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        for (final a in approvals)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: ApprovalCard(item: a, showContext: false),
                          ),
                      ];
                      _entryCount = children.length;
                      // Inserting earlier pages shifts indexes; keyed rows must
                      // keep their element (and expanded state) at the new one.
                      final indexOf = <Key, int>{
                        for (var i = 0; i < children.length; i++)
                          if (children[i].key != null) children[i].key!: i,
                      };
                      // Lazily built: a streamed token rebuilds only what is on screen.
                      return TurnScope(
                        link: h.link,
                        operations: h.operations,
                        onOperationChanged: () => hub.refreshOperation(h),
                        taskId: widget.taskId,
                        executor: defaultExecutor(h, t),
                        executors: h.executors,
                        loadFullItem: _loadFullItem,
                        child: NotificationListener<ScrollMetricsNotification>(
                          onNotification: _resized,
                          child: NotificationListener<ScrollNotification>(
                            onNotification: _scrolled,
                            child: ListView.builder(
                              key: const ValueKey('conversation-timeline'),
                              controller: scroll,
                              padding: const EdgeInsets.fromLTRB(
                                DcSpace.page,
                                8,
                                DcSpace.page,
                                16,
                              ),
                              itemCount: children.length,
                              itemBuilder: (_, i) => children[i],
                              findChildIndexCallback: (key) => indexOf[key],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          ComputerUseBanner(
            key: ValueKey('computer-use-${h.id}-${widget.taskId}'),
            host: h,
            taskId: widget.taskId,
            running: running && h.online,
          ),
          if (recoveryCards.length == 1) recoveryCards.single,
          if (recoveryCards.length > 1)
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: SingleChildScrollView(
                  child: Column(children: recoveryCards),
                ),
              ),
            ),
          _Composer(
            controller: prompt,
            choice: choice,
            draft: draft,
            canSend:
                h.online &&
                t != null &&
                h.pendingOperation == null &&
                !sending &&
                !draft.restoring &&
                !draft.uploading &&
                !draft.picking &&
                draft.choiceValid,
            quota: QuotaMeter.from(
              h.quotas[choice?.executor['installationId']],
              composer: true,
            ),
            loading: choice == null && h.online,
            sending: sending,
            enabled:
                t != null &&
                !sending &&
                !draft.restoring &&
                !draft.restoreFailed &&
                !draft.uploading,
            onSend: send,
            onStop: running && h.online && !stopping ? stop : null,
            running: running,
            onPick:
                h.online &&
                    !sending &&
                    !draft.uploading &&
                    !draft.restoring &&
                    !draft.picking
                ? () async {
                    final value = await showAgentSheet(
                      context,
                      host: h,
                      initial: choice,
                      taskId: widget.taskId,
                    );
                    if (value != null && mounted) {
                      setState(() => choice = value);
                    }
                  }
                : null,
          ),
        ],
      ),
    );
  }
}

class _OfflineBar extends StatelessWidget {
  const _OfflineBar({required this.host, required this.onRetry});
  final HostState host;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return Container(
      color: context.dc.surface,
      padding: const EdgeInsets.fromLTRB(DcSpace.page, 4, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              host.status == LinkStatus.connecting
                  ? tr("正在连接电脑…")
                  : tr("电脑离线{0}。任务不会因此停止。", [
                      host.syncedAt == null
                          ? ''
                          : tr(" · 最后同步 {0}", [shortTime(host.syncedAt)]),
                    ]),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (host.status == LinkStatus.offline)
            TextButton(onPressed: onRetry, child: Text(tr("重新连接"))),
        ],
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.choice,
    required this.draft,
    required this.canSend,
    this.quota,
    this.loading = false,
    required this.sending,
    required this.enabled,
    required this.onSend,
    required this.onStop,
    required this.running,
    required this.onPick,
  });
  final TextEditingController controller;
  final AgentChoice? choice;
  final ComposerState draft;
  final bool canSend;
  final QuotaMeter? quota;
  final bool loading;
  final bool sending, enabled;
  final VoidCallback onSend;
  final VoidCallback? onStop;
  final bool running;
  final VoidCallback? onPick;
  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  static const _inset = 8.0, _gap = 6.0;
  final _focus = FocusNode();

  /// Width of each side of the bottom row: the send button, plus stop while
  /// a run is active. The attach side gets the same width.
  double get _side => widget.running ? DcSpace.touch * 2 + _gap : DcSpace.touch;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _edit() {
    if (!widget.enabled || _focus.hasFocus) return;
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    return SafeArea(
      top: false,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _edit,
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          // The bottom row's buttons sit the same distance from the left,
          // right and bottom edges; the text keeps its own wider inset.
          padding: const EdgeInsets.all(_inset),
          decoration: BoxDecoration(
            color: c.canvas,
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(DcSpace.composer),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 2, 6, 4),
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  minLines: 3,
                  maxLines: keyboard ? 6 : 8,
                  enabled: widget.enabled,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: InputDecoration(
                    hintText: tr("继续交给 Agent…"),
                    filled: false,
                    isCollapsed: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 6),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                  ),
                ),
              ),
              ComposerAttachments(
                draft: widget.draft,
                enabled: widget.enabled,
                // Equal slots either side keep the agent chip on the
                // composer's centre line, whatever the right side holds.
                sideWidth: _side,
                trailing: Row(
                  children: [
                    Expanded(
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: AgentChips(
                            choice: widget.choice,
                            onTap: widget.onPick,
                            quota: widget.quota,
                            loading: widget.loading,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: _side,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (widget.running) ...[
                            IconButton.outlined(
                              style: IconButton.styleFrom(
                                fixedSize: const Size(
                                  DcSpace.touch,
                                  DcSpace.touch,
                                ),
                                padding: EdgeInsets.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              tooltip: tr("停止"),
                              onPressed: widget.onStop,
                              icon: const Icon(Icons.stop_rounded),
                            ),
                            const SizedBox(width: _gap),
                          ],
                          ListenableBuilder(
                            listenable: widget.controller,
                            builder: (context, _) => IconButton.filled(
                              style: accentIconButton(context).copyWith(
                                fixedSize: const WidgetStatePropertyAll(
                                  Size(DcSpace.touch, DcSpace.touch),
                                ),
                                padding: const WidgetStatePropertyAll(
                                  EdgeInsets.zero,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              tooltip: tr("发送"),
                              onPressed:
                                  widget.canSend &&
                                      widget.choice != null &&
                                      (widget.controller.text
                                              .trim()
                                              .isNotEmpty ||
                                          widget.draft.attachments.isNotEmpty)
                                  ? widget.onSend
                                  : null,
                              icon: widget.sending
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.arrow_upward),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
