/// Line diff (Myers O((N+M)·D)) for the phone's single-column diff view.
library;

class DiffLine {
  const DiffLine(this.kind, this.text, {this.oldNo, this.newNo});

  /// ' ' context, '+' added, '-' removed, '@' hunk separator.
  final String kind;
  final String text;
  final int? oldNo, newNo;
}

String _strip(String l) => l.endsWith('\n') ? l.substring(0, l.length - 1) : l;

/// Full edit script between [before] and [after]. Very large, very different
/// inputs fall back to "all removed, all added" rather than stalling the UI.
List<DiffLine> diffLines(
  List<String> before,
  List<String> after, {
  int maxD = 4000,
}) {
  final a = before.map(_strip).toList(), b = after.map(_strip).toList();
  final n = a.length, m = b.length;
  // Trim common prefix/suffix first; most edits are local.
  var start = 0;
  while (start < n && start < m && a[start] == b[start]) {
    start++;
  }
  var endA = n, endB = m;
  while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
    endA--;
    endB--;
  }
  final out = <DiffLine>[
    for (var i = 0; i < start; i++)
      DiffLine(' ', a[i], oldNo: i + 1, newNo: i + 1),
  ];
  final middle = _myers(a.sublist(start, endA), b.sublist(start, endB), maxD);
  var oi = start, ni = start;
  for (final op in middle) {
    if (op == 0) {
      out.add(DiffLine(' ', a[oi], oldNo: ++oi, newNo: ++ni));
    } else if (op < 0) {
      out.add(DiffLine('-', a[oi], oldNo: ++oi));
    } else {
      out.add(DiffLine('+', b[ni], newNo: ++ni));
    }
  }
  for (var i = endA; i < n; i++) {
    out.add(DiffLine(' ', a[i], oldNo: i + 1, newNo: ++ni));
  }
  return out;
}

/// Edit ops: 0 keep, -1 delete from a, +1 insert from b.
List<int> _myers(List<String> a, List<String> b, int maxD) {
  final n = a.length, m = b.length;
  if (n == 0) return List.filled(m, 1);
  if (m == 0) return List.filled(n, -1);
  final max = n + m;
  final offset = max;
  var v = List<int>.filled(2 * max + 2, 0);
  final trace = <List<int>>[];
  for (var d = 0; d <= max; d++) {
    if (d > maxD) return [...List.filled(n, -1), ...List.filled(m, 1)];
    trace.add(List.of(v));
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
        x = v[offset + k + 1];
      } else {
        x = v[offset + k - 1] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[offset + k] = x;
      if (x >= n && y >= m) {
        return _backtrack(trace, n, m, offset);
      }
    }
  }
  return [...List.filled(n, -1), ...List.filled(m, 1)];
}

List<int> _backtrack(List<List<int>> trace, int n, int m, int offset) {
  final ops = <int>[];
  var x = n, y = m;
  for (var d = trace.length - 1; d >= 0; d--) {
    final v = trace[d];
    final k = x - y;
    int prevK;
    if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
      prevK = k + 1;
    } else {
      prevK = k - 1;
    }
    final prevX = v[offset + prevK];
    final prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      ops.add(0);
      x--;
      y--;
    }
    if (d > 0) {
      if (x == prevX) {
        ops.add(1);
        y--;
      } else {
        ops.add(-1);
        x--;
      }
    }
  }
  return ops.reversed.toList();
}

/// Changed lines with [context] lines around them, separated by '@' rows.
List<DiffLine> hunks(List<DiffLine> lines, {int context = 3}) {
  final keep = List<bool>.filled(lines.length, false);
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].kind == ' ') continue;
    for (var j = i - context; j <= i + context; j++) {
      if (j >= 0 && j < lines.length) keep[j] = true;
    }
  }
  final out = <DiffLine>[];
  var gap = false;
  for (var i = 0; i < lines.length; i++) {
    if (!keep[i]) {
      gap = true;
      continue;
    }
    if (gap && out.isNotEmpty) out.add(const DiffLine('@', '⋯'));
    gap = false;
    out.add(lines[i]);
  }
  return out;
}
