import 'dart:convert';
import 'dart:math';
import 'host_api.dart';
import 'mobile_operations.dart' show operationId;

/// Random RFC 4122 v4 identifier for operation/idempotency IDs.
String uuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

Map<String, dynamic> _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _list(Object? v) => [
  for (final e in (v as List? ?? const []))
    if (e is Map) Map<String, dynamic>.from(e),
];

/// Typed wrappers over the paired-device gateway. The PC remains the source
/// of truth; every write carries an operation identity where the PC asks for
/// one, so a retry after a lost reply never repeats the effect.
extension PcApi on HostApi {
  // ── Files (read-only, task scoped) ──────────────────────────────────────
  Future<List<String>> workspaceRoots(String taskId) async => [
    for (final r
        in (await call('workspace_roots', taskId) as List? ?? const []))
      '$r',
  ];
  Future<List<Map<String, dynamic>>> directory(
    String taskId,
    int root,
    String path,
  ) async => _list(
    await call('workspace_directory', {
      'taskId': taskId,
      'root': root,
      'path': path,
    }),
  );
  Future<Map<String, dynamic>> filePreview(
    String taskId,
    int root,
    String path,
  ) async => _map(
    await call('workspace_preview', {
      'taskId': taskId,
      'root': root,
      'path': path,
    }),
  );
  Future<Map<String, dynamic>> findFiles(String taskId, String query) async =>
      _map(await call('workspace_find_files', [taskId, query, true]));

  // ── Changes / Git ───────────────────────────────────────────────────────
  Future<dynamic> review(String operation, Map<String, dynamic> arguments) =>
      call('review', {'operation': operation, 'arguments': arguments});
  Future<Map<String, dynamic>> changes(
    String taskId, {
    String mode = 'uncommitted',
  }) async => _map(
    await review('query', {
      'taskId': taskId,
      'rootId': null,
      'mode': mode,
      'reference': null,
      'parent': null,
    }),
  );
  Future<Map<String, dynamic>> changedFile(
    String taskId,
    String snapshotId,
    String rootId,
    String path,
  ) async => _map(
    await review('file', {
      'taskId': taskId,
      'snapshotId': snapshotId,
      'rootId': rootId,
      'path': path,
    }),
  );
  Future<List<Map<String, dynamic>>> gitWorkspaces(String taskId) async =>
      _list(await review('workspaces', {'taskId': taskId}));
  Future<dynamic> stage(
    String taskId,
    String snapshotId,
    String rootId,
    List<String> paths, {
    bool unstage = false,
  }) => review('index', {
    'operationId': uuid(),
    'taskId': taskId,
    'snapshotId': snapshotId,
    'rootId': rootId,
    'paths': paths,
    'action': unstage ? 'unstage' : 'stage',
  });

  /// Commit (optionally followed by push in one PC-side workflow). Returns
  /// the commit operation ID so a lost reply can be checked with [gitReceipt].
  Future<({String operationId, bool completed})> commit({
    required String taskId,
    required String rootId,
    required String snapshotId,
    required String message,
    required bool stageAll,
    bool push = false,
  }) async {
    final id = uuid();
    final completed = await review('git_action', {
      'operationId': id,
      'taskId': taskId,
      'rootId': rootId,
      'action': 'commit',
      'message': message,
      'stageAll': stageAll,
      'snapshotId': snapshotId,
      'workflow': push ? {'nextOperationId': uuid()} : null,
    });
    return (operationId: id, completed: completed == true);
  }

  Future<dynamic> gitAdvance(String taskId, String operationId) =>
      review('git_advance', {'taskId': taskId, 'operationId': operationId});
  Future<dynamic> gitReceipt(String taskId, String operationId) =>
      review('git_operation', {'taskId': taskId, 'operationId': operationId});
  Future<dynamic> gitPlain(String taskId, String rootId, String action) =>
      review('git_action', {
        'operationId': uuid(),
        'taskId': taskId,
        'rootId': rootId,
        'action': action,
        'message': '',
        'stageAll': false,
        'snapshotId': null,
        'workflow': null,
      });
  Future<String> commitSummary(
    String taskId,
    String rootId,
    Map<String, dynamic> executor,
  ) async {
    // An Agent writes the message on the PC; that can take minutes.
    final text = await withReplyTimeout(
      const Duration(minutes: 3),
      () => review('commit_summary', {
        'taskId': taskId,
        'rootId': rootId,
        'executor': executor,
        'language': 'zh-CN',
      }),
    );
    return '${text ?? ''}';
  }

