import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show kIsWeb;

import 'backend.dart';
import 'emulators_stub.dart' if (dart.library.js_interop) 'emulators_web.dart';

/// Runs the web app against the local Firebase emulators instead of the real
/// project: build with `--dart-define=USE_EMULATORS=true` (functions/scripts/
/// emulators.sh does this). Off otherwise; as a compile-time constant, normal
/// builds don't contain the switch at all.
///
/// The app talks to the emulators through emulator-proxy.js, which serves the
/// app too, so everything goes to the page's own origin. That keeps it to one
/// port, and works over the HTTPS that Codespaces port forwarding uses.
const bool useEmulators = bool.fromEnvironment('USE_EMULATORS');

/// The emulators' project. demo- projects can't reach any real Firebase
/// service, so nothing done in this build touches production.
const String emulatorProjectId = 'demo-chekkin-dev';

/// Made-up options for the emulators, so even a misrouted request can't
/// reach the real project.
const FirebaseOptions emulatorFirebaseOptions = FirebaseOptions(
  apiKey: 'demo-api-key',
  appId: '1:000000000000:web:0000000000000000',
  messagingSenderId: '000000000000',
  projectId: emulatorProjectId,
);

/// The functions to call: the real ones, or the emulator's through the proxy.
FirebaseFunctions get cloudFunctions => functionsOverride ?? (useEmulators
    ? FirebaseFunctions.instanceFor(region: '${Uri.base.origin}/$emulatorProjectId/us-central1')
    : FirebaseFunctions.instance);

/// Points Auth and Firestore at the emulators. Call before using either.
Future<void> connectToEmulators() async {
  if (!kIsWeb) throw UnsupportedError('The emulator build is web-only.');
  Uri origin = Uri.base;
  connectAuthEmulator(origin.origin);
  // Signed in per tab, not per browser, so two windows can be two users.
  await FirebaseAuth.instance.setPersistence(Persistence.SESSION);
  FirebaseFirestore.instance.settings = Settings(
    host: origin.hasPort ? '${origin.host}:${origin.port}' : origin.host,
    sslEnabled: origin.scheme == 'https',
    persistenceEnabled: false,
  );
}

/// The middle of the emulator's test places: scripts/emulator-seed.js puts
/// them around it (Pizzeria La Fleur 8 m north), and the map's "DEV: Go to
/// the test places" teleports here. Keep in sync with TEST_AREA there.
const double emulatorTestAreaLatitude = 59.3165;
const double emulatorTestAreaLongitude = 18.0715;

/// [data] for a callable that looks places up (nearbyPlaces, performCheckIn,
/// requestBusinessClaim). In the emulator build it asks the functions
/// emulator for its stand-in places (see useEmulatorPlaces in
/// functions/index.js); normal builds send [data] unchanged, and as
/// [useEmulators] is a compile-time constant they don't contain the flag.
Map<String, Object?> withEmulatorPlaces(Map<String, Object?> data) =>
    useEmulators ? {...data, 'useEmulatorPlaces': true} : data;
