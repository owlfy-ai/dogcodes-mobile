import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/access_client.dart';
import 'package:dogcodes_app/core/mobile_runtime.dart';
import 'package:dogcodes_app/features/conversation/conversation_page.dart';
import 'package:dogcodes_app/features/conversation/new_session_page.dart';
import 'package:dogcodes_app/features/devices/pairing_page.dart';

/// Drives the real UI against a running dogcodes-server and an isolated PC
/// Core fixture (synthetic Agent). Pass the PC's invitation link with
/// `--dart-define=DOGCODES_E2E_INVITATION=dogcodes://pair#…`.
const invitation = String.fromEnvironment('DOGCODES_E2E_INVITATION');
const service = String.fromEnvironment(
  'DOGCODES_SERVICE_URL',
  defaultValue: 'http://127.0.0.1:8787',
);

Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  bool present = true,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty == present) return;
  }
  final screen = find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>()
      .join(' | ');
  throw TestFailure(
    'Timed out waiting for $finder (present: $present). Screen: $screen',
  );
}

Finder field(Type page) =>
    find.descendant(of: find.byType(page), matching: find.byType(TextField));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'phone pairs with the PC and controls its Agent',
    skip: invitation.isEmpty,
    (tester) async {
      await tester.pumpWidget(
        DogCodesApp(
          runtime: MobileRuntime(),
          client: AccessClient(Uri.parse(service), allowLocalDevelopment: true),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      // Pair from the 电脑 tab with the PC's invitation link.
      await tester.tap(find.text('电脑').last);
      await tester.pump(const Duration(milliseconds: 500));
      final connect = find.text('连接电脑');
      await waitFor(tester, connect);
      await tester.tap(connect.first);
      await waitFor(tester, find.text('或粘贴配对链接'));
      await tester.enterText(field(PairingPage), invitation);
      await tester.tap(find.widgetWithText(OutlinedButton, '连接'));
      await waitFor(tester, find.text('在线'));
      await waitFor(tester, find.text('或粘贴配对链接'), present: false);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('远程桌面'), findsWidgets);

      // Start a task on the PC from the phone.
      await tester.tap(find.text('会话').last);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byTooltip('新会话'));
      await waitFor(tester, find.text('你想完成什么？'));
      await waitFor(tester, find.textContaining('默认模型'));
      await tester.enterText(field(NewSessionPage), 'phone e2e task');
      await tester.pump();
      await tester.tap(find.text('开始任务'));

      // Streamed reply and the Agent's permission request reach the phone.
      await waitFor(
        tester,
        find.textContaining('Synthetic task: phone e2e task'),
      );
      await waitFor(tester, find.text('允许一次'));
      await tester.tap(find.text('允许一次'));
      await waitFor(tester, find.text('Agent 正在电脑上工作…'), present: false);
      await waitFor(tester, find.text('允许一次'), present: false);

      // A follow-up is stopped from the phone while it waits for approval.
      await tester.enterText(field(ConversationPage), 'please stop');
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await waitFor(tester, find.textContaining('Synthetic task: please stop'));
      await waitFor(tester, find.byTooltip('停止'));
      await tester.tap(find.byTooltip('停止'));
      await waitFor(tester, find.text('Agent 正在电脑上工作…'), present: false);
      await waitFor(tester, find.byTooltip('停止'), present: false);
    },
  );
}
