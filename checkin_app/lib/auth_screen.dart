import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

import 'backend.dart';
import 'legal_screen.dart';
import 'location_access.dart';
import 'theme.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final FirebaseAuth auth = firebaseAuth;
  final FirebaseFirestore db = firestore;

  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController nameController = TextEditingController();
  final TextEditingController usernameController = TextEditingController();
  DateTime? dateOfBirth;

  static const int minimumAge = 18;

  bool isSignUpMode = true;
  bool isLoading = false;
  String? errorMessage;

  bool showPassword = false;
  bool agreedToTerms = false;
  bool isSendingReset = false;

  /// A confirmation (the password reset email was sent), in a mint box.
  String? infoMessage;

  late final TapGestureRecognizer termsTap = TapGestureRecognizer()
    ..onTap = () => _openLegal(LegalPage.terms);
  late final TapGestureRecognizer privacyTap = TapGestureRecognizer()
    ..onTap = () => _openLegal(LegalPage.privacy);

  @override
  void dispose() {
    termsTap.dispose();
    privacyTap.dispose();
    super.dispose();
  }

  void _openLegal(LegalPage page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => LegalScreen(page: page)));
  }

  Future<void> _sendPasswordReset() async {
    String email = emailController.text.trim();
    if (email.isEmpty) {
      setState(() {
        infoMessage = null;
        errorMessage = 'Enter your email above, then tap Forgot password? again.';
      });
      return;
    }

    setState(() {
      isSendingReset = true;
      errorMessage = null;
      infoMessage = null;
    });
    try {
      await auth.sendPasswordResetEmail(email: email);
      _showResetSent(email);
    } on FirebaseAuthException catch (e) {
      debugPrint('Password reset failed: [${e.code}] ${e.message}');
      if (e.code == 'user-not-found') {
        // Same message as a sent email, so this doesn't tell anyone which
        // emails have accounts.
        _showResetSent(email);
      } else {
        _showError(_friendlyErrorMessage(e.code));
      }
    } catch (e) {
      debugPrint('Password reset failed: $e');
      _showError('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => isSendingReset = false);
    }
  }

  void _showResetSent(String email) {
    if (!mounted) return;
    setState(() {
      infoMessage = 'If there\'s an account for $email, we\'ve sent it a link to reset your password. '
          'Check your inbox and spam folder.';
    });
  }

  Future<void> _handleSubmit() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
      infoMessage = null;
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
    bool canSubmit = !isLoading && (!showSignUp || agreedToTerms);

    return AuthPage(
      color: showSignUp ? AppColors.coral : AppColors.purple,
      icon: finishingProfile
          ? Icons.how_to_reg_rounded
          : showSignUp
          ? Icons.person_add_alt_1_rounded
          : Icons.waving_hand_rounded,
      title: finishingProfile
          ? 'Finish creating your account'
          : showSignUp
          ? 'Create account'
          : 'Welcome back!',
      subtitle: finishingProfile
          ? 'Just a few more details.'
          : showSignUp
          ? 'Check in at places you love and earn rewards.'
          : 'Sign in to keep collecting points.',
      children: [
        if (!finishingProfile) ...[
          _ModeSwitch(
            signUp: isSignUpMode,
            onChanged: (signUp) {
              setState(() {
                isSignUpMode = signUp;
                errorMessage = null;
                infoMessage = null;
              });
            },
          ),
          const SizedBox(height: 20),
        ],

        if (showSignUp) ...[
          TextField(
            controller: nameController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Name',
              prefixIcon: Icon(Icons.badge_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: usernameController,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Username',
              helperText: 'Friends find you by this.',
              prefixIcon: Icon(Icons.alternate_email_rounded),
            ),
          ),
          const SizedBox(height: 12),
          InkWell(
            borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
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
            // Empty until a date is picked, so the label sits inside the
            // field like the others.
            child: InputDecorator(
              isEmpty: dateOfBirth == null,
              decoration: const InputDecoration(
                labelText: 'Date of birth',
                prefixIcon: Icon(Icons.cake_outlined),
                suffixIcon: Icon(Icons.calendar_month_rounded),
              ),
              child: Text(
                dateOfBirth == null
                    ? ''
                    : '${dateOfBirth!.month}/${dateOfBirth!.day}/${dateOfBirth!.year}',
                style: AppText.body(),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],

        if (!finishingProfile) ...[
          TextField(
            controller: emailController,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'Email',
              prefixIcon: Icon(Icons.mail_outline_rounded),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: passwordController,
            obscureText: !showPassword,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: [showSignUp ? AutofillHints.newPassword : AutofillHints.password],
            // Redraws the strength bar.
            onChanged: showSignUp ? (_) => setState(() {}) : null,
            decoration: InputDecoration(
              labelText: 'Password',
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(
                tooltip: showPassword ? 'Hide password' : 'Show password',
                icon: Icon(showPassword ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                color: AppColors.muted,
                onPressed: () => setState(() => showPassword = !showPassword),
              ),
            ),
          ),
          if (showSignUp) ...[
            const SizedBox(height: 10),
            PasswordStrengthBar(password: passwordController.text),
            const SizedBox(height: 16),
          ] else ...[
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: isSendingReset || isLoading ? null : _sendPasswordReset,
                child: Text(isSendingReset ? 'Sending…' : 'Forgot password?'),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],

        if (showSignUp) ...[
          const AuthNote(
            icon: Icons.home_rounded,
            color: AppColors.sky,
            text: 'We\'ll use your current location as your home city. '
                'You can change this once a year.',
          ),
          const SizedBox(height: 8),
          _TermsCheckbox(
            value: agreedToTerms,
            onChanged: (value) => setState(() => agreedToTerms = value),
            termsTap: termsTap,
            privacyTap: privacyTap,
          ),
          const SizedBox(height: 8),
        ],

        if (infoMessage != null) ...[
          AuthNote(icon: Icons.mark_email_read_rounded, color: AppColors.mint, text: infoMessage!),
          const SizedBox(height: 16),
        ],

        if (errorMessage != null) ...[
          ErrorNote(message: errorMessage!),
          const SizedBox(height: 16),
        ],

        ElevatedButton(
          onPressed: canSubmit ? _handleSubmit : null,
          child: isLoading
              ? const AuthButtonSpinner()
              : Text(
                  finishingProfile
                      ? 'Finish'
                      : showSignUp
                      ? 'Create account'
                      : 'Sign in',
                ),
        ),

        if (finishingProfile) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => auth.signOut(),
            child: const Text('Use a different account'),
          ),
        ],
      ],
    );
  }
}

/// The Sign in / Create account pill switch at the top of the form.
class _ModeSwitch extends StatelessWidget {
  final bool signUp;
  final ValueChanged<bool> onChanged;

  const _ModeSwitch({required this.signUp, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: const ShapeDecoration(color: AppColors.lightPurple, shape: StadiumBorder()),
      child: Row(
        children: [
          _option('Sign in', selected: !signUp, value: false),
          _option('Create account', selected: signUp, value: true),
        ],
      ),
    );
  }

  Widget _option(String label, {required bool selected, required bool value}) {
    return Expanded(
      child: Material(
        color: selected ? AppColors.card : Colors.transparent,
        shape: const StadiumBorder(),
        elevation: selected ? 1 : 0,
        shadowColor: AppColors.ink.withValues(alpha: 0.2),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: selected ? null : () => onChanged(value),
          child: SizedBox(
            height: AppShapes.minTapTarget,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                // Shrinks rather than wraps on very narrow phones.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    style: AppText.heading(
                      size: 16,
                      weight: FontWeight.w600,
                      color: selected ? AppColors.purple : AppColors.muted,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Four segments that fill and change colour as the password gets stronger.
/// Only a hint: the account rules (at least 6 characters) are unchanged.
class PasswordStrengthBar extends StatelessWidget {
  final String password;

  const PasswordStrengthBar({super.key, required this.password});

  /// 0 when empty, otherwise 1 to 4: a point each for 8+ characters, 12+,
  /// letters mixed with digits, and mixed case or a symbol.
  static int strength(String p) {
    if (p.isEmpty) return 0;
    int score = 0;
    if (p.length >= 8) score++;
    if (p.length >= 12) score++;
    if (RegExp(r'[A-Za-z]').hasMatch(p) && RegExp(r'\d').hasMatch(p)) score++;
    if ((RegExp(r'[a-z]').hasMatch(p) && RegExp(r'[A-Z]').hasMatch(p)) || RegExp(r'[^A-Za-z0-9]').hasMatch(p)) {
      score++;
    }
    return score < 1 ? 1 : score;
  }

  @override
  Widget build(BuildContext context) {
    int score = strength(password);
    const colors = [AppColors.coral, AppColors.yellow, AppColors.sky, AppColors.mint];
    const labels = ['Weak', 'Okay', 'Good', 'Strong'];
    Color color = score == 0 ? AppColors.lightPurple : colors[score - 1];
    String label = password.isEmpty
        ? 'At least 6 characters'
        : password.length < 6
        ? 'Too short: at least 6 characters'
        : labels[score - 1];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (int i = 0; i < 4; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  height: 8,
                  decoration: ShapeDecoration(
                    color: i < score ? color : AppColors.lightPurple,
                    shape: const StadiumBorder(),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: AppText.body(size: 14, weight: FontWeight.w700, color: AppColors.muted),
        ),
      ],
    );
  }
}

/// "I agree to the terms and privacy policy", with the two links.
class _TermsCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final GestureRecognizer termsTap;
  final GestureRecognizer privacyTap;

  const _TermsCheckbox({
    required this.value,
    required this.onChanged,
    required this.termsTap,
    required this.privacyTap,
  });

  @override
  Widget build(BuildContext context) {
    TextStyle link = AppText.body(size: 15, weight: FontWeight.w800, color: AppColors.purple)
        .copyWith(decoration: TextDecoration.underline, decorationColor: AppColors.purple);
    return InkWell(
      borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              activeColor: AppColors.purple,
              checkColor: Colors.white,
              side: const BorderSide(color: AppColors.inactive, width: 2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: AppText.body(size: 15),
                  children: [
                    const TextSpan(text: 'I agree to the '),
                    TextSpan(text: 'terms', style: link, recognizer: termsTap),
                    const TextSpan(text: ' and '),
                    TextSpan(text: 'privacy policy', style: link, recognizer: privacyTap),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The layout shared by the sign-in and phone screens: a coloured header
/// with decorative circles and a big icon, then the form in a white card
/// that overlaps it. Scrolls, so the keyboard never hides the button.
class AuthPage extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> children;

  const AuthPage({
    super.key,
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    double top = MediaQuery.of(context).padding.top;
    Color onColor = AppColors.onColor(color);
    Color circle = color == AppColors.purple ? AppColors.coral : AppColors.purple;

    return Scaffold(
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(AppShapes.cardRadius * 1.5)),
                  ),
                  child: Stack(
                    children: [
                      // All circles stay above the title, beside the app name
                      // and the icon tile, so none sits under the text.
                      Positioned(right: -50, top: top - 70, child: DecorCircle(size: 180, color: AppColors.yellow)),
                      Positioned(
                        left: 112,
                        top: top + 84,
                        child: DecorCircle(size: 44, color: Colors.white.withValues(alpha: 0.25)),
                      ),
                      Positioned(left: 168, top: top + 72, child: DecorCircle(size: 18, color: circle)),
                      Padding(
                        padding: EdgeInsets.fromLTRB(24, top + 28, 24, 64),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Chekkin', style: AppText.heading(size: 20, color: onColor)),
                            const SizedBox(height: 20),
                            Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                color: AppColors.card,
                                borderRadius: BorderRadius.circular(24),
                                boxShadow: AppShapes.softShadow,
                              ),
                              child: Icon(icon, size: 38, color: color == AppColors.purple ? AppColors.purple : AppColors.ink),
                            ),
                            const SizedBox(height: 16),
                            Text(title, style: AppText.heading(size: 30, color: onColor)),
                            const SizedBox(height: 6),
                            Text(subtitle, style: AppText.body(size: 16, color: onColor)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Transform.translate(
                  offset: const Offset(0, -36),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(AppShapes.cardRadius),
                      boxShadow: AppShapes.softShadow,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A short explanation in a light tint of [color], with an icon square.
class AuthNote extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const AuthNote({super.key, required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
      ),
      child: Row(
        children: [
          IconSquare(color: color, icon: icon, size: 40),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: AppText.body(size: 14))),
        ],
      ),
    );
  }
}

/// The spinner inside a busy (disabled) button.
class AuthButtonSpinner extends StatelessWidget {
  const AuthButtonSpinner({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 2.5));
  }
}
