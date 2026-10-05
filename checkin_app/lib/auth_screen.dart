import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

import 'location_access.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final FirebaseAuth auth = FirebaseAuth.instance;
  final FirebaseFirestore db = FirebaseFirestore.instance;

  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController nameController = TextEditingController();
  final TextEditingController usernameController = TextEditingController();
  DateTime? dateOfBirth;

  static const int minimumAge = 18;

  bool isSignUpMode = true;
  bool isLoading = false;
  String? errorMessage;

  Future<void> _handleSubmit() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      if (isSignUpMode || auth.currentUser != null) {
        await _signUp();
      } else {
        await _logIn();
      }
    } on FirebaseException catch (e) {
      // FirebaseAuthException extends FirebaseException, so this covers
      // both auth errors and Firestore errors (e.g. permission-denied).
      debugPrint('Auth submit failed: [${e.plugin}/${e.code}] ${e.message}');
      _showError(_friendlyErrorMessage(e.code));
    } on LocationAccessException catch (e) {
      _showError(e.message);
    } catch (e) {
      debugPrint('Auth submit failed: $e');
      _showError('Something went wrong. Please try again.');
    } finally {
      // After a successful sign-up/log-in, AuthGate replaces this screen,
      // so it may already be disposed.
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      errorMessage = message;
    });
  }

  Future<void> _signUp() async {
    if (dateOfBirth == null) {
      throw FirebaseAuthException(
        code: 'no-birthdate',
        message: 'Please enter your date of birth.',
      );
    }

    int age = _calculateAge(dateOfBirth!);
    if (age < minimumAge) {
      throw FirebaseAuthException(
        code: 'underage',
        message: 'Must be $minimumAge or older.',
      );
    }

    String desiredUsername = usernameController.text.trim().toLowerCase();
    if (desiredUsername.isEmpty) {
      throw FirebaseAuthException(
        code: 'no-username',
        message: 'Please choose a username.',
      );
    }

    // Get the location before creating the account so a location failure
    // doesn't leave an auth user with no profile document.
    Position position = await getPositionWithPermission();

    // Firestore rules only allow signed-in users to read publicProfiles,
    // so the account has to exist before the username check.
    // A user may already be signed in without a profile (e.g. an earlier
    // sign-up failed halfway) - in that case finish their profile instead.
    User? user = auth.currentUser;
    bool createdNewUser = false;
    if (user == null) {
      UserCredential credential = await auth.createUserWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text,
      );
      user = credential.user!;
      createdNewUser = true;
    }

    try {
      QuerySnapshot existing = await db
          .collection('publicProfiles')
          .where('username', isEqualTo: desiredUsername)
          .limit(1)
          .get();

      if (existing.docs.isNotEmpty) {
        throw FirebaseAuthException(
          code: 'username-taken',
          message: 'Username already taken.',
        );
      }
    } catch (_) {
      // Don't leave behind an account the person can't finish setting up.
      if (createdNewUser) {
        try {
          await user.delete();
        } catch (e) {
          debugPrint('Failed to clean up new account: $e');
        }
      }
      rethrow;
    }

    await db.collection('users').doc(user.uid).set({
      'name': nameController.text.trim(),
      'username': desiredUsername,
      'email': user.email ?? emailController.text.trim(),
      'points': 0,
      'phoneVerified': false,
      'dateOfBirth': Timestamp.fromDate(dateOfBirth!),
      'homeLatitude': position.latitude,
      'homeLongitude': position.longitude,
      'homeLastChanged': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _logIn() async {
    await auth.signInWithEmailAndPassword(
      email: emailController.text.trim(),
      password: passwordController.text,
    );
  }

  int _calculateAge(DateTime birthDate) {
    DateTime today = DateTime.now();
    int age = today.year - birthDate.year;
    if (today.month < birthDate.month ||
        (today.month == birthDate.month && today.day < birthDate.day)) {
      age--;
    }
    return age;
  }

  String _friendlyErrorMessage(String code) {
    switch (code) {
      case 'email-already-in-use':
        return 'An account with this email already exists.';
      case 'weak-password':
        return 'Password should be at least 6 characters.';
      case 'user-not-found':
      case 'wrong-password':
        return 'Incorrect email or password.';
      case 'invalid-email':
        return 'That email address doesn\'t look right.';
      case 'username-taken':
        return 'That username is already taken.';
      case 'underage':
        return 'You must be $minimumAge or older to use this app.';
      case 'no-birthdate':
        return 'Please enter your date of birth.';
      case 'no-username':
        return 'Please choose a username.';
      case 'permission-denied':
        return 'Couldn\'t check that username. Please try again later.';
      case 'network-request-failed':
      case 'unavailable':
        return 'No internet connection. Please try again.';
      default:
        return 'Something went wrong. Please try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    // Signed in but no profile yet (a previous sign-up didn't finish). While a
    // sign-up is running the user is briefly signed in too, so keep the
    // normal form up until it settles.
    bool finishingProfile = auth.currentUser != null && !isLoading;
    bool showSignUp = isSignUpMode || finishingProfile;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          finishingProfile
              ? 'Finish Sign Up'
              : showSignUp
              ? 'Sign Up'
              : 'Log In',
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showSignUp)
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
            const SizedBox(height: 12),

            if (showSignUp)
              TextField(
                controller: usernameController,
                decoration: const InputDecoration(
                  labelText: 'Username (for friends to find you)',
                ),
              ),
            const SizedBox(height: 12),

            if (showSignUp)
              InkWell(
                onTap: () async {
                  DateTime? picked = await showDatePicker(
                    context: context,
                    initialDate: DateTime.now().subtract(
                      const Duration(days: 365 * 25),
                    ),
                    firstDate: DateTime(1900),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) {
                    setState(() => dateOfBirth = picked);
                  }
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Date of birth'),
                  child: Text(
                    dateOfBirth == null
                        ? 'Tap to select'
                        : '${dateOfBirth!.month}/${dateOfBirth!.day}/${dateOfBirth!.year}',
                  ),
                ),
              ),
            const SizedBox(height: 12),

            if (!finishingProfile) ...[
              TextField(
                controller: emailController,
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 12),

              TextField(
                controller: passwordController,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
              ),
              const SizedBox(height: 8),
            ],

            if (showSignUp)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'We\'ll use your current location as your home city, '
                  'which affects how points are calculated. You can change '
                  'this once a year.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),

            if (errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  errorMessage!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),

            ElevatedButton(
              onPressed: isLoading ? null : _handleSubmit,
              child: isLoading
                  ? const CircularProgressIndicator()
                  : Text(
                      finishingProfile
                          ? 'Finish Sign Up'
                          : showSignUp
                          ? 'Create Account'
                          : 'Log In',
                    ),
            ),

            if (finishingProfile)
              TextButton(
                onPressed: () => auth.signOut(),
                child: const Text('Use a different account'),
              )
            else
              TextButton(
                onPressed: () {
                  setState(() {
                    isSignUpMode = !isSignUpMode;
                    errorMessage = null;
                  });
                },
                child: Text(
                  isSignUpMode
                      ? 'Already have an account? Log In'
                      : 'Need an account? Sign Up',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
