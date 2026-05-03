import 'package:flutter/material.dart';

/// 디자인 시스템에서 ColorScheme로는 표현 못 하는 cubby-특화 토큰.
///
/// 매핑은 `dark-theme.css` / `colors_and_type.css` 기준.
/// canvas/surfaceCard/hairline 같은 warm-cream 톤은 Material의
/// surface/onSurface로 1:1 대응되지 않아 별도 extension으로 노출한다.
class CubbyColors extends ThemeExtension<CubbyColors> {
  const CubbyColors({
    required this.canvas,
    required this.surfaceSoft,
    required this.surfaceCard,
    required this.surfaceCreamStrong,
    required this.hairline,
    required this.hairlineSoft,
    required this.bodyStrong,
    required this.body,
    required this.muted,
    required this.mutedSoft,
    required this.success,
    required this.warning,
    required this.danger,
  });

  final Color canvas;
  final Color surfaceSoft;
  final Color surfaceCard;
  final Color surfaceCreamStrong;
  final Color hairline;
  final Color hairlineSoft;
  final Color bodyStrong;
  final Color body;
  final Color muted;
  final Color mutedSoft;
  final Color success;
  final Color warning;
  final Color danger;

  static const light = CubbyColors(
    canvas: Color(0xFFFAF9F5),
    surfaceSoft: Color(0xFFF5F0E8),
    surfaceCard: Color(0xFFEFE9DE),
    surfaceCreamStrong: Color(0xFFE8E0D2),
    hairline: Color(0xFFE6DFD8),
    hairlineSoft: Color(0xFFEBE6DF),
    bodyStrong: Color(0xFF252523),
    body: Color(0xFF3D3D3A),
    muted: Color(0xFF6C6A64),
    mutedSoft: Color(0xFF8E8B82),
    success: Color(0xFF5DB872),
    warning: Color(0xFFD4A017),
    danger: Color(0xFFC64545),
  );

  static const dark = CubbyColors(
    canvas: Color(0xFF181715),
    surfaceSoft: Color(0xFF1F1E1B),
    surfaceCard: Color(0xFF252320),
    surfaceCreamStrong: Color(0xFF2C2A26),
    hairline: Color(0xFF2C2A26),
    hairlineSoft: Color(0xFF232220),
    bodyStrong: Color(0xFFEBE6DF),
    body: Color(0xFFD4CFC6),
    muted: Color(0xFF9A958C),
    mutedSoft: Color(0xFF6C6A64),
    success: Color(0xFF5DB872),
    warning: Color(0xFFD4A017),
    danger: Color(0xFFFFB4AB),
  );

  @override
  CubbyColors copyWith({
    Color? canvas,
    Color? surfaceSoft,
    Color? surfaceCard,
    Color? surfaceCreamStrong,
    Color? hairline,
    Color? hairlineSoft,
    Color? bodyStrong,
    Color? body,
    Color? muted,
    Color? mutedSoft,
    Color? success,
    Color? warning,
    Color? danger,
  }) {
    return CubbyColors(
      canvas: canvas ?? this.canvas,
      surfaceSoft: surfaceSoft ?? this.surfaceSoft,
      surfaceCard: surfaceCard ?? this.surfaceCard,
      surfaceCreamStrong: surfaceCreamStrong ?? this.surfaceCreamStrong,
      hairline: hairline ?? this.hairline,
      hairlineSoft: hairlineSoft ?? this.hairlineSoft,
      bodyStrong: bodyStrong ?? this.bodyStrong,
      body: body ?? this.body,
      muted: muted ?? this.muted,
      mutedSoft: mutedSoft ?? this.mutedSoft,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
    );
  }

  @override
  CubbyColors lerp(CubbyColors? other, double t) {
    if (other == null) return this;
    return CubbyColors(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surfaceSoft: Color.lerp(surfaceSoft, other.surfaceSoft, t)!,
      surfaceCard: Color.lerp(surfaceCard, other.surfaceCard, t)!,
      surfaceCreamStrong:
          Color.lerp(surfaceCreamStrong, other.surfaceCreamStrong, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      hairlineSoft: Color.lerp(hairlineSoft, other.hairlineSoft, t)!,
      bodyStrong: Color.lerp(bodyStrong, other.bodyStrong, t)!,
      body: Color.lerp(body, other.body, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      mutedSoft: Color.lerp(mutedSoft, other.mutedSoft, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

extension CubbyColorsX on BuildContext {
  CubbyColors get cubby => Theme.of(this).extension<CubbyColors>()!;
}

ThemeData buildLightTheme() {
  const primary = Color(0xFFCC785C);
  const ink = Color(0xFF141413);
  const canvas = Color(0xFFFAF9F5);
  const surfaceCard = Color(0xFFEFE9DE);

  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: primary,
    onPrimary: Colors.white,
    secondary: primary,
    onSecondary: Colors.white,
    error: Color(0xFFC64545),
    onError: Colors.white,
    surface: canvas,
    onSurface: ink,
    surfaceContainerHighest: surfaceCard,
    outline: Color(0xFFE6DFD8),
  );

  return ThemeData(
    brightness: Brightness.light,
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Pretendard',
    scaffoldBackgroundColor: canvas,
    appBarTheme: const AppBarTheme(
      backgroundColor: canvas,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    extensions: const [CubbyColors.light],
  );
}

ThemeData buildDarkTheme() {
  const primary = Color(0xFFE08E72);
  const ink = Color(0xFFFAF9F5);
  const canvas = Color(0xFF181715);
  const surfaceCard = Color(0xFF252320);

  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: primary,
    onPrimary: Colors.white,
    secondary: primary,
    onSecondary: Colors.white,
    error: Color(0xFFFFB4AB),
    onError: Colors.black,
    surface: canvas,
    onSurface: ink,
    surfaceContainerHighest: surfaceCard,
    outline: Color(0xFF2C2A26),
  );

  return ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Pretendard',
    scaffoldBackgroundColor: canvas,
    appBarTheme: const AppBarTheme(
      backgroundColor: canvas,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    extensions: const [CubbyColors.dark],
  );
}
