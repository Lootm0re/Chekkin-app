import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

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

    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: phoneController.text.trim(),
      verificationCompleted: (PhoneAuthCredential credential) async {
        await _linkPhoneCredential(credential);
      },
      verificationFailed: (FirebaseAuthException e) {
        setState(() {
          errorMessage = _friendlyError(e.code);
          isLoading = false;
        });
      },
      codeSent: (String id, int? resendToken) {
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
    } on FirebaseAuthException catch (e) {
      setState(() {
        errorMessage = _friendlyError(e.code);
        isLoading = false;
      });
    }
  }

  Future<void> _linkPhoneCredential(PhoneAuthCredential credential) async {
    try {
      User user = FirebaseAuth.instance.currentUser!;
      await user.linkWithCredential(credential);

      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'phoneVerified': true,
        'phoneNumber': phoneController.text.trim(),
      });
    } on FirebaseAuthException catch (e) {
      setState(() {
        errorMessage = _friendlyError(e.code);
        isLoading = false;
      });
    }
  }

  String _friendlyError(String code) {
    switch (code) {
      case 'credential-already-in-use':
        return 'This phone number is already linked to another account.';
      case 'invalid-verification-code':
        return 'That code doesn\'t look right. Please try again.';
      case 'invalid-phone-number':
        return 'Please enter a valid phone number, including country code (e.g. +1...).';
      default:
        return 'Something went wrong. Please try again.';
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