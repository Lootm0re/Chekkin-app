// Widget tests for the UI polish round (thousand separators, "Available
// points", Rewards order and progress, the sign-in screens). They use the
// fakes in fakes.dart, so nothing reaches Firebase.
//
//   flutter test test/polish_round_test.dart
//   flutter test test/polish_round_test.dart --dart-define=SCREENSHOTS=true

import 'package:checkin_app/auth_screen.dart';
import 'package:checkin_app/business_screen.dart';
import 'package:checkin_app/leaderboard_screen.dart';
import 'package:checkin_app/phone_verify_screen.dart';
import 'package:checkin_app/profile_screen.dart';
import 'package:checkin_app/rewards_screen.dart';
import 'package:checkin_app/theme.dart';
import 'package:checkin_app/vouchers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// A tall phone, so long lists build every row.
const Size tall = Size(390, 1700);

Future<void> addLeaderboard(Fakes fakes) async {
  var profiles = fakes.db.collection('publicProfiles');
  await profiles.doc('u2').set({'name': 'Gais', 'username': 'gais', 'lifetimePoints': 1234567});
  await profiles.doc(testUid).set({'name': 'Gaian', 'username': 'gaian', 'lifetimePoints': 34567});
  await profiles.doc('u3').set({'name': 'Partner Two', 'username': 'partner2', 'lifetimePoints': 999});
}

