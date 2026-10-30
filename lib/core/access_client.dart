import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'protocol.dart';
import 'network_address.dart';
import 'service_origin.dart';

class AccessClient {
  AccessClient(this.origin, {this.allowLocalDevelopment = false});
  final Uri origin;
  final bool allowLocalDevelopment;

  Future<ServiceInfo> info() async {
    if (!validServiceOrigin(
      origin,
      allowLocalDevelopment: allowLocalDevelopment,
    )) {
      throw ProtocolException(tr("服务地址必须使用 HTTPS；调试版本可使用本机或局域网 IP。"));
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      return await (() async {
        final request = await client.getUrl(
          reachable(origin).resolve('/v1/info'),
        );
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != 200) {
          throw ProtocolException(tr("服务暂时不可用，请稍后重试。"));
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 16384) {
            throw ProtocolException(tr("服务返回了无法识别的响应。"));
          }
        }
        return ServiceInfo.fromJson(
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
        );
      })().timeout(const Duration(seconds: 8));
    } on TimeoutException {
      throw ProtocolException(tr("连接超时，请检查网络后重试。"));
    } on SocketException {
      throw ProtocolException(tr("无法连接服务，请检查网络和服务地址。"));
    } on HandshakeException {
      throw ProtocolException(tr("无法验证服务证书，请检查服务配置。"));
    } on ProtocolException {
      rethrow;
    } catch (_) {
      throw ProtocolException(tr("服务响应无效或连接已中断，请重试。"));
    } finally {
      client.close(force: true);
    }
  }
}
