import 'package:flutter/material.dart';
import 'security/secret_storage.dart';
import '../l10n/strings.dart';

/// Phone-local preferences. Never synced to a PC, so each device keeps its own.
class AppPreferences extends ChangeNotifier {
  AppPreferences([this.storage]);
  final SecretStorage? storage;
  static const _themeKey = 'dogcodes.pref.theme.v1';
  static const _languageKey = 'dogcodes.pref.language.v1';
  ThemeMode themeMode = ThemeMode.system;

  /// A catalog id from [appLanguages]; null follows the system.
  String? get language => languageOverride;

  Future<void> load() async {
    try {
      final value = await storage?.read(_themeKey);
      themeMode = ThemeMode.values.firstWhere(
        (m) => m.name == value,
        orElse: () => ThemeMode.system,
      );
      final language = await storage?.read(_languageKey);
      languageOverride = appLanguages.any((l) => l.id == language)
          ? language
          : null;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    try {
      await storage?.write(_themeKey, mode.name);
    } catch (_) {}
  }

  Future<void> setLanguage(String? id) async {
    languageOverride = id;
    notifyListeners();
    try {
      // An empty value follows the system.
      await storage?.write(_languageKey, id ?? '');
    } catch (_) {}
  }
}
