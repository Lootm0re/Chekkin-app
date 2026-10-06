import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'pin_icons.dart';

/// The kinds of place on the map. Restaurants, cafés, hotels and shops can
/// only be checked in to once they're partners, with a code from staff;
/// touristic places only need you to be there. The server decides each
/// place's category.
enum PlaceCategory {
  restaurant('Restaurant', BitmapDescriptor.hueRed),
  cafe('Café', BitmapDescriptor.hueOrange),
  hotel('Hotel', BitmapDescriptor.hueViolet),
  shop('Shop', BitmapDescriptor.hueYellow),
  touristic('Touristic', BitmapDescriptor.hueGreen);

  const PlaceCategory(this.label, this.markerHue);

  final String label;
  final double markerHue;

  bool get isBusiness => this != touristic;

  /// The marker colour, for legends and labels.
  Color get color => pinColor(markerHue);

  static PlaceCategory fromName(String? name) =>
      values.firstWhere((c) => c.name == name, orElse: () => touristic);
}

/// Partner tiers, as in TIERS in functions/index.js.
const Map<String, String> tierLabels = {'basic': 'Basic', 'premium': 'Premium', 'diamond': 'Diamond'};

/// A check-in eligible place, as returned by the nearbyPlaces function.
class CheckInPlace {
  final String id;
  final String name;
  final LatLng position;
  final PlaceCategory category;

  /// A business with a partner tier: checking in needs its current code.
  /// Other businesses can't be checked in to.
  final bool partner;

  /// 'basic', 'premium' or 'diamond' for partners.
  final String? tier;

  /// Base points for a check-in now, before group multipliers.
  final int points;

  /// The partner's monthly budget is used up, so [points] is the touristic rate.
  final bool budgetUsedUp;

  const CheckInPlace({
    required this.id,
    required this.name,
    required this.position,
    required this.category,
    required this.partner,
    this.tier,
    required this.points,
    this.budgetUsedUp = false,
  });

  factory CheckInPlace.fromMap(Map data) {
    return CheckInPlace(
      id: data['id'],
      name: data['name'],
      position: LatLng((data['latitude'] as num).toDouble(), (data['longitude'] as num).toDouble()),
      category: PlaceCategory.fromName(data['category']),
      partner: data['partner'] == true,
      tier: data['tier'],
      points: (data['points'] as num?)?.toInt() ?? 0,
      budgetUsedUp: data['budgetUsedUp'] == true,
    );
  }

  bool get requiresCode => partner;

  /// A business that isn't a partner yet: shown grey, no check-ins.
  bool get closed => category.isBusiness && !partner;

  double get pinHue => closed ? greyPinHue : category.markerHue;

  /// E.g. 'Premium partner · 50 points', for the map.
  String get summary {
    if (closed) return '${category.label} · Not a partner yet';
    if (!partner) return '${category.label} · $points points';
    String tierName = '${tierLabels[tier] ?? 'Partner'} partner';
    return budgetUsedUp ? '$tierName · $points points (monthly bonus used up)' : '$tierName · $points points';
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
          for (final category in PlaceCategory.values) _entry(category.color, category.label),
          _entry(pinColor(greyPinHue), 'Not a partner yet'),
        ],
      ),
    );
  }

  Widget _entry(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.location_on, size: 16, color: color),
        const SizedBox(width: 2),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.black87)),
      ],
    );
  }
}
