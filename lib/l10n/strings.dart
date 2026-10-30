import 'package:flutter/widgets.dart';
import 'catalog.dart';

/// App-owned messages only. User messages, model names, paths and code are data
/// and must never be passed through this catalog.
///
/// Source strings are Simplified Chinese; every other language is a catalog
/// generated from `lib/l10n/<language>.json` (tool/l10n/generate.py).
/// Read the preference at use time so background errors and model helpers use
/// the same language as the widgets.
@visibleForTesting
List<Locale>? testLanguagePreferences;

/// A supported UI language: catalog id, the locale Flutter widgets use, and
/// its own name (never translated).
typedef AppLanguage = ({String id, Locale locale, String name});

const appLanguages = <AppLanguage>[
  (id: 'zh', locale: Locale('zh'), name: '简体中文'),
  (
    id: 'zh-Hant',
    locale: Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    name: '繁體中文',
  ),
  (id: 'en', locale: Locale('en'), name: 'English'),
  (id: 'ja', locale: Locale('ja'), name: '日本語'),
  (id: 'ko', locale: Locale('ko'), name: '한국어'),
  (id: 'fr', locale: Locale('fr'), name: 'Français'),
  (id: 'de', locale: Locale('de'), name: 'Deutsch'),
  (id: 'es', locale: Locale('es'), name: 'Español'),
  (id: 'pt-BR', locale: Locale('pt', 'BR'), name: 'Português (Brasil)'),
  (id: 'ru', locale: Locale('ru'), name: 'Русский'),
  (id: 'it', locale: Locale('it'), name: 'Italiano'),
];

/// Chosen in 偏好设置; null follows the system. Set by AppPreferences.
String? languageOverride;

/// The catalog id for one system locale, or null when unsupported.
String? languageFor(Locale locale) {
  switch (locale.languageCode) {
    case 'zh':
      final traditional =
          locale.scriptCode == 'Hant' ||
          const {'TW', 'HK', 'MO'}.contains(locale.countryCode);
      return traditional ? 'zh-Hant' : 'zh';
    case 'pt':
      return 'pt-BR';
    case final code:
      return appLanguages.any((l) => l.id == code) ? code : null;
  }
}

/// The first supported language in the user's order, as the system does.
String get appLanguage {
  final chosen = languageOverride;
  if (chosen != null) return chosen;
  for (final locale
      in testLanguagePreferences ??
          WidgetsBinding.instance.platformDispatcher.locales) {
    final id = languageFor(locale);
    if (id != null) return id;
  }
  return 'en';
}

bool get usesChinese => appLanguage == 'zh';

String tr(String message, [List<Object?> arguments = const []]) {
  final language = appLanguage;
  var template = message;
  if (language != 'zh') {
    final catalog = messageCatalogs[language] ?? const {};
    template = catalog[message] ?? englishMessages[message] ?? message;
    // Counted labels with a distinct singular form ('@one:' entries).
    // French also uses the singular for zero.
    final n = arguments.isEmpty ? null : arguments.first;
    if (n == 1 || (language == 'fr' && n == 0)) {
      template = catalog['@one:$message'] ?? template;
    }
  }
  if (arguments.isEmpty) return template;
  // Arguments are substituted once, so user content containing placeholder
  // syntax remains untouched.
  return template.replaceAllMapped(RegExp(r'\{(\d+)\}'), (match) {
    final index = int.parse(match[1]!);
    return index < arguments.length ? '${arguments[index]}' : match[0]!;
  });
}

/// Register the locale dependency in widgets that use context-free messages.
void watchAppLanguage(BuildContext context) {
  Localizations.maybeLocaleOf(context);
}
