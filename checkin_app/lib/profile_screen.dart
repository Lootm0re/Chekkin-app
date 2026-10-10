import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';

import 'app_only.dart';
import 'avatar_editor_screen.dart';
import 'business_screen.dart';
import 'dev_app_check_screen.dart';
import 'friends_screen.dart';
import 'leaderboard_screen.dart';
import 'profile_picture.dart';
import 'theme.dart';
import 'user_avatar.dart';

/// The user's profile: picture, name, points and rank, stats, a leaderboard
/// preview, and links to friends, the business screen and logging out.
class ProfileScreen extends StatelessWidget {
  /// Switches to the Ranks tab, for "See all".
  final VoidCallback? onOpenRanks;

  const ProfileScreen({super.key, this.onOpenRanks});

  /// How many leaderboard rows the preview shows (plus the user's own row if
  /// they're further down).
  static const int previewRows = 5;

  Future<void> _uploadPhoto(BuildContext context) async {
    try {
      await ProfilePictureUploader().pickAndUploadPhoto();
    } catch (e) {
      debugPrint('Uploading photo failed: $e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Couldn\'t upload your photo. Please try again.')));
    }
  }

  Future<void> _updateProfile(BuildContext context, Map<String, Object> fields) async {
    try {
      String uid = FirebaseAuth.instance.currentUser!.uid;
      await FirebaseFirestore.instance.collection('users').doc(uid).update(fields);
    } catch (e) {
      debugPrint('Updating profile failed: $e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Couldn\'t save that change. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    String uid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          var data = snapshot.data!.data() as Map<String, dynamic>;
          bool hasAvatar = data['avatar'] is Map;
          String? photoUrl = data['profilePictureUrl'];
          bool hasPhoto = photoUrl != null && photoUrl.isNotEmpty;
          bool hidden = data['avatarHidden'] == true;

          // One leaderboard stream for the rank chip and the preview.
          return StreamBuilder<QuerySnapshot>(
            stream: leaderboardStream(),
            builder: (context, leaderboard) {
              var rows = leaderboard.data?.docs ?? [];
              int myIndex = rows.indexWhere((d) => d.id == uid);
              String? rank = leaderboard.hasData ? (myIndex >= 0 ? '#${myIndex + 1}' : '100+') : null;

              // A ListView so the profile scrolls on small screens.
              return ListView(
                padding: EdgeInsets.zero,
                children: [
                  _Header(data: data, rank: rank),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _StatTiles(uid: uid, points: data['points'] ?? 0),
                        const SizedBox(height: 16),
                        _pictureCard(context, data, hasAvatar: hasAvatar, hasPhoto: hasPhoto, hidden: hidden),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(child: Text('Leaderboard', style: AppText.heading(size: 22))),
                            if (onOpenRanks != null) TextButton(onPressed: onOpenRanks, child: const Text('See all')),
                          ],
                        ),
                        const SizedBox(height: 4),
                        if (!leaderboard.hasData)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else ...[
                          for (int i = 0; i < rows.length && i < previewRows; i++)
                            LeaderboardRow(
                              rank: i + 1,
                              data: rows[i].data() as Map<String, dynamic>,
                              isCurrentUser: rows[i].id == uid,
                            ),
                          if (myIndex >= previewRows)
                            LeaderboardRow(
                              rank: myIndex + 1,
                              data: rows[myIndex].data() as Map<String, dynamic>,
                              isCurrentUser: true,
                            ),
                        ],
                        const SizedBox(height: 24),
                        _LinkCard(
                          icon: Icons.people_rounded,
                          color: AppColors.mint,
                          label: 'Friends',
                          onTap: () =>
                              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FriendsScreen())),
                        ),
                        _LinkCard(
                          icon: Icons.storefront_rounded,
                          color: AppColors.yellow,
                          label: 'My Business',
                          onTap: () =>
                              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BusinessScreen())),
                        ),
                        if (devTools && !kIsWeb && defaultTargetPlatform == TargetPlatform.android)
                          _LinkCard(
                            icon: Icons.verified_user_rounded,
                            color: AppColors.lightPurple,
                            label: 'DEV: App Check code',
                            onTap: () =>
                                Navigator.of(context)
                                    .push(MaterialPageRoute(builder: (_) => const DevAppCheckScreen())),
                          ),
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.logout_rounded),
                          onPressed: () => FirebaseAuth.instance.signOut(),
                          label: const Text('Log Out'),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  /// Avatar and photo buttons, which picture to show, and whether others see it.
  Widget _pictureCard(
    BuildContext context,
    Map<String, dynamic> data, {
    required bool hasAvatar,
    required bool hasPhoto,
    required bool hidden,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Your picture', style: AppText.heading(size: 18)),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.face_rounded),
                  label: Text(hasAvatar ? 'Edit avatar' : 'Create avatar'),
                  onPressed: () =>
                      Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => AvatarEditorScreen(currentAvatar: data['avatar']))),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.photo_rounded),
                  label: Text(hasPhoto ? 'Change photo' : 'Upload photo'),
                  onPressed: () => _uploadPhoto(context),
                ),
              ],
            ),
            if (hasAvatar && hasPhoto) ...[
              const SizedBox(height: 12),
              Center(
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'avatar', label: Text('Show avatar'), icon: Icon(Icons.face_rounded)),
                    ButtonSegment(value: 'photo', label: Text('Show photo'), icon: Icon(Icons.photo_rounded)),
                  ],
                  // Same rule as UserAvatar: the photo, unless the avatar was chosen.
                  selected: {data['profileImage'] == 'avatar' ? 'avatar' : 'photo'},
                  onSelectionChanged: (choice) => _updateProfile(context, {'profileImage': choice.first}),
                ),
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show my picture to other users'),
              subtitle: Text(hidden ? 'Others see a default icon.' : 'Shown on the leaderboard.'),
              value: !hidden,
              onChanged: (show) => _updateProfile(context, {'avatarHidden': !show}),
            ),
          ],
        ),
      ),
    );
  }
}

