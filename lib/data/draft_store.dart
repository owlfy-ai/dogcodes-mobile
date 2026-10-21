import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

/// Stored in application support, never in shared document storage. No auto-send.
/// Identity is encoded as a JSON tuple rather than a delimiter-joined key.
class DraftStore {
  DraftStore(this.directory);
  final Directory directory;
  Future<void> _pending = Future.value();
  String _key(String host, String project, String conversation) => sha256
      .convert(utf8.encode(jsonEncode([host, project, conversation])))
      .toString();

  Future<void> save(
    String host,
    String project,
    String conversation,
    Map<String, dynamic> draft,
  ) {
    final next = _pending.then((_) async {
      await directory.create(recursive: true);
      final file = File(
        '${directory.path}/${_key(host, project, conversation)}.json',
      );
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(draft), flush: true);
      await temporary.rename(file.path);
    });
    _pending = next.then((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<Map<String, dynamic>?> read(
    String host,
    String project,
    String conversation,
  ) async {
    await _pending;
    final file = File(
      '${directory.path}/${_key(host, project, conversation)}.json',
    );
    if (!await file.exists()) return null;
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }
}
