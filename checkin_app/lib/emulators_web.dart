import 'dart:js_interop';

import 'package:firebase_auth_web/firebase_auth_web.dart';

/// FirebaseAuth.useAuthEmulator always uses http://, which an HTTPS page
/// (such as a Codespaces forwarded port) can't call, so this connects the
/// underlying JS SDK with the page's own origin instead.
void connectAuthEmulator(String origin) {
  FirebaseAuthWeb.instance.delegate.useAuthEmulator(origin);
  // The SDK's "Running in emulator mode" strip covers the tab bar; the app's
  // EMULATOR ribbon marks the build instead.
  _head.insertAdjacentHTML('beforeend', '<style>.firebase-emulator-warning{display:none !important}</style>');
}

@JS('document.head')
external _Element get _head;

extension type _Element(JSObject _) implements JSObject {
  external void insertAdjacentHTML(String position, String text);
}
