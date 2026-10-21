import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'widget_test.dart' show FakeLink, fakeHub;

class DelayedTimelineLink extends FakeLink {
  DelayedTimelineLink() : super('macbook-pro-host');
  final source = StreamController<Map<String, dynamic>>.broadcast();
  Completer<dynamic>? delayed;
  @override
  Stream<Map<String, dynamic>> get events => source.stream;
  @override
  Future<void> close() async {
    await source.close();
    await super.close();
  }

  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method == 'timeline_snapshot') {
      final old = delayed;
      delayed = null;
      if (old != null) return old.future;
      return {
        'items': [
          {'itemId': 'new', 'kind': 'assistant_message', 'text': '新连接的内容'},
        ],
        'lastSequence': 9,
      };
    }
    return super.call(method, args);
  }
}

void main() {
  testWidgets(
    'a snapshot from the retired connection cannot overwrite the new timeline',
    (tester) async {
      final link = DelayedTimelineLink(), hub = fakeHub();
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      final old = Completer<dynamic>();
      link.delayed = old;
      await tester.pumpWidget(DogCodesApp(hub: hub));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修复移动端布局'));
      await tester.pump(const Duration(milliseconds: 100));
      link.source.add({'type': 'transport_changing'});
      await tester.pump();
      link.source.add({'type': 'transport_changed'});
      await tester.pump(const Duration(milliseconds: 100));
      old.complete({
        'items': [
          {'itemId': 'old', 'kind': 'assistant_message', 'text': '旧连接的内容'},
        ],
        'lastSequence': 999,
      });
      await tester.pumpAndSettle();
      expect(find.text('新连接的内容'), findsOneWidget);
      expect(find.text('旧连接的内容'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
