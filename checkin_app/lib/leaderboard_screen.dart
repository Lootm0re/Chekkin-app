import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'profile_picture.dart';

class LeaderboardScreen extends StatelessWidget {
  const LeaderboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    String currentUserId = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      appBar: AppBar(title: const Text('Leaderboard')),
      body: StreamBuilder<QuerySnapshot>(
        // Other users' private details live in users/{uid}; publicProfiles
        // only holds what's shown here.
        stream: FirebaseFirestore.instance
            .collection('publicProfiles')
            .orderBy('points', descending: true)
            .limit(100)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          var docs = snapshot.data!.docs;

          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (context, index) {
              var data = docs[index].data() as Map<String, dynamic>;
              bool isCurrentUser = docs[index].id == currentUserId;
              int rank = index + 1;

              return Container(
                color: isCurrentUser ? Colors.blue.withOpacity(0.1) : null,
                child: ListTile(
                  leading: SizedBox(
                    width: 60,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '#$rank',
                          style: TextStyle(
                            fontWeight: rank <= 3 ? FontWeight.bold : FontWeight.normal,
                            color: rank == 1
                                ? Colors.amber[700]
                                : rank == 2
                                    ? Colors.grey[600]
                                    : rank == 3
                                        ? Colors.brown[400]
                                        : null,
                          ),
                        ),
                        ProfileAvatar(photoUrl: data['profilePictureUrl'], radius: 18),
                      ],
                    ),
                  ),
                  title: Text(
                    data['name'] ?? 'Unknown',
                    style: TextStyle(fontWeight: isCurrentUser ? FontWeight.bold : FontWeight.normal),
                  ),
                  subtitle: Text('@${data['username'] ?? ''}'),
                  trailing: Text(
                    '${data['points'] ?? 0} pts',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}