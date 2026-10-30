# App icon

`app-icon.png` is the approved full-bleed black source, shared with the desktop app. Do not add a white border or outer tile.

Android launcher PNGs and adaptive foregrounds live in `android/app/src/main/res/mipmap-*`. The adaptive icon uses a black background and an 18dp foreground inset for the system mask. iOS exports live in `ios/Runner/Assets.xcassets/AppIcon.appiconset`; preserve their filenames and export as opaque RGB PNGs.

Icons were exported using the desktop repository’s Tauri icon CLI with `--ios-color '#000000'`; iOS exports have their alpha channel removed. Launcher icon changes require rebuilding and reinstalling the app.

## Launch screen

`launch-lockup.png` is the shared 240pt/720px launch composition: the approved 96pt mark stays at the screen center, followed by the white `dog.codes` wordmark with its green period. iOS and pre-Android-12 use the same composition. Android 12+ uses the centered mark within its system splash mask, then Flutter adds the wordmark in the same position.

Export native density variants on macOS with `python3 tool/generate_launch_assets.py` (Pillow required). Typography is rasterized at export; no font or new illustration is shipped. Native window backgrounds and Flutter's first frame are black in both appearance modes. The subtle loading dot respects Reduce Motion. The app enters its home screen as soon as local state is available, without waiting for computers to reconnect or adding a minimum splash duration. Native launch changes require a full rebuild/reinstall; hot reload does not update them.
