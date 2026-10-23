import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

String draftKey(String host, String project, String? task) =>
    jsonEncode([host, project, task]);
String draftFingerprint(Map<String, dynamic> data) => sha256
    .convert(
      utf8.encode(
        jsonEncode({
          'text': data['text'] ?? '',
          'choice': data['choice'] is! Map
              ? null
              : {
                  'providerId': data['choice']['executor']?['providerId'],
                  'installationId':
                      data['choice']['executor']?['installationId'],
                  'model': data['choice']['model'],
                  'thinking': data['choice']['thinking'],
                },
          'attachments': [
            for (final a in data['attachments'] as List? ?? [])
              if (a is Map)
                {
                  'request': a['request'],
                  'blobId': a['blobId'],
                  'source': a['source'],
                },
          ],
        }),
      ),
    )
    .toString();

/// Phone-local data only. Pairing keys and operation receipts stay in keychain.
/// All mutations are serialized; clear/remove cannot be undone by older writes.
class LocalWorkspace extends ChangeNotifier {
  LocalWorkspace.memory() : _directory = null;
  LocalWorkspace.directory(Directory directory)
    : _directory = (() async => directory);
  LocalWorkspace.platform()
    : _directory = (() async => Directory(
        '${(await getApplicationSupportDirectory()).path}/workspace-v1',
      ));
  final Future<Directory> Function()? _directory;
  Directory? _root;
  Future<void> _tail = Future.value();
  // A replacement Hub can overlap the previous composer's asynchronous flush.
  // All on-disk instances in this UI isolate share one admission queue.
  static Future<void> _diskTail = Future.value();
  final _memory = <String, Map<String, dynamic>>{};
  final _blobs = <String, Uint8List>{};
  final _reservedBlobs = <String>{};
  final _cache = <String, ({String key, int bytes, DateTime at})>{};
  bool _indexed = false;
  int cacheEpoch = 0;
  String? cacheError;
  static const maxAttachmentBytes = 25 * 1024 * 1024;
  static const maxCachedSessions = 30;
  static const maxCacheBytes = 32 * 1024 * 1024;

  Future<T> _serial<T>(Future<T> Function() action) {
    final tail = _directory == null ? _tail : _diskTail;
    final next = tail.then((_) => action());
    final settled = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    if (_directory == null) {
      _tail = settled;
    } else {
      _diskTail = settled;
    }
    return next;
  }

  Future<Directory?> _base() async {
    if (_directory == null) return null;
    _root ??= await _directory();
    await _root!.create(recursive: true);
    return _root;
  }

