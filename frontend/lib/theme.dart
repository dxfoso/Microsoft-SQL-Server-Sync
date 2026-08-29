import 'package:flutter/material.dart';

/// App-wide theme mode. Any widget can flip this; [SyncAdminApp] listens and
/// persists the choice. Defaults to following the operating system.
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.system);

/// Shared design tokens for the control-plane redesign.
///
/// One palette, resolved per [Brightness]. Screens read colors from
/// `AppTokens.of(context)` instead of hard-coding hex values, so light and
/// dark stay in sync and semantic state colors are never confused with the
/// interactive accent.
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.ground,
    required this.surface,
    required this.surface2,
    required this.rail,
    required this.rail2,
    required this.railLine,
    required this.railInk,
    required this.railMuted,
    required this.ink,
    required this.ink2,
    required this.muted,
    required this.hairline,
    required this.hairline2,
    required this.accent,
    required this.accentInk,
    required this.accentWash,
    required this.ok,
    required this.okWash,
    required this.warn,
    required this.warnWash,
    required this.crit,
    required this.critWash,
    required this.info,
    required this.infoWash,
  });

  final Color ground;
  final Color surface;
  final Color surface2;
  final Color rail;
  final Color rail2;
  final Color railLine;
  final Color railInk;
  final Color railMuted;
  final Color ink;
  final Color ink2;
  final Color muted;
  final Color hairline;
  final Color hairline2;
  final Color accent;
  final Color accentInk;
  final Color accentWash;
  final Color ok;
  final Color okWash;
  final Color warn;
  final Color warnWash;
  final Color crit;
  final Color critWash;
  final Color info;
  final Color infoWash;

  static const AppTokens light = AppTokens(
    ground: Color(0xFFF7F9F8),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF2F5F4),
    rail: Color(0xFF14211E),
    rail2: Color(0xFF1C2C28),
    railLine: Color(0xFF2B3D38),
    railInk: Color(0xFFDFE9E6),
    railMuted: Color(0xFF8BA39C),
    ink: Color(0xFF16211E),
    ink2: Color(0xFF43524D),
    muted: Color(0xFF6A7873),
    hairline: Color(0xFFE3E9E7),
    hairline2: Color(0xFFEEF2F1),
    accent: Color(0xFF0B6E64),
    accentInk: Color(0xFF085A52),
    accentWash: Color(0xFFE6F1EF),
    ok: Color(0xFF1F7A45),
    okWash: Color(0xFFE7F4EC),
    warn: Color(0xFF9A5B00),
    warnWash: Color(0xFFFBEED9),
    crit: Color(0xFFB23A2E),
    critWash: Color(0xFFFBE9E6),
    info: Color(0xFF245EA0),
    infoWash: Color(0xFFE7EEF7),
  );

  static const AppTokens dark = AppTokens(
    ground: Color(0xFF0D1315),
    surface: Color(0xFF141C1E),
    surface2: Color(0xFF1A2426),
    rail: Color(0xFF0B1113),
    rail2: Color(0xFF131D1F),
    railLine: Color(0xFF22302F),
    railInk: Color(0xFFE4EDE9),
    railMuted: Color(0xFF7E928C),
    ink: Color(0xFFE6EDE9),
    ink2: Color(0xFFB4C1BC),
    muted: Color(0xFF869089),
    hairline: Color(0xFF26302F),
    hairline2: Color(0xFF1E2828),
    accent: Color(0xFF43C3B3),
    accentInk: Color(0xFF6FD6C8),
    accentWash: Color(0xFF133330),
    ok: Color(0xFF58C98A),
    okWash: Color(0xFF12281D),
    warn: Color(0xFFE6AB5B),
    warnWash: Color(0xFF2E2415),
    crit: Color(0xFFEF8A79),
    critWash: Color(0xFF2F1A17),
    info: Color(0xFF86B4E6),
    infoWash: Color(0xFF172533),
  );

  static AppTokens of(BuildContext context) {
    return Theme.of(context).extension<AppTokens>() ?? light;
  }

  @override
  AppTokens copyWith() => this;

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    return t < 0.5 ? this : other;
  }
}

/// UI font fallback stack. IBM Plex is not bundled yet; these system faces
/// keep Latin + Arabic rendering correct in the meantime.
const List<String> kSansFallback = <String>[
  'IBM Plex Sans',
  'Segoe UI',
  'Tahoma',
  'Arial',
  'Noto Sans Arabic',
  'Noto Naskh Arabic',
  'sans-serif',
];

/// Monospace stack for versions, batch ids, cursors, timestamps and any
/// value operators compare character by character.
const List<String> kMonoFallback = <String>[
  'IBM Plex Mono',
  'Cascadia Mono',
  'Consolas',
  'SFMono-Regular',
  'Menlo',
  'monospace',
];

TextTheme _withFallback(TextTheme theme) {
  TextStyle? f(TextStyle? s) => s?.copyWith(fontFamilyFallback: kSansFallback);
  return theme.copyWith(
    displayLarge: f(theme.displayLarge),
    displayMedium: f(theme.displayMedium),
    displaySmall: f(theme.displaySmall),
    headlineLarge: f(theme.headlineLarge),
    headlineMedium: f(theme.headlineMedium),
    headlineSmall: f(theme.headlineSmall),
    titleLarge: f(theme.titleLarge),
    titleMedium: f(theme.titleMedium),
    titleSmall: f(theme.titleSmall),
    bodyLarge: f(theme.bodyLarge),
    bodyMedium: f(theme.bodyMedium),
    bodySmall: f(theme.bodySmall),
    labelLarge: f(theme.labelLarge),
    labelMedium: f(theme.labelMedium),
    labelSmall: f(theme.labelSmall),
  );
}

ThemeData buildAppTheme(Brightness brightness) {
  final bool dark = brightness == Brightness.dark;
  final AppTokens t = dark ? AppTokens.dark : AppTokens.light;

  final base = dark ? ThemeData.dark() : ThemeData.light();
  final textTheme = _withFallback(
    base.textTheme.apply(bodyColor: t.ink, displayColor: t.ink),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: t.ground,
    extensions: <ThemeExtension<dynamic>>[t],
    colorScheme:
        (dark ? const ColorScheme.dark() : const ColorScheme.light()).copyWith(
      primary: t.accent,
      onPrimary: dark ? const Color(0xFF06201D) : Colors.white,
      secondary: t.info,
      surface: t.surface,
      onSurface: t.ink,
      error: t.crit,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: t.surface,
      foregroundColor: t.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: t.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(7),
        side: BorderSide(color: t.hairline),
      ),
    ),
    textTheme: textTheme,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: t.accent,
        foregroundColor: dark ? const Color(0xFF06201D) : Colors.white,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: t.ink,
        minimumSize: const Size(0, 34),
        side: BorderSide(color: t.hairline),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: t.accentInk),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.surface,
      isDense: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: t.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: t.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: t.accent, width: 1.4),
      ),
      labelStyle: TextStyle(color: t.muted),
      hintStyle: TextStyle(color: t.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    ),
    dividerTheme: DividerThemeData(color: t.hairline, thickness: 1),
  );
}
