import 'dart:convert';
import 'dart:math';
import 'host_api.dart';

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
class DesktopAuthorizationEnded implements Exception {
  const DesktopAuthorizationEnded(this.message);
  final String message;
  @override
  String toString() => message;
}

void checkDesktopAuthorization(dynamic response) {
  if (response is Map && response['authorizationEnded'] == true) {
    throw DesktopAuthorizationEnded(
      response['error'] as String? ?? '电脑已结束屏幕共享，请重新连接并授权',
    );
  }
}

extension PcApi on HostApi {
  Future<dynamic> _desktopCall(String method, dynamic args) async {
    final response = await call(method, args);
    checkDesktopAuthorization(response);
    return response;
  }

  /// `showHidden` is sent only when set, so older PCs keep answering.
  Future<Map<String, dynamic>> hostDirectories(
    String? path, {
    int offset = 0,
    bool showHidden = false,
  }) async => _map(
    await call('host_directories', {
      'path': path,
      'offset': offset,
      if (showHidden) 'showHidden': true,
    }),
  );

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
  Future<dynamic> terminalResize(String id, int cols, int rows) =>
      call('terminal_resize', [id, cols, rows]);

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
      _list(await _desktopCall('remote_desktop_displays', null));

  /// With [video] the PC also streams the screen as H.264, encoded
  /// [videoMaxWidth] wide: on the connection's WebRTC track (direct desktop
  /// connections), or with [videoTransport] `binary` as binary messages on
  /// this link, for a phone that decodes them itself.
  Future<Map<String, dynamic>> desktopOpen(
    int monitorId, {
    bool video = false,
    int videoMaxWidth = 1920,
    String? videoTransport,
  }) async => _map(
    await _desktopCall('remote_desktop_open', {
      'monitorId': monitorId,
      'control': true,
      'chunkedMessages': true,
      if (video) ...{
        'video': true,
        'deferVideo': true,
        'videoMaxWidth': videoMaxWidth,
        'videoTransport': ?videoTransport,
      },
    }),
  );

  /// With [knownFrameId] a PC that supports it may answer `unchanged`
  /// without image bytes when the screen still matches that frame.
  Future<Map<String, dynamic>> desktopFrame(
    String leaseId, {
    int maxWidth = 1280,
    int quality = 60,
    String? knownFrameId,
  }) async => _map(
    await _desktopCall('remote_desktop_frame', {
      'leaseId': leaseId,
      'maxWidth': maxWidth,
      'quality': quality,
      'knownFrameId': ?knownFrameId,
    }),
  );
  Future<dynamic> desktopSelect(String leaseId, int monitorId) => _desktopCall(
    'remote_desktop_select',
    {'leaseId': leaseId, 'monitorId': monitorId},
  );
  Future<dynamic> desktopInput(
    String leaseId,
    int sequence,
    Map<String, dynamic> event,
  ) => _desktopCall('remote_desktop_input', {
    'leaseId': leaseId,
    'sequence': '$sequence',
    'event': event,
  });

  /// An ordered batch under one sequence number (PCs whose open reply
  /// carries `inputBatch`).
  Future<dynamic> desktopInputBatch(
    String leaseId,
    int sequence,
    List<Map<String, dynamic>> events,
  ) => _desktopCall('remote_desktop_input', {
    'leaseId': leaseId,
    'sequence': '$sequence',
    'events': events,
  });
  Future<dynamic> desktopClose(String leaseId) =>
      call('remote_desktop_close', {'leaseId': leaseId});

  // ── Power & task lifecycle ──────────────────────────────────────────────
  Future<Map<String, dynamic>> powerPreferences() async =>
      _map(await call('power_preferences', null));
}
