import 'dart:convert';

const protocolVersion = 1;
const maxFrameBytes = 262144;

class ProtocolException implements Exception {
  const ProtocolException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ServiceInfo {
  ServiceInfo.fromJson(Map<String, dynamic> json)
    : version = json['protocolVersion'] as int,
      service = json['service'] as String,
      stage = json['stage'] as String,
      capabilities = Map<String, bool>.from(json['capabilities'] as Map),
      frameLimit = json['maxFrameBytes'] as int {
    if (version != protocolVersion ||
        service != 'dogcodes-access' ||
        frameLimit < 1 ||
        frameLimit > maxFrameBytes) {
      throw const ProtocolException('服务版本不兼容，请更新 App 或服务端。');
    }
  }
  final int version;
  final String service;
  final String stage;
  final Map<String, bool> capabilities;
  final int frameLimit;
}

/// QR contents are untrusted until an authenticated endpoint handshake succeeds.
/// Parsing this value never creates a trusted device or sends its secret anywhere.
/// Pins from a scanned invitation, also used when verifying its original grant.
abstract interface class PairingPins {
  String get hostId;
  String get hostKey;
  String get invitationId;
  Uri get service;
}

class PairingInvitation implements PairingPins {
  PairingInvitation._(
    this.hostId,
    this.hostKey,
    this.invitationId,
    this.secret,
    this.service,
    this.expiresAt,
    this.phoneTicket,
  );

  factory PairingInvitation.parse(
    String input, {
    required Uri trustedService,
    required DateTime now,
    bool allowLocalDevelopment = false,
  }) {
    if (input.length > 4096) {
      throw const ProtocolException('二维码内容过长。');
    }
    final uri = Uri.tryParse(input);
    if (uri == null ||
        uri.scheme != 'dogcodes' ||
        uri.host != 'pair' ||
        uri.path.isNotEmpty ||
        uri.hasQuery ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.fragment.isEmpty) {
      throw const ProtocolException('不是 DogCodes 配对二维码。');
    }
    try {
      final bytes = base64Url.decode(base64Url.normalize(uri.fragment));
      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final service = Uri.parse(data['service'] as String);
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(
        int.parse(data['expiresAt'] as String) * 1000,
        isUtc: true,
      );
      final hostKey = data['hostKey'] as String;
      final secret = data['secret'] as String;
      final hostId = data['hostId'] as String;
      final invitationId = data['invitationId'] as String;
      if (data['version'] != protocolVersion ||
          service != trustedService ||
          (service.scheme != 'https' &&
              !(allowLocalDevelopment &&
                  service.scheme == 'http' &&
                  service.host == '127.0.0.1')) ||
          service.userInfo.isNotEmpty ||
          service.hasQuery ||
          service.hasFragment ||
          !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(hostId) ||
          !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(invitationId) ||
          base64Url.decode(base64Url.normalize(hostKey)).length != 32 ||
          base64Url.decode(base64Url.normalize(secret)).length != 32) {
        throw const ProtocolException('配对二维码无效，或来自未配置的服务。');
      }
      if (!expiresAt.isAfter(now)) {
        throw const ProtocolException('配对二维码已过期，请在电脑上重新生成。');
      }
      // Small clock differences must not reject a freshly generated five-minute
      // QR. The PC/server still enforce its original expiry, with no extension.
      if (expiresAt.difference(now) > const Duration(minutes: 5, seconds: 30)) {
        throw const ProtocolException('设备时间不一致，请校准手机和电脑时间后重试。');
      }
      return PairingInvitation._(
        hostId,
        hostKey,
        invitationId,
        secret,
        service,
        expiresAt,
        data['phoneTicket'] as String?,
      );
    } on ProtocolException {
      rethrow;
    } catch (_) {
      throw const ProtocolException('无法读取配对二维码。');
    }
  }
  @override
  final String hostId;
  @override
  final String hostKey;
  @override
  final String invitationId;
  final String secret;
  @override
  final Uri service;
  final DateTime expiresAt;
  final String? phoneTicket;
  @override
  String toString() => 'PairingInvitation(<redacted>)';
}

/// Cursors are decimal strings on the remote wire, never JSON doubles.
BigInt parseSequence(String value) {
  if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value)) {
    throw const ProtocolException('事件游标格式无效。');
  }
  final result = BigInt.parse(value);
  if (result > BigInt.parse('18446744073709551615')) {
    throw const ProtocolException('事件游标超出范围。');
  }
  return result;
}
