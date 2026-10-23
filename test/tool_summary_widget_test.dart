import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/features/conversation/timeline_model.dart';
import 'package:dogcodes_app/features/conversation/timeline_view.dart';
import 'package:dogcodes_app/ui/theme.dart';

Map<String, dynamic> tool(String id, Map<String, dynamic> data) => {
  'itemId': id,
  'turnId': 'turn1',
  'kind': 'activity',
  'text': jsonEncode(data),
};

void main() {
  test('only failed steps and subagent results carry output to show', () {
    Activity a(Map<String, dynamic> data) => Activity(data);
    expect(failurePreview(a({'status': 'completed', 'output': 'x'})), isNull);
    expect(
      failurePreview(a({'status': 'failed', 'outputPreview': 'boom'})),
      'boom',
    );
    final live = [for (var i = 1; i <= 30; i++) 'line $i'].join('\n');
    final tail = failurePreview(
      a({
        'status': 'failed',
        'output': {'stdout': live},
      }),
    )!;
    expect(tail.split('\n'), hasLength(20));
    expect(tail.split('\n').first, 'line 11');
    expect(subagentResult(a({'outputPreview': '已修复'})), '已修复');
    expect(subagentResult(a({})), isNull);
  });

  testWidgets('tool rows open to what ran, never to its output', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: dcTheme(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: TimelineView(
              items: [
                tool('ok', {
                  'type': 'tool',
                  'name': 'Bash',
                  'category': '终端',
                  'status': 'completed',
                  'input': {'command': 'pnpm test'},
                  'output': {'stdout': '成功的输出内容'},
                }),
                tool('bad', {
                  'type': 'tool',
                  'name': 'Bash',
                  'category': '终端',
                  'status': 'failed',
                  'input': {'command': 'pnpm build'},
                  'outputPreview': '构建失败：缺少依赖',
                  'compact': true,
                }),
              ],
            ),
          ),
        ),
      ),
    );
    for (final row in ['pnpm test', 'pnpm build']) {
      await tester.tap(find.textContaining(row).first);
      await tester.pumpAndSettle();
    }
    expect(find.text('\$ pnpm test'), findsOneWidget);
    expect(find.text('成功的输出内容'), findsNothing);
    expect(find.text('构建失败：缺少依赖'), findsOneWidget);
    expect(find.text('完整输出请在电脑上查看'), findsNWidgets(2));
  });
}
