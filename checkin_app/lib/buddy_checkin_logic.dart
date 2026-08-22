import 'package:cloud_firestore/cloud_firestore.dart';

class BuddyCheckInService {
  final FirebaseFirestore db = FirebaseFirestore.instance;

  static const int buddyWindowMinutes = 5;
  static const int buddyBonusPoints = 50;

  Future<String?> findUserIdByUsername(String username) async {
    QuerySnapshot result = await db
        .collection('users')
        .where('username', isEqualTo: username.trim().toLowerCase())
        .limit(1)
        .get();

    if (result.docs.isEmpty) return null;
    return result.docs.first.id;
  }

  Future<bool> attemptBuddyCheckIn({
    required String locationId,
    required String currentUserId,
    required String friendUsername,
  }) async {
    String? friendUserId = await findUserIdByUsername(friendUsername);

    if (friendUserId == null) {
      throw Exception('No user found with that username.');
    }
    if (friendUserId == currentUserId) {
      throw Exception('You can\'t buddy check-in with yourself.');
    }

    DateTime now = DateTime.now();
    DateTime cutoff = now.subtract(const Duration(minutes: buddyWindowMinutes));

    QuerySnapshot matchingAttempts = await db
        .collection('buddyCheckins')
        .where('locationId', isEqualTo: locationId)
        .where('initiatorId', isEqualTo: friendUserId)
        .where('selectedUserId', isEqualTo: currentUserId)
        .where('status', isEqualTo: 'pending')
        .where('createdAt', isGreaterThan: Timestamp.fromDate(cutoff))
        .limit(1)
        .get();

    if (matchingAttempts.docs.isNotEmpty) {
      String matchDocId = matchingAttempts.docs.first.id;

      await db.collection('buddyCheckins').doc(matchDocId).update({'status': 'confirmed'});

      await db.collection('buddyCheckins').add({
        'locationId': locationId,
        'initiatorId': currentUserId,
        'selectedUserId': friendUserId,
        'status': 'confirmed',
        'createdAt': FieldValue.serverTimestamp(),
      });

      await _awardBonus(currentUserId);
      await _awardBonus(friendUserId);

      return true;
    }

    await db.collection('buddyCheckins').add({
      'locationId': locationId,
      'initiatorId': currentUserId,
      'selectedUserId': friendUserId,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });

    return false;
  }

  Future<void> _awardBonus(String userId) async {
    await db.collection('users').doc(userId).update({
      'points': FieldValue.increment(buddyBonusPoints),
    });
  }
}