void main() {
  setUpAll(loadTestFonts);

  group('formatNumber', () {
    test('adds thousand separators', () {
      expect(formatNumber(0), '0');
      expect(formatNumber(999), '999');
      expect(formatNumber(1000), '1,000');
      expect(formatNumber(12000), '12,000');
      expect(formatNumber(1234567), '1,234,567');
      expect(formatNumber(-3000), '-3,000');
      expect(formatNumber(2.6), '3');
      expect(formatNumber(null), '0');
    });
  });

  group('thousand separators and "Available points"', () {
    testWidgets('Profile', (tester) async {
      var fakes = Fakes();
      await fakes.db.collection('users').doc(testUid).set({
        'name': 'Gaian',
        'username': 'gaian',
        'points': 12000,
        'lifetimePoints': 34567,
      });
      await addLeaderboard(fakes);

      await pumpScreen(tester, const ProfileScreen(), size: tall);

      expect(find.text('12,000'), findsOneWidget); // the Available points tile
      expect(find.text('34,567 pts earned'), findsOneWidget);
      expect(find.text('1,234,567'), findsOneWidget); // leaderboard preview
      expect(find.text('34,567'), findsOneWidget);
      expect(find.text('Available points'), findsOneWidget);
      expect(find.text('Points to spend'), findsNothing);
      expect(find.textContaining('total points'), findsNothing);
      await takeScreenshot(tester, 'profile');
    });

    testWidgets('Leaderboard', (tester) async {
      var fakes = Fakes();
      await addLeaderboard(fakes);

      await pumpScreen(tester, const LeaderboardScreen());

      expect(find.text('1,234,567'), findsOneWidget);
      expect(find.text('34,567'), findsOneWidget);
      expect(find.text('999'), findsOneWidget);
      await takeScreenshot(tester, 'leaderboard');
    });

    testWidgets('Voucher confirmation', (tester) async {
      var fakes = Fakes();
      fakes.functions.answer('rewardPartners', {
        'places': [
          {'placeId': 'p1', 'placeName': 'Pizzeria La Fleur', 'category': 'restaurant'},
        ],
      });
      var reward = Reward(
        name: 'Restaurant Discount',
        pointsRequired: 5000,
        description: '50% off at a partner restaurant',
        catalogId: 'restaurant50',
      );

      await pumpScreen(tester, RedeemRewardScreen(reward: reward, userPoints: 17000));
      await tester.tap(find.text('Pizzeria La Fleur'));
      await tester.pumpAndSettle();

      expect(find.textContaining('This uses 5,000 of your 17,000 points.'), findsOneWidget);
      await takeScreenshot(tester, 'voucher-confirmation');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fakes.functions.calls, isNot(contains('redeemReward')));
    });

    testWidgets('Business', (tester) async {
      var fakes = Fakes();
      await fakes.db.collection('businesses').doc('p1').set({
        'ownerUid': testUid,
        'placeName': 'Pizzeria La Fleur',
        'category': 'restaurant',
        'status': 'approved',
        'tier': 'premium',
        'codeSeq': 1,
      });
      fakes.functions.answer('getBusinessCodes', {
        'codes': [
          {'code': '12345678', 'expiresAt': DateTime.now().add(const Duration(hours: 23)).millisecondsSinceEpoch},
        ],
        'activeCount': 1,
        'lifetimeHours': 24,
      });
      fakes.functions.answer('getBusinessLeaderboard', {
        'league': {'tiers': ['premium'], 'label': 'Premium', 'size': 1},
        'top': [
          {'rank': 1, 'placeName': 'Pizzeria La Fleur', 'checkIns': 1234, 'isYou': true},
        ],
        'you': {'rank': 1, 'placeName': 'Pizzeria La Fleur', 'checkIns': 1234, 'isYou': true},
        'above': null,
        'below': null,
        'lastMonthWinner': false,
      });
      fakes.functions.answer('getBusinessStats', {
        'tierLabel': 'Premium',
        'tierPoints': 1500,
        'monthlyBudget': 2500,
        'usedThisMonth': 1234,
        'today': 1200,
        'week': 5300,
        'sinceApproval': 12345,
        'groupCheckIns': 1001,
        'averageGroupSize': 2.5,
      });

      await pumpScreen(tester, const BusinessScreen(), size: tall);

      expect(find.text('Premium partner: 1,500 points a check-in.'), findsOneWidget);
      expect(find.text('1,234 / 2,500'), findsOneWidget);
      expect(find.textContaining('1,234 of 2,500 full-point check-ins'), findsOneWidget);
      expect(find.text('1,200'), findsOneWidget);
      expect(find.text('5,300'), findsOneWidget);
      expect(find.text('12,345'), findsOneWidget);
      expect(find.text('1,001'), findsOneWidget);
      await takeScreenshot(tester, 'business');

      // Verify voucher: no character counter under the code field.
      await tester.tap(find.text('Verify voucher').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ABCD EFG');
      await tester.pump();
      expect(find.textContaining('/9'), findsNothing);
      expect(find.textContaining('/8'), findsNothing);
      await takeScreenshot(tester, 'business-verify-voucher');


    });
  });

  group('Rewards', () {
    Future<void> pumpRewards(WidgetTester tester, int points) async {
      var fakes = Fakes();
      await fakes.db.collection('rewards').doc('restaurant50').set({
        'active': true,
        'type': 'partner_discount',
        'name': 'Restaurant Discount',
        'pointsCost': 5000,
        'discountPercent': 50,
        'category': 'restaurant',
      });
      await pumpScreen(tester, RewardsScreen(userPoints: points), size: tall);
    }

    testWidgets('redeemable first, Coming soon after, and the progress bar', (tester) async {
      await pumpRewards(tester, 17000);

      expect(find.text('Available points'), findsOneWidget);
      expect(find.text('total points'), findsNothing);
      expect(find.text('17,000'), findsOneWidget);
      expect(find.text('5,000 pts'), findsOneWidget);
      expect(find.text('40,000 pts'), findsOneWidget);

      // Order on screen, top to bottom.
      List<String> names = ['Restaurant Discount', 'Coffee Voucher', 'Museum Pass', 'Weekend Getaway', 'Free Flight Ticket'];
      List<double> ys = [for (var name in names) tester.getTopLeft(find.text(name)).dy];
      for (int i = 1; i < ys.length; i++) {
        expect(ys[i], greaterThan(ys[i - 1]), reason: '${names[i]} should be below ${names[i - 1]}');
      }
      // Only the redeemable one has a Redeem button, and it comes first.
      expect(find.widgetWithText(ElevatedButton, 'Redeem'), findsOneWidget);
      expect(find.text('Coming soon'), findsNWidgets(4));
      expect(tester.getTopLeft(find.text('Redeem')).dy, lessThan(tester.getTopLeft(find.text('Coming soon').first).dy));

      // Cheapest reward not yet affordable: Weekend Getaway (20,000).
      expect(find.text('3,000 more points to Weekend Getaway'), findsOneWidget);
      expect(find.text('17,000 / 20,000 · coming soon'), findsOneWidget);
      var bar = tester.widget<LinearProgressIndicator>(
        find.descendant(of: find.byType(ClipRRect), matching: find.byType(LinearProgressIndicator)).first,
      );
      expect(bar.value, closeTo(17000 / 20000, 0.0001));
      await takeScreenshot(tester, 'rewards');
    });

    testWidgets('progress points at a redeemable reward when that is the next one', (tester) async {
      await pumpRewards(tester, 1700);

      expect(find.text('3,300 more points to Restaurant Discount'), findsOneWidget);
      expect(find.text('1,700 / 5,000'), findsOneWidget);
    });
  });

  group('Create account', () {
    Finder passwordField() => find.widgetWithText(TextField, 'Password');
    ElevatedButton submitButton(WidgetTester tester) => tester.widget<ElevatedButton>(find.byType(ElevatedButton));

    testWidgets('button stays disabled until the terms box is ticked', (tester) async {
      Fakes(signedIn: false);
      await pumpScreen(tester, const AuthScreen(), size: tall);

      expect(find.textContaining('I agree to the'), findsOneWidget);
      expect(submitButton(tester).onPressed, isNull);
      await takeScreenshot(tester, 'create-account');

      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(submitButton(tester).onPressed, isNotNull);

      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(submitButton(tester).onPressed, isNull);
    });

    testWidgets('the eye shows and hides the password', (tester) async {
      Fakes(signedIn: false);
      await pumpScreen(tester, const AuthScreen(), size: tall);
      bool obscured() => tester.widget<TextField>(passwordField()).obscureText;

      expect(obscured(), isTrue);
      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();
      expect(obscured(), isFalse);
      await tester.tap(find.byTooltip('Hide password'));
      await tester.pump();
      expect(obscured(), isTrue);
    });

    testWidgets('the strength bar follows the password', (tester) async {
      Fakes(signedIn: false);
      await pumpScreen(tester, const AuthScreen(), size: tall);

      int filledSegments() => tester
          .widgetList<AnimatedContainer>(
            find.descendant(of: find.byType(PasswordStrengthBar), matching: find.byType(AnimatedContainer)),
          )
          .where((c) => (c.decoration as ShapeDecoration).color != AppColors.lightPurple)
          .length;

      expect(find.text('At least 6 characters'), findsOneWidget);
      expect(filledSegments(), 0);

      var steps = {
        'abc': ('Too short: at least 6 characters', 1),
        'abcdefgh': ('Weak', 1),
        'abcdefgh1': ('Okay', 2),
        'abc12345X': ('Good', 3),
        'Abc12345!xyz': ('Strong', 4),
      };
      for (var entry in steps.entries) {
        await tester.enterText(passwordField(), entry.key);
        await tester.pumpAndSettle();
        expect(find.text(entry.value.$1), findsOneWidget, reason: entry.key);
        expect(filledSegments(), entry.value.$2, reason: entry.key);
      }
      await takeScreenshot(tester, 'create-account-strong-password');
    });
  });

  group('Forgot password', () {
    Future<Fakes> openSignIn(WidgetTester tester) async {
      var fakes = Fakes(signedIn: false);
      await pumpScreen(tester, const AuthScreen());
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome back!'), findsOneWidget);
      return fakes;
    }

    testWidgets('with no email, asks for one and sends nothing', (tester) async {
      var fakes = await openSignIn(tester);
      await takeScreenshot(tester, 'sign-in');

      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();

      expect(find.text('Enter your email above, then tap Forgot password? again.'), findsOneWidget);
      expect(fakes.auth.resetEmails, isEmpty);
      await takeScreenshot(tester, 'sign-in-forgot-no-email');
    });

    testWidgets('with an email, sends the reset (fake) and confirms', (tester) async {
      var fakes = await openSignIn(tester);

      await tester.enterText(find.widgetWithText(TextField, 'Email'), '  gaian@chekkin.test ');
      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();

      expect(fakes.auth.resetEmails, ['gaian@chekkin.test']);
      expect(
        find.text('If there\'s an account for gaian@chekkin.test, we\'ve sent it a link to reset your password. '
            'Check your inbox and spam folder.'),
        findsOneWidget,
      );
      await takeScreenshot(tester, 'sign-in-forgot-sent');
    });
  });

  group('small phone (320x568) with the keyboard open', () {
    const Size small = Size(320, 568);
    const double keyboard = 260;
    const double visibleBottom = 568 - keyboard;

    /// Every field and the button can be scrolled above the keyboard and is
    /// then fully visible. Any overflow fails the test by itself.
    Future<void> expectAllReachable(WidgetTester tester) async {
      var targets = [
        ...find.byType(TextField).evaluate().map((e) => find.byWidget(e.widget)),
        find.byType(ElevatedButton),
      ];
      for (var target in targets) {
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        Rect rect = tester.getRect(target);
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(visibleBottom + 0.5));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(small.width));
      }
    }

    testWidgets('Create account', (tester) async {
      Fakes(signedIn: false);
      await pumpScreen(tester, const AuthScreen(), size: small, keyboard: keyboard);
      await takeScreenshot(tester, 'small-create-account-keyboard-top');
      await expectAllReachable(tester);
      await takeScreenshot(tester, 'small-create-account-keyboard-bottom');
    });

    testWidgets('Sign in', (tester) async {
      Fakes(signedIn: false);
      await pumpScreen(tester, const AuthScreen(), size: small, keyboard: keyboard);
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await expectAllReachable(tester);
      await takeScreenshot(tester, 'small-sign-in-keyboard');
    });
  });

  testWidgets('Verify phone (screenshot only)', (tester) async {
    Fakes();
    await pumpScreen(tester, const PhoneVerifyScreen());
    expect(find.text('Send code'), findsOneWidget);
    await takeScreenshot(tester, 'verify-phone');
  });
}
