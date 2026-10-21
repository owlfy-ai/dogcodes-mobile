import 'dart:async';
import 'package:flutter/foundation.dart';
import 'host_api.dart';
import 'adaptive_host_link.dart';
export 'host_api.dart' show HostLink;
import 'mobile_operations.dart';
import 'security/secret_storage.dart';

typedef HostConnector = Future<HostLink> Function(Map<String, dynamic> host);
typedef HostLister = Future<List<Map<String, dynamic>>> Function();
typedef HostForgetter = Future<void> Function(String hostId);

enum LinkStatus { connecting, online, offline }

/// Live state of one paired PC. The PC remains the source of truth; a
/// snapshot kept after a disconnect is shown as cached with its sync time.
class HostState {
  HostState(this.record, SecretStorage storage)
    : operations = MobileOperations(storage, record['hostId'] as String);
  Map<String, dynamic> record;
  final MobileOperations operations;
  String get id => record['hostId'] as String;
  String get name {
    final label = record['displayName'];
    if (label is String && label.isNotEmpty) return label;
    return '电脑 ${id.length > 6 ? id.substring(0, 6) : id}';
  }

  LinkStatus status = LinkStatus.offline;
  HostLink? link;
  Map<String, dynamic>? snapshot;
  Map<String, dynamic>? history;
  void acceptHistory(Map<String, dynamic> value) {
    final revision = BigInt.tryParse('${value['revision']}');
    if (revision == null || value['preferences'] is! Map) return;
    final old = BigInt.tryParse('${history?['revision']}');
    if (old == null || revision >= old) history = value;
  }

  List<Map<String, dynamic>> executors = [];
  Map<String, List<Map<String, dynamic>>> approvals = {};
  Map<String, dynamic>? pendingOperation;

  /// Latest read-only quota per installation; empty when the PC withholds it.
  Map<String, Map<String, dynamic>> quotas = {};
  DateTime? syncedAt;
  String? error;

  /// Bumped on every successful refresh so open pages can reload detail.
  int revision = 0;
  int _transportGeneration = 0;
  int get connectionEpoch => _transportGeneration;
  ConnectionRoute? get route =>
      link is RoutedHostLink ? (link as RoutedHostLink).route : null;
  StreamSubscription<Map<String, dynamic>>? _events;

  /// PC event envelopes from the project subscriptions, for pages that merge
  /// streamed output (e.g. the open conversation).
  Stream<Map<String, dynamic>> get events => _stream.stream;
  final _stream = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  Timer? _debounce, _poll;
  final _subscribed = <String>{};
  final _subscriptionIds = <String, String>{};
  String? _focusedProject;
  Future<void> _subscriptionQueue = Future.value();
  bool get online => status == LinkStatus.online && link != null;

  List<Map<String, dynamic>> get projects => [
    for (final p in (snapshot?['projects'] as List?) ?? const [])
      Map<String, dynamic>.from(p as Map),
  ];
  List<Map<String, dynamic>> get tasks => [
    for (final t in (snapshot?['tasks'] as List?) ?? const [])
      Map<String, dynamic>.from(t as Map),
  ];
  List<Map<String, dynamic>> get installations => [
    for (final i in (snapshot?['installations'] as List?) ?? const [])
      Map<String, dynamic>.from(i as Map),
  ];
  Map<String, dynamic>? project(String? id) {
    for (final p in projects) {
      if (p['projectId'] == id) return p;
    }
    return null;
  }

  Map<String, dynamic>? task(String? id) {
    for (final t in tasks) {
      if (t['taskId'] == id) return t;
    }
    return null;
  }

  /// Most recently updated task of a project; workspace calls are task-scoped.
  Map<String, dynamic>? latestTask(String? projectId) {
    Map<String, dynamic>? best;
    for (final t in tasks) {
      if (t['projectId'] != projectId) continue;
      if (best == null ||
          '${t['updatedAt'] ?? ''}'.compareTo('${best['updatedAt'] ?? ''}') >
              0) {
        best = t;
      }
    }
    return best;
  }

