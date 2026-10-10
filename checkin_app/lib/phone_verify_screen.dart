import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'emulators.dart';

class PhoneVerifyScreen extends StatefulWidget {
  const PhoneVerifyScreen({super.key});

  @override
  State<PhoneVerifyScreen> createState() => _PhoneVerifyScreenState();
}

class _PhoneVerifyScreenState extends State<PhoneVerifyScreen> {
  final TextEditingController phoneController = TextEditingController();
  final TextEditingController codeController = TextEditingController();

  String? verificationId;
  bool codeSent = false;
  bool isLoading = false;
  String? errorMessage;

  Future<void> _sendCode() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: phoneController.text.trim(),
        verificationCompleted: (PhoneAuthCredential credential) async {
          await _linkPhoneCredential(credential);
        },
        verificationFailed: (FirebaseAuthException e) {
          _showError(e, 'Sending verification code failed');
        },
        codeSent: (String id, int? resendToken) {
          if (!mounted) return;
          setState(() {
            verificationId = id;
            codeSent = true;
            isLoading = false;
          });
        },
        codeAutoRetrievalTimeout: (String id) {
          verificationId = id;
        },
      );
    } catch (e) {
      _showError(e, 'Sending verification code failed');
    }
  }

  Future<void> _verifyCode() async {
    if (verificationId == null) return;

    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      PhoneAuthCredential credential = PhoneAuthProvider.credential(
        verificationId: verificationId!,
        smsCode: codeController.text.trim(),
      );
      await _linkPhoneCredential(credential);
    } catch (e, stack) {
      _showError(e, 'Verifying code failed', stack);
    }
  }

  Future<void> _linkPhoneCredential(PhoneAuthCredential credential) async {
    // Tracks how far we got so the error says which step failed.
    String step = 'link phone to account';
    try {
      User user = FirebaseAuth.instance.currentUser!;
      bool hasPhone = user.providerData.any((p) => p.providerId == PhoneAuthProvider.PROVIDER_ID);
      debugPrint('Phone verify: uid=${user.uid} hasPhone=$hasPhone');
      if (hasPhone) {
        // A phone was linked on an earlier attempt that didn't finish.
        step = 'replace linked phone';
        await user.updatePhoneNumber(credential);
      } else {
        await user.linkWithCredential(credential);
      }
      debugPrint('Phone verify: $step OK');

      // The server checks the number isn't used by another account and sets
      // phoneVerified (clients aren't allowed to). AuthGate moves on once the
      // profile updates.
      step = 'confirmPhoneVerified function';
      try {
        final result = await cloudFunctions.httpsCallable('confirmPhoneVerified').call();
        debugPrint('Phone verify: $step OK ${result.data}');
      } on FirebaseFunctionsException catch (e) {
        debugPrint('Phone verify: $step details=${e.details}');
        if (e.code == 'already-exists') {
          // Free this account to try a different number.
          await user.unlink(PhoneAuthProvider.PROVIDER_ID);
        }
        rethrow;
      }
    } catch (e, stack) {
      _showError(e, 'Phone verify failed at "$step"', stack);
    }
  }

  /// Logs the real error to the console (browser devtools on web) and shows
  /// a friendly version of it on screen.
  void _showError(Object error, String context, [StackTrace? stack]) {
    String code = 'unknown';
    if (error is FirebaseFunctionsException) {
      code = error.code;
      debugPrint('$context: [functions/${error.code}] ${error.message} details=${error.details}');
    } else if (error is FirebaseException) {
      code = error.code;
      debugPrint('$context: [${error.plugin}/${error.code}] ${error.message}');
    } else {
      debugPrint('$context: ${error.runtimeType}: $error');
    }
    if (stack != null) debugPrint('$stack');

    if (!mounted) return;
    setState(() {
      errorMessage = _friendlyError(code) ?? 'Something went wrong ($context: $code). Please try again.';
      isLoading = false;
    });
  }

  String? _friendlyError(String code) {
    switch (code) {
      case 'already-exists':
      case 'credential-already-in-use':
        return 'This phone number is already used by another account.';
      case 'operation-not-allowed':
        return 'Phone verification isn\'t available for this number\'s region yet.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a while and try again.';
      case 'captcha-check-failed':
      case 'invalid-app-credential':
        return 'Couldn\'t confirm you\'re not a robot. Please reload the page and try again.';
      case 'session-expired':
      case 'code-expired':
        return 'That code has expired. Please request a new one.';
      case 'invalid-verification-code':
        return 'That code doesn\'t look right. Please try again.';
      case 'invalid-phone-number':
        return 'Please enter a valid phone number, including country code (e.g. +1...).';
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verify Your Phone')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'To keep one account per person, we need to verify your phone number.',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 16),

            if (!codeSent) ...[
              TextField(
                controller: phoneController,
                decoration: const InputDecoration(labelText: 'Phone number (e.g. +14155551234)'),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              if (errorMessage != null)
                Text(errorMessage!, style: const TextStyle(color: Colors.red)),
              ElevatedButton(
                onPressed: isLoading ? null : _sendCode,
                child: isLoading ? const CircularProgressIndicator() : const Text('Send Code'),
              ),
            ] else ...[
              TextField(
                controller: codeController,
                decoration: const InputDecoration(labelText: '6-digit code'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              if (errorMessage != null)
                Text(errorMessage!, style: const TextStyle(color: Colors.red)),
              ElevatedButton(
                onPressed: isLoading ? null : _verifyCode,
                child: isLoading ? const CircularProgressIndicator() : const Text('Verify'),
              ),
              TextButton(
                onPressed: () => setState(() => codeSent = false),
                child: const Text('Wrong number? Go back'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}