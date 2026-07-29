import 'package:flutter/material.dart';

abstract final class HaloColors {
  static const ink = Color(0xFF171923);
  static const muted = Color(0xFF8B909A);
  static const line = Color(0xFFE9EBEF);
  static const soft = Color(0xFFF4F5F7);
  static const paper = Color(0xFFFFFFFF);
  static const accent = Color(0xFF5668D8);
  static const accentDeep = Color(0xFF3F50B7);
  static const accentSoft = Color(0xFFEEF0FF);
  static const green = Color(0xFF2E9D72);
  static const amber = Color(0xFFCF8A2E);
  static const red = Color(0xFFE75B62);
  static const navy = Color(0xFF28314E);
}

abstract final class HaloMetrics {
  static const navigationBarHeight = 53.0;
  static const searchHeight = 38.0;
  static const tabBarHeight = 80.0;
  static const avatarSize = 50.0;
  static const compactAvatarSize = 36.0;
  static const horizontalPadding = 15.0;
  static const iconButtonSize = 34.0;
  static const settingsRowHeight = 52.0;
}

abstract final class HaloRadii {
  static const card = 14.0;
  static const search = 10.0;
  static const avatar = 13.0;
  static const compactAvatar = 9.0;
  static const settingsIcon = 9.0;
  static const tag = 5.0;
  static const sheet = 23.0;
}

abstract final class HaloTextStyles {
  static const pageTitle = TextStyle(
    color: HaloColors.ink,
    fontSize: 22,
    height: 1.1,
    fontWeight: FontWeight.w700,
  );

  static const compactTitle = TextStyle(
    color: HaloColors.ink,
    fontSize: 16,
    height: 1.15,
    fontWeight: FontWeight.w700,
  );

  static const rowTitle = TextStyle(
    color: HaloColors.ink,
    fontSize: 15,
    height: 1.2,
    fontWeight: FontWeight.w600,
  );

  static const body = TextStyle(
    color: HaloColors.ink,
    fontSize: 13,
    height: 1.55,
    fontWeight: FontWeight.w400,
  );

  static const secondary = TextStyle(
    color: HaloColors.muted,
    fontSize: 12,
    height: 1.35,
    fontWeight: FontWeight.w400,
  );

  static const caption = TextStyle(
    color: HaloColors.muted,
    fontSize: 10,
    height: 1.3,
    fontWeight: FontWeight.w400,
  );

  static const sectionLabel = TextStyle(
    color: Color(0xFF999EA7),
    fontSize: 10,
    height: 1.2,
    fontWeight: FontWeight.w700,
  );
}
