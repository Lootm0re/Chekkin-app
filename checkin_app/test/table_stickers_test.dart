// Widget tests for table stickers: scanning in the check-in flow (with a
// stand-in camera), the code as a fallback, the camera permission message,
// the owner's sticker card and the printable sheet. They use the fakes in
// fakes.dart, so nothing reaches Firebase.
//
//   flutter test test/table_stickers_test.dart
//   flutter test test/table_stickers_test.dart --dart-define=SCREENSHOTS=true

import 'package:checkin_app/check_in_place.dart';
import 'package:checkin_app/place_screen.dart';
import 'package:checkin_app/table_stickers.dart';
import 'package:checkin_app/theme.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart' show MobileScannerErrorCode, MobileScannerException;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'fakes.dart';

const String validToken = 'CHK1.eyJwIjoibGFGbGV1ciJ9.c2lnbmF0dXJl';

const CheckInPlace laFleur = CheckInPlace(
  id: 'laFleur',
  name: 'Pizzeria La Fleur',
  position: LatLng(59.3165, 18.0715),
  category: PlaceCategory.restaurant,
  partner: true,
  tier: 'platinum',
  points: 75,
);

/// A stand-in camera with buttons that "scan" a sticker or another QR code.
Widget fakeCamera(BuildContext context, void Function(String) onScanned) => ColoredBox(
      color: const Color(0xFF3A3170),
      child: Align(
        alignment: const Alignment(0, -0.6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(onPressed: () => onScanned(validToken), child: const Text('fake: sticker')),
            TextButton(onPressed: () => onScanned('https://menu.example.com'), child: const Text('fake: menu QR')),
          ],
        ),
      ),
    );

/// PlaceScreen as MapScreen opens it, recording what it checks in with.
class Recorder {
  final List<({String? code, String? stickerToken})> calls = [];
  CheckInOutcome next = const CheckInOutcome.succeeded(placeName: 'Pizzeria La Fleur', pointsEarned: 75);
  CheckInOutcome? popped;
}

