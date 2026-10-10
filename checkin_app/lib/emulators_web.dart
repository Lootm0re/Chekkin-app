import 'package:firebase_auth_web/firebase_auth_web.dart';

/// FirebaseAuth.useAuthEmulator always uses http://, which an HTTPS page
/// (such as a Codespaces forwarded port) can't call, so this connects the
/// underlying JS SDK with the page's own origin instead.
void connectAuthEmulator(String origin) {
  FirebaseAuthWeb.instance.delegate.useAuthEmulator(origin);
}
