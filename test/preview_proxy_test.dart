import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/features/tools/preview_proxy.dart';

class PreviewLink implements HostLink {
  @override
  String get hostId => 'fixture-host';
  @override
  String? get hostName => 'Fixture';
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<void> close() async {}

  final opened = Completer<void>();
  Completer<Map<String, dynamic>>? openReply;
  final firstWrite = Completer<void>();
  final releaseWrite = Completer<void>();
  final reads = <Completer<Map<String, dynamic>>>[];
  final started = <String>[], completed = <String>[], closed = <String>[];
  int inFlight = 0, maximum = 0, previewCloses = 0, readCalls = 0;
  bool rejectWrite = false;
  Future<Map<String, dynamic>> Function(Map params)? http;

  void endReads() {
    for (final read in reads) {
      if (!read.isCompleted) read.complete({'type': 'closed'});
    }
  }

  @override
  Future<dynamic> call(String method, dynamic params) async {
    switch (method) {
      case 'preview_http':
        return http!(params as Map);
      case 'preview_ws_open':
        if (!opened.isCompleted) opened.complete();
        return openReply == null
            ? {
                'socketId': 'socket',
                'sequence': '0',
                'maxMessageBytes': 1048576,
              }
            : await openReply!.future;
      case 'preview_ws_write':
        final sequence = params['sequence'] as String;
        started.add(sequence);
        inFlight++;
        if (inFlight > maximum) maximum = inFlight;
        try {
          if (sequence == '1') {
            firstWrite.complete();
            await releaseWrite.future;
            if (rejectWrite) throw StateError('lost write reply');
          }
          completed.add(sequence);
          return {'sequence': sequence};
        } finally {
          inFlight--;
        }
      case 'preview_ws_read':
        readCalls++;
        final read = Completer<Map<String, dynamic>>();
        reads.add(read);
        return read.future;
      case 'preview_ws_close':
        closed.add(params as String);
        endReads();
        return {'closed': true};
      case 'preview_close':
        previewCloses++;
        endReads();
        return {'closed': true};
      default:
        throw StateError('unexpected fixture call $method');
    }
  }
}

Future<void> until(bool Function() ready) => Future<void>(() async {
  while (!ready()) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}).timeout(const Duration(seconds: 3));

Future<WebSocket> connect(PreviewProxy proxy) =>
    WebSocket.connect('ws://127.0.0.1:${proxy.port}/hmr');

void main() {
  test(
    'relative service redirects remain inside the phone loopback proxy',
    () async {
      final paths = <String>[];
      final link = PreviewLink()
        ..http = (params) async {
          paths.add(params['path'] as String);
          if (params['path'] == '/source') {
            return {
              'status': 302,
              'headers': [
                ['location', '/signin?next=%2Fhome#form'],
              ],
              'body': '',
            };
          }
          return {
            'status': 200,
            'headers': [
              ['content-type', 'text/plain'],
            ],
            'body': base64.encode(utf8.encode('signin page')),
          };
        };
      final proxy = PreviewProxy(link, 'preview');
      await proxy.start();
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await proxy.stop();
      });
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${proxy.port}/source'),
      );
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(await response.transform(utf8.decoder).join(), 'signin page');
      expect(paths, ['/source', '/signin?next=%2Fhome']);
      expect(response.redirects.single.location.host, isEmpty);
    },
  );

  test(
    'real loopback WebSocket serializes RPC writes across a slow reply',
    () async {
      final link = PreviewLink();
      // Keep each test's remote endpoint and local proxy scoped together.
      final actual = PreviewProxy(link, 'preview');
      await actual.start();
      final client = await connect(actual);
      client.listen((_) {}, onError: (Object _) {});
      addTearDown(() async {
        if (!link.releaseWrite.isCompleted) link.releaseWrite.complete();
        await client.close();
        await actual.stop();
      });
      client.add('first');
      await link.firstWrite.future.timeout(const Duration(seconds: 3));
      client.add('second');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      link.releaseWrite.complete();
      await until(() => link.completed.length == 2);
      expect(
        link.maximum,
        1,
        reason: 'a later frame overtook an unconfirmed write',
      );
      expect(link.completed, ['1', '2']);
    },
  );

  test(
    'stopping during remote open retires the late socket without starting a reader',
    () async {
      final link = PreviewLink()..openReply = Completer<Map<String, dynamic>>();
      final proxy = PreviewProxy(link, 'preview');
      await proxy.start();
      final connection = connect(
        proxy,
      ).then<WebSocket?>((value) => value, onError: (Object _) => null);
      await link.opened.future.timeout(const Duration(seconds: 3));
      await proxy.stop();
      await proxy.stop();
      link.openReply!.complete({
        'socketId': 'late',
        'sequence': '0',
        'maxMessageBytes': 1048576,
      });
      final client = await connection.timeout(const Duration(seconds: 3));
      await client?.close();
      await until(() => link.closed.contains('late'));
      expect(link.readCalls, 0);
      expect(link.previewCloses, 1);
    },
  );

  test(
    'an unknown write closes the socket and never dispatches queued messages',
    () async {
      final link = PreviewLink()..rejectWrite = true;
      final proxy = PreviewProxy(link, 'preview');
      await proxy.start();
      final client = await connect(proxy);
      client.listen((_) {}, onError: (Object _) {});
      addTearDown(() async {
        if (!link.releaseWrite.isCompleted) link.releaseWrite.complete();
        await client.close();
        await proxy.stop();
      });
      client.add('first');
      await link.firstWrite.future.timeout(const Duration(seconds: 3));
      client.add('second');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      link.releaseWrite.complete();
      await until(() => link.closed.contains('socket'));
      expect(link.started, ['1']);
      expect(link.closed, ['socket']);
    },
  );
}
