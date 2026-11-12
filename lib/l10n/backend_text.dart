import 'dart:convert';

import 'backend_text_catalog.dart';
import 'strings.dart';

/// Errors and notes from the computer arrive as codes such as
/// `backendText.undoFileChanged`, optionally followed by U+001E and a JSON
/// array of values. The desktop app translates them with the same catalog
/// (apps/desktop/src/backendText.ts); this is its phone counterpart.
const _prefix = 'backendText.';
final _code = RegExp(r'^[a-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9]*)+$');
final _embedded = RegExp(r'backendText\.[A-Za-z0-9]+');

/// The translation of [text] when it is a known code, otherwise null.
String? localizeBackendText(String text) {
  final separator = text.indexOf('\u001e');
  final code = separator < 0 ? text : text.substring(0, separator);
  if (!code.startsWith(_prefix) || !_code.hasMatch(code)) return null;
  final catalog =
      backendTextCatalogs[appLanguage] ?? backendTextCatalogs['en']!;
  final template =
      catalog[code.substring(_prefix.length)] ??
      backendTextCatalogs['en']![code.substring(_prefix.length)];
  if (template == null) return null;
  var values = const <String>[];
  if (separator >= 0) {
    try {
      final parsed = jsonDecode(text.substring(separator + 1));
      if (parsed is! List || parsed.any((v) => v is! String)) return null;
      values = parsed.cast<String>();
    } catch (_) {
      return null;
    }
  }
  final names =
      backendTextParams[code] ?? [for (var i = 0; i < values.length; i++) '$i'];
  var result = template;
  for (final (i, name) in names.indexed) {
    final value = i < values.length ? values[i] : '';
    final nested = localizeBackendText(value) ?? _localizeEmbedded(value);
    result = result.replaceAll('{$name}', nested);
  }
  return result;
}

String _localizeEmbedded(String text) => text.replaceAllMapped(_embedded, (m) {
  if (m.end < text.length && text[m.end] == '\u001e') return m[0]!;
  return localizeBackendText(m[0]!) ?? m[0]!;
});

/// Display text for anything the computer sent: a code, a message with a
/// code inside it, or plain text (left unchanged).
String displayBackendText(String text) =>
    localizeBackendText(text) ?? _localizeEmbedded(text);
