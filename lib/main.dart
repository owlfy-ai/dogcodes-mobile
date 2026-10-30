import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'app.dart';
import 'core/access_client.dart';
import 'core/mobile_runtime.dart';

void main() {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  // Keep the native launch view until Flutter's identical artwork is decoded;
  // otherwise its first frame can briefly be an empty black canvas.
  binding.deferFirstFrame();
  final artwork = const AssetImage(
    'assets/branding/launch-lockup.png',
  ).resolve(const ImageConfiguration());
  late final ImageStreamListener listener;
  void ready() {
    artwork.removeListener(listener);
    binding.allowFirstFrame();
  }

  listener = ImageStreamListener(
    (image, _) {
      image.dispose();
      ready();
    },
    onError: (Object error, StackTrace? stack) {
      debugPrint('Launch artwork unavailable: $error');
      ready();
    },
  );
  artwork.addListener(listener);
  const address = String.fromEnvironment(
    'DOGCODES_SERVICE_URL',
    defaultValue: 'https://global.dog.codes',
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