  int pendingInteractions(String taskId) {
    final workspaces =
        (snapshot?['companion'] as Map?)?['workspaces'] as List? ?? const [];
    for (final w in workspaces) {
      if (w['taskId'] == taskId) {
        return (w['pendingInteractionCount'] as num?)?.toInt() ?? 0;
      }
    }
    return 0;
  }
}

class SessionRef {
  SessionRef(this.host, this.task);
  final HostState host;
  final Map<String, dynamic> task;
  String get taskId => task['taskId'] as String;
  String get projectId => task['projectId'] as String;
  String get title => task['title'] as String? ?? '未命名会话';
  String? get state =>
      (host.history?['preferences'] as Map?)?['tasks']?[taskId] as String?;
  bool get pinned => state == 'pinned';
  bool get archived => state == 'archived';
  Map<String, dynamic>? get project => host.project(projectId);
  String get projectName => projectLabel(project) ?? '项目';
  bool get running => task['activePrimaryRun'] != null;
  bool get needsAttention =>
      host.pendingInteractions(taskId) > 0 ||
      (host.approvals[taskId]?.isNotEmpty ?? false);
  String? get providerId =>
      ((task['lastTurnExecutor'] ?? task['preferredExecutor'])
              as Map?)?['providerId']
          as String?;
  String get agent {
    final executor =
        (task['lastTurnExecutor'] ?? task['preferredExecutor']) as Map?;
    return agentLabel(executor?['providerId'] as String?);
  }

  DateTime? get updatedAt =>
      DateTime.tryParse(task['updatedAt'] as String? ?? '');
}

class ApprovalRef {
  ApprovalRef(this.host, this.task, this.approval);
  final HostState host;
  final Map<String, dynamic> task;
  final Map<String, dynamic> approval;
  bool get isQuestion => approval['question'] != null;
  String get projectName =>
      projectLabel(host.project(task['projectId'] as String?)) ?? '项目';
}

String? projectLabel(Map<String, dynamic>? project) {
  if (project == null) return null;
  final name = project['displayName'] as String?;
  if (name != null && name.isNotEmpty) return name;
  final path = project['path'] as String? ?? '';
  final parts = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
  return parts.isEmpty ? project['projectId'] as String? : parts.last;
}

/// Display names shared with the desktop (agentPresentation.tsx).
String agentLabel(String? providerId) => switch (providerId?.toLowerCase()) {
  null || '' => 'Agent',
  'claude' || 'claude-code' => 'Claude Code',
  'codex' => 'Codex',
  'kimi' => 'Kimi',
  'cursor' => 'Cursor',
  'codebuddy' => 'CodeBuddy',
  'antigravity' => 'Antigravity',
  'grok' => 'Grok Build',
  'zcode' => 'ZCode',
  'pi' => 'Pi',
  'opencode' => 'OpenCode',
  'deepseek-harness' => 'DeepSeek Harness',
  'kiro' => 'Kiro',
  'fake' => '离线模式',
  'fake-peer' => '离线协作',
  final id => id[0].toUpperCase() + id.substring(1),
};

/// Holds one connection per paired PC so sessions and pending work can be
/// aggregated across computers. Leaving a page never stops a PC task.
class HostHub extends ChangeNotifier {
  HostHub({required this.storage, this.connector, this.lister, this.forgetter});
  final SecretStorage storage;
  final HostConnector? connector;
  final HostLister? lister;
  final HostForgetter? forgetter;
  final hosts = <HostState>[];

  /// 会话 tab filter: (computer, project). A view filter only; it never
  /// changes the workspace's execution target.
  final sessionScope = ValueNotifier<(String?, String?)>((null, null));
  String? loadError;
  bool loaded = false;
  bool _disposed = false;
  static const pollInterval = Duration(seconds: 20);

  bool get canConnect => connector != null;

