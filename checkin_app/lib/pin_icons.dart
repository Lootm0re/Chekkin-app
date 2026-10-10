import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'theme.dart';

/// How a map pin looks: a [color] circle with a white border and [icon] in
/// the middle.
@immutable
class PinStyle {
  final Color color;
  final IconData icon;

  const PinStyle(this.color, this.icon);

  /// Dark ink on the bright colours, white on purple (see AppColors.onColor).
  Color get iconColor => AppColors.onColor(color);

  @override
  bool operator ==(Object other) => other is PinStyle && other.color == color && other.icon == icon;

  @override
  int get hashCode => Object.hash(color, icon);
}

/// Pin icons for the given styles, drawn here so they look the same on every
/// platform (google_maps_flutter's built-in pins only come in hues).
Future<Map<PinStyle, BitmapDescriptor>> loadPinIcons(Iterable<PinStyle> styles) async {
  final distinct = styles.toSet().toList();
  final icons = await Future.wait(distinct.map(_drawPin));
  return Map.fromIterables(distinct, icons);
}

// Logical size of a pin. Drawn at _scale times that for sharp edges on
// high-density screens.
const double _size = 40;
const double _border = 3;
const double _scale = 3;

Future<BitmapDescriptor> _drawPin(PinStyle style) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(_scale);
  const center = Offset(_size / 2, _size / 2);
  const radius = _size / 2 - 2; // room for the shadow

  canvas
    ..drawCircle(
      center.translate(0, 1),
      radius,
      Paint()
        ..color = AppColors.ink.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    )
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

  final image = await recorder.endRecording().toImage((_size * _scale).round(), (_size * _scale).round());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return BitmapDescriptor.bytes(png!.buffer.asUint8List(), width: _size, height: _size);
}
