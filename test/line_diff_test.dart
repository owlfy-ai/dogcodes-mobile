import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/features/tools/line_diff.dart';

String render(List<DiffLine> l) => l.map((d) => '${d.kind}${d.text}').join('|');

void main() {
  test('myers diff keeps common lines and numbers both sides', () {
    final d = diffLines(
      ['a\n', 'b\n', 'c\n', 'd\n'],
      ['a\n', 'x\n', 'c\n', 'd\n', 'e\n'],
    );
    expect(render(d), ' a|-b|+x| c| d|+e');
    expect(d[3].oldNo, 3);
    expect(d[3].newNo, 3);
    expect(d.last.newNo, 5);
  });
  test('added and deleted files', () {
    expect(render(diffLines([], ['x', 'y'])), '+x|+y');
    expect(render(diffLines(['x'], [])), '-x');
  });
  test('hunks keep context and mark gaps', () {
    final before = [for (var i = 0; i < 20; i++) 'l$i'];
    final after = [...before]..[10] = 'changed';
    final h = hunks(diffLines(before, after), context: 1);
    expect(render(h), ' l9|-l10|+changed| l11');
    final two = [...after]..[1] = 'top';
    expect(
      render(hunks(diffLines(before, two), context: 1)),
      ' l0|-l1|+top| l2|@⋯| l9|-l10|+changed| l11',
    );
  });
}
