import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../features/tools/line_diff.dart';
import 'host_api.dart';

/// One file a turn changed, as captured by the PC at the end of the turn
/// (`application/vnd.dogcodes.turn-changes.v1+json`, schema 1 or 2).
class TurnFile {
  TurnFile({
    required this.absolute,
    required this.display,
    required this.status,
    this.before,
    this.after,
    this.binary = false,
  });
  final String absolute, display, status;

  /// Text content before/after the turn; null when absent or not text.
  final String? before, after;
  final bool binary;

  List<DiffLine>? _lines;
  List<DiffLine> get lines => _lines ??= diffLines(
    before == null ? const [] : const LineSplitter().convert(before!),
    after == null ? const [] : const LineSplitter().convert(after!),
  );
  int get additions => lines.where((l) => l.kind == '+').length;
  int get deletions => lines.where((l) => l.kind == '-').length;
  String get name => display.split('/').last;
  String get directory {
    final i = display.lastIndexOf('/');
    return i < 0 ? '' : display.substring(0, i + 1);
  }
}

class TurnChanges {
  TurnChanges(this.files, {this.recovered = false});
  final List<TurnFile> files;

  /// Snapshot taken after an interruption; other tools may still be writing.
  final bool recovered;
  int get additions =>
      files.fold(0, (n, f) => n + (f.binary ? 0 : f.additions));
  int get deletions =>
      files.fold(0, (n, f) => n + (f.binary ? 0 : f.deletions));

  static String _slash(String p) =>
      p.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');
  static bool _absolute(String p) =>
      p.startsWith('/') || RegExp(r'^[a-zA-Z]:/').hasMatch(p);

  static ({String? text, bool binary}) _content(Object? version) {
    if (version is! Map) return (text: null, binary: false);
    final hex = version['hex'];
    if (hex is! String) return (text: null, binary: version['kind'] == 'file');
    try {
      final bytes = [
        for (var i = 0; i + 1 < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ];
      if (bytes.contains(0)) return (text: null, binary: true);
      return (text: utf8.decode(bytes), binary: false);
    } catch (_) {
      return (text: null, binary: true);
    }
  }

  factory TurnChanges.parse(Map<String, dynamic> data) {
    final workspaces = [
      for (final w in (data['workspacePaths'] as List? ?? const []))
        _slash('$w'),
    ];
    final base = workspaces.length == 1 ? workspaces.single : null;
    final files = <TurnFile>[];
    for (final raw in (data['files'] as List? ?? const [])) {
      if (raw is! Map || raw['path'] is! String) continue;
      final path = _slash(raw['path'] as String);
      final workspace = raw['workspacePath'] is String
          ? _slash(raw['workspacePath'] as String)
          : base;
      final relative = _slash(
        (raw['relativePath'] ?? raw['workspaceRelativePath'] ?? path) as String,
      );
      final absolute = _absolute(path)
          ? path
          : workspace == null
          ? path
          : '$workspace/$relative';
      // Several roots: keep the root folder so same-named files differ.
      final display = workspaces.length > 1 && workspace != null
          ? '${workspace.split('/').last}/$relative'
          : _absolute(path) && workspace != null
          ? relative
          : path;
      final before = _content(raw['before']), after = _content(raw['after']);
      files.add(
        TurnFile(
          absolute: absolute,
          display: display,
          status: '${raw['status'] ?? 'M'}',
          before: before.text,
          after: after.text,
          binary: before.binary || after.binary,
        ),
      );
    }
    return TurnChanges(
      files,
      recovered:
          data['attribution'] == 'workspace_recovery_interval' ||
          data['recoveredAfterInterruption'] == true,
    );
  }

  /// This turn's files that still have uncommitted changes, per Git root of a
  /// `review query` snapshot. Files committed or undone since are left out.
  List<TurnCommitTarget> commitTargets(Map<String, dynamic> snapshot) {
    final targets = <TurnCommitTarget>[];
    for (final r in (snapshot['roots'] as List? ?? const [])) {
      if (r is! Map) continue;
      final root = r['root'] as Map? ?? const {};
      if (root['git'] != true) continue;
      final rootPath = _slash('${root['path']}');
      final changed = <String>{
        for (final f in (r['files'] as List? ?? const []))
          if (f is Map) ...[
            _slash('${f['path']}'),
            if (f['previousPath'] is String)
              _slash(f['previousPath'] as String),
          ],
        for (final u in (r['untracked'] as List? ?? const [])) _slash('$u'),
      };
      final paths = <String>{
        for (final f in files)
          if (f.absolute.startsWith('$rootPath/'))
            f.absolute.substring(rootPath.length + 1),
      }.where(changed.contains).toList();
      if (paths.isNotEmpty) {
        targets.add(TurnCommitTarget('${root['id']}', rootPath, paths));
      }
    }
    return targets;
  }
}

class TurnCommitTarget {
  TurnCommitTarget(this.rootId, this.rootPath, this.paths);
  final String rootId, rootPath;
  final List<String> paths;
  String get name => rootPath.split('/').last;
}

/// Per PC link: artifact IDs are only meaningful on the PC that made them.
final _caches = Expando<Map<String, Future<TurnChanges>>>();

/// Long conversations hold many summaries; reading them all at once would
/// crowd out the link's in-flight request budget (and user actions).
class _Gate {
  int active = 0;
  final waiting = <Completer<void>>[];
  Future<T> run<T>(Future<T> Function() task) async {
    if (active >= 2) {
      final turn = Completer<void>();
      waiting.add(turn);
      await turn.future;
    }
    active++;
    try {
      return await task();
    } finally {
      active--;
      if (waiting.isNotEmpty) waiting.removeAt(0).complete();
    }
  }
}

final _gates = Expando<_Gate>();

extension TurnArtifacts on HostApi {
  /// Reads a turn's captured changes in 32 KiB chunks and checks the hash the
  /// timeline recorded. Immutable, so cached per artifact.
  Future<TurnChanges> turnChanges(String taskId, Map<String, dynamic> meta) {
    final key = '${meta['artifactId']}:${meta['payloadSha256']}';
    final cache = _caches[this] ??= {};
    if (cache.length > 64) cache.remove(cache.keys.first);
    final gate = _gates[this] ??= _Gate();
    return cache[key] ??= gate.run(() => _read(taskId, meta)).catchError((
      Object e,
    ) {
      cache.remove(key);
      throw e;
    });
  }

  Future<TurnChanges> _read(String taskId, Map<String, dynamic> meta) async {
    final total = (meta['byteLength'] as num).toInt();
    if (total > 1048576) throw StateError('本轮变更记录过大，请在电脑上查看');
    final bytes = <int>[];
    while (bytes.length < total || total == 0) {
      final chunk = await call('read_artifact', [
        null,
        {
          'taskId': taskId,
          'artifactId': meta['artifactId'],
          'expectedPayloadSha256': meta['payloadSha256'],
          'offset': bytes.length,
          'limit': 32768,
        },
      ]);
      final part = (chunk as Map)['bytes'] as List? ?? const [];
      if (chunk['offset'] != bytes.length || (part.isEmpty && total > 0)) {
        throw StateError('本轮变更记录读取不一致');
      }
      bytes.addAll(part.cast<num>().map((b) => b.toInt()));
      if (chunk['nextOffset'] == null) break;
    }
    if (bytes.length != total ||
        sha256.convert(bytes).toString() != meta['payloadSha256']) {
      throw StateError('本轮变更记录校验失败');
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map) throw StateError('本轮变更记录格式不可用');
    return TurnChanges.parse(Map<String, dynamic>.from(data));
  }
}
