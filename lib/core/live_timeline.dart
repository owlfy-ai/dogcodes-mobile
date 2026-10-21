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

  static const merged = {'message.delta', 'activity.updated'};

  /// Replaces [items] with a snapshot, then re-applies streamed events newer
  /// than it. An older snapshot finishing after a newer one is ignored.
  bool reset(Map<String, dynamic> snapshot) {
    final base = _int(snapshot['lastSequence']);
    if (base < _base || base < _snapshotFloor) return false;
    _base = base;
    items = [
      for (final i in (snapshot['items'] as List? ?? const []))
        Map<String, dynamic>.from(i as Map),
    ];
    cursor = base;
    _loaded = true;
    _buffer.removeWhere((e) => _int(e['sequence']) <= cursor);
    for (final e in _buffer) {
      _merge(e);
    }
    return true;
  }

  /// Applies one event envelope. Returns true when [items] changed.
  bool apply(Map<String, dynamic> event) {
    if (!merged.contains(event['eventType'])) return false;
    final payload = event['payload'];
    if (payload is! Map || payload['taskId'] != taskId) return false;
    final sequence = _int(event['sequence']);
    if (_loaded && sequence <= cursor) return false;
    _buffer.add(event);
    if (_buffer.length > _maxBuffer) {
      // A snapshot older than a discarded delta cannot be repaired. Keep the
      // displayed live text and request a fresh snapshot instead of rolling back.
      _snapshotFloor = _int(_buffer.removeAt(0)['sequence']);
    }
    return _loaded && _merge(event);
  }

  bool _merge(Map<String, dynamic> event) {
    final sequence = _int(event['sequence']);
    if (sequence <= cursor) return false;
    cursor = sequence;
    final p = Map<String, dynamic>.from(event['payload'] as Map);
    final turn = p['turnId'], native = p['itemId'];
    if (turn is! String || native is! String) return false;
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