  // ── Terminals ───────────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> terminals(String projectId) async =>
      _list(await call('terminal_list', projectId));
  Future<Map<String, dynamic>> terminalStart({
    required String projectId,
    required String cwd,
    int cols = 80,
    int rows = 24,
  }) async => _map(
    await call('terminal_start', {
      'projectLaunch': null,
      'operationId': uuid(),
      'projectId': projectId,
      'directoryIndex': 0,
      'taskId': null,
      'commandId': null,
      'label': '终端',
      'cwd': cwd,
      'command': null,
      'cols': cols,
      'rows': rows,
    }),
  );
  Future<Map<String, dynamic>> terminalRead(String id, String after) async =>
      _map(await call('terminal_read', [id, after]));
  Future<dynamic> terminalWrite(String id, List<int> bytes) =>
      call('terminal_write', [id, bytes]);
  Future<dynamic> terminalResize(String id, int cols, int rows) =>
      call('terminal_resize', [id, cols, rows]);
  Future<dynamic> terminalStop(String id) => call('terminal_stop', id);

  // ── Project runs & preview ──────────────────────────────────────────────
  Future<Map<String, dynamic>> projectRuns(String taskId) async =>
      _map(await call('project_runs', taskId));
  Future<Map<String, dynamic>> projectRunStart({
    required String taskId,
    required String generation,
    required int directoryIndex,
    required String commandId,
    int cols = 80,
    int rows = 24,
  }) async => _map(
    await call('project_run_start', {
      'taskId': taskId,
      'generation': generation,
      'directoryIndex': directoryIndex,
      'commandId': commandId,
      'cols': cols,
      'rows': rows,
      'operationId': uuid(),
    }),
  );
  Future<Map<String, dynamic>> previewOpen(String taskId, int port) async =>
      _map(await call('preview_open', {'taskId': taskId, 'port': port}));
  Future<Map<String, dynamic>> previewHttp(
    String previewId,
    String path, {
    String method = 'GET',
    Map<String, String> headers = const {},
    List<int> body = const [],
  }) async => _map(
    await call('preview_http', {
      'previewId': previewId,
      'path': path,
      'method': method,
      'headers': headers,
      'body': base64.encode(body),
    }),
  );
  Future<dynamic> previewClose(String previewId) =>
      call('preview_close', previewId);

  // ── Remote desktop & clipboard ──────────────────────────────────────────
  Future<Map<String, dynamic>> deviceStatus() async =>
      _map(await call('device_status', null));
  Future<List<Map<String, dynamic>>> displays() async =>
      _list(await call('remote_desktop_displays', null));
  Future<Map<String, dynamic>> desktopOpen(int monitorId) async => _map(
    await call('remote_desktop_open', {
      'monitorId': monitorId,
      'control': true,
    }),
  );
  Future<Map<String, dynamic>> desktopFrame(
    String leaseId, {
    int maxWidth = 1280,
    int quality = 60,
  }) async => _map(
    await call('remote_desktop_frame', {
      'leaseId': leaseId,
      'maxWidth': maxWidth,
      'quality': quality,
    }),
  );
  Future<dynamic> desktopSelect(String leaseId, int monitorId) => call(
    'remote_desktop_select',
    {'leaseId': leaseId, 'monitorId': monitorId},
  );
  Future<dynamic> desktopInput(
    String leaseId,
    int sequence,
    Map<String, dynamic> event,
  ) => call('remote_desktop_input', {
    'leaseId': leaseId,
    'sequence': '$sequence',
    'event': event,
  });
  Future<dynamic> desktopClose(String leaseId) =>
      call('remote_desktop_close', {'leaseId': leaseId});
  Future<Map<String, dynamic>> clipboardGet(String kind) async =>
      _map(await call('clipboard_get', {'kind': kind}));
  Future<dynamic> clipboardSet(Map<String, dynamic> value) =>
      call('clipboard_set', value);

  // ── Power & task lifecycle ──────────────────────────────────────────────
  Future<Map<String, dynamic>> powerPreferences() async =>
      _map(await call('power_preferences', null));
  Future<Map<String, dynamic>> setKeepAwake(
    bool enabled,
    String expectedRevision,
  ) async => _map(
    await call('power_preferences_set', {
      'operationId': uuid(),
      'expectedRevision': expectedRevision,
      'enabled': enabled,
    }),
  );

  Future<dynamic> executeCommand(
    Map<String, dynamic> payload, {
    Object? expectedStreamVersion,
  }) {
    final id = operationId();
    return call('execute', [
      {
        'schemaVersion': 1,
        'commandId': id,
        'idempotencyKey': id,
        'actor': {'kind': 'local_user'},
        'expectedStreamVersion': expectedStreamVersion,
        'issuedAt': DateTime.now().toUtc().toIso8601String(),
        'payload': payload,
      },
    ]);
  }

  Future<dynamic> renameTask(Map<String, dynamic> task, String title) =>
      executeCommand({
        'type': 'rename_task',
        'data': {'taskId': task['taskId'], 'title': title},
      }, expectedStreamVersion: task['streamVersion']);
  Future<dynamic> deleteTask(Map<String, dynamic> task) => executeCommand({
    'type': 'delete_task',
    'data': {'taskId': task['taskId']},
  }, expectedStreamVersion: task['streamVersion']);
}
