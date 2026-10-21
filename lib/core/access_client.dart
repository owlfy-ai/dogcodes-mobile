import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'protocol.dart';
import 'network_address.dart';

class AccessClient {
  AccessClient(this.origin, {this.allowLocalDevelopment = false});
  final Uri origin;
  final bool allowLocalDevelopment;

  Future<ServiceInfo> info() async {
    final local = [
      '127.0.0.1',
      'localhost',
      '::1',
      '10.0.2.2',
    ].contains(origin.host);
    if ((origin.scheme != 'https' &&
            !(origin.scheme == 'http' && local && allowLocalDevelopment)) ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        (origin.path.isNotEmpty && origin.path != '/')) {
      throw const ProtocolException('服务地址必须使用 HTTPS；本地开发仅允许模拟器回环地址。');
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
          throw const ProtocolException('服务暂时不可用，请稍后重试。');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 16384) {
            throw const ProtocolException('服务返回了无法识别的响应。');
          }
        }
        return ServiceInfo.fromJson(
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
        );
      })().timeout(const Duration(seconds: 8));
    } on TimeoutException {
      throw const ProtocolException('连接超时，请检查网络后重试。');
    } on SocketException {
      throw const ProtocolException('无法连接服务，请检查网络和服务地址。');
    } on HandshakeException {
      throw const ProtocolException('无法验证服务证书，请检查服务配置。');
    } on ProtocolException {
      rethrow;
    } catch (_) {
      throw const ProtocolException('服务响应无效或连接已中断，请重试。');
    } finally {
      client.close(force: true);
    }
  }
}
