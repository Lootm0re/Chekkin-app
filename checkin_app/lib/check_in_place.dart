import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'pin_icons.dart';
import 'theme.dart';

/// The kinds of place on the map. Restaurants, cafés, hotels and shops can
/// only be checked in to once they're partners, with a code from staff;
/// touristic places only need you to be there. The server decides each
/// place's category.
enum PlaceCategory {
  restaurant('Restaurant', AppColors.coral, Icons.restaurant_rounded),
  cafe('Café', AppColors.mint, Icons.local_cafe_rounded),
  hotel('Hotel', AppColors.purple, Icons.hotel_rounded),
  shop('Shop', AppColors.yellow, Icons.shopping_bag_rounded),
  touristic('Touristic', AppColors.sky, Icons.attractions_rounded);

  const PlaceCategory(this.label, this.color, this.icon);

  final String label;

  /// The pin, legend and place page colour.
  final Color color;
  final IconData icon;

  bool get isBusiness => this != touristic;

  static PlaceCategory fromName(String? name) =>
      values.firstWhere((c) => c.name == name, orElse: () => touristic);
}

/// Partner tiers, as in TIERS in functions/index.js.
/// Partner tiers, lowest first. Keep in sync with TIERS in functions/index.js.
const Map<String, String> tierLabels = {
  'basic': 'Basic',
  'premium': 'Premium',
  'platinum': 'Platinum',
  'diamond': 'Diamond',
};

/// 1 for Basic up to 4 for Diamond; 0 for anything else.
int tierRank(String? tier) => tier == null ? 0 : tierLabels.keys.toList().indexOf(tier) + 1;

/// Tiers whose pins are highlighted on the map: Premium and up.
bool isHighlightedTier(String? tier) => tierRank(tier) >= tierRank('premium');

/// The plan chip for [tier]: a brighter colour and icon for higher tiers.
ColorChip tierChip(String tier, {String? label, bool compact = false}) => ColorChip(
      label: label ?? '${tierLabels[tier] ?? 'Partner'} plan',
      color: switch (tier) {
        'premium' => AppColors.yellow,
        'platinum' => AppColors.sky,
        'diamond' => AppColors.purple,
        _ => AppColors.lightPurple,
      },
      icon: switch (tier) {
        'platinum' => Icons.military_tech_rounded,
        'diamond' => Icons.diamond_rounded,
        _ => Icons.workspace_premium_rounded,
      },
      compact: compact,
    );

/// A check-in eligible place, as returned by the nearbyPlaces function.
class CheckInPlace {
  final String id;
  final String name;
  final LatLng position;
  final PlaceCategory category;

  /// A business with a partner tier: checking in needs its current code.
  /// Other businesses can't be checked in to.
  final bool partner;

  /// 'basic', 'premium', 'platinum' or 'diamond' for partners.
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

  /// Grey for businesses that aren't partners yet, else the category's
  /// colour; highlighted for Premium partners and up.
  PinStyle get pinStyle => PinStyle(
        closed ? AppColors.inactive : category.color,
        category.icon,
        highlighted: partner && isHighlightedTier(tier),
      );

  /// Drawing order on the map: higher tiers on top of lower ones.
  int get mapLayer => partner ? tierRank(tier) : 0;

  /// E.g. 'Premium partner · 50 points', for the map.
  String get summary {
    if (closed) return '${category.label} · Not a partner yet';
    if (!partner) return '${category.label} · $points points';
    String tierName = '${tierLabels[tier] ?? 'Partner'} partner';
    return budgetUsedUp ? '$tierName · $points points (monthly bonus used up)' : '$tierName · $points points';
  }
}

/// A key to the pin colours.
class PlaceCategoryLegend extends StatelessWidget {
  const PlaceCategoryLegend({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.card.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
        boxShadow: AppShapes.softShadow,
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        alignment: WrapAlignment.center,
        children: [
          for (final category in PlaceCategory.values) _entry(category.color, category.label),
          _entry(AppColors.inactive, 'Not a partner yet'),
        ],
      ),
    );
  }

  Widget _entry(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [BoxShadow(color: AppColors.ink.withValues(alpha: 0.2), blurRadius: 2)],
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: AppText.body(size: 14, weight: FontWeight.w700)),
      ],
    );
  }
}
