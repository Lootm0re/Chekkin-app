import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'location_access.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? mapController;
  Position? currentPosition;
  Set<Marker> markers = {};

  String? nearbyEligiblePlaceId;
  String? nearbyEligiblePlaceName;
  bool isCheckingIn = false;
  bool isLoadingPlaces = false;

  String? locationError;
  bool locationPermanentlyDenied = false;

  final TextEditingController buddyUsernameController = TextEditingController();
  final FirebaseFunctions functions = FirebaseFunctions.instance;

  static const double checkInRangeMeters = 22;

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
      Position position = await getPositionWithPermission();
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
      for (var place in places) {
        String id = place['id'];
        String name = place['name'];
        newMarkers.add(
          Marker(
            markerId: MarkerId(id),
            position: LatLng((place['latitude'] as num).toDouble(), (place['longitude'] as num).toDouble()),
            infoWindow: InfoWindow(title: name),
            onTap: () => _selectPlace(id, name, (place['latitude'] as num).toDouble(), (place['longitude'] as num).toDouble()),
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

  Future<void> _selectPlace(String placeId, String placeName, double placeLat, double placeLng) async {
    // You may have walked here since the map opened, so measure from where
    // you are now.
    try {
      Position position = await getPositionWithPermission();
      if (!mounted) return;
      setState(() => currentPosition = position);
    } catch (e) {
      debugPrint('Refreshing location failed: $e');
    }

    double distance = Geolocator.distanceBetween(
      currentPosition!.latitude,
      currentPosition!.longitude,
      placeLat,
      placeLng,
    );

    if (distance <= checkInRangeMeters) {
      setState(() {
        nearbyEligiblePlaceId = placeId;
        nearbyEligiblePlaceName = placeName;
      });
    } else {
      setState(() {
        nearbyEligiblePlaceId = null;
        nearbyEligiblePlaceName = null;
      });
      _showSnackBar(
        'Too far away - get within ${checkInRangeMeters.toInt()}m to check in '
        '(currently ${distance.toStringAsFixed(0)}m away)',
      );
    }
  }

  void _handleCheckIn() async {
    if (nearbyEligiblePlaceId == null || isCheckingIn) return;

    setState(() => isCheckingIn = true);

    try {
      HttpsCallable callable = functions.httpsCallable('performCheckIn');
      final response = await callable.call({
        'placeId': nearbyEligiblePlaceId,
        'deviceLatitude': currentPosition!.latitude,
        'deviceLongitude': currentPosition!.longitude,
      });

      if (!mounted) return;
      int pointsEarned = response.data['pointsEarned'];

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Checked in at $nearbyEligiblePlaceName! +$pointsEarned points')),
      );

      String buddyUsername = buddyUsernameController.text.trim();
      if (buddyUsername.isNotEmpty) {
        try {
          HttpsCallable buddyCallable = functions.httpsCallable('attemptBuddyCheckIn');
          final buddyResponse = await buddyCallable.call({
            'locationId': nearbyEligiblePlaceId,
            'friendUsername': buddyUsername,
          });

          if (!mounted) return;
          bool matched = buddyResponse.data['matched'];
          if (matched) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Buddy bonus! You and your friend both earned extra points.')),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Waiting for your friend to check in and select you too (within 5 minutes).')),
            );
          }
        } on FirebaseFunctionsException catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.message ?? 'Buddy check-in failed.')),
          );
        }
      }
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Check-in failed. Please try again.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong. Please check your connection and try again.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          isCheckingIn = false;
          nearbyEligiblePlaceId = null;
          nearbyEligiblePlaceName = null;
          buddyUsernameController.clear();
        });
      }
    }
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
            markers: markers,
            onMapCreated: (controller) => mapController = controller,
          ),

          if (nearbyEligiblePlaceName != null)
            Positioned(
              bottom: 30,
              left: 20,
              right: 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
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
                  ElevatedButton(
                    onPressed: isCheckingIn ? null : _handleCheckIn,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      minimumSize: const Size(double.infinity, 0),
                    ),
                    child: isCheckingIn
                        ? const SizedBox(
                            height: 20, width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : Text('Check In at $nearbyEligiblePlaceName'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}