/// Blue header with decorative circles: picture, name, username, and chips
/// for points ever earned and leaderboard rank.
class _Header extends StatelessWidget {
  final Map<String, dynamic> data;
  final String? rank;

  const _Header({required this.data, required this.rank});

  @override
  Widget build(BuildContext context) {
    double top = MediaQuery.of(context).padding.top;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(40)),
      child: Container(
        color: AppColors.sky,
        child: Stack(
          children: [
            const Positioned(right: -50, top: -40, child: DecorCircle(size: 180, color: AppColors.yellow)),
            Positioned(
              left: -40,
              bottom: -60,
              child: DecorCircle(size: 150, color: Colors.white.withValues(alpha: 0.22)),
            ),
            const Positioned(left: 40, top: 90, child: DecorCircle(size: 26, color: AppColors.coral)),
            Padding(
              padding: EdgeInsets.fromLTRB(20, top + 16, 20, 28),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Profile', style: AppText.heading(size: 26)),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: AppShapes.softShadow,
                    ),
                    child: UserAvatar(data: data, radius: 52),
                  ),
                  const SizedBox(height: 12),
                  Text(data['name'] ?? '', style: AppText.heading(size: 26), textAlign: TextAlign.center),
                  Text('@${data['username']}', style: AppText.body(size: 16, weight: FontWeight.w700)),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      ColorChip(
                        label: '${data['lifetimePoints'] ?? data['points']} pts earned',
                        color: AppColors.yellow,
                        icon: Icons.star_rounded,
                      ),
                      if (rank != null)
                        ColorChip(label: 'Rank $rank', color: AppColors.card, icon: Icons.emoji_events_rounded),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Points to spend, vouchers and friends.
class _StatTiles extends StatelessWidget {
  final String uid;
  final num points;

  const _StatTiles({required this.uid, required this.points});

  @override
  Widget build(BuildContext context) {
    // Same height for all three, even when a label wraps.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _StatTile(
              icon: Icons.star_rounded,
              color: AppColors.yellow,
              value: '$points',
              label: 'Points to spend',
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('vouchers').where('userId', isEqualTo: uid).snapshots(),
              builder: (context, snapshot) => _StatTile(
                icon: Icons.confirmation_number_rounded,
                color: AppColors.coral,
                value: snapshot.hasData ? '${snapshot.data!.size}' : '–',
                label: 'Vouchers',
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: StreamBuilder<List<String>>(
              stream: friendUidsStream(),
              builder: (context, snapshot) => _StatTile(
                icon: Icons.people_rounded,
                color: AppColors.mint,
                value: snapshot.hasData ? '${snapshot.data!.length}' : '–',
                label: 'Friends',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String value;
  final String label;

  const _StatTile({required this.icon, required this.color, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(24),
        boxShadow: AppShapes.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconSquare(color: color, icon: icon, size: 40),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value, style: AppText.heading(size: 24)),
          ),
          Text(label, style: AppText.body(size: 14, color: AppColors.muted), maxLines: 2),
        ],
      ),
    );
  }
}

/// A white card with an icon square, a label and a chevron.
class _LinkCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _LinkCard({required this.icon, required this.color, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 6, 16, 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppShapes.cardRadius)),
        leading: IconSquare(color: color, icon: icon, size: 44),
        title: Text(label, style: AppText.heading(size: 18)),
        trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.purple),
        onTap: onTap,
      ),
    );
  }
}