Future<Recorder> openPlace(WidgetTester tester) async {
  Fakes();
  var recorder = Recorder();
  await pumpScreen(
    tester,
    Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              recorder.popped = await Navigator.of(context).push<CheckInOutcome>(MaterialPageRoute(
                builder: (_) => PlaceScreen(
                  place: laFleur,
                  distanceMeters: 8,
                  onCheckIn: ({code, stickerToken, required friendUids}) async {
                    recorder.calls.add((code: code, stickerToken: stickerToken));
                    return recorder.next;
                  },
                ),
              ));
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
    size: const Size(390, 1000),
  );
  await tester.tap(find.text('open'));
  await settle(tester);
  return recorder;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => ScanStickerScreen.debugCamera = fakeCamera);
  tearDown(() => ScanStickerScreen.debugCamera = null);

  test('only Chekkin stickers are sent to the server', () {
    expect(looksLikeStickerToken(validToken), isTrue);
    expect(looksLikeStickerToken('https://menu.example.com'), isFalse);
    expect(looksLikeStickerToken('CHK1${'x' * 600}'), isFalse);
  });

  testWidgets('scanning a sticker checks in with it, not a code', (tester) async {
    var recorder = await openPlace(tester);
    expect(find.text('Scan the table sticker'), findsOneWidget);
    expect(find.text('No sticker? Enter the code'), findsOneWidget, reason: 'the code stays as a fallback');
    await takeScreenshot(tester, 'qr-check-in-options');

    await tester.tap(find.widgetWithText(ElevatedButton, 'Scan'));
    await settle(tester);
    expect(find.text('At Pizzeria La Fleur'), findsOneWidget);
    expect(find.text('Enter the code instead'), findsOneWidget);
    await takeScreenshot(tester, 'qr-scan-screen');

    await tester.tap(find.text('fake: sticker'));
    await settle(tester);
    expect(recorder.calls, [(code: null, stickerToken: validToken)]);
    expect(recorder.popped?.pointsEarned, 75, reason: 'back on the map with the outcome');
  });

  testWidgets('another QR code is ignored with a note, and nothing is sent', (tester) async {
    var recorder = await openPlace(tester);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Scan'));
    await settle(tester);
    await tester.tap(find.text('fake: menu QR'));
    await settle(tester);
    expect(find.textContaining('isn\'t a Chekkin sticker'), findsOneWidget);
    expect(recorder.calls, isEmpty);
  });

  testWidgets('a refused sticker shows why on the check-in screen', (tester) async {
    var recorder = await openPlace(tester);
    recorder.next = const CheckInOutcome.failed('That sticker has been replaced. Ask the staff at Pizzeria La Fleur for a code.');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Scan'));
    await settle(tester);
    await tester.tap(find.text('fake: sticker'));
    await settle(tester);
    expect(find.textContaining('That sticker has been replaced'), findsOneWidget);
    expect(find.text('No sticker? Enter the code'), findsOneWidget);
    expect(recorder.popped, isNull);
  });

  testWidgets('"Enter the code instead" goes back to the code, which still works', (tester) async {
    var recorder = await openPlace(tester);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Scan'));
    await settle(tester);
    await tester.tap(find.text('Enter the code instead'));
    await settle(tester);
    expect(recorder.calls, isEmpty);

    await tester.enterText(find.byType(TextField).first, '12345678');
    await settle(tester);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Check in'));
    await settle(tester);
    expect(recorder.calls, [(code: '12345678', stickerToken: null)]);
  });

  for (var (platform, hint) in [
    (TargetPlatform.android, 'Settings > Apps > Chekkin > Permissions > Camera'),
    (TargetPlatform.iOS, 'Settings > Chekkin > Camera'),
  ]) {
    testWidgets('camera permission denied (${platform.name}): a clear message and the code', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      ScanStickerScreen.debugCamera = (context, _) =>
          const CameraProblem(error: MobileScannerException(errorCode: MobileScannerErrorCode.permissionDenied));
      try {
        await pumpScreen(tester, const ScanStickerScreen(placeName: 'Pizzeria La Fleur'));
        expect(find.text('Camera access is off'), findsOneWidget);
        expect(find.textContaining(hint), findsOneWidget);
        expect(find.textContaining('Or enter the code from the staff'), findsOneWidget);
        expect(find.text('Enter the code instead'), findsOneWidget);
        if (platform == TargetPlatform.android) await takeScreenshot(tester, 'qr-camera-denied');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  group('owner', () {
    List<Map> stickers(List<String> labels, {int version = 1}) => [
          for (var (i, label) in labels.indexed) {'id': 's$i', 'label': label, 'token': 'CHK1.v$version-s$i.sig'},
        ];

    Fakes setUpStickers(List<String> labels) {
      var fakes = Fakes();
      var current = [...labels];
      int version = 1;
      fakes.functions.handlers['getTableStickers'] = (_) => {'version': version, 'stickers': stickers(current, version: version)};
      fakes.functions.handlers['createTableSticker'] = (params) {
        current.add(params['label']);
        return {'version': version, 'stickers': stickers(current, version: version)};
      };
      fakes.functions.handlers['resetTableStickers'] = (_) {
        version++;
        return {'version': version, 'stickers': stickers(current, version: version)};
      };
      return fakes;
    }

    Future<void> pumpCard(WidgetTester tester) => pumpScreen(
          tester,
          const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: TableStickersCard(placeId: 'laFleur', placeName: 'Pizzeria La Fleur'),
            ),
          ),
          size: const Size(390, 1100),
        );

    testWidgets('the sticker list: add by table name, print and reset', (tester) async {
      var fakes = setUpStickers(['Table 1', 'Table 2', 'Terrace 1']);
      await pumpCard(tester);
      for (var label in ['Table 1', 'Table 2', 'Terrace 1']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Print 3 stickers'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Table 4');
      await settle(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await settle(tester);
      expect(find.text('Table 4'), findsOneWidget);
      expect(find.textContaining('Sticker for Table 4 added'), findsOneWidget);
      // Buttons are pills at least 54 high.
      for (var label in ['Add', 'Print 4 stickers', 'Reset all stickers']) {
        var button = find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));
        expect(tester.getSize(button.first).height, greaterThanOrEqualTo(54), reason: label);
      }
      await takeScreenshot(tester, 'qr-sticker-list');

      // Reset asks first.
      await tester.tap(find.text('Reset all stickers'));
      await settle(tester);
      expect(find.text('Reset all stickers?'), findsOneWidget);
      await tester.tap(find.text('Keep stickers'));
      await settle(tester);
      expect(fakes.functions.calls, isNot(contains('resetTableStickers')));
      await tester.tap(find.text('Reset all stickers'));
      await settle(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Reset all'));
      await settle(tester);
      expect(fakes.functions.calls.where((c) => c == 'resetTableStickers'), hasLength(1));
      expect(find.textContaining('The old ones no longer work'), findsOneWidget);
    });

    testWidgets('no stickers yet', (tester) async {
      setUpStickers([]);
      await pumpCard(tester);
      expect(find.textContaining('No stickers yet'), findsOneWidget);
      expect(find.text('Reset all stickers'), findsNothing);
    });

    testWidgets('errors from the server are shown', (tester) async {
      var fakes = setUpStickers(['Table 1']);
      fakes.functions.handlers['createTableSticker'] =
          (_) => throw FirebaseFunctionsException(code: 'already-exists', message: 'There\'s already a sticker for Table 1.');
      await pumpCard(tester);
      await tester.enterText(find.byType(TextField), 'table 1');
      await settle(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await settle(tester);
      expect(find.byType(ErrorNote), findsOneWidget);
      expect(find.text('There\'s already a sticker for Table 1.'), findsOneWidget);
    });
  });

  test('the sticker sheet has six stickers a page', () async {
    var fonts = StickerFonts(heading: pw.Font.helveticaBold(), label: pw.Font.helveticaBold(), body: pw.Font.helvetica());
    var all = [for (int i = 1; i <= 7; i++) TableSticker(id: 's$i', label: 'Table $i', token: 'CHK1.payload$i.sig')];
    var pdf = await buildStickerSheet(PdfPageFormat.a4, placeName: 'Pizzeria La Fleur', stickers: all, fonts: fonts);
    String text = String.fromCharCodes(pdf);
    expect(text.startsWith('%PDF'), isTrue);
    expect(RegExp(r'/Type\s*/Page\b').allMatches(text).length, 2);
  });
}
