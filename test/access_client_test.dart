import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/access_client.dart';
import 'package:dogcodes_app/core/protocol.dart';

void main() {
  test(
    'local service is available only with explicit development configuration',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          await File('test/fixtures/service-info.v1.json').readAsString(),
        );
        await request.response.close();
      });
      await expectLater(
        AccessClient(origin).info(),
        throwsA(isA<ProtocolException>()),
      );
      final info = await AccessClient(
        origin,
        allowLocalDevelopment: true,
      ).info();
      expect(info.capabilities['relayProbe'], true);
    },
  );
  test(
    'redirects are not followed and friendly failures hide raw response data',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = 302;
        request.response.headers.set('Location', 'https://attacker.invalid');
        await request.response.close();
      });
      await expectLater(
        AccessClient(
          Uri.parse('http://127.0.0.1:${server.port}'),
          allowLocalDevelopment: true,
        ).info(),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            '服务暂时不可用，请稍后重试。',
          ),
        ),
      );
    },
  );
}
