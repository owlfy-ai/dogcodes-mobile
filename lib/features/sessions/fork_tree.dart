import '../../core/host_hub.dart';

/// Nests forked sessions under the session they came from, as the desktop
/// sidebar does. A fork nests only when its source is listed beside it on the
/// same computer and in the same section (pinned, archived or ordinary);
/// otherwise it stays a row of its own so it can never disappear.
class ForkTree {
  ForkTree(Iterable<SessionRef> listed) {
    final byKey = {for (final s in listed) _key(s.host.id, s.taskId): s};
    for (final s in listed) {
      final source = s.forkedFrom;
      if (source == null) continue;
      final parent = byKey[_key(s.host.id, source)];
      if (parent == null || _section(parent) != _section(s)) continue;
      if (_cyclic(s, byKey)) continue;
      nested.add(_key(s.host.id, s.taskId));
      (_children[_key(s.host.id, source)] ??= []).add(s);
    }
  }

  final nested = <String>{};
  final _children = <String, List<SessionRef>>{};

  bool isNested(SessionRef s) => nested.contains(_key(s.host.id, s.taskId));
  List<SessionRef> childrenOf(SessionRef s) =>
      _children[_key(s.host.id, s.taskId)] ?? const [];

  /// [s] followed by its forks, depth first, each with its nesting depth.
  Iterable<(SessionRef, int)> branch(SessionRef s, [int depth = 0]) sync* {
    yield (s, depth);
    for (final child in childrenOf(s)) {
      yield* branch(child, depth + 1);
    }
  }

  static String _key(String host, String task) => '$host/$task';
  static String _section(SessionRef s) => s.pinned
      ? 'pinned'
      : s.archived
      ? 'archived'
      : 'listed';
  static bool _cyclic(SessionRef s, Map<String, SessionRef> byKey) {
    final seen = {s.taskId};
    for (var next = s.forkedFrom; next != null;) {
      if (!seen.add(next)) return true;
      next = byKey[_key(s.host.id, next)]?.forkedFrom;
    }
    return false;
  }
}
