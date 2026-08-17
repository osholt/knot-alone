import 'package:flutter/material.dart';

/// Colours a sailor can personally choose.
///
/// The selected colour is their identity on every roster and map surface.
/// Roles and alerts use labels, borders and icons rather than replacing it.
enum SailorColor {
  green,
  orange,
  yellow,
  teal,
  pink,
  cyan,
  amber,
  crimson,
  purple,
  white,
  blue,
  lime,
  slate,
}

extension SailorColorData on SailorColor {
  Color get color => switch (this) {
    SailorColor.green => const Color(0xFF6ED89A),
    SailorColor.orange => const Color(0xFFFF9F5A),
    SailorColor.yellow => const Color(0xFFE8D24C),
    SailorColor.teal => const Color(0xFF4FC7C7),
    SailorColor.pink => const Color(0xFFE87FC0),
    SailorColor.cyan => const Color(0xFF5AC8FA),
    SailorColor.amber => const Color(0xFFD9A441),
    SailorColor.crimson => const Color(0xFFD9607A),
    SailorColor.purple => const Color(0xFF9B7BFF),
    SailorColor.white => const Color(0xFFF4F6F8),
    SailorColor.blue => const Color(0xFF5B8DEF),
    SailorColor.lime => const Color(0xFFA7D957),
    SailorColor.slate => const Color(0xFF8796A8),
  };

  String get label => switch (this) {
    SailorColor.green => 'Green',
    SailorColor.orange => 'Orange',
    SailorColor.yellow => 'Yellow',
    SailorColor.teal => 'Teal',
    SailorColor.pink => 'Pink',
    SailorColor.cyan => 'Sky blue',
    SailorColor.amber => 'Amber',
    SailorColor.crimson => 'Crimson',
    SailorColor.purple => 'Purple',
    SailorColor.white => 'White',
    SailorColor.blue => 'Blue',
    SailorColor.lime => 'Lime',
    SailorColor.slate => 'Slate',
  };
}

/// White and near-white badges need a dark edge; the other light identity
/// colours retain the familiar white selection/position edge.
Color sailorBadgeStrokeColor(Color fill) =>
    fill.computeLuminance() > 0.82 ? const Color(0xFF10151C) : Colors.white;

/// Default for sessions created before this feature existed, and the
/// fallback when a peer sends an unrecognised colour name. Matches the
/// green sailors have always shown as.
const sailorColorDefault = SailorColor.green;

SailorColor sailorColorFromName(String? name) => SailorColor.values.firstWhere(
  (value) => value.name == name,
  orElse: () => sailorColorDefault,
);

/// Reserved status colours that never come from a sailor's personal choice.
/// They remain available for role/alert accents without replacing identity.
const leadColor = Color(0xFFB58CFF);
const sweeperColor = Color(0xFF68A9FF);
const alertColor = Color(0xFFFF5D73);
