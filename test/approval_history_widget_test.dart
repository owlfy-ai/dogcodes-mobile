import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'widget_test.dart' show FakeLink, fakeHub;

/// A PC that stops listing an approval once it is answered (or [drop]ped).
class AnsweringLink extends FakeLink {
  AnsweringLink() : super('macbook-pro-host');
  final gone = <String>{};
  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'execute' &&
        params[0]['payload']['type'] == 'respond_to_approval') {
      gone.add(params[0]['payload']['data']['approvalId'] as String);
    }
    final value = await super.call(method, params);
    if (method == 'pending_approvals' && value is List) {
      return [
        for (final a in value)
          if (!gone.contains(a['approvalId'])) a,
      ];
    }
    return value;
  }
}

void main() {
  testWidgets('the inbox keeps handled requests as read-only messages that '
      'can be deleted', (tester) async {
    final link = AnsweringLink();
    final hub = fakeHub(link);
    await tester.pumpWidget(DogCodesApp(hub: hub));
    await tester.pumpAndSettle();
    await tester.tap(find.text('待处理').last);
    await tester.pumpAndSettle();
    expect(find.text('2 项需要你处理'), findsOneWidget);
    expect(find.text('今天'), findsNothing);
    // Every message names its chat's project.
    expect(find.text('dogcodes-web'), findsNWidgets(2));

    // Answered from its detail page, which then shows the record.
    await tester.tap(find.text('命令：pnpm test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('允许一次'));
    await tester.pumpAndSettle();
    expect(find.text('你的选择：允许一次'), findsOneWidget);
    expect(find.text('允许一次'), findsNothing);
    expect(find.byTooltip('其他授权范围'), findsNothing);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('1 项需要你处理'), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('你的选择：允许一次'), findsOneWidget);

    // Answered on the computer: kept, without a choice from this phone.
    link.gone.add('q1');
    await hub.refresh(hub.hosts.single);
    await tester.pumpAndSettle();
    expect(find.textContaining('需要你处理'), findsNothing);
    expect(find.text('已在电脑上处理，或请求已失效'), findsOneWidget);
    await tester.tap(find.text('登录方式采用哪一种？'));
    await tester.pumpAndSettle();
    expect(find.text('发送回答'), findsNothing);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    // Each filter shows its own kind.
    await tester.tap(find.text('权限'));
    await tester.pumpAndSettle();
    expect(find.text('你的选择：允许一次'), findsOneWidget);
    expect(find.text('登录方式采用哪一种？'), findsNothing);
    await tester.tap(find.text('问题'));
    await tester.pumpAndSettle();
    expect(find.text('你的选择：允许一次'), findsNothing);
    expect(find.text('登录方式采用哪一种？'), findsOneWidget);
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();

    // Swipe one away, then clear the rest; the empty inbox explains itself.
    await tester.drag(find.text('你的选择：允许一次'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('你的选择：允许一次'), findsNothing);
    expect(find.text('登录方式采用哪一种？'), findsOneWidget);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空已处理记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('登录方式采用哪一种？'), findsNothing);
    expect(find.text('收件箱是空的'), findsOneWidget);
    expect(hub.hosts.single.approvalHistory, isEmpty);

    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });
}
