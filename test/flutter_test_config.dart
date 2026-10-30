import 'dart:async';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/l10n/strings.dart';

// Existing behavioral tests use the app's Chinese copy. Localization tests
// explicitly choose English; production follows the device language list.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() => testLanguagePreferences = const [Locale('zh')]);
  tearDown(() {
    testLanguagePreferences = null;
    languageOverride = null;
  });
  await testMain();
}
