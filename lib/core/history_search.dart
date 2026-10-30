import 'package:dogcodes_app/l10n/strings.dart';
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
/// Only online computers are queried, most recent sessions first, [batch] at
/// a time; [searchMore] continues with the next batch.
class HistorySearch extends ChangeNotifier {
  HistorySearch(this.sessions, {this.batch = 40});
  final List<SessionRef> sessions;
  final int batch;
  List<HistoryMatches> groups = [];

  /// Computers in scope that were offline when the search started.
  List<String> offlineHosts = [];
  List<SessionRef> _queue = [];
  int get remaining => _queue.length - groups.length;
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
    _queue = [];
    offlineHosts = [];
    // Workers of an earlier query stop on the generation change.
    searching = false;
    if (query.isEmpty) {
      searching = false;
      notifyListeners();
      return;
    }
    if (utf8.encode(query).length > 1024) {
      searching = false;
      notifyListeners();
      throw ProtocolException(tr("关键词过长，请缩短后再搜索。"));
    }
    final online = sessions.where((s) => s.host.online).toList()
      ..sort((a, b) {
        final x = a.updatedAt, y = b.updatedAt;
        return x == null || y == null
            ? (y == null ? 0 : 1) - (x == null ? 0 : 1)
            : y.compareTo(x);
      });
    offlineHosts = {
      for (final s in sessions)
        if (!s.host.online) s.host.name,
    }.toList();
    _queue = online;
    await _searchBatch(generation);
  }

  Future<void> searchMore() => _searchBatch(_generation);

  Future<void> _searchBatch(int generation) async {
    if (searching || remaining <= 0) return;
    final pending = [
      for (final s in _queue.skip(groups.length).take(batch)) HistoryMatches(s),
    ];
    groups = [...groups, ...pending];
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
        throw ProtocolException(tr("电脑离线，连接后重试搜索。"));
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
        throw ProtocolException(tr("连接已更换，请重试本次搜索。"));
      }
      if (value is! Map ||
          value['items'] is! List ||
          value['throughSequence'] == null) {
        throw ProtocolException(tr("电脑未返回可用的历史搜索结果。"));
      }
      final next = value['nextCursor'] == null
          ? null
          : int.parse('${value['nextCursor']}');
      if (next != null && next <= (group.next ?? 0)) {
        throw ProtocolException(tr("历史搜索游标没有前进，请重新搜索。"));
      }
      final through = int.parse('${value['throughSequence']}');
      if (group.through != null && through != group.through) {
        throw ProtocolException(tr("历史搜索范围发生变化，请重新搜索。"));
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
