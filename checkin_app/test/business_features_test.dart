// Widget tests for the business features: the Platinum tier (plan chip and
// highlighted pins), check-in codes in batches of 1, 10 or 50, and the
// business leaderboard on My Business. They use the fakes in fakes.dart, so
// nothing reaches Firebase.
//
//   flutter test test/business_features_test.dart
//   flutter test test/business_features_test.dart --dart-define=SCREENSHOTS=true

import 'package:checkin_app/business_screen.dart';
import 'package:checkin_app/check_in_place.dart';
import 'package:checkin_app/pin_icons.dart';
import 'package:checkin_app/theme.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'fakes.dart';

const Size tall = Size(390, 2400);

/// A Platinum place owned by the test user, with stats, a code list that
/// grows as codes are created, and [leaderboard].
Future<Fakes> setUpBusiness({required Map leaderboard, List<String> codes = const []}) async {
  var fakes = Fakes();
  await fakes.db.collection('businesses').doc('laFleur').set({
    'ownerUid': testUid,
    'placeName': 'Pizzeria La Fleur',
    'category': 'restaurant',
    'status': 'approved',
    'tier': 'platinum',
    'codeSeq': 1,
  });
  fakes.functions.answer('getBusinessStats', {
    'tierLabel': 'Platinum',
    'tierPoints': 75,
    'monthlyBudget': 1500,
    'usedThisMonth': 1041,
    'today': 38,
    'week': 245,
    'sinceApproval': 12480,
    'groupCheckIns': 310,
    'averageGroupSize': 2.6,
  });

  var active = [...codes];
  int expires = DateTime.now().add(const Duration(hours: 23)).millisecondsSinceEpoch;
  fakes.functions.handlers['getBusinessCodes'] = (_) => {
        'codes': [for (var c in active.reversed) {'code': c, 'expiresAt': expires}],
        'activeCount': active.length,
        'lifetimeHours': 24,
      };
  int next = 40000000;
  fakes.functions.handlers['createBusinessCodes'] = (params) {
    var created = [for (int i = 0; i < (params['count'] as int); i++) '${next++}'];
    active.addAll(created);
    return {'codes': created, 'expiresAt': expires};
  };
  fakes.functions.answer('getBusinessLeaderboard', leaderboard);
  return fakes;
}

/// The owner's own row in the league (marked for screen readers).
final Finder yourRow =
    find.byWidgetPredicate((w) => w is Text && w.semanticsLabel == 'Pizzeria La Fleur, your place');

Map row(int rank, String name, int checkIns, {bool you = false}) =>
    {'rank': rank, 'placeName': name, 'checkIns': checkIns, 'isYou': you};

/// La Fleur 6th of 9 in a merged league, last month's winner (like the emulator seed).
final Map busyLeague = {
  'month': '2026-10',
  'league': {'tiers': ['premium', 'platinum', 'diamond'], 'label': 'Premium & Platinum & Diamond', 'size': 9},
  'top': [
    row(1, 'Grand Hotell Norr', 1284),
    row(2, 'Restaurang Fyren', 96),
    row(3, 'Café Lyktan', 81),
    row(4, 'Hotell Ankaret', 64),
    row(5, 'Saluhallen', 57),
  ],
  'you': row(6, 'Pizzeria La Fleur', 41, you: true),
  'above': row(5, 'Saluhallen', 57),
  'below': row(7, 'Sushi Nami', 33),
  'lastMonthWinner': true,
};

final Map emptyLeague = {
  'month': '2026-10',
  'league': {'tiers': ['basic'], 'label': 'Basic', 'size': 6},
  'top': [for (int i = 1; i <= 5; i++) row(1, 'Place $i', 0)],
  'you': row(1, 'Pizzeria La Fleur', 0, you: true),
  'above': null,
  'below': null,
  'lastMonthWinner': false,
};

