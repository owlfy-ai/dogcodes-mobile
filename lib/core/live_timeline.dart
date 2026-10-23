import 'dart:convert';

/// One task's timeline kept current between snapshots by merging streamed
/// `message.delta` and `activity.updated` events the same way the PC's store
/// projects them (crates/store `apply_projection`), so a merged timeline equals
/// the next `timeline_snapshot`.
///
/// Sequences are the PC's global event cursor. Events are buffered while a
/// snapshot is in flight and re-applied past its `lastSequence`, so nothing
/// streamed during the read is lost or applied twice.
class LiveTimeline {
  LiveTimeline(this.taskId);
  final String taskId;
  List<Map<String, dynamic>> items = [];

  /// Last sequence reflected in [items]; 0 until the first snapshot.
  int cursor = 0;
  bool get loaded => _loaded;
  bool _loaded = false;
  int _base = -1;
  int _snapshotFloor = 0;
  bool get needsSnapshot => _snapshotFloor > _base;
  final _buffer = <Map<String, dynamic>>[];
  static const _maxBuffer = 4000;

  /// Cursor for the next older page of a tail-paged timeline; null when the
  /// beginning is shown (or the PC sent the whole timeline).
  String? earlierBefore;
  bool _pagedEarlier = false;

  /// Snapshot reads in flight. Once loaded, streamed events are kept only
  /// while one is: an idle buffer would fill and force a needless re-read.
  int _reads = 0;
  void beginRead() => _reads++;
  void endRead() {
    if (_reads > 0) _reads--;
    if (_reads == 0 && _loaded) _buffer.clear();
  }

  static const merged = {'message.delta', 'activity.updated'};

  /// Replaces [items] with a snapshot, then re-applies streamed events newer
  /// than it. An older snapshot finishing after a newer one is ignored.
  bool reset(Map<String, dynamic> snapshot) {
    final base = _int(snapshot['lastSequence']);
    if (base < _base || base < _snapshotFloor) return false;
    _base = base;
    final next = [
      for (final i in (snapshot['items'] as List? ?? const []))
        Map<String, dynamic>.from(i as Map),
    ];
    // Items kept from before already carry every streamed event merged so
    // far; replaying the buffer onto them would append the same text twice.
    var kept = const <Object?>{};
    final tailTurns = {for (final i in next) turnKey(i)};
    final contiguous =
        snapshot['earlierBefore'] == null ||
        items.any((i) => tailTurns.contains(turnKey(i)));
    if (!snapshot.containsKey('earlierBefore')) {
      // A whole timeline.
      items = next;
      earlierBefore = null;
      _pagedEarlier = false;
    } else if (_pagedEarlier && contiguous) {
      // Keep the older pages the user loaded; the tail's turns are replaced
      // whole, including any of their items written after newer turns.
      final older = [
        for (final i in items)
          if (!tailTurns.contains(turnKey(i))) i,
      ];
      kept = {for (final i in older) i['itemId']};
      items = [...older, ...next];
    } else {
      // No loaded pages, or turns are missing between them and the new tail
      // (e.g. many turns while offline): restart from the tail so nothing is
      // silently skipped; 加载更早 continues from it.
      items = next;
      earlierBefore = snapshot['earlierBefore'] as String?;
      _pagedEarlier = false;
    }
    cursor = base;
    _loaded = true;
    _buffer.removeWhere((e) => _int(e['sequence']) <= cursor);
    for (final e in _buffer) {
      _merge(e, skip: kept);
    }
    return true;
  }

  /// A turn's items belong together wherever they sit in the store; the PC
  /// pages by the same key.
  static String turnKey(Map<String, dynamic> item) {
    final turn = item['turnId'];
    return turn is String ? 'turn:$turn' : 'item:${item['itemId'] ?? ''}';
  }

  /// Replaces one item (a trimmed one read in full).
  bool replaceItem(Map<String, dynamic> item) {
    final index = items.indexWhere((i) => i['itemId'] == item['itemId']);
    if (index < 0) return false;
    items = [...items]..[index] = item;
    return true;
  }

