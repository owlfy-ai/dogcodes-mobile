import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/features/conversation/timeline_model.dart';

Item item(
  String id,
  String kind,
  Object text, {
  String turn = 't1',
  Map? completion,
}) => {
  'itemId': id,
  'taskId': 'task',
  'turnId': turn,
  'kind': kind,
  'text': text is String ? text : jsonEncode(text),
  'providerId': 'cursor',
  'occurredAt': '2026-10-19T06:00:00Z',
  'attachments': [],
  'turnCompletion': ?completion,
};

void main() {
  test('activity JSON decodes into categories, titles and terminal output', () {
    final bash = activityOf(
      item('a', 'activity', {
        'type': 'tool',
        'name': 'Bash',
        'status': 'completed',
        'input': {'command': 'pnpm test'},
        'output': {'stdout': 'ok', 'stderr': ''},
      }),
    )!;
    expect(categoryOf(bash), '终端');
    expect(toolTitle(bash), 'pnpm test');
    expect(terminalOutput(bash.output), 'ok');
    final read = activityOf(
      item('b', 'activity', {
        'type': 'tool',
        'category': 'read',
        'status': 'completed',
        'input': {'file_path': '/repo/src/auth.ts'},
      }),
    )!;
    expect(categoryOf(read), '读取');
    expect(toolTitle(read), '/repo/src/auth.ts');
    expect(
      terminalCommand({
        'argv': ['git', 'commit', '-m', 'a b'],
      }),
      "git commit -m 'a b'",
    );
    expect(activityOf(item('c', 'activity', 'not json')), isNull);
  });

  test('finished turn folds its process behind the final answer', () {
    final done = {
      'startedAt': '2026-10-19T06:00:00Z',
      'completedAt': '2026-10-19T06:01:05Z',
    };
    final items = [
      item('u', 'user_message', '你是什么模型'),
      item('th', 'activity', {
        'type': 'thought',
        'status': 'completed',
        'durationMs': 2000,
      }),
      item('r1', 'activity', {
        'type': 'tool',
        'category': 'read',
        'status': 'completed',
        'input': {'path': 'a'},
      }),
      item('r2', 'activity', {
        'type': 'tool',
        'category': 'search',
        'status': 'completed',
        'input': {'pattern': 'x'},
      }),
      item('empty', 'activity', {'type': 'tool', 'sourceEventId': 'e'}),
      item('m', 'activity', {
        'type': 'message',
        'text': '我是 **Composer**',
      }, completion: done),
      item('h', 'handoff', 'Confirmed codex → cursor · art_1'),
      item('f', 'turn_files', {'artifactId': 'art_2'}),
    ];
    final entries = buildEntries(items, agentName: (p) => 'Cursor');
    expect(entries.length, 5);
    expect((entries[0] as ItemEntry).item['kind'], 'user_message');
    final process = entries[1] as ProcessEntry;
    expect(process.steps, 2);
    expect((process.entries[1] as LookupEntry).summary, '读取 1 次 · 搜索 1 次');
    expect(
      durationLabel(process.completedAt!.difference(process.startedAt!)),
      '1 分 5 秒',
    );
    expect((entries[2] as ItemEntry).item['itemId'], 'm');
    expect((entries[3] as ItemEntry).item['kind'], 'turn_files');
    expect((entries[4] as TurnActionsEntry).turnId, 't1');
  });

  test('an active turn stays expanded and subagent steps nest under it', () {
    final items = [
      item('u', 'user_message', 'go'),
      item('tool:task:t1:sub', 'activity', {
        'type': 'subagent',
        'status': 'running',
        'title': '检查依赖',
      }),
      item('child', 'activity', {
        'type': 'tool',
        'name': 'Read',
        'status': 'completed',
        'parentId': 'sub',
      }),
      item(
        'm',
        'activity',
        {'type': 'message', 'text': 'done'},
        completion: {'startedAt': 'x', 'completedAt': 'y'},
      ),
    ];
    final entries = buildEntries(items, activeTurnId: 't1');
    expect(entries.length, 3);
    final sub = entries[1] as ItemEntry;
    expect(sub.children.single['itemId'], 'child');
  });
}
