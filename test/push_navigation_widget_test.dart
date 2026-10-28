import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/mobile_runtime.dart';
import 'package:dogcodes_app/features/conversation/conversation_page.dart';
import 'notification_settings_test.dart'
    show NotificationFixture, notificationHost;
import 'push_notifications_test.dart' show FakePushAdapter, notice;
import 'widget_test.dart' show FakeLink;

void main() {
  testWidgets(
    'an initial click waits for navigation and opens a conversation without executing an action',
    (t) async {
      final fixture = NotificationFixture();
      await fixture.init();
      final link = FakeLink(notificationHost);
      final hub = HostHub(storage: fixture.storage, lister: fixture.hosts.list);
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      final adapter = FakePushAdapter()..initial = notice();
      final runtime = MobileRuntime(
        storage: fixture.storage,
        pushAdapter: adapter,
        notificationRequest: fixture.request,
      );
      await t.pumpWidget(DogCodesApp(hub: hub, runtime: runtime));
      // This fixture has a running turn, so its activity animation deliberately
      // never settles. Advance the navigation without waiting for task completion.
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(ConversationPage), findsOneWidget);
      expect(
        t.widget<ConversationPage>(find.byType(ConversationPage)).taskId,
        't1',
      );
      expect(link.executed, isEmpty);
      adapter.opened!(notice());
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(ConversationPage), findsOneWidget);
      expect(fixture.calls, isEmpty);
      await t.pumpWidget(const SizedBox());
      hub.dispose();
    },
  );

  testWidgets(
    'a click for an unpaired computer cannot open or execute anything',
    (t) async {
      final fixture = NotificationFixture();
      await fixture.init();
      final hub = HostHub(storage: fixture.storage, lister: fixture.hosts.list);
      await hub.load(connect: false);
      final adapter = FakePushAdapter()
        ..initial = notice('unknown', 'unpaired-pc');
      final runtime = MobileRuntime(
        storage: fixture.storage,
        pushAdapter: adapter,
        notificationRequest: fixture.request,
      );
      await t.pumpWidget(DogCodesApp(hub: hub, runtime: runtime));
      await t.pumpAndSettle();
      expect(find.byType(ConversationPage), findsNothing);
      expect(find.text('这台电脑已移除，请核实电脑列表中的绑定。'), findsOneWidget);
      expect(fixture.calls, isEmpty);
      await t.pumpWidget(const SizedBox());
      hub.dispose();
    },
  );
}