  HostState? host(String id) {
    for (final h in hosts) {
      if (h.id == id) return h;
    }
    return null;
  }

  Future<void> load({bool connect = true}) async {
    try {
      final records = await (lister?.call() ?? Future.value(const []));
      for (final record in records) {
        final existing = host(record['hostId'] as String);
        if (existing == null) {
          hosts.add(HostState(record, storage));
        } else {
          existing.record = record;
        }
      }
      loadError = null;
    } catch (_) {
      loadError = '已配对电脑暂时无法读取，请检查系统安全存储。';
    }
    loaded = true;
    _notify();
    if (connect) await connectAll();
  }

  Future<void> resume() async {
    await Future.wait([
      connectAll(),
      for (final h in hosts)
        if (h.link is RoutedHostLink) (h.link as RoutedHostLink).resume(),
    ]);
  }

  Future<void> connectAll() => Future.wait([
    for (final h in hosts)
      if (h.status == LinkStatus.offline) connect(h),
  ]);

  Future<void> connect(HostState h) async {
    if (connector == null || h.status != LinkStatus.offline) return;
    final generation = h._transportGeneration;
    h.status = LinkStatus.connecting;
    h.error = null;
    _notify();
    try {
      final link = await connector!(h.record);
      if (_disposed ||
          generation != h._transportGeneration ||
          !hosts.contains(h)) {
        await link.close();
        return;
      }
      await attach(h, link);
    } catch (e) {
      if (_disposed || generation != h._transportGeneration) return;
      h.status = LinkStatus.offline;
      h.error = '$e';
      _notify();
    }
  }

  /// Takes ownership of an already authenticated link (e.g. right after pairing).
  Future<void> attach(HostState h, HostLink link) async {
    if (_disposed) {
      await link.close();
      return;
    }
    final dropping = _drop(h);
    final generation = h._transportGeneration;
    await dropping;
    if (_disposed || generation != h._transportGeneration) {
      await link.close();
      return;
    }
    h.link = link;
    if (link.hostName != null) h.record['displayName'] = link.hostName;
    h.status = LinkStatus.online;
    h.error = null;
    h._events = link.events.listen((event) {
      if (h.link != link) return;
      if (event['type'] == 'transport_changing' ||
          event['type'] == 'transport_changed') {
        h._transportGeneration++;
        h._subscribed.clear();
        h._subscriptionIds.clear();
        h._subscriptionQueue = Future.value();
        h._debounce?.cancel();
        final ready = event['type'] == 'transport_changed';
        h.status = ready ? LinkStatus.online : LinkStatus.connecting;
        h.error = ready ? null : '连接中断，正在重新连接。已发送操作不会重复执行。';
        h.revision++;
        _notify();
        if (ready) unawaited(refresh(h, executors: true));
        return;
      }
      if (event['type'] == 'disconnected') {
        if (h.link == link) _lost(h);
        return;
      }
      // Workspace/terminal stream notifications are handled by their pages.
      if (event['type'] != 'event') return;
      final envelope = event['event'];
      if (envelope is Map) {
        if (envelope['eventType'] == 'preferences.history.updated' &&
            envelope['payload'] is Map) {
          h.acceptHistory({
            'revision': envelope['streamVersion'],
            'lastSequence': envelope['sequence'],
            'preferences': envelope['payload'],
          });
        }
        h._stream.add(Map<String, dynamic>.from(envelope));
        // Streamed output is merged by the open conversation; it does not
        // change the overview, so it must not cost a full refresh per chunk.
        if (_streamOnly.contains(envelope['eventType'])) return;
      }
      if (h._debounce?.isActive != true) {
        h._debounce = Timer(
          const Duration(milliseconds: 200),
          () => refresh(h),
        );
      }
    });
    h._poll = Timer.periodic(pollInterval, (_) => refresh(h));
    _notify();
    await refresh(h, executors: true);
  }

  static const _streamOnly = {'message.delta', 'activity.updated'};

