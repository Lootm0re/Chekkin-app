import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'backend.dart';
import 'check_in_place.dart';
import 'theme.dart';
import 'vouchers.dart';

class Reward {
  final String name;
  final int pointsRequired;
  final String description;

  /// Shown but not yet available, so it can't be redeemed.
  final bool comingSoon;

  /// rewards/{catalogId}, for rewards that can be redeemed.
  final String? catalogId;

  /// The card's icon square.
  final Color color;
  final IconData icon;

  Reward({
    required this.name,
    required this.pointsRequired,
    required this.description,
    this.comingSoon = false,
    this.catalogId,
    this.color = AppColors.purple,
    this.icon = Icons.card_giftcard_rounded,
  });

  /// A partner discount from the catalog (functions/scripts/rewards-catalog.js),
  /// in its place category's colour.
  factory Reward.fromCatalog(DocumentSnapshot doc) {
    var data = doc.data() as Map<String, dynamic>;
    PlaceCategory? category = data['category'] == null ? null : PlaceCategory.fromName(data['category']);
    return Reward(
      name: data['name'] ?? 'Reward',
      pointsRequired: (data['pointsCost'] as num).toInt(),
      description: data['description'] ?? '${data['discountPercent']}% off at a partner place',
      catalogId: doc.id,
      color: category?.color ?? AppColors.coral,
      icon: category?.icon ?? Icons.local_offer_rounded,
    );
  }
}

/// Partner discounts can be redeemed: the redeemReward function takes the
/// points and issues a voucher. Other rewards stay "Coming soon".
const bool redeemingOpen = true;

// Costs suit a heavy user earning about 300 points a day (the daily partner
// cap): a coffee every couple of days, a weekend away in about two months.
// The partner discounts (Restaurant Discount, 5000 points) come from the
// catalog in Firestore instead.
final List<Reward> comingSoonRewards = [
  Reward(
    name: 'Coffee Voucher',
    pointsRequired: 500,
    description: 'Free coffee at a partner cafe',
    comingSoon: true,
    color: AppColors.mint,
    icon: Icons.local_cafe_rounded,
  ),
  Reward(
    name: 'Museum Pass',
    pointsRequired: 1500,
    description: 'Free entry to a partner museum',
    comingSoon: true,
    color: AppColors.sky,
    icon: Icons.museum_rounded,
  ),
  Reward(
    name: 'Weekend Getaway',
    pointsRequired: 20000,
    description: 'A free weekend stay',
    comingSoon: true,
    color: AppColors.purple,
    icon: Icons.hotel_rounded,
  ),
  Reward(
    name: 'Free Flight Ticket',
    pointsRequired: 40000,
    description: 'A free ticket to anywhere on our partner airline',
    comingSoon: true,
    color: AppColors.yellow,
    icon: Icons.flight_rounded,
  ),
];

class RewardsScreen extends StatelessWidget {
  final int userPoints;

  const RewardsScreen({super.key, required this.userPoints});

  /// The cheapest reward the user can't afford yet, Coming soon ones
  /// included, for the progress bar.
  Reward? _getNextReward(List<Reward> rewards) {
    Reward? next;
    for (Reward reward in rewards) {
      if (userPoints < reward.pointsRequired && (next == null || reward.pointsRequired < next.pointsRequired)) {
        next = reward;
      }
    }
    return next;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your Points'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.confirmation_number_rounded),
            label: const Text('My vouchers'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MyVouchersScreen()),
            ),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: firestore
            .collection('rewards')
            .where('active', isEqualTo: true)
            .where('type', isEqualTo: 'partner_discount')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) debugPrint('Loading rewards failed: ${snapshot.error}');
          List<Reward> rewards = [
            ...?snapshot.data?.docs.map(Reward.fromCatalog),
            ...comingSoonRewards,
          ]..sort((a, b) {
              // Rewards that can be redeemed first, Coming soon ones after;
              // cheapest first within each.
              if (a.comingSoon != b.comingSoon) return a.comingSoon ? 1 : -1;
              return a.pointsRequired.compareTo(b.pointsRequired);
            });
          return _buildList(context, rewards, loading: !snapshot.hasData && !snapshot.hasError);
        },
      ),
    );
  }

  Widget _buildList(BuildContext context, List<Reward> rewards, {required bool loading}) {
    Reward? nextReward = _getNextReward(rewards);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        _PointsCard(points: userPoints, nextReward: nextReward),
        const SizedBox(height: 24),
        Text('All Rewards', style: AppText.heading(size: 22)),
        const SizedBox(height: 8),
        if (loading) const LinearProgressIndicator(),
        for (var reward in rewards)
          _RewardCard(
            reward: reward,
            unlocked: !reward.comingSoon && userPoints >= reward.pointsRequired,
            onRedeem: () => _redeemReward(context, reward),
          ),
      ],
    );
  }

  void _redeemReward(BuildContext context, Reward reward) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RedeemRewardScreen(reward: reward, userPoints: userPoints)),
    );
  }
}

