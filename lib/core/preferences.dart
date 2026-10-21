import 'package:flutter/material.dart';
import 'security/secret_storage.dart';

/// Phone-local preferences. Never synced to a PC, so each device keeps its own.
class AppPreferences extends ChangeNotifier {
  AppPreferences([this.storage]);
  final SecretStorage? storage;
  static const _themeKey = 'dogcodes.pref.theme.v1';
  ThemeMode themeMode = ThemeMode.system;

  Future<void> load() async {
    try {
      final value = await storage?.read(_themeKey);
      themeMode = ThemeMode.values.firstWhere(
        (m) => m.name == value,
        orElse: () => ThemeMode.system,
      );
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
}