  String _id(String space, String key) =>
      '$space-${sha256.convert(utf8.encode(key))}';
  Future<Map<String, dynamic>?> _get(String space, String key) async {
    final base = await _base(), id = _id(space, key);
    if (base == null) {
      return _memory[id] == null
          ? null
          : Map<String, dynamic>.from(
              jsonDecode(jsonEncode(_memory[id])) as Map,
            );
    }
    final file = File('${base.path}/$id.json');
    if (!await file.exists()) return null;
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map || raw['key'] != key || raw['data'] is! Map) {
      throw const FormatException('本机保存的数据不可读取');
    }
    return Map<String, dynamic>.from(raw['data'] as Map);
  }

  Future<void> _put(
    String space,
    String key,
    Map<String, dynamic> value,
  ) async {
    final base = await _base(), id = _id(space, key);
    if (base == null) {
      _memory[id] = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(value)) as Map,
      );
      return;
    }
    final staging = await base.createTemp('.record-');
    try {
      final temporary = File('${staging.path}/record');
      await temporary.writeAsString(
        jsonEncode({'key': key, 'data': value}),
        flush: true,
      );
      await temporary.rename('${base.path}/$id.json');
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<void> _remove(String space, String key) async {
    final base = await _base(), id = _id(space, key);
    _memory.remove(id);
    if (base != null) {
      final file = File('${base.path}/$id.json');
      if (await file.exists()) await file.delete();
    }
  }

  Future<Map<String, dynamic>?> draft(String key) =>
      _serial(() => _get('draft', key));
  Future<void> saveDraft(String key, Map<String, dynamic> value) {
    final frozen = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(value)) as Map,
    );
    return _serial(() async {
      final previous = await _get('draft', key);
      await _put('draft', key, frozen);
      final now = _blobIds(frozen);
      _reservedBlobs.removeAll(now);
      if (_blobIds(previous).difference(now).isNotEmpty) await _pruneBlobs();
    });
  }

  Future<void> clearSubmittedDraft(Map<String, dynamic> identity) => _serial(
    () async {
      final key = identity['key'];
      if (key is! String) return;
      final saved = await _get('draft', key);
      if (saved != null && draftFingerprint(saved) == identity['fingerprint']) {
        await _put('draft', key, {...saved, 'text': '', 'attachments': []});
        await _pruneBlobs();
      }
    },
  );
  Future<Map<String, dynamic>?> picker() =>
      _serial(() => _get('meta', 'picker'));
  Future<void> savePicker(Map<String, dynamic>? value) => _serial(
    () => value == null
        ? _remove('meta', 'picker')
        : _put('meta', 'picker', value),
  );

  /// Caller freezes the bytes before recording their digest/length in a draft.
  Future<void> saveBlob(String id, Uint8List bytes) => _serial(() async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id) ||
        bytes.length > maxAttachmentBytes) {
      throw StateError('附件大小或标识无效');
    }
    final base = await _base();
    var used = _blobs.values.fold<int>(0, (total, b) => total + b.length);
    if (base != null) {
      final folder = Directory('${base.path}/attachments');
      if (await folder.exists()) {
        await for (final file in folder.list()) {
          if (file is File) used += await file.length();
        }
      }
    }
    if (used + bytes.length > 256 * 1024 * 1024) {
      throw StateError('手机未发送附件已超过 256 MB，请先发送或移除其他草稿中的附件。');
    }
    _reservedBlobs.add(id);
    if (base == null) {
      _blobs[id] = Uint8List.fromList(bytes);
      return;
    }
    final folder = await Directory('${base.path}/attachments').create();
    final file = File('${folder.path}/$id.tmp');
    await file.writeAsBytes(bytes, flush: true);
    await file.rename('${folder.path}/$id');
  });

  Set<String> _blobIds(Map? value) => {
    for (final a in value?['attachments'] as List? ?? [])
      if (a is Map && a['blobId'] is String) a['blobId'] as String,
  };
  Future<void> releaseUnusedAttachments(Iterable<String> ids) =>
      _serial(() async {
        _reservedBlobs.removeAll(ids);
        await _pruneBlobs();
      });
  Future<void> _pruneBlobs() async {
    final used = {..._reservedBlobs}, base = await _base();
    if (base == null) {
      for (final entry in _memory.entries) {
        if (entry.key.startsWith('draft-')) used.addAll(_blobIds(entry.value));
      }
      _blobs.removeWhere((id, _) => !used.contains(id));
      return;
    }
    await for (final file in base.list()) {
      if (file is! File ||
          !file.path.split('/').last.startsWith('draft-') ||
          !file.path.endsWith('.json')) {
        continue;
      }
      try {
        used.addAll(
          _blobIds(
            (jsonDecode(await file.readAsString()) as Map)['data'] as Map,
          ),
        );
      } catch (_) {
        return;
      } // Preserve bytes if a damaged draft could reference them.
    }
    final folder = Directory('${base.path}/attachments');
    if (await folder.exists()) {
      await for (final file in folder.list()) {
        if (file is File && !used.contains(file.path.split('/').last)) {
          await file.delete();
        }
      }
    }
  }

  Future<Uint8List> blob(String id) => _serial(() async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) throw StateError('附件标识无效');
    final base = await _base();
    if (base == null) {
      final value = _blobs[id];
      if (value == null) throw StateError('本机附件已不可读取，请重新添加。');
      return Uint8List.fromList(value);
    }
    final file = File('${base.path}/attachments/$id');
    if (await file.length() > maxAttachmentBytes) {
      throw StateError('本机附件大小已变化。');
    }
    return file.readAsBytes();
  });

  Future<void> _index() async {
    if (_indexed) return;
    final base = await _base();
    if (base != null) {
      await for (final file in base.list()) {
        if (file is! File ||
            !file.path.split('/').last.startsWith('cache-') ||
            !file.path.endsWith('.json')) {
          continue;
        }
        try {
          final raw = jsonDecode(await file.readAsString()) as Map;
          final key = raw['key'] as String;
          _cache[key] = (
            key: key,
            bytes: await file.length(),
            at:
                DateTime.tryParse('${raw['data']['syncedAt']}') ??
                DateTime.fromMillisecondsSinceEpoch(0),
          );
        } catch (_) {
          await file.delete();
        }
      }
    }
    _indexed = true;
  }

  Future<void> _cachePut(String key, Map<String, dynamic> value) async {
    await _index();
    final bytes = utf8.encode(jsonEncode({'key': key, 'data': value})).length;
    if (bytes > 2 * 1024 * 1024) return;
    await _put('cache', key, value);
    _cache[key] = (
      key: key,
      bytes: bytes,
      at: DateTime.parse(value['syncedAt'] as String),
    );
    final oldest = _cache.values.toList()..sort((a, b) => a.at.compareTo(b.at));
    var total = _cache.values.fold<int>(0, (sum, e) => sum + e.bytes);
    var sessions = _cache.keys.where((k) => k.startsWith('timeline:')).length;
    for (final e in oldest) {
      if (total <= maxCacheBytes && sessions <= maxCachedSessions) break;
      if (!e.key.startsWith('timeline:') && total <= maxCacheBytes) continue;
      await _remove('cache', e.key);
      _cache.remove(e.key);
      total -= e.bytes;
      if (e.key.startsWith('timeline:')) sessions--;
    }
  }

  Future<Map<String, dynamic>?> cachedHost(String host) =>
      _serial(() => _get('cache', 'host:$host'));
  Future<Map<String, dynamic>?> cachedTimeline(String host, String task) =>
      _serial(() => _get('cache', 'timeline:${jsonEncode([host, task])}'));
  Future<void> cacheHost(String host, Map<String, dynamic> value, int epoch) {
    final frozen = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(value)) as Map,
    );
    return _serial(() async {
      if (epoch == cacheEpoch) await _cachePut('host:$host', frozen);
    });
  }

  Future<void> cacheTimeline(
    String host,
    String task,
    Map<String, dynamic> snapshot,
    DateTime at,
    int epoch,
  ) {
    final frozen = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(snapshot)) as Map,
    );
    return _serial(() async {
      if (epoch != cacheEpoch) return;
      final items = (frozen['items'] as List).toList();
      var truncated = false;
      while (items.length > 2000 ||
          utf8.encode(jsonEncode({...frozen, 'items': items})).length >
              1800 * 1024) {
        if (items.length <= 1) return;
        items.removeRange(0, (items.length ~/ 4).clamp(1, items.length - 1));
        truncated = true;
      }
      await _cachePut('timeline:${jsonEncode([host, task])}', {
        'snapshot': {...frozen, 'items': items},
        'syncedAt': at.toUtc().toIso8601String(),
        'truncated': truncated,
      });
    });
  }

  Future<({int sessions, int bytes})> cacheUsage() => _serial(() async {
    await _index();
    return (
      sessions: _cache.keys.where((k) => k.startsWith('timeline:')).length,
      bytes: _cache.values.fold<int>(0, (s, e) => s + e.bytes),
    );
  });
  Future<void> clearCache() {
    cacheEpoch++;
    return _serial(() async {
      await _index();
      for (final key in _cache.keys.toList()) {
        await _remove('cache', key);
      }
      _cache.clear();
      cacheError = null;
      notifyListeners();
    });
  }

  Future<void> forgetHost(String host) => _serial(() async {
    await _index();
    for (final key in _cache.keys.toList()) {
      if (key == 'host:$host' ||
          key.startsWith('timeline:[${jsonEncode(host)},')) {
        await _remove('cache', key);
        _cache.remove(key);
      }
    }
    final base = await _base();
    if (base == null) {
      _memory.removeWhere((_, value) => value['hostId'] == host);
    } else {
      await for (final file in base.list()) {
        if (file is! File ||
            !file.path.split('/').last.startsWith('draft-') ||
            !file.path.endsWith('.json')) {
          continue;
        }
        final raw = jsonDecode(await file.readAsString()) as Map;
        if (raw['data']['hostId'] == host) await file.delete();
      }
    }
    await _pruneBlobs();
  });
}
