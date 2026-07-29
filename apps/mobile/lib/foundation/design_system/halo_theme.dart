import 'package:flutter/material.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

abstract final class HaloTheme {
  static ThemeData light() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: HaloColors.accent,
      brightness: Brightness.light,
      surface: HaloColors.paper,
      error: HaloColors.red,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: HaloColors.paper,
      dividerColor: HaloColors.line,
      splashColor: HaloColors.accent.withValues(alpha: 0.06),
      highlightColor: HaloColors.accent.withValues(alpha: 0.04),
      textTheme: ThemeData.light().textTheme.apply(
        bodyColor: HaloColors.ink,
        displayColor: HaloColors.ink,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: HaloMetrics.tabBarHeight,
        backgroundColor: HaloColors.paper.withValues(alpha: 0.96),
        indicatorColor: Colors.transparent,
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          return TextStyle(
            color: states.contains(WidgetState.selected)
                ? HaloColors.accentDeep
                : const Color(0xFF999DA6),
            fontSize: 10,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w400,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          return IconThemeData(
            color: states.contains(WidgetState.selected)
                ? HaloColors.accentDeep
                : const Color(0xFF999DA6),
            size: 21,
          );
        }),
      ),
      dividerTheme: const DividerThemeData(
        color: HaloColors.line,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