void main() {
  setUpAll(loadTestFonts);

  testWidgets('My Business: Platinum plan, codes in batches, and the league', (tester) async {
    var fakes = await setUpBusiness(leaderboard: busyLeague, codes: ['12345678']);
    await pumpScreen(tester, const BusinessScreen(), size: tall);

    // Plan chips in the header and on the place card, and the stats with separators.
    expect(find.text('Platinum plan'), findsNWidgets(2));
    expect(find.text('Platinum partner: 75 points a check-in.'), findsOneWidget);
    expect(find.text('1,041 / 1,500'), findsOneWidget);
    expect(find.text('12,480'), findsOneWidget);

    // Codes: the newest one large, split in two halves.
    expect(find.text('1234 5678'), findsOneWidget);
    for (var label in ['1 code', '10 codes', '50 codes']) {
      expect(find.text(label), findsOneWidget);
    }
    // The batch buttons are pills at least 54 high, the 1-code one the primary.
    for (var label in ['1 code', '10 codes', '50 codes']) {
      expect(tester.getSize(find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)).first).height,
          greaterThanOrEqualTo(54));
    }
    expect(find.ancestor(of: find.text('1 code'), matching: find.byType(ElevatedButton)), findsOneWidget);

    // League: top 5, a gap, then the owner's place and its neighbours.
    expect(find.text('Premium & Platinum & Diamond league · 9 places · check-ins this month'), findsOneWidget);
    expect(find.text('1,284'), findsOneWidget);
    expect(yourRow, findsOneWidget);
    expect(find.text('Sushi Nami'), findsOneWidget);
    expect(find.text('Saluhallen'), findsNWidgets(1), reason: 'the place above is in the top 5, so it is shown once');
    expect(find.text('•  •  •'), findsNothing, reason: 'ranks 1 to 7 follow on, so no gap');
    expect(find.text('Last month\'s winner'), findsOneWidget);
    var you = tester.widget<Container>(
      find.ancestor(of: yourRow, matching: find.byType(Container)).first,
    );
    expect(((you.decoration as BoxDecoration).border as Border).top.color, AppColors.purple);
    await takeScreenshot(tester, 'my-business');

    // A batch of 10.
    await tester.tap(find.text('10 codes'));
    await settle(tester);
    expect(fakes.functions.calls.where((c) => c == 'createBusinessCodes'), hasLength(1));
    expect(find.text('10 new codes ready.'), findsOneWidget);
    expect(find.text('10 more active codes'), findsOneWidget);
    expect(find.text('4000 0009'), findsOneWidget, reason: 'the newest code');
    await takeScreenshot(tester, 'my-business-batch');
  });

  testWidgets('a gap marks ranks left out between the top 5 and the owner\'s place', (tester) async {
    await setUpBusiness(leaderboard: {
      ...busyLeague,
      'league': {'tiers': ['basic'], 'label': 'Basic', 'size': 12},
      'you': row(9, 'Pizzeria La Fleur', 12, you: true),
      'above': row(8, 'Nudelbaren', 21),
      'below': row(10, 'Blomsterboden', 3),
      'lastMonthWinner': false,
    });
    await pumpScreen(tester, const BusinessScreen(), size: tall);
    expect(find.text('•  •  •'), findsOneWidget);
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y('Saluhallen'), lessThan(y('•  •  •')));
    expect(y('•  •  •'), lessThan(y('Nudelbaren')));
    double you = tester.getTopLeft(yourRow).dy;
    expect(y('Nudelbaren'), lessThan(you));
    expect(you, lessThan(y('Blomsterboden')));
  });

  testWidgets('the hourly safety limit is shown politely', (tester) async {
    var fakes = await setUpBusiness(leaderboard: busyLeague);
    fakes.functions.handlers['createBusinessCodes'] = (_) => throw FirebaseFunctionsException(
          code: 'resource-exhausted',
          message: 'For safety, a place can create up to 1,000 codes an hour. You can create 40 more this hour, '
              'or create more in 12 minutes. Codes you already have still work.',
        );
    await pumpScreen(tester, const BusinessScreen(), size: tall);

    await tester.tap(find.text('50 codes'));
    await settle(tester);
    expect(find.textContaining('up to 1,000 codes an hour'), findsOneWidget);
    expect(find.byType(ErrorNote), findsOneWidget);
    await takeScreenshot(tester, 'my-business-code-limit');
  });

  testWidgets('empty states: no codes yet, no check-ins this month', (tester) async {
    await setUpBusiness(leaderboard: emptyLeague);
    await pumpScreen(tester, const BusinessScreen(), size: tall);

    expect(find.text('No active codes'), findsOneWidget);
    expect(find.text('No check-ins yet this month'), findsOneWidget);
    expect(find.text('Last month\'s winner'), findsNothing);
    await takeScreenshot(tester, 'my-business-empty');
  });

  group('tiers', () {
    CheckInPlace partner(String? tier) => CheckInPlace(
          id: 'p',
          name: 'P',
          position: const LatLng(0, 0),
          category: PlaceCategory.fromName('restaurant'),
          partner: tier != null,
          tier: tier,
          points: 0,
        );

    test('Premium, Platinum and Diamond pins are highlighted alike; Basic is not', () {
      expect(partner('basic').pinStyle.highlighted, isFalse);
      for (var tier in ['premium', 'platinum', 'diamond']) {
        expect(partner(tier).pinStyle.highlighted, isTrue, reason: tier);
        expect(pinSize(partner(tier).pinStyle), pinSize(partner('premium').pinStyle));
      }
      expect(partner(null).pinStyle.highlighted, isFalse);
    });

    test('higher tiers are drawn on top: Diamond > Platinum > Premium > Basic', () {
      expect(
        ['basic', 'premium', 'platinum', 'diamond'].map((t) => partner(t).mapLayer).toList(),
        [1, 2, 3, 4],
      );
      expect(partner(null).mapLayer, 0);
    });

    test('Platinum has a label and its own plan chip', () {
      expect(tierLabels['platinum'], 'Platinum');
      expect(tierLabels.keys.toList(), ['basic', 'premium', 'platinum', 'diamond']);
      ColorChip chip = tierChip('platinum');
      expect(chip.label, 'Platinum plan');
      expect(chip.color, AppColors.sky);
    });

    testWidgets('pins and plan chips (screenshot)', (tester) async {
      Fakes();
      var styles = [
        for (var tier in [null, 'basic', 'premium', 'platinum', 'diamond'])
          (tier: tier, style: partner(tier).pinStyle),
      ];
      var pngs = await tester.runAsync(() => Future.wait(styles.map((s) => drawPinPng(s.style))));
      await pumpScreen(
        tester,
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Pins', style: AppText.heading(size: 22)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 14,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  children: [
                    for (int i = 0; i < styles.length; i++)
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Image.memory(pngs![i], width: pinSize(styles[i].style), height: pinSize(styles[i].style)),
                          const SizedBox(height: 6),
                          Text(tierLabels[styles[i].tier] ?? 'Not a partner', style: AppText.body(size: 14)),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                Text('Plan chips', style: AppText.heading(size: 22)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (var tier in tierLabels.keys) tierChip(tier)],
                ),
              ],
            ),
          ),
        ),
        size: const Size(390, 400),
      );
      expect(find.text('Platinum plan'), findsOneWidget);
      await takeScreenshot(tester, 'tier-pins-and-chips');
    });
  });
}
