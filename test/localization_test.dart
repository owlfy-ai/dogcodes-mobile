import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/l10n/catalog.dart';
import 'package:dogcodes_app/l10n/strings.dart';
import 'package:dogcodes_app/ui/quota_ring.dart';
import '../tool/store/fixture.dart';

void main() {
  test(
    'English catalog preserves all placeholders and contains no Chinese',
    () {
      final source = jsonDecode(File('lib/l10n/en.json').readAsStringSync());
      expect(source, englishMessages);
      final placeholder = RegExp(r'\{\d+\}');
      for (final entry in englishMessages.entries) {
        expect(
          placeholder.allMatches(entry.value).map((m) => m[0]).toSet(),
          placeholder.allMatches(entry.key).map((m) => m[0]).toSet(),
          reason: entry.key,
        );
        expect(RegExp(r'[\u3400-\u9fff]').hasMatch(entry.value), isFalse);
      }
    },
  );

  test('language preference order and unsupported-language fallback', () {
    testLanguagePreferences = const [Locale('nl'), Locale('zh')];
    expect(tr('工作区'), '工作区');
    testLanguagePreferences = const [Locale('fr'), Locale('zh')];
    expect(tr('工作区'), 'Espace de travail');
    testLanguagePreferences = const [Locale('nl')];
    expect(tr('工作区'), 'Workspace');
    testLanguagePreferences = const [Locale('zh', 'TW')];
    expect(tr('工作区'), '工作區');
    testLanguagePreferences = const [Locale('pt', 'PT')];
    expect(appLanguage, 'pt-BR');
    languageOverride = 'de';
    expect(tr('{0} 个文件', [1]), '1 Datei');
    languageOverride = 'fr';
    expect(tr('{0} 个文件', [0]), '0 fichier');
  });

  test('every catalog translates every message', () {
    for (final language in appLanguages) {
      if (language.id == 'zh') continue;
      final catalog = messageCatalogs[language.id]!;
      final missing = englishMessages.keys.where(
        (k) => !k.startsWith('@one:') && !catalog.containsKey(k),
      );
      expect(missing, isEmpty, reason: language.id);
    }
  });

  test(
    'formatting preserves inserted text and errors retain raw protocol data',
    () {
      testLanguagePreferences = const [Locale('en')];
      expect(tr('会话「{0}」需要你的回答。', ['{1}']), 'Chat “{1}” needs your answer.');
      const error = ProtocolException('终端不存在');
      expect(error.message, 'Terminal does not exist');
      expect(error.rawMessage, '终端不存在');
      expect(tr('unrecognized remote message'), 'unrecognized remote message');
      expect(tr('{0} 个文件', [1]), '1 file');
      expect(tr('{0} 个文件', [2]), '2 files');
      expect(tr('允许一次'), 'Allow once');
    },
  );

  test('quota labels use current language when read, not startup language', () {
    Map<String, dynamic> sample = {
      'providerId': 'codex',
      'quota': {
        'windows': [
          {'windowMinutes': 300, 'usedPercent': 48},
        ],
      },
    };
    expect(QuotaReading.from(sample)!.window, '5 小时');
    testLanguagePreferences = const [Locale('en')];
    expect(QuotaReading.from(sample)!.window, '5 hours');
    expect(QuotaReading.from(sample)!.remaining, 52);
  });

  testWidgets('system language changes update the selected page in place', (
    t,
  ) async {
    testLanguagePreferences = null;
    t.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(t.binding.platformDispatcher.clearLocalesTestValue);
    await t.binding.setSurfaceSize(const Size(440, 956));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final hub = HostHub(
      storage: MemorySecretStorage(),
      lister: () async => [
        {'hostId': 'store-mac', 'displayName': 'MacBook Pro'},
      ],
    );
    await hub.load(connect: false);
    await hub.attach(
      hub.hosts.single,
      StoreLink(english: true, approvals: false),
    );
    await t.pumpWidget(DogCodesApp(hub: hub));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Chats'), findsWidgets);
    await t.tap(find.text('Computers').last);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Remote desktop'), findsOneWidget);
    t.binding.platformDispatcher.localesTestValue = const [Locale('zh')];
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('远程桌面'), findsOneWidget);
    expect(find.text('Remote desktop'), findsNothing);
    final bar = t.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.selectedIndex, 3);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    hub.dispose();
  });
}
