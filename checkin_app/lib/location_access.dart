import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Thrown when the device position can't be read. [message] is safe to show
/// to the user as-is.
class LocationAccessException implements Exception {
  final String message;

  /// True when the fix is in the app's system settings and
  /// [Geolocator.openAppSettings] can take the user there (never on web).
  final bool canOpenSettings;

  const LocationAccessException(this.message, {this.canOpenSettings = false});

  @override
  String toString() => 'LocationAccessException: $message';
}

/// Gets the current position, asking for location permission if needed.
///
/// Throws [LocationAccessException] if location is unavailable or denied.
Future<Position> getPositionWithPermission() {
  return kIsWeb ? _getWebPosition() : _getNativePosition();
}

Future<Position> _getWebPosition() async {
  // Browsers only expose geolocation on secure origins, and refuse it
  // without showing a prompt anywhere else.
  bool isLocalhost = const ['localhost', '127.0.0.1', '[::1]', '::1'].contains(Uri.base.host);
  if (Uri.base.scheme != 'https' && !isLocalhost) {
    throw const LocationAccessException(
      'Location only works over a secure connection. Open the app from an '
      'https:// address and try again.',
    );
  }

  // Don't use Geolocator.checkPermission/requestPermission on web: they rely
  // on the Permissions API (which can report "denied" without ever having
  // prompted, notably in Safari) and requestPermission hides the browser's
  // real error. getCurrentPosition is what makes the browser show its prompt.
  try {
    // The timeout includes time spent on the permission prompt, so it's
    // generous. (LocationSettings.timeLimit is mis-converted on web.)
    return await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 60));
  } on PermissionDeniedException catch (e) {
    debugPrint('Geolocation denied by browser: ${e.message}');
    throw const LocationAccessException(
      'Location access is blocked for this site. Allow location in your '
      'browser\'s website settings (Safari: Settings for This Website > '
      'Location) and make sure Location Services is on for your browser, '
      'then try again.',
    );
  } catch (e) {
    debugPrint('Geolocation failed: $e');
    throw const LocationAccessException('Couldn\'t get your location. Please try again.');
  }
}

Future<Position> _getNativePosition() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw const LocationAccessException('Location services are turned off. Turn them on and try again.');
  }

  LocationPermission permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.deniedForever) {
    throw const LocationAccessException(
      'Location permission is blocked. Enable it in Settings and try again.',
      canOpenSettings: true,
    );
  }
  if (permission == LocationPermission.denied) {
    throw const LocationAccessException('Location permission is needed for this. Please allow it and try again.');
  }

  try {
    return await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 10));
  } catch (e) {
    debugPrint('Geolocation failed: $e');
    throw const LocationAccessException('Couldn\'t get your location. Please try again.');
  }
}
