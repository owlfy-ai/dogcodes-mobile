import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/features/conversation/review_report.dart';
import 'review_fixture.dart';
import 'widget_test.dart' show fakeHub;

Future<void> openConversation(
  WidgetTester tester,
  HostHub hub,
  ReviewLink link,
) async {
  await tester.binding.setSurfaceSize(const Size(360, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await hub.load(connect: false);
  await hub.attach(hub.hosts.single, link);
  await tester.pumpWidget(DogCodesApp(hub: hub));
  await tester.pumpAndSettle();
  await tester.tap(find.text('修复移动端布局'));
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class RunningLink extends ReviewLink {
  @override
  Future<dynamic> call(String method, dynamic params) async {
    final value = await super.call(method, params);
    if (method == 'bootstrap') {
      for (final task in value['tasks'] as List) {
        if (task['taskId'] == 't2') {
          task['activePrimaryRun'] = {'runId': 'run9', 'turnId': 'turn9'};
        }
      }
    }
    return value;
  }
}

void main() {
  testWidgets('Fork during a run says why instead of doing nothing', (
    tester,
  ) async {
    final hub = fakeHub(), link = RunningLink();
    // A running session animates forever, so frames are pumped by hand.
    Future<void> frames() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await hub.load(connect: false);
    await hub.attach(hub.hosts.single, link);
    await tester.pumpWidget(DogCodesApp(hub: hub));
    await frames();
    await tester.tap(find.text('修复移动端布局'));
    await frames();
    const reason = '会话正在运行，结束后才能从本轮 Fork';
    final fork = find.byTooltip(reason);
    await tester.scrollUntilVisible(
      fork,
      -300,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('conversation-timeline')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(fork);
    await frames();
    expect(find.text(reason), findsWidgets);
    expect(find.text('Fork 会话'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });

  testWidgets(
    'review can be cancelled and explicitly rechecked with a new run',
    (tester) async {
      final hub = fakeHub(), link = ReviewLink()..autoComplete = false;
      await openConversation(tester, hub, link);
      await tapVisible(tester, find.widgetWithText(TextButton, '本轮审查'));
      await tapVisible(tester, find.widgetWithText(OutlinedButton, '审查代码'));
      final original = link.starts.single['runId'];
      await tapVisible(tester, find.text('取消审查'));
      expect(find.text('已取消'), findsOneWidget);
      expect(find.text('已完成'), findsNothing);
      link.autoComplete = true;
      await tapVisible(tester, find.text('重新检查'));
      expect(link.starts.length, 2);
      expect(link.starts.last['runId'], isNot(original));
      expect(link.starts.last['retryOf'], original);
      expect(link.starts.last['turnId'], 'turn2');
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'repair recheck links to the exact source review and repair turn',
    (tester) async {
      final hub = fakeHub(), link = ReviewLink();
      await openConversation(tester, hub, link);
      await tapVisible(tester, find.widgetWithText(TextButton, '本轮审查'));
      await tapVisible(tester, find.widgetWithText(OutlinedButton, '审查代码'));
      final original = link.starts.single['runId'];
      link.runs.single['repairs'] = [
        {
          'turnId': 'repair-turn',
          'status': 'completed',
          'findingIndices': [0],
          'recheckRuns': [],
        },
      ];
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('复审修复后的版本'));
      expect(link.starts.length, 2);
      expect(link.starts.last['turnId'], 'repair-turn');
      expect(link.starts.last['retryOf'], isNull);
      expect(link.starts.last['recheckOf'], {
        'runId': original,
        'repairTurnId': 'repair-turn',
      });
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'turn footer copies final reply and shows real statistics on a phone screen',
    (tester) async {
      final hub = fakeHub(), link = ReviewLink();
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = call.arguments['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await openConversation(tester, hub, link);
      expect(find.byTooltip('复制本轮回复'), findsOneWidget);
      await tapVisible(tester, find.byTooltip('复制本轮回复'));
      expect(copied, '匹配历史正文');
      await tapVisible(tester, find.byTooltip('本轮消耗'));
      expect(find.text('本轮耗时'), findsOneWidget);
      expect(find.text('60 秒'), findsOneWidget);
      expect(find.text('Agent 未提供'), findsOneWidget);
      expect(link.starts, isEmpty);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'turn review uses chosen Agent, opens frozen source, and repairs with the primary Agent',
    (tester) async {
      final hub = fakeHub(), link = ReviewLink();
      await openConversation(tester, hub, link);
      await tapVisible(tester, find.widgetWithText(TextButton, '本轮审查'));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cursor').last);
      await tester.pumpAndSettle();
      await tapVisible(tester, find.widgetWithText(OutlinedButton, '审查代码'));
      expect(link.starts.single['executor']['providerId'], 'cursor');
      expect(link.starts.single['turnId'], 'turn2');
      expect(find.text('已完成'), findsOneWidget);
      await tapVisible(tester, find.text('高 · 权限判断缺失'));
      await tapVisible(tester, find.text('查看审查时的代码'));
      expect(link.sources.single, [
        't2',
        link.starts.single['runId'],
        'file-1',
      ]);
      expect(find.text('审查代码证据'), findsOneWidget);
      Navigator.of(tester.element(find.text('审查代码证据'))).pop();
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find
            .descendant(
              of: find.byType(ReviewReportView),
              matching: find.byType(Checkbox),
            )
            .first,
      );
      await tapVisible(tester, find.text('开始修复'));
      expect(link.repairs.single['target'], isNull);
      expect(link.repairs.single['reference']['findingIndices'], [0]);
      expect(link.entry!['intent']['target']['providerId'], 'claude');
      expect(find.text('修复已提交给主 Agent，携带所选问题及原审查上下文。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'interrupted review stays incomplete and preserves failure feedback',
    (tester) async {
      final hub = fakeHub(), link = ReviewLink()..autoComplete = false;
      await openConversation(tester, hub, link);
      await tapVisible(tester, find.widgetWithText(TextButton, '本轮审查'));
      await tapVisible(tester, find.widgetWithText(OutlinedButton, '安全检查'));
      expect(find.text('检查中'), findsOneWidget);
      expect(find.text('已完成'), findsNothing);
      link.runs.single['status'] = 'interrupted';
      link.runs.single['error'] =
          'RetriableError: HTTP/2 keepalive ping timed out after 5000ms';
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('连接中断'), findsOneWidget);
      expect(find.text('已完成'), findsNothing);
      expect(find.text('审查连接中断，本次审查未完成。请检查网络后重新检查。'), findsOneWidget);
      expect(find.text('重新检查'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
    },
  );

  testWidgets(
    'review lost reply is verified through pending card without a second start',
    (tester) async {
      final hub = fakeHub(), link = ReviewLink()..loseStart = true;
      await openConversation(tester, hub, link);
      await tapVisible(tester, find.widgetWithText(TextButton, '本轮审查'));
      await tapVisible(tester, find.widgetWithText(OutlinedButton, '性能分析'));
      // The page and sheet both expose the same durable pending operation.
      expect(find.text('本轮审查：还没收到电脑确认'), findsWidgets);
      await tapVisible(tester, find.text('重新确认').last);
      expect(link.starts.length, 1);
      expect(hub.hosts.single.pendingOperation, isNull);
      expect(find.text('本轮审查：还没收到电脑确认'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
    },
  );
}
