import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/demo/demo_banner.dart';
import 'package:dogcodes_app/demo/demo_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _settle(WidgetTester tester) async {
  // Simulated replies arrive in two steps a moment apart.
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

Future<void> _openExample(WidgetTester tester) async {
  await tester.pumpWidget(const DogCodesApp());
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text('先看看示例'), 100);
  await tester.tap(find.text('先看看示例'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the example opens from the first screen without pairing and '
      'says so on every page', (tester) async {
    await _openExample(tester);

    expect(find.byType(DemoBanner), findsOneWidget);
    expect(find.textContaining('示例模式', findRichText: true), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('完善商品搜索体验'), findsOneWidget);
    expect(find.text('Canvas'), findsWidgets);

    // A pushed page still carries the banner.
    await tester.tap(find.text('检查登录接口权限'));
    await _settle(tester);
    expect(find.byType(DemoBanner), findsOneWidget);
    expect(find.textContaining('没有发现越权问题'), findsOneWidget);

    // Pairing needs the device's own services, which the example never has.
    final scope = AppScope.of(tester.element(find.byType(DemoBanner)));
    expect(scope.demo, isTrue);
    expect(scope.runtime, isNull);
    expect(scope.client, isNull);

    await tester.tap(find.text('退出示例'));
    await tester.pumpAndSettle();
    expect(find.byType(DemoBanner), findsNothing);
    expect(find.text('把电脑上的工作带在身边'), findsOneWidget);
    expect(
      AppScope.of(tester.element(find.text('把电脑上的工作带在身边'))).hub.hosts,
      isEmpty,
    );
  });

  testWidgets('a message sent in the example gets a simulated reply', (
    tester,
  ) async {
    await _openExample(tester);
    await tester.tap(find.text('检查登录接口权限'));
    await _settle(tester);

    await tester.enterText(find.byType(TextField), '再把字号调大一点');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await _settle(tester);

    expect(find.text('再把字号调大一点'), findsOneWidget);
    expect(find.textContaining('这是示例模式里的模拟回复'), findsOneWidget);
    await tester.tap(find.text('退出示例'));
    await tester.pumpAndSettle();
  });

  testWidgets('approving in the example clears the request and continues', (
    tester,
  ) async {
    await _openExample(tester);
    expect(find.text('2 项等待处理'), findsOneWidget);
    await tester.tap(find.text('2 项等待处理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('命令：pnpm test --filter search'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('允许一次'));
    await _settle(tester);

    final hub = AppScope.of(tester.element(find.byType(DemoBanner))).hub;
    expect(hub.pendingCount, 1);
    await tester.tap(find.text('退出示例'));
    await tester.pumpAndSettle();
  });

  test('the example link answers from memory and refuses real work', () async {
    final link = DemoLink(replyDelay: Duration.zero);
    final hub = HostHub(
      storage: MemorySecretStorage(),
      lister: () async => [
        {'hostId': DemoLink.id, 'displayName': 'Example'},
      ],
    );
    await hub.load(connect: false);
    await hub.attach(hub.hosts.single, link);
    final host = hub.hosts.single;
    expect(host.online, isTrue);
    expect(host.snapshot?['tasks'], hasLength(6));

    final value = await host.operations.send(link, {
      'scope': 'mobile:${host.id}:p1:t3',
      'taskId': 't3',
      'projectId': 'p1',
      'target': {'providerId': 'claude', 'installationId': 'demo-claude'},
      'input': {'prompt': '加一个暗色主题'},
    });
    expect(value['resolution']['status'], 'submitted');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final items = (await link.call('timeline_snapshot', ['t3']))['items'];
    expect(items.map((i) => i['text']), contains('加一个暗色主题'));
    expect(items.last['kind'], 'assistant_message');

    await expectLater(
      link.call('terminal_stop', {'terminalId': 'demo-terminal'}),
      throwsA(isA<ProtocolException>()),
    );
    expect(await link.call('remote_capabilities', null), isA<Map>());
    hub.dispose();
  });
}
