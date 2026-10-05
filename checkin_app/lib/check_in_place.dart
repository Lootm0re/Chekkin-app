import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// The kinds of place on the map. Restaurants, cafés and hotels need a code
/// from staff once the business has registered; touristic places only need
/// you to be there. The server decides each place's category.
enum PlaceCategory {
  restaurant('Restaurant', BitmapDescriptor.hueRed),
  cafe('Café', BitmapDescriptor.hueOrange),
  hotel('Hotel', BitmapDescriptor.hueViolet),
  touristic('Touristic', BitmapDescriptor.hueGreen);

  const PlaceCategory(this.label, this.markerHue);

  final String label;
  final double markerHue;

  bool get isBusiness => this != touristic;

  /// The marker colour, for legends and labels.
  Color get color => HSVColor.fromAHSV(1, markerHue, 0.85, 0.9).toColor();

  static PlaceCategory fromName(String? name) =>
      values.firstWhere((c) => c.name == name, orElse: () => touristic);
}

/// A check-in eligible place, as returned by the nearbyPlaces function.
class CheckInPlace {
  final String id;
  final String name;
  final LatLng position;
  final PlaceCategory category;

  /// The business has registered, so checking in needs its current code.
  final bool requiresCode;

  const CheckInPlace({
    required this.id,
    required this.name,
    required this.position,
    required this.category,
    required this.requiresCode,
  });

  factory CheckInPlace.fromMap(Map data) {
    return CheckInPlace(
      id: data['id'],
      name: data['name'],
      position: LatLng((data['latitude'] as num).toDouble(), (data['longitude'] as num).toDouble()),
      category: PlaceCategory.fromName(data['category']),
      requiresCode: data['requiresCode'] == true,
    );
  }
}

/// A key to the marker colours.
class PlaceCategoryLegend extends StatelessWidget {
  const PlaceCategoryLegend({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        children: [
          for (final category in PlaceCategory.values)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.location_on, size: 16, color: category.color),
                const SizedBox(width: 2),
                Text(category.label, style: const TextStyle(fontSize: 12, color: Colors.black87)),
              ],
            ),
        ],
      ),
    );
  }
}
