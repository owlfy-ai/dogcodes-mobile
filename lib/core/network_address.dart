import 'dart:io';

const _release = bool.fromEnvironment('dart.vm.product');

// Preserve the canonical service origin for QR validation and Noise prologues.
// Only transport to the development host uses Android emulator's loopback alias.
Uri reachable(Uri origin) =>
    !_release && Platform.isAndroid && origin.host == '127.0.0.1'
    ? origin.replace(host: '10.0.2.2')
    : origin;
