import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'friends_screen.dart';
import 'user_avatar.dart';

/// Group check-ins: at a partner business, the customer who uses the code
/// can invite friends, who join from their own phones within 10 minutes.

const int groupMaxSize = 6; // keep in sync with GROUP_MAX_SIZE

// Applied to each member's base points; keep in sync with GROUP_MULTIPLIERS.
const Map<int, double> groupMultipliers = {1: 1, 2: 1.5, 3: 2, 4: 3, 5: 3.5, 6: 5};

String formatMultiplier(num multiplier) =>
    '×${multiplier == multiplier.roundToDouble() ? multiplier.toInt() : multiplier}';

/// "m:ss" until [expiresAt], updated every second.
class CountdownText extends StatefulWidget {
  final DateTime expiresAt;
  final String prefix;
  final TextStyle? style;

  const CountdownText({super.key, required this.expiresAt, this.prefix = '', this.style});

  @override
  State<CountdownText> createState() => _CountdownTextState();
}

class _CountdownTextState extends State<CountdownText> {
  Timer? ticker;

  @override
  void initState() {
    super.initState();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Duration left = widget.expiresAt.difference(DateTime.now());
    if (left.isNegative) left = Duration.zero;
    return Text(
      '${widget.prefix}${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}',
      style: widget.style,
    );
  }
}

/// Lets the user tick up to [groupMaxSize] - 1 friends. Returns the chosen
/// friends' ids mapped to their usernames, or null if dismissed.
Future<Map<String, String>?> pickGroupFriends(BuildContext context, Map<String, String> selected) {
  return showModalBottomSheet<Map<String, String>>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _FriendPicker(initial: selected),
  );
}

class _FriendPicker extends StatefulWidget {
  final Map<String, String> initial;

  const _FriendPicker({required this.initial});

  @override
  State<_FriendPicker> createState() => _FriendPickerState();
}

class _FriendPickerState extends State<_FriendPicker> {
  late final Map<String, String> selected = Map.of(widget.initial);
  static const int maxFriends = groupMaxSize - 1;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Check in with friends'),
              subtitle: Text('Pick up to $maxFriends. They join from their own phones within 10 minutes.'),
            ),
            Flexible(
              child: StreamBuilder<List<String>>(
                stream: friendUidsStream(),
                builder: (context, snapshot) {
                  var friendUids = snapshot.data;
                  if (friendUids == null) return const Center(child: CircularProgressIndicator());
                  if (friendUids.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('You haven\'t added any friends yet.'),
                          TextButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const FriendsScreen()),
                            ),
                            child: const Text('Add friends'),
                          ),
                        ],
                      ),
                    );
                  }
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      for (var friendUid in friendUids)
                        PublicProfileBuilder(
                          uid: friendUid,
                          builder: (context, profile) {
                            String username = profile?['username'] ?? '';
                            bool isSelected = selected.containsKey(friendUid);
                            bool canAdd = isSelected || selected.length < maxFriends;
                            return CheckboxListTile(
                              value: isSelected,
                              onChanged: canAdd
                                  ? (on) => setState(() {
                                        if (on == true) {
                                          selected[friendUid] = username;
                                        } else {
                                          selected.remove(friendUid);
                                        }
                                      })
                                  : null,
                              secondary: UserAvatar(data: profile, radius: 18),
                              title: Text(profile?['name'] ?? ''),
                              subtitle: Text('@$username'),
                            );
                          },
                        ),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(selected),
                style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
                child: Text(selected.isEmpty
                    ? 'Check in alone'
                    : 'Done: group of ${selected.length + 1} '
                        '(up to ${formatMultiplier(groupMultipliers[selected.length + 1]!)} points)'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Invites to friends' group check-ins, with Join and Decline. Expired invites
/// are cleared.
class GroupInviteCards extends StatelessWidget {
  final Future<void> Function(String groupId) onJoin;

  const GroupInviteCards({super.key, required this.onJoin});

  @override
  Widget build(BuildContext context) {
    String uid = FirebaseAuth.instance.currentUser!.uid;
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).collection('groupInvites').snapshots(),
      builder: (context, snapshot) {
        var docs = snapshot.data?.docs ?? [];
        var live = <QueryDocumentSnapshot>[];
        for (var doc in docs) {
          DateTime expiresAt = (doc['expiresAt'] as Timestamp).toDate();
          if (expiresAt.isAfter(DateTime.now())) {
            live.add(doc);
          } else {
            doc.reference.delete().catchError((e) => debugPrint('Clearing expired invite failed: $e'));
          }
        }
        return Column(
          children: [for (var doc in live) _InviteCard(invite: doc, onJoin: onJoin)],
        );
      },
    );
  }
}

class _InviteCard extends StatefulWidget {
  final QueryDocumentSnapshot invite;
  final Future<void> Function(String groupId) onJoin;

  const _InviteCard({required this.invite, required this.onJoin});

  @override
  State<_InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends State<_InviteCard> {
  bool isJoining = false;

  Future<void> _join() async {
    setState(() => isJoining = true);
    try {
      await widget.onJoin(widget.invite.id);
    } finally {
      if (mounted) setState(() => isJoining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    var invite = widget.invite;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.groups, color: Colors.deepPurple),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '@${invite['fromUsername']} invited you to check in together at ${invite['placeName']}',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                CountdownText(
                  expiresAt: (invite['expiresAt'] as Timestamp).toDate(),
                  prefix: 'Closes in ',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
                const Spacer(),
                TextButton(
                  onPressed: isJoining ? null : () => invite.reference.delete(),
                  child: const Text('Decline'),
                ),
                FilledButton(
                  onPressed: isJoining ? null : _join,
                  child: isJoining
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Join'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Live progress of a group check-in the user started or joined.
class ActiveGroupCard extends StatelessWidget {
  final String groupId;
  final VoidCallback onDismiss;

  const ActiveGroupCard({super.key, required this.groupId, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    String uid = FirebaseAuth.instance.currentUser!.uid;
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('groups').doc(groupId).snapshots(),
      builder: (context, snapshot) {
        var group = snapshot.data?.data() as Map<String, dynamic>?;
        if (group == null) return const SizedBox.shrink();
        int size = group['size'] ?? 1;
        int invited = (group['invited'] as List?)?.length ?? 0;
        num myPoints = (group['awarded'] as Map?)?[uid] ?? 0;
        DateTime expiresAt = (group['expiresAt'] as Timestamp).toDate();
        bool closed = group['status'] != 'open' || expiresAt.isBefore(DateTime.now());

        return Card(
          margin: const EdgeInsets.only(top: 8),
          color: Colors.deepPurple[50],
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                const Icon(Icons.groups, color: Colors.deepPurple),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Group at ${group['placeName']}: $size of ${invited + 1} '
                        '· ${formatMultiplier(groupMultipliers[size]!)} · +$myPoints pts',
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      closed
                          ? Text('Group closed', style: TextStyle(color: Colors.grey[700], fontSize: 12))
                          : CountdownText(
                              expiresAt: expiresAt,
                              prefix: 'Friends can join for ',
                              style: TextStyle(color: Colors.grey[700], fontSize: 12),
                            ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Hide',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: onDismiss,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
