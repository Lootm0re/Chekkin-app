import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'vouchers.dart';

class Reward {
  final String name;
  final int pointsRequired;
  final String description;

  /// Shown but not yet available, so it can't be redeemed.
  final bool comingSoon;

  /// rewards/{catalogId}, for rewards that can be redeemed.
  final String? catalogId;

  Reward({
    required this.name,
    required this.pointsRequired,
    required this.description,
    this.comingSoon = false,
    this.catalogId,
  });

  /// A partner discount from the catalog (functions/scripts/rewards-catalog.js).
  factory Reward.fromCatalog(DocumentSnapshot doc) {
    var data = doc.data() as Map<String, dynamic>;
    return Reward(
      name: data['name'] ?? 'Reward',
      pointsRequired: (data['pointsCost'] as num).toInt(),
      description: data['description'] ?? '${data['discountPercent']}% off at a partner place',
      catalogId: doc.id,
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
  Reward(name: 'Coffee Voucher', pointsRequired: 500, description: 'Free coffee at a partner cafe', comingSoon: true),
  Reward(name: 'Museum Pass', pointsRequired: 1500, description: 'Free entry to a partner museum', comingSoon: true),
  Reward(name: 'Weekend Getaway', pointsRequired: 20000, description: 'A free weekend stay', comingSoon: true),
  Reward(
    name: 'Free Flight Ticket',
    pointsRequired: 40000,
    description: 'A free ticket to anywhere on our partner airline',
    comingSoon: true,
  ),
];

class RewardsScreen extends StatelessWidget {
  final int userPoints;

  const RewardsScreen({super.key, required this.userPoints});

  Reward? _getNextReward(List<Reward> rewards) {
    for (Reward reward in rewards) {
      if (!reward.comingSoon && userPoints < reward.pointsRequired) {
        return reward;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your Points'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.confirmation_number_outlined),
            label: const Text('My vouchers'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MyVouchersScreen()),
            ),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('rewards')
            .where('active', isEqualTo: true)
            .where('type', isEqualTo: 'partner_discount')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) debugPrint('Loading rewards failed: ${snapshot.error}');
          List<Reward> rewards = [
            ...?snapshot.data?.docs.map(Reward.fromCatalog),
            ...comingSoonRewards,
          ]..sort((a, b) => a.pointsRequired.compareTo(b.pointsRequired));
          return _buildList(context, rewards, loading: !snapshot.hasData && !snapshot.hasError);
        },
      ),
    );
  }

  Widget _buildList(BuildContext context, List<Reward> rewards, {required bool loading}) {
    Reward? nextReward = _getNextReward(rewards);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: Column(
            children: [
              Text(
                '$userPoints',
                style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold),
              ),
              const Text('total points', style: TextStyle(fontSize: 16, color: Colors.grey)),
            ],
          ),
        ),

        const SizedBox(height: 16),

        if (nextReward != null) ...[
          Text('Next reward: ${nextReward.name}'),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: userPoints / nextReward.pointsRequired,
            minHeight: 10,
          ),
          const SizedBox(height: 4),
          Text('${nextReward.pointsRequired - userPoints} points to go'),
        ],

        const SizedBox(height: 24),
        const Text('All Rewards', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (loading) const LinearProgressIndicator(),

        ...rewards.map((reward) {
          bool unlocked = !reward.comingSoon && userPoints >= reward.pointsRequired;

          return Card(
            child: ListTile(
              leading: Icon(
                reward.comingSoon ? Icons.schedule : (unlocked ? Icons.check_circle : Icons.lock_outline),
                color: unlocked ? Colors.green : Colors.grey,
              ),
              title: Text(reward.name),
              subtitle: Text('${reward.description}\n${reward.pointsRequired} points'),
              isThreeLine: true,
              trailing: reward.comingSoon
                  ? const Chip(label: Text('Coming soon'), visualDensity: VisualDensity.compact)
                  : unlocked
                      ? ElevatedButton(
                          onPressed: redeemingOpen ? () => _redeemReward(context, reward) : null,
                          child: Text(redeemingOpen ? 'Redeem' : 'Coming soon'),
                        )
                      : null,
            ),
          );
        }),
      ],
    );
  }

  void _redeemReward(BuildContext context, Reward reward) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RedeemRewardScreen(reward: reward, userPoints: userPoints)),
    );
  }
}
