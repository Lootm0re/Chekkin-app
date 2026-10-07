import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'firebase_options.dart';
import 'app_only.dart';
import 'dev_app_check_screen.dart';
import 'auth_screen.dart';
import 'map_screen.dart';
import 'rewards_screen.dart';
import 'phone_verify_screen.dart';
import 'leaderboard_screen.dart';
import 'profile_picture.dart';
import 'business_screen.dart';
import 'friends_screen.dart';
import 'avatar_editor_screen.dart';
import 'user_avatar.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _activateAppCheck();
  runApp(const CheckInApp());
}

/// reCAPTCHA Enterprise key for App Check on web. Site keys are public; this
/// one only works on the app's own domains and localhost.
const String _recaptchaSiteKey = '6LePf-ItAAAAAAlz3lEzaUxuLdg9q5hJ4JFR7PQq';

/// Attaches App Check tokens to Firebase requests, so the server can tell
/// they come from this app. If it fails the app carries on without it; the
/// server then only lets dev testers check in. Android uses Play Integrity,
/// which only works for installs from Google Play, so DEV_TOOLS builds (sideloaded
/// test APKs) use the debug provider instead: see DevAppCheckScreen.
Future<void> _activateAppCheck() async {
  try {
    await FirebaseAppCheck.instance.activate(
      webProvider: ReCaptchaEnterpriseProvider(_recaptchaSiteKey),
      androidProvider: devTools ? AndroidProvider.debug : AndroidProvider.playIntegrity,
    );
  } catch (e) {
    debugPrint('App Check activation failed: $e');
  }
}

class CheckInApp extends StatelessWidget {
  const CheckInApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Check In',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  // Sign-up creates the auth account before writing the profile, so the auth
  // state flips mid-flow. A global key lets the same AuthScreen state (form
  // contents, loading, errors) move between branches instead of being reset.
  static final GlobalKey _authScreenKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnapshot) {
        if (authSnapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (!authSnapshot.hasData) {
          return AuthScreen(key: _authScreenKey);
        }

        String uid = authSnapshot.data!.uid;
        return StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
          builder: (context, userSnapshot) {
            if (!userSnapshot.hasData) {
              // Keep the auth screen up if it's already showing (sign-up in
              // progress); otherwise this is a normal app start.
              if (_authScreenKey.currentState != null) {
                return AuthScreen(key: _authScreenKey);
              }
              return const Scaffold(body: Center(child: CircularProgressIndicator()));
            }
            if (!userSnapshot.data!.exists) {
              // Signed in without a profile: sign-up is in progress, or an
              // earlier one failed halfway and still needs finishing.
              return AuthScreen(key: _authScreenKey);
            }

            var data = userSnapshot.data!.data() as Map<String, dynamic>;
            bool phoneVerified = data['phoneVerified'] ?? false;

            if (!phoneVerified) {
              return const PhoneVerifyScreen();
            }
            return const HomeScreen();
          },
        );
      },
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int currentTab = 0;
  int userPoints = 0;

  @override
  void initState() {
    super.initState();
    _listenToPoints();
  }

  void _listenToPoints() {
    String uid = FirebaseAuth.instance.currentUser!.uid;
    FirebaseFirestore.instance.collection('users').doc(uid).snapshots().listen((doc) {
      setState(() {
        userPoints = doc['points'] ?? 0;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> screens = [
      const MapScreen(),
      RewardsScreen(userPoints: userPoints),
      const LeaderboardScreen(),
      const ProfileScreen(),
    ];

    return Scaffold(
      body: screens[currentTab],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: currentTab,
        onTap: (index) => setState(() => currentTab = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Map'),
          BottomNavigationBarItem(icon: Icon(Icons.star), label: 'Rewards'),
          BottomNavigationBarItem(icon: Icon(Icons.leaderboard), label: 'Leaderboard'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  Future<void> _uploadPhoto(BuildContext context) async {
    try {
      await ProfilePictureUploader().pickAndUploadPhoto();
    } catch (e) {
      debugPrint('Uploading photo failed: $e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn\'t upload your photo. Please try again.')),
      );
    }
  }

  Future<void> _updateProfile(BuildContext context, Map<String, Object> fields) async {
    try {
      String uid = FirebaseAuth.instance.currentUser!.uid;
      await FirebaseFirestore.instance.collection('users').doc(uid).update(fields);
    } catch (e) {
      debugPrint('Updating profile failed: $e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn\'t save that change. Please try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    String uid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          var data = snapshot.data!.data() as Map<String, dynamic>;
          bool hasAvatar = data['avatar'] is Map;
          String? photoUrl = data['profilePictureUrl'];
          bool hasPhoto = photoUrl != null && photoUrl.isNotEmpty;
          bool hidden = data['avatarHidden'] == true;

          // A ListView so the profile scrolls on small screens.
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Center(child: UserAvatar(data: data, radius: 50)),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.face),
                    label: Text(hasAvatar ? 'Edit avatar' : 'Create avatar'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => AvatarEditorScreen(currentAvatar: data['avatar'])),
                    ),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.photo),
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
                      ButtonSegment(value: 'avatar', label: Text('Show avatar'), icon: Icon(Icons.face)),
                      ButtonSegment(value: 'photo', label: Text('Show photo'), icon: Icon(Icons.photo)),
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
              const SizedBox(height: 16),
              Text('Name: ${data['name']}', style: const TextStyle(fontSize: 18)),
              const SizedBox(height: 8),
              Text('Username: @${data['username']}', style: const TextStyle(fontSize: 18)),
              const SizedBox(height: 8),
              Text('Points: ${data['points']}', style: const TextStyle(fontSize: 18)),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                icon: const Icon(Icons.people),
                label: const Text('Friends'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const FriendsScreen()),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.storefront),
                label: const Text('My Business'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BusinessScreen()),
                ),
              ),
              if (devTools && !kIsWeb && defaultTargetPlatform == TargetPlatform.android) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.verified_user),
                  label: const Text('DEV: App Check code'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const DevAppCheckScreen()),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () => FirebaseAuth.instance.signOut(),
                child: const Text('Log Out'),
              ),
            ],
          );
        },
      ),
    );
  }
}