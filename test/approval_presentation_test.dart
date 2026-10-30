import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/features/inbox/approval_presentation.dart';
import 'package:dogcodes_app/l10n/strings.dart';

void main() {
  setUp(() => testLanguagePreferences = const [Locale('zh')]);
  tearDown(() => testLanguagePreferences = null);

  test('a wrapped shell command shows the command, not the envelope', () {
    final view = approvalPresentation(
      '{"input":{"command":"rm -- approval-test.txt"}}',
      'Bash',
    );
    expect(view.category, '终端');
    expect(view.question, '是否允许运行以下命令？');
    expect(view.sections.single.label, '命令');
    expect(view.sections.single.text, 'rm -- approval-test.txt');
    expect(view.warning, isNull);
  });

  test('argv is quoted and the agent reason becomes the question', () {
    final view = approvalPresentation(
      '{"rawInput":{"argv":["git","commit","-m","fix it"],'
      '"justification":"Commit the fix"}}',
    );
    expect(view.question, 'Commit the fix');
    expect(view.sections.single.text, "git commit -m 'fix it'");
  });

  test('file edits list the path and the replaced text', () {
    final view = approvalPresentation(
      '{"input":{"file_path":"lib/a.dart","old_string":"a","new_string":"b"}}',
      'Edit',
    );
    expect(view.category, '修改文件');
    expect(view.question, '是否允许修改以下文件？');
    expect([for (final s in view.sections) s.label], ['文件路径', '替换前', '替换后']);
  });

  test('plain text stays a command; a cut-off envelope is never shown', () {
    expect(approvalPresentation('pnpm test').sections.single.text, 'pnpm test');
    final broken = approvalPresentation('{"input":{"command":"rm');
    expect(broken.sections, isEmpty);
    expect(broken.warning, contains('格式不完整'));
  });
}