  Future<void> adopt(HostLink link) async {
    await load(connect: false);
    final h = host(link.hostId);
    if (h == null) {
      await link.close();
      return;
    }
    await attach(h, link);
  }

  void _lost(HostState h) {
    h._debounce?.cancel();
    h._poll?.cancel();
    h._events?.cancel();
    h._subscribed.clear();
    h._subscriptionIds.clear();
    final lost = h.link;
    h.link = null;
    h._transportGeneration++;
    unawaited(lost?.close());
    h.status = LinkStatus.offline;
    h.error ??= '连接已断开。电脑上的任务不会因此停止。';
    _notify();
  }

  Future<void> _drop(HostState h) async {
    final link = h.link;
    h._transportGeneration++;
    h._debounce?.cancel();
    h._poll?.cancel();
    await h._events?.cancel();
    h._subscribed.clear();
    h._subscriptionIds.clear();
    h.link = null;
    await link?.close();
  }

  Future<void> disconnect(HostState h) async {
    await _drop(h);
    h.status = LinkStatus.offline;
    h.error = null;
    _notify();
  }

  /// Removes a computer from this phone. Tasks on the computer are unaffected.
  Future<void> forget(HostState h) async {
    await forgetter?.call(h.id);
    hosts.remove(h);
    _notify();
    await _drop(h);
  }

  Future<void> refresh(HostState h, {bool executors = false}) async {
    final link = h.link;
    if (link == null || !h.online) return;
    final generation = h._transportGeneration;
    bool current() =>
        h.link == link && h._transportGeneration == generation && h.online;
    try {
      final snapshot = Map<String, dynamic>.from(
        await link.call('bootstrap', null) as Map,
      );
      if (!current()) return;
      h.snapshot = snapshot;
      try {
        final preferences = await link.call('history_preferences', null);
        if (!current()) return;
        if (preferences is Map) {
          h.acceptHistory(Map<String, dynamic>.from(preferences));
        }
      } catch (_) {
        // Older PCs may lack organization APIs; ordinary conversations remain usable.
      }
      if (executors || h.executors.isEmpty) {
        final executors = await _executors(link, snapshot);
        final quotas = await _quotas(link);
        if (!current()) return;
        h.executors = executors;
        h.quotas = quotas;
      }
      final approvals = <String, List<Map<String, dynamic>>>{};
      for (final task in h.tasks) {
        final id = task['taskId'] as String;
        if (task['activePrimaryRun'] == null &&
            h.pendingInteractions(id) == 0) {
          continue;
        }
        final list = await link.call('pending_approvals', [id, 50]) as List?;
        if (list != null && list.isNotEmpty) {
          approvals[id] = [
            for (final a in list) Map<String, dynamic>.from(a as Map),
          ];
        }
      }
      if (!current()) return;
      h.approvals = approvals;
      h.syncedAt = DateTime.now();
      h.error = null;
      h.revision++;
      _syncSubscriptions(h, link);
    } catch (e) {
      if (current()) h.error = '$e';
    }
    await refreshOperation(h);
  }

  Future<void> refreshOperation(HostState h) async {
    try {
      h.pendingOperation = await h.operations.pending();
    } catch (_) {
      h.error = '待核实操作暂时无法读取，请检查系统安全存储。';
    }
    _notify();
  }

  /// Keep the open conversation live even when its project is beyond the
  /// overview's subscription budget. Retire old overview streams as needed.
  void followProject(HostState h, String project) {
    if (h._focusedProject == project) return;
    h._focusedProject = project;
    if (h.online) _syncSubscriptions(h, h.link!);
  }

  void _syncSubscriptions(HostState h, HostLink link) {
    final desired = <String>{
      if (h.projects.any((p) => p['projectId'] == h._focusedProject))
        h._focusedProject!,
      for (final p in h.projects) p['projectId'] as String,
    }.take(16).toSet();
    for (final project in h._subscribed.toList()) {
      if (desired.contains(project)) continue;
      h._subscribed.remove(project);
      final id = h._subscriptionIds.remove(project);
      if (id != null) {
        unawaited(link.call('unsubscribe', id).catchError((Object _) => null));
      }
    }
    for (final project in desired) {
      _subscribe(h, link, project);
    }
  }

