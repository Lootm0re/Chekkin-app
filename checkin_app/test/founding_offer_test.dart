// Widget tests for the Founding Partner card on My Business: the free months
// and, for Platinum and Diamond, the 50% off; nothing when there's no offer;
// and cancelling, which asks first. They use the fakes in fakes.dart, so
// nothing reaches Firebase.
//
//   flutter test test/founding_offer_test.dart
//   flutter test test/founding_offer_test.dart --dart-define=SCREENSHOTS=true

import 'package:checkin_app/business_screen.dart';
import 'package:checkin_app/business_tools.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const Size tall = Size(390, 2400);

final DateTime now = DateTime.now();
final DateTime freeUntil = DateTime(now.year, now.month + 3, now.day, 12, 15);
final DateTime discountUntil = DateTime(now.year, now.month + 6, now.day, 12, 15);

/// La Fleur on [tier], owned by the test user, with [offer] fields.
Future<Fakes> setUpOffer(String tier, Map<String, Object?> offer) async {
  var fakes = Fakes();
  await fakes.db.collection('businesses').doc('laFleur').set({
    'ownerUid': testUid,
    'placeName': 'Pizzeria La Fleur',
    'category': 'restaurant',
    'status': 'approved',
    'tier': tier,
    'codeSeq': 1,
    ...offer,
  });
  fakes.functions.answer('getBusinessStats', {
    'tierLabel': tier[0].toUpperCase() + tier.substring(1),
    'tierPoints': 75,
    'monthlyBudget': 1500,
    'usedThisMonth': 41,
    'today': 4,
    'week': 22,
    'sinceApproval': 41,
    'groupCheckIns': 6,
    'averageGroupSize': 2.5,
  });
  fakes.functions.answer('getBusinessCodes', {'codes': [], 'activeCount': 0, 'lifetimeHours': 24});
  fakes.functions.answer('getTableStickers', {'version': 1, 'stickers': []});
  fakes.functions.answer('getBusinessLeaderboard', {
    'month': '2026-10',
    'league': {'tiers': [tier], 'label': 'Platinum', 'size': 6},
    'top': [],
    'you': {'rank': 1, 'placeName': 'Pizzeria La Fleur', 'checkIns': 41, 'isYou': true},
    'above': null,
    'below': null,
    'lastMonthWinner': false,
  });
  return fakes;
}

Map<String, Object?> founding(int number, {bool discount = true}) => {
      'foundingPartner': true,
      'foundingNumber': number,
      'freeUntil': Timestamp.fromDate(freeUntil),
      if (discount) 'discountUntil': Timestamp.fromDate(discountUntil),
    };

void main() {
  setUpAll(loadTestFonts);

  test('dates read like 22 Jan 2027', () {
    expect(formatDate(DateTime(2027, 1, 22)), '22 Jan 2027');
    expect(formatDate(DateTime(2028, 2, 29, 23, 59)), '29 Feb 2028');
    expect(formatDate(DateTime(2026, 12, 1)), '1 Dec 2026');
  });

  test('an offer counts while it runs, and not once it\'s cancelled or over', () {
    Timestamp at(DateTime d) => Timestamp.fromDate(d);
    var offer = FoundingOffer.of(founding(7))!;
    expect(offer.number, 7);
    expect(offer.freeUntil, freeUntil);
    expect(offer.discountUntil, discountUntil);

    expect(FoundingOffer.of({}), isNull);
    expect(FoundingOffer.of({'foundingPartner': false}), isNull, reason: 'after the first 50');
    expect(FoundingOffer.of({...founding(7), 'offerCancelledAt': at(now)}), isNull);
    // During the discount the offer still runs; after it, it's over.
    var later = discountUntil.subtract(const Duration(days: 1));
    expect(FoundingOffer.of(founding(7), now: later), isNotNull);
    expect(FoundingOffer.of(founding(7), now: discountUntil), isNull);
    expect(FoundingOffer.of(founding(7, discount: false), now: freeUntil), isNull, reason: 'no discount: over when the free months end');
  });

  testWidgets('Platinum: the founding number, the free months and the 50% off', (tester) async {
    await setUpOffer('platinum', founding(7));
    await pumpScreen(tester, const BusinessScreen(), size: tall);

    expect(find.text('Founding Partner #7'), findsOneWidget);
    expect(find.text('Free until ${formatDate(freeUntil)}, cancel anytime'), findsOneWidget);
    expect(find.text('50% off until ${formatDate(discountUntil)}'), findsOneWidget);
    var cancel = find.widgetWithText(OutlinedButton, 'Cancel offer');
    expect(cancel, findsOneWidget);
    expect(tester.getSize(cancel).height, greaterThanOrEqualTo(54));

    // Right under the place card, above the check-in codes.
    double y(Finder f) => tester.getTopLeft(f).dy;
    expect(y(find.text('Pizzeria La Fleur').first), lessThan(y(find.text('Founding Partner #7'))));
    expect(y(find.text('Founding Partner #7')), lessThan(y(find.text('1 code'))));
    await takeScreenshot(tester, 'founding-partner-card');
  });

  testWidgets('Basic and Premium: free months only, no 50% off', (tester) async {
    await setUpOffer('premium', founding(12, discount: false));
    await pumpScreen(tester, const BusinessScreen(), size: tall);
    expect(find.text('Founding Partner #12'), findsOneWidget);
    expect(find.textContaining('50% off'), findsNothing);
    await takeScreenshot(tester, 'founding-partner-card-premium');
  });

  for (var (name, offer) in [
    ('no offer', <String, Object?>{}),
    ('after the first 50', <String, Object?>{'foundingPartner': false}),
    ('cancelled', {...founding(3), 'offerCancelledAt': Timestamp.now()}),
  ]) {
    testWidgets('nothing shown: $name', (tester) async {
      await setUpOffer('platinum', offer);
      await pumpScreen(tester, const BusinessScreen(), size: tall);
      expect(find.textContaining('Founding Partner'), findsNothing);
      expect(find.text('Cancel offer'), findsNothing);
      expect(find.text('Platinum plan'), findsWidgets, reason: 'the rest of My Business is there');
    });
  }

  testWidgets('cancelling asks first, then the card goes', (tester) async {
    var fakes = await setUpOffer('diamond', founding(7));
    fakes.functions.handlers['cancelFoundingOffer'] = (params) {
      expect(params, {'placeId': 'laFleur'});
      // The function writes offerCancelledAt; the screen follows the document.
      fakes.db.collection('businesses').doc('laFleur').update({'offerCancelledAt': Timestamp.now()});
      return {'cancelledAt': DateTime.now().millisecondsSinceEpoch};
    };
    await pumpScreen(tester, const BusinessScreen(), size: tall);

    // Changing your mind keeps the offer.
    await tester.tap(find.text('Cancel offer'));
    await settle(tester);
    expect(find.text('Cancel the Founding Partner offer?'), findsOneWidget);
    expect(find.textContaining('You keep Founding Partner #7.'), findsOneWidget);
    await takeScreenshot(tester, 'founding-partner-cancel');
    await tester.tap(find.text('Keep offer'));
    await settle(tester);
    expect(fakes.functions.calls, isNot(contains('cancelFoundingOffer')));
    expect(find.text('Founding Partner #7'), findsOneWidget);

    await tester.tap(find.text('Cancel offer'));
    await settle(tester);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Cancel offer'));
    await settle(tester);
    expect(fakes.functions.calls.where((c) => c == 'cancelFoundingOffer'), hasLength(1));
    expect(find.text('Founding Partner offer cancelled.'), findsOneWidget);
    expect(find.text('Founding Partner #7'), findsNothing);
  });
}
