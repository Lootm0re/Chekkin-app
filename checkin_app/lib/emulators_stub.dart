/// Only the web build can use the emulators (see emulators.dart).
void connectAuthEmulator(String origin) {
  throw UnsupportedError('The emulator build is web-only.');
}
