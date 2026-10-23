import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/history_search.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';

class SearchLink implements HostLink {
  SearchLink(this.handler);
  final Future<dynamic> Function(dynamic) handler;
  @override
  String get hostId => 'pc';
  @override
  String? get hostName => null;
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<void> close() async {}
  @override
  Future<dynamic> call(String method, dynamic args) {
    expect(method, 'query_history');
    return handler(args[0]);
  }
}

List<SessionRef> scope(SearchLink link, [int count = 1]) {
  final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
    ..link = link
    ..status = LinkStatus.online;
  return List.generate(
    count,
    (i) => SessionRef(host, {'taskId': 'task$i', 'projectId': 'project'}),
  );
}

void main() {
  test(
    'pagination freezes the native upper bound, deduplicates and retries errors at the same cursor',
    () async {
      final calls = <dynamic>[];
      var fail = false;
      final search = HistorySearch(
        scope(
          SearchLink((request) async {
            calls.add(Map.from(request as Map));
            if (fail) throw StateError('offline');
            if (request['afterSequence'] == 0) {
              return {
                'items': [
                  {'sequence': '4', 'text': 'body'},
                ],
                'throughSequence': '20',
                'nextCursor': '4',
              };
            }
            return {
              'items': [
                {'sequence': '4'},
                {'sequence': '8'},
              ],
              'throughSequence': '20',
              'nextCursor': null,
            };
          }),
        ),
      );
      await search.search('正文');
      fail = true;
      await search.more(search.groups.single);
      expect(search.groups.single.error, contains('offline'));
      fail = false;
      await search.more(search.groups.single);
      expect(calls[1], calls[2]);
      expect(calls[2]['throughSequence'], 20);
      expect(calls[2]['afterSequence'], 4);
      expect(search.groups.single.items.length, 2);
      search.dispose();
    },
  );
  test(
    'search concurrency is bounded and obsolete results cannot replace a new query',
    () async {
      var active = 0, maximum = 0;
      final old = Completer<void>();
      final search = HistorySearch(
        scope(
          SearchLink((request) async {
            active++;
            if (active > maximum) maximum = active;
            if (request['text'] == 'old') await old.future;
            active--;
            return {
              'items': [
                {'sequence': '1', 'text': request['text']},
              ],
              'throughSequence': '10',
              'nextCursor': null,
            };
          }),
          8,
        ),
      );
      final pending = search.search('old');
      await Future<void>.delayed(Duration.zero);
      expect(maximum, 4);
      // Finish old in-flight requests after starting a new search.
      final next = search.search('new');
      old.complete();
      await Future.wait([pending, next]);
      expect(maximum, 4);
      expect(search.query, 'new');
      expect(search.groups.length, 8);
      expect(
        search.groups.every((g) => g.items.single['text'] == 'new'),
        isTrue,
      );
      search.dispose();
    },
  );

  test(
    'offline computers get one notice and sessions are searched in batches',
    () async {
      final asked = <String>[];
      final link = SearchLink((request) async {
        asked.add(request['taskId'] as String);
        return {'items': [], 'throughSequence': '1', 'nextCursor': null};
      });
      final online = HostState({'hostId': 'pc'}, MemorySecretStorage())
        ..link = link
        ..status = LinkStatus.online;
      final offline = HostState({
        'hostId': 'old',
        'displayName': 'Old Mac',
      }, MemorySecretStorage());
      final sessions = [
        for (var i = 0; i < 5; i++)
          SessionRef(online, {
            'taskId': 'task$i',
            'projectId': 'p',
            'updatedAt': '2026-10-0${i + 1}T00:00:00Z',
          }),
        for (var i = 0; i < 3; i++)
          SessionRef(offline, {'taskId': 'gone$i', 'projectId': 'p'}),
      ];
      final search = HistorySearch(sessions, batch: 2);
      await search.search('正文');
      expect(asked, ['task4', 'task3']);
      expect(search.offlineHosts, [offline.name]);
      expect(search.groups.length, 2);
      expect(search.remaining, 3);
      await search.searchMore();
      await search.searchMore();
      expect(asked, ['task4', 'task3', 'task2', 'task1', 'task0']);
      expect(search.remaining, 0);
      expect(search.groups.every((g) => g.error == null), isTrue);
      search.dispose();
    },
  );
}
