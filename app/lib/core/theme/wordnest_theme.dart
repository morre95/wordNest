import 'package:flutter/material.dart';

/// WordNest's visual language: a warm, quiet palette — twig, moss, and the
/// pale straw of a nest — so the microphone is the only loud thing on screen.
abstract final class WordNestTheme {
  static const _seed = Color(0xFF8C6A3F);

  /// Minimum tap target for every interactive control on the speak screen.
  static const minTapTarget = 48.0;

  static ThemeData light() => _theme(Brightness.light);
  static ThemeData dark() => _theme(Brightness.dark);

  static ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(minTapTarget, minTapTarget),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(minTapTarget, minTapTarget),
        ),
      ),
    );
  }
}
