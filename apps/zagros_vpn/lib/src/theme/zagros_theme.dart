import 'package:flutter/material.dart';

ThemeData buildZagrosTheme(Brightness brightness) {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff155e75),
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: colorScheme.surface,
    cardTheme: CardThemeData(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      indicatorColor: colorScheme.secondaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    navigationRailTheme: NavigationRailThemeData(
      indicatorColor: colorScheme.secondaryContainer,
      useIndicator: true,
    ),
  );
}