/// Purple card with the points and progress to the next reward.
class _PointsCard extends StatelessWidget {
  final int points;
  final Reward? nextReward;

  const _PointsCard({required this.points, required this.nextReward});

  @override
  Widget build(BuildContext context) {
    Reward? next = nextReward;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppShapes.cardRadius),
      child: Container(
        color: AppColors.purple,
        child: Stack(
          children: [
            // Kept to the corners, clear of the text: the top one above the
            // points, the bottom one right of the progress numbers.
            const Positioned(right: -40, top: -60, child: DecorCircle(size: 140, color: AppColors.coral)),
            Positioned(right: -40, bottom: -60, child: DecorCircle(size: 110, color: Colors.white.withValues(alpha: 0.12))),
            Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Available points', style: AppText.body(size: 15, weight: FontWeight.w700, color: Colors.white70)),
                  Text(formatNumber(points), style: AppText.heading(size: 52, color: Colors.white)),
                  if (next != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      '${formatNumber(next.pointsRequired - points)} more points to ${next.name}',
                      style: AppText.body(size: 15, weight: FontWeight.w700, color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: points / next.pointsRequired,
                        minHeight: 14,
                        color: AppColors.yellow,
                        backgroundColor: Colors.white.withValues(alpha: 0.22),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${formatNumber(points)} / ${formatNumber(next.pointsRequired)}'
                      '${next.comingSoon ? ' · coming soon' : ''}',
                      style: AppText.body(size: 14, color: Colors.white70),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A reward: icon square, name, description, cost, and Redeem when it can
/// be redeemed, Coming soon for rewards that aren't available yet.
class _RewardCard extends StatelessWidget {
  final Reward reward;
  final bool unlocked;
  final VoidCallback onRedeem;

  const _RewardCard({required this.reward, required this.unlocked, required this.onRedeem});

  @override
  Widget build(BuildContext context) {
    Widget? action;
    if (reward.comingSoon) {
      action = const ColorChip(label: 'Coming soon', color: AppColors.lightPurple, icon: Icons.schedule_rounded);
    } else if (unlocked) {
      action = ElevatedButton(
        onPressed: redeemingOpen ? onRedeem : null,
        style: ElevatedButton.styleFrom(minimumSize: const Size(120, AppShapes.buttonHeight)),
        child: Text(redeemingOpen ? 'Redeem' : 'Coming soon'),
      );
    } else {
      action = const ColorChip(label: 'Locked', color: AppColors.lightPurple, icon: Icons.lock_rounded);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconSquare(color: reward.color, icon: reward.icon),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(reward.name, style: AppText.heading(size: 19)),
                      const SizedBox(height: 2),
                      Text(reward.description, style: AppText.body(size: 15, color: AppColors.muted)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ColorChip(label: '${formatNumber(reward.pointsRequired)} pts', color: AppColors.yellow, icon: Icons.star_rounded),
                const Spacer(),
                action,
              ],
            ),
          ],
        ),
      ),
    );
  }
}
