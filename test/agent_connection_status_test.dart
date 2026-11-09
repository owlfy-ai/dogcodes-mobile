import 'dart:async';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/features/conversation/new_session_page.dart';
import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'attachment_fixture.dart';
import 'cancel_widget_test.dart' show advance, waitForTask;
import 'local_features_widget_test.dart' show setup;
import 'widget_test.dart' show FakeLink, fakeHub;

class ConnectionLink extends FakeLink {
  ConnectionLink() : super('macbook-pro-host');
  String? state = 'starting';
  String provider = 'cursor';
  @override
  Future<dynamic> call(String method, dynamic params) async {
    final value = await super.call(method, params);
    if (method == 'bootstrap') {
      final task = (value['tasks'] as List).singleWhere(
        (task) => task['taskId'] == 't2',
      );
      task['activePrimaryRun'] = state == null
          ? null
          : {
              'runId': 'run-connection',
              'turnId': 'turn-connection',
              'state': state,
              'executor': {
                'providerId': provider,
                'installationId': 'current-installation',
              },
            };
    }
    return value;
  }
}

class HeldSubmission extends AttachmentLink {
  final release = Completer<void>();
  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'submission_intents' && params['type'] == 'start') {
      await release.future;
    }
    return super.call(method, params);
  }
}

void main() {
  setUp(() => languageOverride = 'zh');
  tearDown(() => languageOverride = null);
  testWidgets(
    'new task names the submitted Agent while the start request is pending',
    (tester) async {
      final link = HeldSubmission();
      final hub = await setup(tester, link);
      try {
        unawaited(
          tester
              .state<NavigatorState>(find.byType(Navigator).first)
              .push(
                MaterialPageRoute<void>(
                  builder: (_) => NewSessionPage(
                    hostId: hub.hosts.single.id,
                    projectId: 'p1',
                  ),
                ),
              ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, '开始新的任务');
        await tester.pump();
        await tester.tap(find.text('开始任务'));
        await advance(tester);
        expect(find.text('正在连接Claude Code'), findsOneWidget);
        link.release.complete();
        await tester.pumpAndSettle();
      } finally {
        if (!link.release.isCompleted) link.release.complete();
        await tester.pumpWidget(const SizedBox());
        hub.dispose();
        await tester.pump();
      }
    },
  );
  testWidgets(
    'shows the active Agent name while starting and queued, then responding',
    (tester) async {
      final link = ConnectionLink();
      final hub = fakeHub(link);
      try {
        await tester.pumpWidget(DogCodesApp(hub: hub));
        await advance(tester);
        await waitForTask(tester);
        await tester.tap(find.text('修复移动端布局'));
        await advance(tester);
        expect(find.text('正在连接Cursor'), findsOneWidget);
        expect(find.text('正在响应'), findsNothing);
        link.state = 'queued';
        link.provider = 'deepseek-harness';
        await hub.refresh(hub.hosts.single);
        await advance(tester);
        expect(find.text('正在连接DeepSeek Harness'), findsOneWidget);
        expect(find.text('正在连接Cursor'), findsNothing);
        link.state = 'running';
        await hub.refresh(hub.hosts.single);
        await advance(tester);
        expect(find.text('正在响应'), findsOneWidget);
        expect(find.text('正在连接DeepSeek Harness'), findsNothing);
        link.state = null;
        await hub.refresh(hub.hosts.single);
        await advance(tester);
        expect(find.text('正在响应'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        hub.dispose();
        await tester.pump();
      }
    },
  );
  testWidgets(
    'shows the submitted Agent before an active run or Stop button exists',
    (tester) async {
      final link = HeldSubmission();
      final hub = await setup(tester, link);
      try {
        await tester.tap(find.text('修复移动端布局'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, '你好');
        await tester.pump();
        await tester.tap(find.byTooltip('发送'));
        await advance(tester);
        expect(find.text('正在连接Claude Code'), findsOneWidget);
        expect(find.byTooltip('停止'), findsNothing);
        link.release.complete();
        await tester.pumpAndSettle();
        expect(find.text('正在连接Claude Code'), findsNothing);
      } finally {
        if (!link.release.isCompleted) link.release.complete();
        await tester.pumpWidget(const SizedBox());
        hub.dispose();
        await tester.pump();
      }
    },
  );
}
