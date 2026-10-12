import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'auth_screen.dart';
import 'backend.dart';
import 'emulators.dart';
import 'place_screen.dart';
import 'theme.dart';

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
      await firebaseAuth.verifyPhoneNumber(
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
      User user = firebaseAuth.currentUser!;
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
    return AuthPage(
      color: AppColors.mint,
      icon: codeSent ? Icons.sms_rounded : Icons.phone_iphone_rounded,
      title: codeSent ? 'Enter your code' : 'Verify your phone',
      subtitle: codeSent
          ? 'We texted a 6-digit code to ${phoneController.text.trim()}.'
          : 'We\'ll text you a 6-digit code to confirm it\'s you.',
      children: [
        if (!codeSent) ...[
          TextField(
            controller: phoneController,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumber],
            style: AppText.heading(size: 20, weight: FontWeight.w600),
            decoration: const InputDecoration(
              labelText: 'Phone number',
              hintText: '+14155551234',
              helperText: 'Include the country code, e.g. +1.',
              prefixIcon: Icon(Icons.phone_rounded),
            ),
          ),
          const SizedBox(height: 16),
          const AuthNote(
            icon: Icons.verified_user_rounded,
            color: AppColors.purple,
            text: 'One account per phone number. A number that\'s already used by another account can\'t be '
                'added again.',
          ),
          const SizedBox(height: 16),
          if (errorMessage != null) ...[
            ErrorNote(message: errorMessage!),
            const SizedBox(height: 16),
          ],
          ElevatedButton(
            onPressed: isLoading ? null : _sendCode,
            child: isLoading ? const AuthButtonSpinner() : const Text('Send code'),
          ),
        ] else ...[
          CodeBoxes(
            controller: codeController,
            length: 6,
            enabled: !isLoading,
            semanticsLabel: 'Verification code, 6 digits',
          ),
          const SizedBox(height: 16),
          if (errorMessage != null) ...[
            ErrorNote(message: errorMessage!),
            const SizedBox(height: 16),
          ],
          ElevatedButton(
            onPressed: isLoading ? null : _verifyCode,
            child: isLoading ? const AuthButtonSpinner() : const Text('Verify'),
          ),
          const SizedBox(height: 8),
          // A new verification ID means a new code was sent, so the
          // countdown starts again.
          _ResendCode(key: ValueKey(verificationId), onResend: isLoading ? null : _sendCode),
          TextButton(
            onPressed: () => setState(() => codeSent = false),
            child: const Text('Wrong number? Go back'),
          ),
        ],
      ],
    );
  }
}

/// "Resend code in 0:59", then a Resend code button.
class _ResendCode extends StatefulWidget {
  final VoidCallback? onResend;

  const _ResendCode({super.key, required this.onResend});

  @override
  State<_ResendCode> createState() => _ResendCodeState();
}

class _ResendCodeState extends State<_ResendCode> {
  static const int waitSeconds = 60;

  int secondsLeft = waitSeconds;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() => secondsLeft--);
      if (secondsLeft <= 0) t.cancel();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (secondsLeft > 0) {
      return SizedBox(
        height: AppShapes.minTapTarget,
        child: Center(
          child: Text(
            'Resend code in ${secondsLeft ~/ 60}:${(secondsLeft % 60).toString().padLeft(2, '0')}',
            style: AppText.body(size: 15, weight: FontWeight.w700, color: AppColors.muted),
          ),
        ),
      );
    }
    return TextButton.icon(
      onPressed: widget.onResend,
      icon: const Icon(Icons.refresh_rounded),
      label: const Text('Resend code'),
    );
  }
}
