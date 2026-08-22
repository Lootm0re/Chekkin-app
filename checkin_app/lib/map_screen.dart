import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_functions/cloud_functions.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? mapController;
  Position? currentPosition;
  Set<Marker> markers = {};

  String? nearbyEligiblePlaceName;
  double? nearbyEligiblePlaceLat;
  double? nearbyEligiblePlaceLng;
  List<String> nearbyEligiblePlaceTypes = [];
  bool isCheckingIn = false;

  final TextEditingController buddyUsernameController = TextEditingController();
  final FirebaseFunctions functions = FirebaseFunctions.instance;

  static const double checkInRangeMeters = 22;

  @override
  void initState() {
    super.initState();
    _getUserLocation();
  }

  Future<void> _getUserLocation() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    Position position = await Geolocator.getCurrentPosition();

    setState(() {
      currentPosition = position;
    });

    _loadNearbyPlaces(position);
  }

  Future<void> _loadNearbyPlaces(Position position) async {
    List<Map<String, dynamic>> nearbyPlaces = [
      {'name': 'City Museum', 'lat': position.latitude + 0.001, 'lng': position.longitude + 0.001, 'types': ['museum']},
      {'name': 'Riverside Cafe', 'lat': position.latitude - 0.001, 'lng': position.longitude + 0.002, 'types': ['cafe']},
    ];

    Set<Marker> newMarkers = {};
    for (var place in nearbyPlaces) {
      newMarkers.add(
        Marker(
          markerId: MarkerId(place['name']),
          position: LatLng(place['lat'], place['lng']),
          infoWindow: InfoWindow(title: place['name']),
          onTap: () => _selectPlace(place['name'], place['lat'], place['lng'], List<String>.from(place['types'])),
        ),
      );
    }

    setState(() {
      markers = newMarkers;
    });
  }

  void _selectPlace(String placeName, double placeLat, double placeLng, List<String> placeTypes) {
    double distance = Geolocator.distanceBetween(
      currentPosition!.latitude,
      currentPosition!.longitude,
      placeLat,
      placeLng,
    );

    if (distance <= checkInRangeMeters) {
      setState(() {
        nearbyEligiblePlaceName = placeName;
        nearbyEligiblePlaceLat = placeLat;
        nearbyEligiblePlaceLng = placeLng;
        nearbyEligiblePlaceTypes = placeTypes;
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Too far away - get within ${checkInRangeMeters.toInt()}m to check in '
            '(currently ${distance.toStringAsFixed(0)}m away)',
          ),
        ),
      );
    }
  }

  void _handleCheckIn() async {
    if (nearbyEligiblePlaceName == null || isCheckingIn) return;

    setState(() => isCheckingIn = true);

    try {
      HttpsCallable callable = functions.httpsCallable('performCheckIn');
      final response = await callable.call({
        'locationId': nearbyEligiblePlaceName,
        'deviceLatitude': currentPosition!.latitude,
        'deviceLongitude': currentPosition!.longitude,
        'placeLatitude': nearbyEligiblePlaceLat,
        'placeLongitude': nearbyEligiblePlaceLng,
        'placeTypes': nearbyEligiblePlaceTypes,
      });

      int pointsEarned = response.data['pointsEarned'];

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Checked in at $nearbyEligiblePlaceName! +$pointsEarned points')),
      );

      String buddyUsername = buddyUsernameController.text.trim();
      if (buddyUsername.isNotEmpty) {
        try {
          HttpsCallable buddyCallable = functions.httpsCallable('attemptBuddyCheckIn');
          final buddyResponse = await buddyCallable.call({
            'locationId': nearbyEligiblePlaceName,
            'friendUsername': buddyUsername,
          });

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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.message ?? 'Buddy check-in failed.')),
          );
        }
      }
    } on FirebaseFunctionsException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Check-in failed. Please try again.')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong. Please check your connection and try again.')),
      );
    } finally {
      setState(() {
        isCheckingIn = false;
        nearbyEligiblePlaceName = null;
        buddyUsernameController.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (currentPosition == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Check In')),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(currentPosition!.latitude, currentPosition!.longitude),
              zoom: 15,
            ),
            myLocationEnabled: true,
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