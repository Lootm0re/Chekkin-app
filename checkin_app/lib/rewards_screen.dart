import 'package:flutter/material.dart';

class Reward {
  final String name;
  final int pointsRequired;
  final String description;

  Reward({
    required this.name,
    required this.pointsRequired,
    required this.description,
  });
}

final List<Reward> availableRewards = [
  Reward(name: 'Coffee Voucher', pointsRequired: 5000, description: 'Free coffee at a partner cafe'),
  Reward(name: 'Museum Pass', pointsRequired: 25000, description: 'Free entry to a partner museum'),
  Reward(name: 'Restaurant Discount', pointsRequired: 100000, description: '50% off at a partner restaurant'),
  Reward(name: 'Weekend Getaway', pointsRequired: 500000, description: 'A free weekend stay'),
  Reward(name: 'Free Flight Ticket', pointsRequired: 1000000, description: 'A free ticket to anywhere on our partner airline'),
];

class RewardsScreen extends StatelessWidget {
  final int userPoints;

  const RewardsScreen({super.key, required this.userPoints});

  Reward? _getNextReward() {
    for (Reward reward in availableRewards) {
      if (userPoints < reward.pointsRequired) {
        return reward;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    Reward? nextReward = _getNextReward();

    return Scaffold(
      appBar: AppBar(title: const Text('Your Points')),
      body: ListView(
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

          ...availableRewards.map((reward) {
            bool unlocked = userPoints >= reward.pointsRequired;

            return Card(
              child: ListTile(
                leading: Icon(
                  unlocked ? Icons.check_circle : Icons.lock_outline,
                  color: unlocked ? Colors.green : Colors.grey,
                ),
                title: Text(reward.name),
                subtitle: Text('${reward.description}\n${reward.pointsRequired} points'),
                isThreeLine: true,
                trailing: unlocked
                    ? ElevatedButton(
                        onPressed: () => _redeemReward(context, reward),
                        child: const Text('Redeem'),
                      )
                    : null,
              ),
            );
          }),
        ],
      ),
    );
  }

  void _redeemReward(BuildContext context, Reward reward) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Redeem ${reward.name}?'),
        content: Text('This will use ${reward.pointsRequired} of your points.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('${reward.name} redeemed!')),
              );
            },
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }
}