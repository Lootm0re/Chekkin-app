import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'check_in_place.dart';
import 'location_access.dart';

/// Dev-only location override, for testing check-ins away from a place.
/// Off unless built with `--dart-define=DEV_TOOLS=true`; as a compile-time
/// constant, release builds without it don't contain the dev code at all.
const bool devTools = bool.fromEnvironment('DEV_TOOLS');

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? mapController;
  Position? currentPosition;
  Set<Marker> markers = {};

  // The place in range that the check-in panel is showing.
  CheckInPlace? selectedPlace;
  bool isCheckingIn = false;
  bool isLoadingPlaces = false;

  String? locationError;
  bool locationPermanentlyDenied = false;

  // Dev tools only: used instead of the real location while set.
  Position? devFakePosition;

  final TextEditingController buddyUsernameController = TextEditingController();
  final TextEditingController codeController = TextEditingController();
  final FirebaseFunctions functions = FirebaseFunctions.instance;

  static const double checkInRangeMeters = 22;
  static const int codeLength = 6; // keep in sync with BUSINESS_CODE_DIGITS

  // Hides Google's own place icons: tapping them opens Google's info popup,
  // which the app can't hook into. The app shows check-in places as markers.
  static const String _hidePointsOfInterestStyle =
      '[{"featureType":"poi","elementType":"labels","stylers":[{"visibility":"off"}]},'
      '{"featureType":"transit","elementType":"labels.icon","stylers":[{"visibility":"off"}]}]';

  @override
  void initState() {
    super.initState();
    _getUserLocation();
  }

  Future<void> _getUserLocation() async {
    setState(() {
      locationError = null;
      locationPermanentlyDenied = false;
    });

    try {
      Position position = await _readPosition();
      if (!mounted) return;

      setState(() {
        currentPosition = position;
      });

      _loadNearbyPlaces(position);
    } on LocationAccessException catch (e) {
      _showLocationError(e.message, permanentlyDenied: e.canOpenSettings);
    } catch (e) {
      debugPrint('Failed to get location: $e');
      _showLocationError('Couldn\'t get your location. Please try again.');
    }
  }

  Future<Position> _readPosition() async {
    return devFakePosition ?? await getPositionWithPermission();
  }

  /// Dev tools only: pretend to be at [target] until the override is cleared.
  void _devTeleport(LatLng target) {
    setState(() {
      devFakePosition = Position(
        latitude: target.latitude,
        longitude: target.longitude,
        timestamp: DateTime.now(),
        accuracy: 0,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
        isMocked: true,
      );
      currentPosition = devFakePosition;
      selectedPlace = null;
    });
    mapController?.animateCamera(CameraUpdate.newLatLng(target));
    _loadNearbyPlaces(devFakePosition!);
  }

  void _devClearTeleport() {
    setState(() {
      devFakePosition = null;
      selectedPlace = null;
    });
    _getUserLocation().then((_) {
      if (currentPosition != null) {
        mapController?.animateCamera(CameraUpdate.newLatLng(
          LatLng(currentPosition!.latitude, currentPosition!.longitude),
        ));
      }
    });
  }

  void _showLocationError(String message, {bool permanentlyDenied = false}) {
    if (!mounted) return;
    setState(() {
      locationError = message;
      locationPermanentlyDenied = permanentlyDenied;
    });
  }

  /// Shows check-in eligible places near [position] as markers. The server
  /// looks them up with the Places API and filters out ineligible ones.
  Future<void> _loadNearbyPlaces(Position position) async {
    setState(() => isLoadingPlaces = true);
    try {
      final response = await functions.httpsCallable('nearbyPlaces').call({
        'latitude': position.latitude,
        'longitude': position.longitude,
      });
      if (!mounted) return;

      List places = response.data['places'];
      Set<Marker> newMarkers = {};
      for (var data in places) {
        CheckInPlace place = CheckInPlace.fromMap(data);
        newMarkers.add(
          Marker(
            markerId: MarkerId(place.id),
            position: place.position,
            icon: BitmapDescriptor.defaultMarkerWithHue(place.category.markerHue),
            infoWindow: InfoWindow(title: place.name, snippet: place.category.label),
            onTap: () => _selectPlace(place),
          ),
        );
      }

      setState(() => markers = newMarkers);
      if (newMarkers.isEmpty) {
        _showSnackBar('No check-in places found nearby.');
      }
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Loading nearby places failed: [${e.code}] ${e.message}');
      _showSnackBar(e.message ?? 'Couldn\'t load nearby places.');
    } catch (e) {
      debugPrint('Loading nearby places failed: $e');
      _showSnackBar('Couldn\'t load nearby places. Please check your connection.');
    } finally {
      if (mounted) setState(() => isLoadingPlaces = false);
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _selectPlace(CheckInPlace place) async {
    // You may have walked here since the map opened, so measure from where
    // you are now.
    try {
      Position position = await _readPosition();
      if (!mounted) return;
      setState(() => currentPosition = position);
    } catch (e) {
      debugPrint('Refreshing location failed: $e');
    }

    double distance = Geolocator.distanceBetween(
      currentPosition!.latitude,
      currentPosition!.longitude,
      place.position.latitude,
      place.position.longitude,
    );

    if (distance <= checkInRangeMeters) {
      if (selectedPlace?.id != place.id) codeController.clear();
      setState(() => selectedPlace = place);
    } else {
      setState(() => selectedPlace = null);
      String message = 'Too far away - get within ${checkInRangeMeters.toInt()}m to check in '
          '(currently ${distance.toStringAsFixed(0)}m away)';
      if (devTools) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(message),
          action: SnackBarAction(
            label: 'DEV: Teleport here',
            onPressed: () {
              _devTeleport(place.position);
              _selectPlace(place);
            },
          ),
        ));
      } else {
        _showSnackBar(message);
      }
    }
  }

  void _handleCheckIn() async {
    CheckInPlace? place = selectedPlace;
    if (place == null || isCheckingIn) return;

    setState(() => isCheckingIn = true);

    String placeId = place.id;
    String placeName = place.name;
    String buddyUsername = buddyUsernameController.text.trim().replaceFirst('@', '');
    int? pointsEarned;
    String? buddyMessage;

    try {
      HttpsCallable callable = functions.httpsCallable('performCheckIn');
      final response = await callable.call({
        'placeId': placeId,
        'deviceLatitude': currentPosition!.latitude,
        'deviceLongitude': currentPosition!.longitude,
        if (place.requiresCode) 'code': codeController.text.trim(),
      });

      pointsEarned = (response.data['pointsEarned'] as num).toInt();
      placeName = response.data['placeName'] ?? placeName;

      if (buddyUsername.isNotEmpty) {
        buddyMessage = await _attemptBuddyCheckIn(placeId, buddyUsername);
      }
    } on FirebaseFunctionsException catch (e) {
      _showSnackBar(e.message ?? 'Check-in failed. Please try again.');
    } catch (e) {
      debugPrint('Check-in failed: $e');
      _showSnackBar('Something went wrong. Please check your connection and try again.');
    } finally {
      // On failure the panel stays open, so a mistyped code can be retried.
      if (mounted) {
        setState(() {
          isCheckingIn = false;
          codeController.clear();
          if (pointsEarned != null) {
            selectedPlace = null;
            buddyUsernameController.clear();
          }
        });
      }
    }

    if (pointsEarned != null && mounted) {
      _showCheckInConfirmation(placeName, pointsEarned, buddyMessage);
    }
  }

  /// Returns what to tell the user about the buddy check-in. A failure here
  /// doesn't undo the check-in itself, so it's reported rather than thrown.
  Future<String> _attemptBuddyCheckIn(String placeId, String friendUsername) async {
    try {
      final response = await functions.httpsCallable('attemptBuddyCheckIn').call({
        'locationId': placeId,
        'friendUsername': friendUsername,
      });
      if (response.data['matched'] == true) {
        return 'Buddy bonus! You and @$friendUsername each earned '
            '+${response.data['bonusPoints']} points.';
      }
      return 'Waiting for @$friendUsername to check in here and pick you too '
          '(within 5 minutes).';
    } on FirebaseFunctionsException catch (e) {
      return e.message ?? 'Buddy check-in failed.';
    } catch (e) {
      debugPrint('Buddy check-in failed: $e');
      return 'Buddy check-in failed.';
    }
  }

  // A dialog rather than a snackbar: the snackbar shows on the home screen's
  // Scaffold at the bottom of the map, where it was easy to miss.
  void _showCheckInConfirmation(String placeName, int pointsEarned, String? buddyMessage) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: Colors.green, size: 48),
        title: const Text('Checked in!'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(placeName, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 12),
            Text(
              '+$pointsEarned points',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.green[700],
                  ),
            ),
            if (buddyMessage != null) ...[
              const SizedBox(height: 16),
              Text(buddyMessage, textAlign: TextAlign.center),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (currentPosition == null && locationError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Check In')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.location_off, size: 48, color: Colors.grey),
                const SizedBox(height: 16),
                Text(locationError!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _getUserLocation,
                  child: const Text('Try Again'),
                ),
                if (locationPermanentlyDenied)
                  TextButton(
                    onPressed: Geolocator.openAppSettings,
                    child: const Text('Open Settings'),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    if (currentPosition == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Check In'),
        actions: [
          if (devFakePosition != null)
            IconButton(
              tooltip: 'DEV: Back to real location',
              icon: const Icon(Icons.gps_off, color: Colors.deepOrange),
              onPressed: _devClearTeleport,
            ),
          IconButton(
            tooltip: 'Find places near me',
            icon: isLoadingPlaces
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            onPressed: isLoadingPlaces ? null : _getUserLocation,
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(currentPosition!.latitude, currentPosition!.longitude),
              zoom: 15,
            ),
            myLocationEnabled: true,
            style: _hidePointsOfInterestStyle,
            markers: {
              ...markers,
              if (devFakePosition != null)
                Marker(
                  markerId: const MarkerId('dev-fake-position'),
                  position: LatLng(devFakePosition!.latitude, devFakePosition!.longitude),
                  icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
                  infoWindow: const InfoWindow(title: 'DEV: Pretend location'),
                ),
            },
            onMapCreated: (controller) => mapController = controller,
            onLongPress: devTools ? _devTeleport : null,
          ),

          Positioned(
            top: devTools ? 44 : 8,
            left: 8,
            right: 8,
            child: const IgnorePointer(child: Center(child: PlaceCategoryLegend())),
          ),

          if (devTools)
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.deepOrange.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    devFakePosition != null
                        ? 'DEV: Using a pretend location. Long-press to move it.'
                        : 'DEV: Long-press the map to pretend you\'re there.',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),

          if (selectedPlace != null)
            Positioned(
              bottom: 30,
              left: 20,
              right: 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selectedPlace!.requiresCode) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: selectedPlace!.category.color, width: 2),
                      ),
                      child: TextField(
                        controller: codeController,
                        keyboardType: TextInputType.number,
                        maxLength: codeLength,
                        decoration: InputDecoration(
                          hintText: 'Code from the staff at ${selectedPlace!.name}',
                          border: InputBorder.none,
                          counterText: '',
                          icon: const Icon(Icons.pin),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: TextField(
                      controller: buddyUsernameController,
                      decoration: const InputDecoration(
                        hintText: 'Checking in with a friend? Enter their username (optional)',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Rebuilds as the code is typed, to enable the button.
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: codeController,
                    builder: (context, code, _) {
                      bool needsCode = selectedPlace!.requiresCode && code.text.trim().length != codeLength;
                      return ElevatedButton(
                        onPressed: isCheckingIn || needsCode ? null : _handleCheckIn,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          minimumSize: const Size(double.infinity, 0),
                        ),
                        child: isCheckingIn
                            ? const SizedBox(
                                height: 20, width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Text('Check In at ${selectedPlace!.name}'),
                      );
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}