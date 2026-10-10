import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'emulators.dart';
import 'user_avatar.dart';

/// The signed-in user's friends, as user ids. Names and pictures come from
/// publicProfiles (see [PublicProfileBuilder]).
Stream<List<String>> friendUidsStream() {
  String uid = FirebaseAuth.instance.currentUser!.uid;
  return FirebaseFirestore.instance
      .collection('users')
      .doc(uid)
      .collection('friends')
      .snapshots()
      .map((snapshot) => snapshot.docs.map((d) => d.id).toList());
}

/// Builds with another user's public profile (name, username, picture).
class PublicProfileBuilder extends StatelessWidget {
  final String uid;
  final Widget Function(BuildContext context, Map<String, dynamic>? profile) builder;

  const PublicProfileBuilder({super.key, required this.uid, required this.builder});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('publicProfiles').doc(uid).snapshots(),
      builder: (context, snapshot) => builder(context, snapshot.data?.data() as Map<String, dynamic>?),
    );
  }
}

/// Add friends by username, answer friend requests, and see your friends.
/// Friends can be invited to group check-ins.
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  final TextEditingController usernameController = TextEditingController();
  final FirebaseFunctions functions = cloudFunctions;
  final String uid = FirebaseAuth.instance.currentUser!.uid;
  bool isSending = false;

  @override
  void dispose() {
    usernameController.dispose();
    super.dispose();
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _sendRequest() async {
    String username = usernameController.text.trim().replaceFirst('@', '');
    if (username.isEmpty || isSending) return;
    setState(() => isSending = true);
    try {
      final response = await functions.httpsCallable('sendFriendRequest').call({'username': username});
      usernameController.clear();
      _showSnackBar(response.data['status'] == 'friends'
          ? 'You\'re now friends with @$username.'
          : 'Friend request sent to @$username.');
    } on FirebaseFunctionsException catch (e) {
      _showSnackBar(e.message ?? 'Couldn\'t send that friend request.');
    } catch (e) {
      debugPrint('Sending friend request failed: $e');
      _showSnackBar('Couldn\'t send that friend request. Please check your connection.');
    } finally {
      if (mounted) setState(() => isSending = false);
    }
  }

  Future<void> _accept(String fromUid, String username) async {
    try {
      await functions.httpsCallable('acceptFriendRequest').call({'fromUid': fromUid});
      _showSnackBar('You\'re now friends with @$username.');
    } on FirebaseFunctionsException catch (e) {
      _showSnackBar(e.message ?? 'Couldn\'t accept that request.');
    } catch (e) {
      debugPrint('Accepting friend request failed: $e');
      _showSnackBar('Couldn\'t accept that request. Please check your connection.');
    }
  }

  // Declining and cancelling just delete the request.
  Future<void> _deleteRequest(DocumentReference request) async {
    try {
      await request.delete();
    } catch (e) {
      debugPrint('Deleting friend request failed: $e');
      _showSnackBar('Couldn\'t do that. Please try again.');
    }
  }

  Future<void> _remove(String friendUid, String username) async {
    bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove @$username?'),
        content: const Text('You won\'t be able to invite each other to group check-ins.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await functions.httpsCallable('removeFriend').call({'friendUid': friendUid});
    } on FirebaseFunctionsException catch (e) {
      _showSnackBar(e.message ?? 'Couldn\'t remove that friend.');
    } catch (e) {
      debugPrint('Removing friend failed: $e');
      _showSnackBar('Couldn\'t remove that friend. Please check your connection.');
    }
  }

  @override
  Widget build(BuildContext context) {
    CollectionReference requests = FirebaseFirestore.instance.collection('friendRequests');

    return Scaffold(
      appBar: AppBar(title: const Text('Friends')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: usernameController,
                  decoration: const InputDecoration(
                    labelText: 'Add a friend by username',
                    prefixText: '@',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _sendRequest(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: isSending ? null : _sendRequest,
                child: isSending
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Add'),
              ),
            ],
          ),
          StreamBuilder<QuerySnapshot>(
            stream: requests.where('to', isEqualTo: uid).snapshots(),
            builder: (context, snapshot) {
              var docs = snapshot.data?.docs ?? [];
              if (docs.isEmpty) return const SizedBox.shrink();
              return _Section(
                title: 'Friend requests',
                children: [
                  for (var doc in docs)
                    PublicProfileBuilder(
                      uid: doc['from'],
                      builder: (context, profile) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: UserAvatar(data: profile, radius: 20),
                        title: Text(doc['fromName'] ?? ''),
                        subtitle: Text('@${doc['fromUsername']}'),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            IconButton(
                              tooltip: 'Decline',
                              icon: const Icon(Icons.close),
                              onPressed: () => _deleteRequest(doc.reference),
                            ),
                            IconButton.filled(
                              tooltip: 'Accept',
                              icon: const Icon(Icons.check),
                              onPressed: () => _accept(doc['from'], doc['fromUsername']),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          StreamBuilder<QuerySnapshot>(
            stream: requests.where('from', isEqualTo: uid).snapshots(),
            builder: (context, snapshot) {
              var docs = snapshot.data?.docs ?? [];
              if (docs.isEmpty) return const SizedBox.shrink();
              return _Section(
                title: 'Sent requests',
                children: [
                  for (var doc in docs)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.schedule),
                      title: Text('@${doc['toUsername']}'),
                      subtitle: const Text('Waiting for them to accept'),
                      trailing: TextButton(
                        onPressed: () => _deleteRequest(doc.reference),
                        child: const Text('Cancel'),
                      ),
                    ),
                ],
              );
            },
          ),
          StreamBuilder<List<String>>(
            stream: friendUidsStream(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                debugPrint('Loading friends failed: ${snapshot.error}');
                return const _Section(title: 'Your friends', children: [Text('Couldn\'t load your friends.')]);
              }
              var friendUids = snapshot.data;
              return _Section(
                title: 'Your friends',
                children: [
                  if (friendUids == null)
                    const Center(child: CircularProgressIndicator())
                  else if (friendUids.isEmpty)
                    const Text('No friends yet. Add someone by their username to check in together.')
                  else
                    for (var friendUid in friendUids)
                      PublicProfileBuilder(
                        uid: friendUid,
                        builder: (context, profile) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: UserAvatar(data: profile, radius: 20),
                          title: Text(profile?['name'] ?? ''),
                          subtitle: Text('@${profile?['username'] ?? ''}'),
                          trailing: IconButton(
                            tooltip: 'Remove friend',
                            icon: const Icon(Icons.person_remove_outlined),
                            onPressed: () => _remove(friendUid, profile?['username'] ?? ''),
                          ),
                        ),
                      ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}
