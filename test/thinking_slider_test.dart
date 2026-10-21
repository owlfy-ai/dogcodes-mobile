import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/features/conversation/agent_picker.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'package:dogcodes_app/ui/widgets.dart';

AgentChoice choice(
  List<List<String>> options,
  String def, {
  String? thinking,
}) => AgentChoice(
  {'providerId': 'claude-code'},
  catalog: {
    'defaultModel': 'm',
    'models': [
      {
        'id': 'm',
        'label': 'Model',
        'defaultThinking': def,
        'thinkingOptions': [
          for (final o in options) {'id': o[0], 'label': o[1]},
        ],
      },
    ],
  },
  model: 'm',
  thinking: thinking,
);

Future<String?> pump(WidgetTester tester, AgentChoice c) async {
  String? picked = 'unset';
  await tester.pumpWidget(
    MaterialApp(
      theme: dcTheme(Brightness.light),
      home: Scaffold(
        body: ThinkingSlider(choice: c, onChanged: (v) => picked = v),
      ),
    ),
  );
  return picked;
}

void main() {
  testWidgets('levels sort low to high; modes become chips; default shown', (
    tester,
  ) async {
    final c = choice([
      ['off', 'off'],
      ['auto', 'auto'],
      ['low', 'low'],
      ['medium', 'medium'],
      ['high', 'high'],
      ['xhigh', 'xhigh'],
      ['max', 'max'],
    ], 'auto');
    await pump(tester, c);
    expect(find.text('默认 · auto'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'auto'), findsOneWidget);
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.divisions, 5); // off..max, auto excluded
    expect(find.text('off'), findsOneWidget);
    expect(find.text('max'), findsOneWidget);
  });

  testWidgets('descending vendor order still slides low to high', (
    tester,
  ) async {
    String? picked;
    final c = choice([
      ['xhigh', 'Extra High'],
      ['high', 'High'],
      ['medium', 'Medium'],
      ['low', 'Low'],
    ], 'high');
    await tester.pumpWidget(
      MaterialApp(
        theme: dcTheme(Brightness.light),
        home: Scaffold(
          body: ThinkingSlider(choice: c, onChanged: (v) => picked = v),
        ),
      ),
    );
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 2); // low, medium, [high], xhigh
    slider.onChanged!(3);
    expect(picked, 'xhigh');
  });

  testWidgets('agent glyph shows the bundled logo or an initial', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: dcTheme(Brightness.light),
        home: const Row(
          children: [
            AgentGlyph(providerId: 'codex'),
            AgentGlyph(providerId: 'unknown-agent'),
          ],
        ),
      ),
    );
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('U'), findsOneWidget);
  });
}
