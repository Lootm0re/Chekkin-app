// Fakes and helpers for widget tests of whole screens: an in-memory
// Firestore, a fake signed-in user, and canned answers from the callable
// functions. Nothing here talks to Firebase.
//
// Screenshots: run with --dart-define=SCREENSHOTS=true and every
// takeScreenshot() call saves a PNG with real fonts into ../screenshots/
// (the repo's screenshots/ folder, which git ignores). This needs internet
// for the fonts. Without the flag, tests use the test font and save nothing.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:checkin_app/backend.dart';
import 'package:checkin_app/theme.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

const bool screenshotsOn = bool.fromEnvironment('SCREENSHOTS');

const String testUid = 'u1';

/// Answers callable functions by name: a value, or a function of the
/// call's parameters.
class FakeFunctions implements FirebaseFunctions {
  final Map<String, Object? Function(dynamic parameters)> handlers = {};
  final List<String> calls = [];

  void answer(String name, Object? data) => handlers[name] = (_) => data;

  @override
  HttpsCallable httpsCallable(String name, {HttpsCallableOptions? options}) => _FakeCallable(this, name);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCallable implements HttpsCallable {
  final FakeFunctions functions;
  final String name;

  _FakeCallable(this.functions, this.name);

  @override
  Future<HttpsCallableResult<T>> call<T>([dynamic parameters]) async {
    functions.calls.add(name);
    var handler = functions.handlers[name];
    if (handler == null) throw FirebaseFunctionsException(code: 'not-found', message: 'No fake for $name');
    return _FakeResult<T>(handler(parameters) as T);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResult<T> implements HttpsCallableResult<T> {
  @override
  final T data;

  _FakeResult(this.data);
}

/// MockFirebaseAuth that records password reset emails instead of sending.
class RecordingAuth extends MockFirebaseAuth {
  final List<String> resetEmails = [];

  RecordingAuth({super.signedIn, super.mockUser});

  @override
  Future<void> sendPasswordResetEmail({required String email, ActionCodeSettings? actionCodeSettings}) async {
    resetEmails.add(email);
  }
}

class Fakes {
  final FakeFirebaseFirestore db = FakeFirebaseFirestore();
  final RecordingAuth auth;
  final FakeFunctions functions = FakeFunctions();

  Fakes({bool signedIn = true})
      : auth = RecordingAuth(
          signedIn: signedIn,
          mockUser: MockUser(uid: testUid, email: 'gaian@chekkin.test'),
        ) {
    firestoreOverride = db;
    authOverride = auth;
    functionsOverride = functions;
  }

  static void reset() {
    firestoreOverride = null;
    authOverride = null;
    functionsOverride = null;
  }
}

final GlobalKey _screenKey = GlobalKey();

Future<void> _loadFont(String family, String file) async {
  String flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '../flutter';
  var bytes = File('$flutterRoot/bin/cache/artifacts/material_fonts/$file').readAsBytes();
  await (FontLoader(family)..addFont(bytes.then((b) => ByteData.view(b.buffer)))).load();
}

/// Call from setUpAll. The default test font draws every character as a
/// full square, much wider than real text, so layouts that fit on a phone
/// "overflow" in tests. Roboto (bundled with Flutter, works offline) stands
/// in for Fredoka and Nunito, registered under the names google_fonts gives
/// each weight ("Fredoka_700"); the test engine ignores fallback fonts. With
/// SCREENSHOTS on, google_fonts downloads the real fonts instead.
Future<void> loadTestFonts() async {
  await _loadFont('MaterialIcons', 'MaterialIcons-Regular.otf');
  if (screenshotsOn) {
    // flutter_test blocks HTTP; google_fonts needs it to fetch the fonts.
    // Fetched here, in real time: a download started while a widget test
    // runs on its fake clock never finishes.
    HttpOverrides.global = null;
    // google_fonts caches downloads on disk via path_provider, which has no
    // plugin in tests; a temp folder stands in.
    String cache = Directory.systemTemp.createTempSync('fonts').path;
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => cache,
    );
    for (var weight in [FontWeight.w400, FontWeight.w500, FontWeight.w600, FontWeight.w700, FontWeight.w800]) {
      GoogleFonts.fredoka(fontWeight: weight);
      GoogleFonts.nunito(fontWeight: weight);
    }
    await GoogleFonts.pendingFonts();
    return;
  }
  for (var family in ['Fredoka', 'Nunito']) {
    await _loadFont('${family}_regular', 'Roboto-Regular.ttf');
    for (var weight in [500, 600]) {
      await _loadFont('${family}_$weight', 'Roboto-Medium.ttf');
    }
    for (var weight in [700, 800, 900]) {
      await _loadFont('${family}_$weight', 'Roboto-Bold.ttf');
    }
  }
}

/// Shows [screen] in the app theme on a [size] phone (logical pixels).
/// [keyboard] is the height the on-screen keyboard covers.
Future<void> pumpScreen(WidgetTester tester, Widget screen,
    {Size size = const Size(390, 844), double keyboard = 0}) async {
  const double ratio = 2;
  tester.view.devicePixelRatio = ratio;
  tester.view.physicalSize = size * ratio;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard * ratio);
  addTearDown(tester.view.reset);
  addTearDown(Fakes.reset);

  await tester.pumpWidget(RepaintBoundary(
    key: _screenKey,
    child: MaterialApp(theme: AppTheme.light(), debugShowCheckedModeBanner: false, home: screen),
  ));
  await settle(tester);
}

/// Lets streams and fake calls finish.
Future<void> settle(WidgetTester tester) async {
  for (int i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 400));
  }
}

/// Saves the current screen as screenshots/[name].png when screenshots are on.
Future<void> takeScreenshot(WidgetTester tester, String name) async {
  if (!screenshotsOn) return;
  await settle(tester);
  var boundary = _screenKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
  await tester.runAsync(() async {
    ui.Image image = await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
    ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
    var file = File('../screenshots/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(png!.buffer.asUint8List());
  });
}
