// Isolated authoring target for the real WKWebView preview. Not imported by lib/.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:dogcodes_app/l10n/strings.dart';
import 'package:dogcodes_app/features/tools/preview_page.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'fixture.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: dcTheme(Brightness.light),
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      initialRoute: '/preview',
      routes: {
        '/': (_) => const Scaffold(),
        '/preview': (_) => PreviewPage(
          link: StoreLink(english: !usesChinese),
          taskId: 't0',
          port: 5173,
        ),
      },
    ),
  );
}
