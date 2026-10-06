import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Hue for a grey pin, for businesses that aren't partners yet.
const double greyPinHue = -1;

/// Map pins in the given hues (0-360, as for
/// [BitmapDescriptor.defaultMarkerWithHue], or [greyPinHue]).
///
/// google_maps_flutter_web ignores the hue and shows every default pin in
/// red, so on web the pins are drawn here instead, in the same colour as the
/// legend. Other platforms use the built-in pin, except for grey, which it
/// has no hue for.
Future<Map<double, BitmapDescriptor>> loadPinIcons(Iterable<double> hues) async {
  final distinct = hues.toSet().toList();
  final icons = await Future.wait(distinct.map(
    (hue) => kIsWeb || hue == greyPinHue
        ? _drawPin(hue)
        : Future.value(BitmapDescriptor.defaultMarkerWithHue(hue)),
  ));
  return Map.fromIterables(distinct, icons);
}

// Logical size of the pin, about that of Google's default one. Drawn at
// _scale times that for sharp edges on high-density screens.
const double _width = 27;
const double _height = 43;
const double _scale = 3;

/// Same as PlaceCategory.color, so pins match the legend.
Color pinColor(double hue) => _pinHsv(hue).toColor();

HSVColor _pinHsv(double hue) =>
    hue == greyPinHue ? const HSVColor.fromAHSV(1, 0, 0, 0.62) : HSVColor.fromAHSV(1, hue, 0.85, 0.9);

Future<BitmapDescriptor> _drawPin(double hue) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(_scale);

  // A circular head with straight sides tapering to the tip at the bottom
  // centre, which is where Marker anchors the icon.
  const double stroke = 1;
  const double radius = _width / 2 - stroke;
  const center = Offset(_width / 2, radius + stroke);
  const tip = Offset(_width / 2, _height - stroke);
  // Where the sides meet the head: lines from the tip that touch the circle.
  final double touch = math.acos(radius / (tip.dy - center.dy));
  final path = Path()
    ..moveTo(tip.dx, tip.dy)
    ..arcTo(Rect.fromCircle(center: center, radius: radius), math.pi / 2 + touch, 2 * math.pi - 2 * touch, false)
    ..close();

  final hsv = _pinHsv(hue);
  final dark = hsv.withValue(hsv.value * 0.55).toColor();
  canvas
    ..drawPath(path, Paint()..color = hsv.toColor())
    ..drawPath(
      path,
      Paint()
        ..color = dark
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    )
    ..drawCircle(center, radius * 0.38, Paint()..color = dark);

  final image = await recorder.endRecording().toImage((_width * _scale).round(), (_height * _scale).round());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return BitmapDescriptor.bytes(png!.buffer.asUint8List(), width: _width, height: _height);
}
