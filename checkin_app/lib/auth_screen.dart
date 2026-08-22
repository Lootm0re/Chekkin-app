import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

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
  
  print('Button tapped - isSignUpMode: $isSignUpMode');
  setState(() {
    isLoading = true;
    errorMessage = null;
  });

    try {
      if (isSignUpMode) {
        await _signUp();
      } else {
        await _logIn();
      }
    } on FirebaseAuthException catch (e) {
      setState(() {
        errorMessage = _friendlyErrorMessage(e.code);
      });
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<void> _signUp() async {
    if (dateOfBirth == null) {
      throw FirebaseAuthException(code: 'no-birthdate', message: 'Please enter your date of birth.');
    }

    int age = _calculateAge(dateOfBirth!);
    if (age < minimumAge) {
      throw FirebaseAuthException(code: 'underage', message: 'Must be $minimumAge or older.');
    }

    String desiredUsername = usernameController.text.trim().toLowerCase();

    QuerySnapshot existing = await db
        .collection('users')
        .where('username', isEqualTo: desiredUsername)
        .limit(1)
        .get();

    if (existing.docs.isNotEmpty) {
      throw FirebaseAuthException(code: 'username-taken', message: 'Username already taken.');
    }

    UserCredential credential = await auth.createUserWithEmailAndPassword(
      email: emailController.text.trim(),
      password: passwordController.text,
    );

    Position position = await Geolocator.getCurrentPosition().timeout(
  const Duration(seconds: 10),
  onTimeout: () => throw Exception('Location request timed out. Please allow location access and try again.'),
);

    await db.collection('users').doc(credential.user!.uid).set({
      'name': nameController.text.trim(),
      'username': desiredUsername,
      'email': emailController.text.trim(),
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
      default:
        return 'Something went wrong. Please try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(isSignUpMode ? 'Sign Up' : 'Log In')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isSignUpMode)
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
            const SizedBox(height: 12),

            if (isSignUpMode)
              TextField(
                controller: usernameController,
                decoration: const InputDecoration(labelText: 'Username (for friends to find you)'),
              ),
            const SizedBox(height: 12),

            if (isSignUpMode)
              InkWell(
                onTap: () async {
                  DateTime? picked = await showDatePicker(
                    context: context,
                    initialDate: DateTime.now().subtract(const Duration(days: 365 * 25)),
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

            if (isSignUpMode)
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
                child: Text(errorMessage!, style: const TextStyle(color: Colors.red)),
              ),

            ElevatedButton(
              onPressed: isLoading ? null : _handleSubmit,
              child: isLoading
                  ? const CircularProgressIndicator()
                  : Text(isSignUpMode ? 'Create Account' : 'Log In'),
            ),

            TextButton(
              onPressed: () {
                setState(() {
                  isSignUpMode = !isSignUpMode;
                  errorMessage = null;
                });
              },
              child: Text(isSignUpMode
                  ? 'Already have an account? Log In'
                  : 'Need an account? Sign Up'),
            ),
          ],
        ),
      ),
    );
  }
}