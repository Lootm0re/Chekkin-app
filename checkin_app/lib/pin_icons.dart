import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'theme.dart';

/// How a map pin looks: a [color] circle with a white border and [icon] in
/// the middle. [highlighted] pins (Premium partners and up) are bigger, with
/// a purple ring and a yellow star badge.
@immutable
class PinStyle {
  final Color color;
  final IconData icon;
  final bool highlighted;

  const PinStyle(this.color, this.icon, {this.highlighted = false});

  /// Dark ink on the bright colours, white on purple (see AppColors.onColor).
  Color get iconColor => AppColors.onColor(color);

  @override
  bool operator ==(Object other) =>
      other is PinStyle && other.color == color && other.icon == icon && other.highlighted == highlighted;

  @override
  int get hashCode => Object.hash(color, icon, highlighted);
}

/// Pin icons for the given styles, drawn here so they look the same on every
/// platform (google_maps_flutter's built-in pins only come in hues).
Future<Map<PinStyle, BitmapDescriptor>> loadPinIcons(Iterable<PinStyle> styles) async {
  final distinct = styles.toSet().toList();
  final icons = await Future.wait(distinct.map(_drawPin));
  return Map.fromIterables(distinct, icons);
}

// Logical size of a pin (a highlighted one is _highlightedSize). Drawn at
// _scale times that for sharp edges on high-density screens.
const double _size = 40;
const double _highlightedSize = 52;
const double _border = 3;
const double _ring = 3;
const double _scale = 3;

Future<BitmapDescriptor> _drawPin(PinStyle style) async {
  final double size = pinSize(style);
  return BitmapDescriptor.bytes(await drawPinPng(style), width: size, height: size);
}

/// The pin's logical width and height.
double pinSize(PinStyle style) => style.highlighted ? _highlightedSize : _size;

/// The pin as a PNG, at [_scale] times [pinSize].
Future<Uint8List> drawPinPng(PinStyle style) async {
  final double size = pinSize(style);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(_scale);
  final center = Offset(size / 2, size / 2);
  // Room for the shadow, and for the ring and badge on highlighted pins.
  final double outer = style.highlighted ? size / 2 - 5 : size / 2 - 2;
  final double radius = style.highlighted ? outer - _ring : outer;

  canvas.drawCircle(
    center.translate(0, 1),
    outer,
    Paint()
      ..color = AppColors.ink.withValues(alpha: 0.25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
  );
  if (style.highlighted) canvas.drawCircle(center, outer, Paint()..color = AppColors.purple);
  canvas
    ..drawCircle(center, radius, Paint()..color = Colors.white)
    ..drawCircle(center, radius - _border, Paint()..color = style.color);

  final icon = TextPainter(
    textDirection: TextDirection.ltr,
    text: TextSpan(
      text: String.fromCharCode(style.icon.codePoint),
      style: TextStyle(
        fontFamily: style.icon.fontFamily,
        package: style.icon.fontPackage,
        fontSize: 20,
        color: style.iconColor,
      ),
    ),
  )..layout();
  icon.paint(canvas, center - Offset(icon.width / 2, icon.height / 2));

  if (style.highlighted) {
    // A yellow star badge on the top right, over the ring.
    final badge = Offset(size - 10, 10);
    canvas
      ..drawCircle(badge, 9, Paint()..color = Colors.white)
      ..drawCircle(badge, 7.5, Paint()..color = AppColors.yellow);
    final star = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(Icons.star_rounded.codePoint),
        style: TextStyle(fontFamily: Icons.star_rounded.fontFamily, fontSize: 11, color: AppColors.ink),
      ),
    )..layout();
    star.paint(canvas, badge - Offset(star.width / 2, star.height / 2));
  }

  final image = await recorder.endRecording().toImage((size * _scale).round(), (size * _scale).round());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}
