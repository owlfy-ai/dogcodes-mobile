import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_directory_browser.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';

class DirectoryLink implements HostLink {
  DirectoryLink(this.handler);
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
    expect(method, 'host_directories');
    return handler(args);
  }
}

HostState computer(DirectoryLink link) =>
    HostState({'hostId': 'pc'}, MemorySecretStorage())
      ..link = link
      ..status = LinkStatus.online;

void main() {
  test(
    'PC paths and parents are preserved, pages deduplicate, and empty directories are selectable',
    () async {
      const path = r'C:\Work\项目';
      final requests = <dynamic>[];
      final browser = HostDirectoryBrowser(
        computer(
          DirectoryLink((args) async {
            requests.add(args);
            if (args['path'] == null) {
              return {
                'path': null,
                'parent': null,
                'entries': [
                  {'name': 'C:', 'path': 'C:\\'},
                ],
                'next': null,
              };
            }
            return {
              'path': path,
              'parent': r'C:\Work',
              'entries': args['offset'] == 0
                  ? [
                      {'name': 'a', 'path': '$path\\a'},
                    ]
                  : [
                      {'name': 'a', 'path': '$path\\a'},
                      {'name': 'b', 'path': '$path\\b'},
                    ],
              'next': args['offset'] == 0 ? 200 : null,
            };
          }),
        ),
      );
      await browser.open(null);
      expect(browser.selectable, isFalse);
      await browser.open(path);
      expect(browser.path, path);
      expect(browser.parent, r'C:\Work');
      await browser.more();
      expect(requests.last, {'path': path, 'offset': 200});
      expect(browser.entries.length, 2);
      expect(browser.selectable, isTrue);
      browser.dispose();
    },
  );
  test(
    'slow navigation and replies from a retired connection cannot replace the selected directory',
    () async {
      final delayed = Completer<dynamic>();
      final host = computer(
        DirectoryLink((args) async {
          if (args['path'] == '/old') return delayed.future;
          return {
            'path': args['path'],
            'parent': '/',
            'entries': [],
            'next': null,
          };
        }),
      );
      final browser = HostDirectoryBrowser(host);
      final old = browser.open('/old');
      await browser.open('/new');
      delayed.complete({'path': '/old', 'entries': [], 'parent': null});
      await old;
      expect(browser.path, '/new');
      expect(browser.selectable, isTrue);
      final late = Completer<dynamic>();
      host.link = DirectoryLink((_) => late.future);
      final pending = browser.open('/retired');
      host.link = DirectoryLink((_) async => {});
      late.complete({'path': '/retired', 'entries': []});
      await pending;
      expect(browser.path, '/new');
      expect(browser.selectable, isFalse);
      expect(browser.error, contains('连接已更换'));
      browser.dispose();
    },
  );
  test(
    'permission errors remain recoverable and old PCs cannot authorize an empty response',
    () async {
      var fail = true;
      final browser = HostDirectoryBrowser(
        computer(
          DirectoryLink((_) async {
            if (fail) throw StateError('permission denied');
            return {
              'path': '/empty',
              'parent': '/',
              'entries': [],
              'next': null,
            };
          }),
        ),
      );
      await browser.open('/empty');
      expect(browser.selectable, isFalse);
      fail = false;
      await browser.retry();
      expect(browser.entries, isEmpty);
      expect(browser.selectable, isTrue);
      browser.dispose();
      final unsupported = HostDirectoryBrowser(
        computer(DirectoryLink((_) async => null)),
      );
      await unsupported.open('/empty');
      expect(unsupported.selectable, isFalse);
      expect(unsupported.error, contains('更新电脑端'));
      unsupported.dispose();
    },
  );

  test(
    'hidden directories are requested only after the toggle, on the same path',
    () async {
      final requests = <dynamic>[];
      final browser = HostDirectoryBrowser(
        computer(
          DirectoryLink((args) async {
            requests.add(Map.of(args as Map));
            return {
              'path': '/Users/me',
              'parent': '/Users',
              'entries': [
                if (args['showHidden'] == true)
                  {'name': '.config', 'path': '/Users/me/.config'},
                {'name': 'code', 'path': '/Users/me/code'},
              ],
              'next': null,
            };
          }),
        ),
      );
      await browser.open(null);
      expect(requests.single.containsKey('showHidden'), isFalse);
      expect(browser.entries.map((e) => e['name']), ['code']);

      await browser.setShowHidden(true);
      expect(requests.last, {
        'path': '/Users/me',
        'offset': 0,
        'showHidden': true,
      });
      expect(browser.entries.map((e) => e['name']), ['.config', 'code']);

      await browser.setShowHidden(false);
      expect(requests.last.containsKey('showHidden'), isFalse);
      expect(browser.entries.map((e) => e['name']), ['code']);
      browser.dispose();
    },
  );
}
