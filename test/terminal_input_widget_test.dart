import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/features/tools/terminal_pane.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'terminal_input_test.dart' show InputPeer;
import 'widget_test.dart' show FakeLink;

class InputLink extends FakeLink {
  InputLink(this.peer) : super('fixture-host');
  final InputPeer peer;
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if ([
      'terminal_input',
      'terminal_get',
      'remote_capabilities',
    ].contains(method)) {
      return peer.call(method, args);
    }
    if (method == 'terminal_read') {
      return {
        'bytes': <int>[],
        'next': '0',
        'info': {'id': 'terminal', 'epoch': 'epoch', 'status': 'running'},
      };
    }
    if (method == 'terminal_resize') return null;
    return super.call(method, args);
  }
}

Future<void> open(WidgetTester t, TerminalSession session) async {
  await t.pumpWidget(
    MaterialApp(
      theme: dcTheme(Brightness.light),
      home: Scaffold(body: TerminalPane(session: session)),
    ),
  );
  await t.pumpAndSettle();
}

String text(WidgetTester t) =>
    t.widget<TextField>(find.byType(TextField)).controller!.text;
void main() {
  testWidgets(
    'a pending line is not submitted twice and clears only after its acknowledgement',
    (t) async {
      final peer = InputPeer()..writeGate = Completer<void>(),
          session = TerminalSession(InputLink(peer), 'terminal');
      await open(t, session);
      await t.enterText(find.byType(TextField), 'echo once');
      await t.tap(find.byTooltip('发送'));
      await t.pump();
      await t.tap(find.byTooltip('发送'));
      await t.pump();
      expect(peer.writes.length, 1);
      expect(text(t), 'echo once');
      peer.writeGate!.complete();
      await t.pumpAndSettle();
      expect(text(t), '');
      expect(peer.writes.length, 1);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets(
    'unknown input survives output refresh and verification preserves newly typed text',
    (t) async {
      final peer = InputPeer()..unknown = true,
          session = TerminalSession(InputLink(peer), 'terminal')..start();
      await open(t, session);
      await t.enterText(find.byType(TextField), 'original');
      await t.tap(find.byTooltip('发送'));
      await t.pumpAndSettle();
      expect(session.input.paused, true);
      expect(text(t), 'original');
      await t.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('输入结果尚未确认'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'new draft');
      peer.apply();
      await t.tap(find.text('核实输入结果'));
      await t.pumpAndSettle();
      expect(session.input.paused, false);
      expect(text(t), 'new draft');
      expect(peer.writes.length, 1);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets(
    'continuing after uncertainty requires confirmation and never resends the retained line',
    (t) async {
      final peer = InputPeer()..unknown = true,
          session = TerminalSession(InputLink(peer), 'terminal');
      await open(t, session);
      await t.enterText(find.byType(TextField), 'unconfirmed');
      await t.tap(find.byTooltip('发送'));
      await t.pumpAndSettle();
      await t.tap(find.text('继续输入'));
      await t.pumpAndSettle();
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(session.input.paused, true);
      expect(text(t), 'unconfirmed');
      await t.tap(find.text('继续输入'));
      await t.pumpAndSettle();
      await t.tap(find.text('已检查，继续'));
      await t.pumpAndSettle();
      expect(session.input.paused, false);
      expect(text(t), '');
      expect(peer.writes.length, 1);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets(
    'leaving a page while input is in flight does not update disposed widgets',
    (t) async {
      final peer = InputPeer()..writeGate = Completer<void>(),
          session = TerminalSession(InputLink(peer), 'terminal');
      await open(t, session);
      await t.enterText(find.byType(TextField), 'pending');
      await t.tap(find.byTooltip('发送'));
      await t.pump();
      await t.pumpWidget(const SizedBox());
      session.dispose();
      peer.writeGate!.complete();
      await t.pumpAndSettle();
      expect(peer.writes.length, 1);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'viewing output does not claim an input stream for terminal status replies',
    (t) async {
      final peer = InputPeer(),
          session = TerminalSession(InputLink(peer), 'terminal');
      await open(t, session);
      session.terminal.write('\x1b[6n');
      await t.pump();
      expect(peer.calls, isEmpty);
      expect(peer.writes, isEmpty);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}