  void _subscribe(HostState h, HostLink link, String project) {
    if (!h._subscribed.add(project)) return;
    final generation = h._transportGeneration;
    final queued = h._subscriptionQueue.then((_) async {
      if (h.link != link ||
          h._transportGeneration != generation ||
          !h._subscribed.contains(project)) {
        return;
      }
      try {
        final result = await link.call('subscribe_project', [
          h.snapshot?['lastSequence'] ?? 0,
          project,
        ]);
        if (h.link != link || h._transportGeneration != generation) return;
        final id = result is Map ? result['subscriptionId'] : null;
        if (id is String) {
          if (h._subscribed.contains(project)) {
            h._subscriptionIds[project] = id;
          } else {
            await link.call('unsubscribe', id);
          }
        }
      } catch (_) {
        if (h.link == link && h._transportGeneration == generation) {
          h._subscribed.remove(project);
        }
      }
    });
    h._subscriptionQueue = queued;
    unawaited(queued);
  }

  Future<Map<String, Map<String, dynamic>>> _quotas(HostApi link) async {
    try {
      final list = await link.call('quota_snapshots_for', [null, null, false]);
      return {
        for (final q in (list as List? ?? const []))
          if (q is Map && q['installationId'] is String)
            q['installationId'] as String: Map<String, dynamic>.from(q),
      };
    } catch (_) {
      return const {};
    }
  }

  /// Loads the PC's ready Agents now (e.g. when a picker opens before the
  /// background refresh finished). Returns an error message, or null.
  Future<String?> loadExecutors(HostState h) async {
    final link = h.link;
    if (link == null) return '电脑离线';
    try {
      final snapshot =
          h.snapshot ??
          Map<String, dynamic>.from(await link.call('bootstrap', null) as Map);
      h.executors = await _executors(link, snapshot);
      h.quotas = await _quotas(link);
      _notify();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<List<Map<String, dynamic>>> _executors(
    HostApi link,
    Map<String, dynamic> snapshot,
  ) async {
    final preferences = await link.call('agent_preferences', null);
    final disabled =
        (((preferences is Map ? preferences['preferences'] : null) ??
                    preferences)
                as Map?)?['disabled']
            as List? ??
        const [];
    final ready = [
      for (final i in (snapshot['installations'] as List? ?? const []))
        if (i['status'] == 'ready' && !disabled.contains(i['providerId'])) i,
    ];
    final registered =
        await link.call('registered_executors', null) as List? ?? const [];
    return [
      for (final e in registered)
        if (ready.any((i) => i['installationId'] == e['installationId']))
          Map<String, dynamic>.from(e as Map),
    ];
  }

  /// Cross-computer sessions, most recently updated first.
  List<SessionRef> get sessions {
    final list = [
      for (final h in hosts)
        for (final t in h.tasks) SessionRef(h, t),
    ];
    list.sort((a, b) {
      final x = a.updatedAt, y = b.updatedAt;
      if (x == null && y == null) return 0;
      if (x == null) return 1;
      if (y == null) return -1;
      return y.compareTo(x);
    });
    return list;
  }

  List<ApprovalRef> get approvals => [
    for (final h in hosts)
      for (final entry in h.approvals.entries)
        if (h.task(entry.key) case final task?)
          for (final a in entry.value) ApprovalRef(h, task, a),
  ];

  List<HostState> get hostsWithPendingOperation => [
    for (final h in hosts)
      if (h.pendingOperation != null) h,
  ];

  int get pendingCount => approvals.length + hostsWithPendingOperation.length;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    sessionScope.dispose();
    _disposed = true;
    for (final h in hosts) {
      unawaited(_drop(h));
    }
    super.dispose();
  }
}
