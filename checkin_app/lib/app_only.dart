import 'package:flutter/foundation.dart' show kIsWeb;

/// Dev-only tools, such as the location override for testing check-ins away
/// from a place. Off unless built with `--dart-define=DEV_TOOLS=true`; as a
/// compile-time constant, release builds without it don't contain the dev
/// code at all.
const bool devTools = bool.fromEnvironment('DEV_TOOLS');

/// Whether this build can check in and use the business tools. The product
/// is app-only: web builds are just for testing with DEV_TOOLS, and the
/// server refuses these calls from web unless the account is a dev tester.
const bool appOnlyFeaturesAvailable = !kIsWeb || devTools;

const String appOnlyMessage = 'Check-ins and business tools work in the Chekkin app for iPhone and Android.';
