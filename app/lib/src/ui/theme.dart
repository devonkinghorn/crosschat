import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Dark, dense Slack/Discord-inspired palette.
class CC {
  static const rail = Color(0xFF1E1F22);
  static const sidebar = Color(0xFF2B2D31);
  static const channel = Color(0xFF313338);
  static const panel = Color(0xFF2B2D31);
  static const input = Color(0xFF383A40);
  static const hover = Color(0xFF35373C);
  static const selected = Color(0xFF404249);
  static const divider = Color(0xFF3F4147);
  static const text = Color(0xFFDBDEE1);
  static const textMuted = Color(0xFF949BA4);
  static const textFaint = Color(0xFF6D6F78);
  static const accent = Color(0xFF5865F2);
  static const link = Color(0xFF00A8FC);
  static const danger = Color(0xFFF23F43);
  static const success = Color(0xFF23A55A);
  static const warning = Color(0xFFF0B232);
}

ThemeData buildTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: CC.accent, brightness: Brightness.dark, surface: CC.channel),
    scaffoldBackgroundColor: CC.channel,
    visualDensity: VisualDensity.compact,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: CC.text, displayColor: CC.text),
    dividerColor: CC.divider,
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: CC.input,
      border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.all(Radius.circular(8))),
      isDense: true,
      hintStyle: TextStyle(color: CC.textFaint),
    ),
    dialogTheme: const DialogThemeData(backgroundColor: CC.sidebar),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(color: Color(0xFF111214), borderRadius: BorderRadius.all(Radius.circular(6))),
      textStyle: TextStyle(color: CC.text, fontSize: 13),
    ),
  );
}

/// Text style that renders emoji in the platform's color emoji font (the
/// default text font may carry monochrome glyphs for some of them).
TextStyle emojiStyle(double size) =>
    TextStyle(fontSize: size, fontFamily: _emojiFont, fontFamilyFallback: const ['Apple Color Emoji', 'Noto Color Emoji', 'Segoe UI Emoji']);

final String? _emojiFont = switch (defaultTargetPlatform) {
  TargetPlatform.macOS || TargetPlatform.iOS => 'Apple Color Emoji',
  TargetPlatform.windows => 'Segoe UI Emoji',
  TargetPlatform.linux || TargetPlatform.android => 'Noto Color Emoji',
  _ => null,
};
