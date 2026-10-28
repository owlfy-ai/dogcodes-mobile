import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'app.dart';
import 'core/access_client.dart';
import 'core/mobile_runtime.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const address = String.fromEnvironment(
    'DOGCODES_SERVICE_URL',
    defaultValue: kDebugMode ? 'http://127.0.0.1:8787' : '',
  );
  const development = bool.fromEnvironment('DOGCODES_LOCAL_DEV');
  runApp(
    DogCodesApp(
      runtime: MobileRuntime(),
      client: address.isEmpty
          ? null
          : AccessClient(
              Uri.parse(address),
              allowLocalDevelopment:
                  (development || kDebugMode) && !kReleaseMode,
            ),
    ),
  );
}