  /// Prepends an older page read with [earlierBefore] as its cursor.
  void prependEarlier(Map<String, dynamic> page) {
    final known = {for (final i in items) i['itemId']};
    items = [
      for (final i in (page['items'] as List? ?? const []))
        if (!known.contains((i as Map)['itemId'])) Map<String, dynamic>.from(i),
      ...items,
    ];
    earlierBefore = page['earlierBefore'] as String?;
    _pagedEarlier = true;
  }

  /// Applies one event envelope. Returns true when [items] changed.
  bool apply(Map<String, dynamic> event) {
    if (!merged.contains(event['eventType'])) return false;
    final payload = event['payload'];
    if (payload is! Map || payload['taskId'] != taskId) return false;
    final sequence = _int(event['sequence']);
    if (_loaded && sequence <= cursor) return false;
    if (_loaded && _reads == 0) return _merge(event);
    _buffer.add(event);
    if (_buffer.length > _maxBuffer) {
      // A snapshot older than a discarded delta cannot be repaired. Keep the
      // displayed live text and request a fresh snapshot instead of rolling back.
      _snapshotFloor = _int(_buffer.removeAt(0)['sequence']);
    }
    return _loaded && _merge(event);
  }

  bool _merge(
    Map<String, dynamic> event, {
    Set<Object?> skip = const <Object?>{},
  }) {
    final sequence = _int(event['sequence']);
    if (sequence <= cursor) return false;
    cursor = sequence;
    final p = Map<String, dynamic>.from(event['payload'] as Map);
    final turn = p['turnId'], native = p['itemId'];
    if (turn is! String || native is! String) return false;
    final kind = event['eventType'] == 'message.delta' ? 'message' : 'tool';
    if (skip.contains('$kind:$taskId:$turn:$native')) return false;
    final source = event['source'];
    final provider = source is Map ? source['providerId'] : null;
    if (event['eventType'] == 'message.delta') {
      final text = p['text'];
      if (text is! String) return false;
      final id = 'message:$taskId:$turn:$native';
      final item = _find(id);
      if (item != null) {
        item['text'] = '${item['text'] ?? ''}$text';
      } else {
        items.add(_item(id, turn, 'assistant_message', text, provider, event));
      }
      return true;
    }
    final patch = p['data'];
    if (patch is! Map) return false;
    final id = 'tool:$taskId:$turn:$native';
    final item = _find(id);
    final data = _decode(item?['text']);
    _patch(data, Map<String, dynamic>.from(patch));
    if (item != null) {
      item['kind'] = 'activity';
      item['text'] = jsonEncode(data);
    } else {
      items.add(_item(id, turn, 'activity', jsonEncode(data), provider, event));
    }
    return true;
  }

  /// Field rules of the store's `activity.updated` projection.
  static void _patch(Map<String, dynamic> data, Map<String, dynamic> patch) {
    const terminal = ['completed', 'failed', 'interrupted', 'cancelled'];
    const running = ['pending', 'running', 'in_progress'];
    patch.forEach((k, v) {
      if (v == null) return;
      if (k == 'type' && data[k] == 'subagent' && v == 'tool') return;
      if (k == 'parentId' && v == '' && '${data[k] ?? ''}'.isNotEmpty) return;
      if (k == 'textDelta') {
        data['text'] = '${data['text'] ?? ''}${v is String ? v : ''}';
        return;
      }
      if (k == 'status' && terminal.contains(data[k]) && running.contains(v)) {
        return;
      }
      if (k == 'startedAt' && data[k] != null) return;
      data[k] = v;
    });
  }

  Map<String, dynamic>? _find(String id) {
    for (var i = items.length - 1; i >= 0; i--) {
      if (items[i]['itemId'] == id) return items[i];
    }
    return null;
  }

  Map<String, dynamic> _item(
    String id,
    String turn,
    String kind,
    String text,
    Object? provider,
    Map<String, dynamic> event,
  ) => {
    'itemId': id,
    'taskId': taskId,
    'turnId': turn,
    'kind': kind,
    'text': text,
    'providerId': provider,
    'sequence': event['sequence'],
    'occurredAt': event['occurredAt'],
    'attachments': const [],
  };

  static Map<String, dynamic> _decode(Object? text) {
    if (text is! String) return {};
    try {
      final v = jsonDecode(text);
      return v is Map ? Map<String, dynamic>.from(v) : {};
    } catch (_) {
      return {};
    }
  }

  static int _int(Object? v) =>
      v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
}
