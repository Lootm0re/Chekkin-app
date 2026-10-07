import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'app_only.dart';
import 'check_in_place.dart';
import 'group_check_in.dart';
import 'location_access.dart';
import 'pin_icons.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? mapController;
  Position? currentPosition;
  Set<Marker> markers = {};

  // Pin icons by hue: one per place category, grey for businesses that
  // aren't partners yet, and the dev pretend location.
  static const double _devPinHue = BitmapDescriptor.hueAzure;
  final Future<Map<double, BitmapDescriptor>> _pinIcons = loadPinIcons([
    for (final category in PlaceCategory.values) category.markerHue,
    greyPinHue,
    _devPinHue,
  ]);
  // _pinIcons once loaded, for building the dev marker.
  Map<double, BitmapDescriptor> pinIcons = {};

  // The place in range that the check-in panel is showing.
  CheckInPlace? selectedPlace;
  // Why the last check-in attempt failed, shown in the panel.
  String? checkInError;

  // Messages are shown in a banner on the map, not snackbars: on web the
  // Google Map is drawn over snackbars, so they never appeared.
  String? mapMessage;
  String? mapMessageActionLabel;
  VoidCallback? mapMessageAction;
  Timer? mapMessageTimer;
  bool isCheckingIn = false;
  bool isLoadingPlaces = false;

  String? locationError;
  bool locationPermanentlyDenied = false;

  // Dev tools only: used instead of the real location while set.
  Position? devFakePosition;

  // Friends to invite to a group check-in (id -> username); code places only.
  Map<String, String> groupFriends = {};
  // A group check-in the user started or joined, shown until dismissed.
  String? activeGroupId;
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
    _pinIcons.then((icons) {
      if (mounted) setState(() => pinIcons = icons);
    });
    _getUserLocation();
  }

  BitmapDescriptor _pinIcon(double hue) => pinIcons[hue] ?? BitmapDescriptor.defaultMarkerWithHue(hue);

  @override
  void dispose() {
    mapMessageTimer?.cancel();
    codeController.dispose();
    super.dispose();
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

  /// [position] as performCheckIn and joinGroup expect it. The server rejects
  /// fixes that are mocked, too rough or too old.
  Map<String, Object> _deviceFix(Position position) {
    return {
      'deviceLatitude': position.latitude,
      'deviceLongitude': position.longitude,
      'deviceAccuracy': position.accuracy,
      'deviceTimestamp': position.timestamp.millisecondsSinceEpoch,
      'deviceIsMocked': position.isMocked,
    };
  }

  /// Dev tools only: pretend to be at [target] until the override is cleared.
  /// The server only accepts this mocked position from accounts listed with
  /// functions/scripts/dev-testers.js.
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
      await _pinIcons;
      if (!mounted) return;

      List places = response.data['places'];
      Set<Marker> newMarkers = {};
      for (var data in places) {
        CheckInPlace place = CheckInPlace.fromMap(data);
        newMarkers.add(
          Marker(
            markerId: MarkerId(place.id),
            position: place.position,
            icon: _pinIcon(place.pinHue),
            infoWindow: InfoWindow(title: place.name, snippet: place.summary),
            onTap: () => _selectPlace(place),
          ),
        );
      }

      setState(() => markers = newMarkers);
      if (newMarkers.isEmpty) {
        _showMapMessage('No check-in places found nearby.');
      }
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Loading nearby places failed: [${e.code}] ${e.message}');
      _showMapMessage(e.message ?? 'Couldn\'t load nearby places.');
    } catch (e) {
      debugPrint('Loading nearby places failed: $e');
      _showMapMessage('Couldn\'t load nearby places. Please check your connection.');
    } finally {
      if (mounted) setState(() => isLoadingPlaces = false);
    }
  }

  void _showMapMessage(String message, {String? actionLabel, VoidCallback? onAction}) {
    if (!mounted) return;
    mapMessageTimer?.cancel();
    setState(() {
      mapMessage = message;
      mapMessageActionLabel = actionLabel;
      mapMessageAction = onAction;
    });
    mapMessageTimer = Timer(Duration(seconds: onAction != null ? 10 : 6), _hideMapMessage);
  }

  void _hideMapMessage() {
    mapMessageTimer?.cancel();
    if (mounted) setState(() => mapMessage = null);
  }

  Future<void> _selectPlace(CheckInPlace place) async {
    if (place.closed) {
      setState(() => selectedPlace = null);
      _showMapMessage('${place.name} isn\'t a partner yet, so you can\'t check in here.');
      return;
    }

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
      if (selectedPlace?.id != place.id) {
        codeController.clear();
        checkInError = null;
        groupFriends = {};
      }
      setState(() => selectedPlace = place);
      _hideMapMessage();
    } else {
      setState(() => selectedPlace = null);
      String message = 'Too far away - get within ${checkInRangeMeters.toInt()}m to check in '
          '(currently ${distance.toStringAsFixed(0)}m away)';
      if (devTools) {
        _showMapMessage(message, actionLabel: 'DEV: Teleport here', onAction: () {
          _hideMapMessage();
          _devTeleport(place.position);
          _selectPlace(place);
        });
      } else {
        _showMapMessage(message);
      }
    }
  }

  void _handleCheckIn() async {
    CheckInPlace? place = selectedPlace;
    if (place == null || isCheckingIn) return;

    setState(() {
      isCheckingIn = true;
      checkInError = null;
    });

    String placeId = place.id;
    String placeName = place.name;
    List<String> friendUids = place.requiresCode ? groupFriends.keys.toList() : [];
    int? pointsEarned;
    String? groupId;
    String? pointsNote;

    // The position from when the place was picked may be minutes old, and the
    // server only accepts a recent one.
    Position position = currentPosition!;
    try {
      position = await _readPosition();
    } catch (e) {
      debugPrint('Refreshing location failed: $e');
    }

    try {
      HttpsCallable callable = functions.httpsCallable('performCheckIn');
      final response = await callable.call({
        'placeId': placeId,
        ..._deviceFix(position),
        if (place.requiresCode) 'code': codeController.text.trim(),
        if (friendUids.isNotEmpty) 'friendUids': friendUids,
      });

      pointsEarned = (response.data['pointsEarned'] as num).toInt();
      placeName = response.data['placeName'] ?? placeName;
      groupId = response.data['groupId'];
      pointsNote = _pointsNote(response.data);
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Check-in failed: [${e.code}] ${e.message}');
      checkInError = e.message ?? 'Check-in failed. Please try again.';
    } catch (e) {
      debugPrint('Check-in failed: $e');
      checkInError = 'Something went wrong. Please check your connection and try again.';
    } finally {
      // On failure the panel stays open, so a mistyped code can be retried.
      if (mounted) {
        setState(() {
          isCheckingIn = false;
          codeController.clear();
          if (pointsEarned != null) {
            selectedPlace = null;
            groupFriends = {};
            if (groupId != null) activeGroupId = groupId;
          }
        });
      }
    }

    if (pointsEarned != null && mounted) {
      int invited = friendUids.length;
      String? groupNote = groupId == null
          ? null
          : 'You invited $invited friend${invited == 1 ? '' : 's'}. They have 10 minutes to join from their '
              'own phones here, and everyone\'s points grow with the group: up to '
              '${formatMultiplier(groupMultipliers[invited + 1]!)} if they all join.';
      _showCheckInConfirmation(
        placeName,
        pointsEarned,
        note: pointsNote == null || groupNote == null ? pointsNote ?? groupNote : '$pointsNote\n\n$groupNote',
      );
    }
  }

  /// Why a check-in earned less than usual, if it did.
  String? _pointsNote(Map data) {
    if (data['capped'] == true) {
      return 'You\'ve reached today\'s limit of ${data['dailyPartnerPointsCap']} points from partner '
          'check-ins, so this one earned less. The limit resets at midnight.';
    }
    if (data['budgetUsedUp'] == true) {
      return 'This partner\'s monthly bonus is used up, so check-ins here earn the touristic rate until next month.';
    }
    return null;
  }

  /// Joins a friend's group check-in from the user's current position.
  Future<void> _joinGroup(String groupId) async {
    if (!appOnlyFeaturesAvailable) {
      _showMapMessage(appOnlyMessage);
      return;
    }
    try {
      Position position = await _readPosition();
      final response = await functions.httpsCallable('joinGroup').call({
        'groupId': groupId,
        ..._deviceFix(position),
      });
      if (!mounted) return;
      int size = response.data['groupSize'];
      setState(() => activeGroupId = groupId);
      String? pointsNote = _pointsNote(response.data);
      _showCheckInConfirmation(
        response.data['placeName'],
        (response.data['pointsEarned'] as num).toInt(),
        title: 'Joined the group!',
        note: '${pointsNote == null ? '' : '$pointsNote\n\n'}'
            'Group of $size: ${formatMultiplier(response.data['multiplier'])} points for everyone. '
            'You\'ll get more if others join.',
      );
    } on LocationAccessException catch (e) {
      _showMapMessage(e.message);
    } on FirebaseFunctionsException catch (e) {
      _showMapMessage(e.message ?? 'Couldn\'t join that group.');
    } catch (e) {
      debugPrint('Joining group failed: $e');
      _showMapMessage('Couldn\'t join that group. Please check your connection.');
    }
  }

  // A dialog rather than a snackbar: the snackbar shows on the home screen's
  // Scaffold at the bottom of the map, where it was easy to miss.
  void _showCheckInConfirmation(String placeName, int pointsEarned, {String title = 'Checked in!', String? note}) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: Colors.green, size: 48),
        title: Text(title),
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
            if (note != null) ...[
              const SizedBox(height: 16),
              Text(note, textAlign: TextAlign.center),
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
                  icon: _pinIcon(_devPinHue),
                  infoWindow: const InfoWindow(title: 'DEV: Pretend location'),
                ),
            },
            onMapCreated: (controller) => mapController = controller,
            onLongPress: devTools ? _devTeleport : null,
          ),

          // Legend, messages, group progress and invites, top to bottom.
          Positioned(
            top: devTools ? 44 : 8,
            left: 8,
            right: 8,
            child: Column(
              children: [
                const IgnorePointer(child: Center(child: PlaceCategoryLegend())),
                if (mapMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Material(
                      color: Colors.grey[900],
                      elevation: 4,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: Text(mapMessage!, style: const TextStyle(color: Colors.white)),
                              ),
                            ),
                            if (mapMessageAction != null)
                              TextButton(onPressed: mapMessageAction, child: Text(mapMessageActionLabel ?? 'OK')),
                            IconButton(
                              tooltip: 'Dismiss',
                              icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                              onPressed: _hideMapMessage,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (activeGroupId != null)
                  ActiveGroupCard(groupId: activeGroupId!, onDismiss: () => setState(() => activeGroupId = null)),
                GroupInviteCards(onJoin: _joinGroup),
              ],
            ),
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
                  if (checkInError != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red[50],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red[300]!),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline, color: Colors.red[700]),
                          const SizedBox(width: 8),
                          Expanded(child: Text(checkInError!, style: TextStyle(color: Colors.red[900]))),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  // Tier and what the check-in is worth.
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
                    ),
                    child: Text(selectedPlace!.summary, style: const TextStyle(fontSize: 13)),
                  ),
                  const SizedBox(height: 8),
                  if (appOnlyFeaturesAvailable && selectedPlace!.requiresCode) ...[
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
                  // Group check-ins are only at partner businesses.
                  if (appOnlyFeaturesAvailable && selectedPlace!.requiresCode) ...[
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 44),
                      ),
                      icon: const Icon(Icons.group_add),
                      label: Text(
                        groupFriends.isEmpty
                            ? 'Check in with friends (optional)'
                            : 'With ${groupFriends.values.map((u) => '@$u').join(', ')}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      onPressed: isCheckingIn
                          ? null
                          : () async {
                              var picked = await pickGroupFriends(context, groupFriends);
                              if (picked != null && mounted) setState(() => groupFriends = picked);
                            },
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (!appOnlyFeaturesAvailable)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
                      ),
                      child: const Text(appOnlyMessage, textAlign: TextAlign.center),
                    )
                  else
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