import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'host_hub.dart';
import 'protocol.dart';

class HistoryMatches {
  HistoryMatches(this.session);
  final SessionRef session;
  final items = <Map<String, dynamic>>[];
  int? next, through;
  bool busy = false;
  String? error;
}

/// The PC query is task-scoped. Fan out within the selected computer/project,
/// with bounded concurrency and one frozen upper bound per paginated query.
class HistorySearch extends ChangeNotifier {
  HistorySearch(this.sessions);
  final List<SessionRef> sessions;
  List<HistoryMatches> groups = [];
  String query = '';
  bool searching = false, _disposed = false;
  int _generation = 0;
  int _active = 0;
  Completer<void>? _slot;
  Future<bool> _acquire(int generation) async {
    while (_active >= 4 && !_disposed && generation == _generation) {
      await (_slot ??= Completer<void>()).future;
    }
    if (_disposed || generation != _generation) return false;
    _active++;
    return true;
  }

  void _release() {
    _active--;
    _slot?.complete();
    _slot = null;
  }

  Future<void> search(String text) async {
    final generation = ++_generation;
    query = text.trim();
    groups = [];
    if (query.isEmpty) {
      searching = false;
      notifyListeners();
      return;
    }
    if (utf8.encode(query).length > 1024) {
      searching = false;
      notifyListeners();
      throw const ProtocolException('关键词过长，请缩短后再搜索。');
    }
    final pending = [for (final s in sessions) HistoryMatches(s)];
    groups = pending;
    searching = true;
    notifyListeners();
    var next = 0;
    Future<void> worker() async {
      while (!_disposed && generation == _generation && next < pending.length) {
        await _load(pending[next++], generation, query);
      }
    }

    await Future.wait(
      List.generate(pending.length.clamp(0, 4), (_) => worker()),
    );
    if (!_disposed && generation == _generation) {
      searching = false;
      notifyListeners();
    }
  }

  Future<void> more(HistoryMatches group) => _load(group, _generation, query);

  Future<void> _load(HistoryMatches group, int generation, String text) async {
    if (group.busy) return;
    final host = group.session.host, link = group.session.host.link;
    final epoch = host.connectionEpoch;
    group.busy = true;
    group.error = null;
    if (!_disposed) notifyListeners();
    var acquired = false;
    try {
      acquired = await _acquire(generation);
      if (!acquired) return;
      if (!host.online || link == null) {
        throw const ProtocolException('电脑离线，连接后重试搜索。');
      }
      final value = await link.call('query_history', [
        {
          'taskId': group.session.taskId,
          'kind': 'search',
          'text': text,
          'afterSequence': group.next ?? 0,
          'throughSequence': group.through,
          'limit': 30,
        },
      ]);
      if (_disposed || generation != _generation) return;
      if (host.link != link || host.connectionEpoch != epoch || !host.online) {
        throw const ProtocolException('连接已更换，请重试本次搜索。');
      }
      if (value is! Map ||
          value['items'] is! List ||
          value['throughSequence'] == null) {
        throw const ProtocolException('电脑未返回可用的历史搜索结果。');
      }
      final next = value['nextCursor'] == null
          ? null
          : int.parse('${value['nextCursor']}');
      if (next != null && next <= (group.next ?? 0)) {
        throw const ProtocolException('历史搜索游标没有前进，请重新搜索。');
      }
      final through = int.parse('${value['throughSequence']}');
      if (group.through != null && through != group.through) {
        throw const ProtocolException('历史搜索范围发生变化，请重新搜索。');
      }
      final known = group.items.map((i) => '${i['sequence']}').toSet();
      for (final raw in value['items'] as List) {
        final item = Map<String, dynamic>.from(raw as Map);
        if (known.add('${item['sequence']}')) group.items.add(item);
      }
      group.through = through;
      group.next = next;
    } catch (e) {
      if (!_disposed && generation == _generation) group.error = '$e';
    } finally {
      if (acquired) _release();
      group.busy = false;
      if (!_disposed && generation == _generation) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _slot?.complete();
    _slot = null;
    super.dispose();
  }
}
