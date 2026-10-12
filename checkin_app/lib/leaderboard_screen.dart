import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'backend.dart';
import 'theme.dart';
import 'user_avatar.dart';

/// The top 100 by points ever earned, so spending points on rewards doesn't
/// cost a place. Other users' private details live in users/{uid};
/// publicProfiles only holds what's shown here.
Stream<QuerySnapshot> leaderboardStream() => firestore
    .collection('publicProfiles')
    .orderBy('lifetimePoints', descending: true)
    .limit(100)
    .snapshots();

class LeaderboardScreen extends StatelessWidget {
  const LeaderboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    String currentUserId = firebaseAuth.currentUser!.uid;

    return Scaffold(
      appBar: AppBar(title: const Text('Leaderboard')),
      body: StreamBuilder<QuerySnapshot>(
        stream: leaderboardStream(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            debugPrint('Leaderboard failed: ${snapshot.error}');
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Couldn\'t load the leaderboard. Please try again later.',
                  textAlign: TextAlign.center,
                  style: AppText.body(size: 16),
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          var docs = snapshot.data!.docs;

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            itemCount: docs.length,
            itemBuilder: (context, index) => LeaderboardRow(
              rank: index + 1,
              data: docs[index].data() as Map<String, dynamic>,
              isCurrentUser: docs[index].id == currentUserId,
            ),
          );
        },
      ),
    );
  }
}

/// One leaderboard entry: a rank circle, picture, name, username and points.
/// The current user's row has a purple border.
class LeaderboardRow extends StatelessWidget {
  final int rank;
  final Map<String, dynamic> data;
  final bool isCurrentUser;

  const LeaderboardRow({super.key, required this.rank, required this.data, required this.isCurrentUser});

  /// Gold, silver and bronze in the app's colours, then light purple.
  static Color rankColor(int rank) => switch (rank) {
    1 => AppColors.yellow,
    2 => AppColors.sky,
    3 => AppColors.coral,
    _ => AppColors.lightPurple,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
        border: Border.all(color: isCurrentUser ? AppColors.purple : Colors.transparent, width: 2.5),
        boxShadow: AppShapes.softShadow,
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: rankColor(rank), shape: BoxShape.circle),
            child: Text('$rank', style: AppText.heading(size: rank < 100 ? 18 : 15)),
          ),
          const SizedBox(width: 12),
          UserAvatar(data: data, radius: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data['name'] ?? 'Unknown',
                  style: AppText.body(size: 16, weight: FontWeight.w800),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '@${data['username'] ?? ''}',
                  style: AppText.body(size: 14, color: AppColors.muted),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(formatNumber(data['lifetimePoints']), style: AppText.heading(size: 18)),
          const SizedBox(width: 4),
          Text('pts', style: AppText.body(size: 14, color: AppColors.muted)),
        ],
      ),
    );
  }
}
