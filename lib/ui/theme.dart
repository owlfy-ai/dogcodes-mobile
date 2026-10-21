import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Tokens from docs/design/mobile-2026-10-18/design-tokens.json.
/// Main canvases stay pure white / pure black; green is a restrained accent.
@immutable
class DcColors extends ThemeExtension<DcColors> {
  const DcColors({
    required this.canvas,
    required this.text,
    required this.secondary,
    required this.surface,
    required this.code,
    required this.line,
    required this.accent,
    required this.onAccent,
    required this.added,
    required this.removed,
    required this.warning,
  });
  final Color canvas,
      text,
      secondary,
      surface,
      code,
      line,
      accent,
      onAccent,
      added,
      removed,
      warning;

  static const light = DcColors(
    canvas: Color(0xFFFFFFFF),
    text: Color(0xFF171717),
    secondary: Color(0xFF777777),
    surface: Color(0xFFF6F6F6),
    code: Color(0xFFF6F6F6),
    line: Color(0xFFE8E8E8),
    accent: Color(0xFF78A91F),
    onAccent: Color(0xFF101010),
    added: Color(0xFF3F8F2F),
    removed: Color(0xFFC0473F),
    warning: Color(0xFFD98A1C),
  );
  static const dark = DcColors(
    canvas: Color(0xFF000000),
    text: Color(0xFFF5F5F5),
    secondary: Color(0xFF969696),
    surface: Color(0xFF101010),
    code: Color(0xFF0A0A0A),
    line: Color(0xFF242424),
    accent: Color(0xFFB7F34C),
    onAccent: Color(0xFF101010),
    added: Color(0xFF8FD16A),
    removed: Color(0xFFE57B72),
    warning: Color(0xFFF0B45A),
  );

  @override
  DcColors copyWith() => this;
  @override
  DcColors lerp(ThemeExtension<DcColors>? other, double t) =>
      other is DcColors && t >= 0.5 ? other : this;
}

abstract final class DcSpace {
  static const page = 20.0;
  static const section = 24.0;
  static const row = 12.0;
  static const touch = 44.0;
  static const control = 10.0;
  static const composer = 20.0;
  static const sheet = 24.0;
}

const monoFamily = 'Menlo';
const monoFallback = ['SF Mono', 'Roboto Mono', 'monospace'];

extension DcTheme on BuildContext {
  DcColors get dc => Theme.of(this).extension<DcColors>()!;
}

ThemeData dcTheme(Brightness brightness) {
  final c = brightness == Brightness.light ? DcColors.light : DcColors.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.accent,
    onPrimary: c.onAccent,
    secondary: c.text,
    onSecondary: c.canvas,
    error: c.removed,
    onError: c.canvas,
    surface: c.canvas,
    onSurface: c.text,
    onSurfaceVariant: c.secondary,
    outline: c.line,
    outlineVariant: c.line,
    surfaceContainerLowest: c.canvas,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surface,
    surfaceContainerHighest: c.surface,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
  );
  final text = base.textTheme.apply(bodyColor: c.text, displayColor: c.text);
  final control = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(DcSpace.control),
  );
  const minimum = Size(DcSpace.touch, DcSpace.touch);
  return base.copyWith(
    extensions: [c],
    scaffoldBackgroundColor: c.canvas,
    canvasColor: c.canvas,
    dividerColor: c.line,
    splashFactory: NoSplash.splashFactory,
    textTheme: text.copyWith(
      headlineSmall: text.headlineSmall?.copyWith(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      titleLarge: text.titleLarge?.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: text.titleMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: text.bodyLarge?.copyWith(fontSize: 16, height: 1.5),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 15, height: 1.45),
      bodySmall: text.bodySmall?.copyWith(fontSize: 13, color: c.secondary),
      labelLarge: text.labelLarge?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
    ),
    appBarTheme: AppBarTheme(
      systemOverlayStyle: overlayStyle(brightness),
      backgroundColor: c.canvas,
      foregroundColor: c.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: 0,
      titleTextStyle: text.titleLarge?.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
    ),
    dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: c.text, size: 22),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        disabledBackgroundColor: c.surface,
        disabledForegroundColor: c.secondary,
        minimumSize: minimum,
        shape: control,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.text,
        disabledForegroundColor: c.secondary,
        side: BorderSide(color: c.line),
        minimumSize: minimum,
        shape: control,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.text,
        minimumSize: minimum,
        shape: control,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: minimum),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      hintStyle: TextStyle(color: c.secondary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DcSpace.control),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DcSpace.control),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DcSpace.control),
        borderSide: BorderSide(color: c.line),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.canvas,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      height: 60,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontSize: 11,
          fontWeight: s.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
          color: s.contains(WidgetState.selected) ? c.accent : c.secondary,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          size: 24,
          color: s.contains(WidgetState.selected) ? c.accent : c.secondary,
        ),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.canvas,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: c.line,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.canvas,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DcSpace.control),
        side: BorderSide(color: c.line),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.text,
      contentTextStyle: TextStyle(color: c.canvas),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.onAccent : c.secondary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.accent : c.surface,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.canvas,
      selectedColor: c.surface,
      checkmarkColor: c.accent,
      labelStyle: TextStyle(color: c.text, fontSize: 14),
      secondaryLabelStyle: TextStyle(color: c.text, fontSize: 14),
      side: BorderSide(color: c.line),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DcSpace.control),
      ),
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: c.accent,
      textColor: c.onAccent,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accent,
      linearTrackColor: c.line,
    ),
  );
}

SystemUiOverlayStyle overlayStyle(Brightness brightness) =>
    brightness == Brightness.dark
    ? SystemUiOverlayStyle.light
    : SystemUiOverlayStyle.dark;

/// Filled icon actions on the accent always use near-black glyphs.
ButtonStyle accentIconButton(BuildContext context) => IconButton.styleFrom(
  backgroundColor: context.dc.accent,
  foregroundColor: context.dc.onAccent,
  disabledBackgroundColor: context.dc.surface,
  disabledForegroundColor: context.dc.secondary,
);
