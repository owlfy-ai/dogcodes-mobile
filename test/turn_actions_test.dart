import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/features/conversation/timeline_model.dart';
import 'package:dogcodes_app/features/conversation/turn_statistics.dart';
import 'timeline_model_test.dart' show item;

void main() {
  final completion = {
    'startedAt': '2026-10-21T10:00:00Z',
    'completedAt': '2026-10-21T10:01:00Z',
  };
  test('copy does not include a late nested subagent response', () {
    final entries = buildEntries([
      item('u', 'user_message', 'task'),
      item('sub', 'activity', {
        'type': 'subagent',
        'childSessionId': 'child-session',
      }),
      item(
        'main',
        'assistant_message',
        'primary answer',
        completion: completion,
      ),
      item('child', 'activity', {
        'type': 'message',
        'sessionId': 'child-session',
        'text': 'nested answer',
      }),
    ]);
    expect(
      finalTurnReply(entries.whereType<TurnActionsEntry>().single.items),
      'primary answer',
    );
  });
  test(
    'each finished turn has one footer after its files; live turn has none',
    () {
      final entries = buildEntries([
        item('u1', 'user_message', 'first'),
        item('a1', 'assistant_message', 'answer', completion: completion),
        item('f1', 'turn_files', '{}'),
        item('u2', 'user_message', 'second', turn: 't2'),
        item(
          'a2',
          'assistant_message',
          'streaming',
          turn: 't2',
          completion: completion,
        ),
      ], activeTurnId: 't2');
      expect(entries.whereType<TurnActionsEntry>().single.turnId, 't1');
      expect((entries[2] as ItemEntry).item['itemId'], 'f1');
      expect(entries[3], isA<TurnActionsEntry>());
    },
  );
  test('copy reads only final nonempty reply, including decoded activity', () {
    expect(
      finalTurnReply([
        item('u', 'user_message', 'secret request'),
        item('a', 'assistant_message', 'interim'),
        item('final', 'activity', {'type': 'message', 'text': '**final**'}),
        item('tool', 'activity', {'type': 'tool', 'text': 'tool output'}),
        item('empty', 'assistant_message', ''),
      ]),
      '**final**',
    );
  });
  test(
    'statistics honor native counters and partial coverage without inventing zeros',
    () {
      final c = {
        ...completion,
        'firstOutputMs': 1250,
        'usage': {
          'scope': 'observed_requests',
          'models': ['m1', 'm1'],
          'inputTokens': 120,
          'outputTokens': 30,
          'credits': 1.5,
          'partial': true,
          'incompleteReason': 'partial output',
        },
      };
      final rows = Map.fromEntries(
        turnStatistics(
          TurnActionsEntry('t1', [
            item('a', 'assistant_message', 'done', completion: c),
          ], c),
        ).map((r) => MapEntry(r.$1, r.$2)),
      );
      expect(rows['合计 Tokens'], '150');
      expect(rows['模型'], 'm1');
      expect(rows['首个输出等待'], '1.25 秒');
      expect(rows.containsKey('原生费用（USD）'), isFalse);
      expect(rows['统计范围'], contains('部分数据'));
      expect(
        turnStatistics(TurnActionsEntry('t1', [], completion)),
        contains(('消耗数据', 'Agent 未提供')),
      );
    },
  );
}
