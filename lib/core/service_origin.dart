import 'dart:io';

const _release = bool.fromEnvironment('dart.vm.product');

/// HTTP is restricted to local development, using literal LAN or loopback
/// addresses. Hostnames resolving to private addresses do not bypass HTTPS.
bool developmentServiceHost(String host) {
  if (host == 'localhost' || host == '::1') return true;
  final address = InternetAddress.tryParse(host);
  if (address == null || address.type != InternetAddressType.IPv4) return false;
  final bytes = address.rawAddress;
  return bytes[0] == 127 ||
      bytes[0] == 10 ||
      (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
      (bytes[0] == 192 && bytes[1] == 168);
}

bool validServiceOrigin(Uri uri, {bool allowLocalDevelopment = false}) =>
    uri.host.isNotEmpty &&
    (uri.scheme == 'https' ||
        (!_release &&
            allowLocalDevelopment &&
            uri.scheme == 'http' &&
            developmentServiceHost(uri.host))) &&
    uri.userInfo.isEmpty &&
    !uri.hasQuery &&
    !uri.hasFragment &&
    (uri.path.isEmpty || uri.path == '/');
