import 'dart:convert';
import 'secure_relay_exchange.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:dogcodes_app/core/access_client.dart';
import 'package:dogcodes_app/core/relay_probe.dart';

/// Run against a local dogcodes-server. Uses only synthetic probe bytes.
Future<void> main() async {
  final token = Platform.environment['DOGCODES_ADMIN_TOKEN'];
  if (token == null) throw StateError('Set DOGCODES_ADMIN_TOKEN locally.');
  final public = Uri.parse(
    Platform.environment['DOGCODES_PROBE_ORIGIN'] ?? 'http://127.0.0.1:8787',
  );
  final admin = Uri.parse(
    Platform.environment['DOGCODES_PROBE_ADMIN'] ?? 'http://127.0.0.1:8788',
  );
  if (admin.scheme != 'http' || admin.host != '127.0.0.1') {
    throw StateError('Probe admin must be local.');
  }
  final info = await AccessClient(public, allowLocalDevelopment: true).info();
  if (info.capabilities['relayProbe'] != true) {
    throw StateError('Probe unsupported.');
  }
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  RelayProbe? host;
  RelayProbe? phone;
  try {
    final request = await http.postUrl(admin.resolve('/v1/relay-sessions'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close();
    if (response.statusCode != 201) {
      throw StateError('Probe allocation failed (${response.statusCode}).');
    }
    final grant =
        jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
    final ws = public.replace(scheme: 'ws');
    host = await RelayProbe.connect(
      ws,
      grant['sessionId'] as String,
      grant['hostTicket'] as String,
    );
    phone = await RelayProbe.connect(
      ws,
      grant['sessionId'] as String,
      grant['phoneTicket'] as String,
    );
    if (Platform.environment['DOGCODES_SECURE_PROBE'] == '1') {
      await secureExchange(host, phone);
    } else {
      final reply = phone.frames.first.timeout(const Duration(seconds: 5));
      host.send(Uint8List.fromList([0, 255, 42]));
      if (base64Encode(await reply) != base64Encode([0, 255, 42])) {
        throw StateError('Frame mismatch.');
      }
      final reverse = host.frames.first.timeout(const Duration(seconds: 5));
      phone.send(Uint8List.fromList([17, 0, 255]));
      if (base64Encode(await reverse) != base64Encode([17, 0, 255])) {
        throw StateError('Reverse frame mismatch.');
      }
    }
  } finally {
    await host?.close();
    await phone?.close();
    http.close(force: true);
  }
  stdout.writeln(
    'PASS: Dart ↔ Rust relay, cleanup; encrypted=${Platform.environment['DOGCODES_SECURE_PROBE'] == '1'}.',
  );
}
