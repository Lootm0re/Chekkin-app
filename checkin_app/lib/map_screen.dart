import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'app_only.dart';
import 'check_in_place.dart';
import 'emulators.dart';
import 'group_check_in.dart';
import 'location_access.dart';
import 'pin_icons.dart';
import 'place_screen.dart';
import 'theme.dart';

class MapScreen extends StatefulWidget {
  /// Spendable points, for the points pill.
  final int userPoints;

  const MapScreen({super.key, this.userPoints = 0});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? mapController;
  Position? currentPosition;
  Set<Marker> markers = {};

  // Pin icons: one per place category, grey ones for businesses that aren't
  // partners yet, and the dev pretend location.
  static const PinStyle _devPin = PinStyle(AppColors.lightPurple, Icons.my_location_rounded);
  final Future<Map<PinStyle, BitmapDescriptor>> _pinIcons = loadPinIcons([
    for (final category in PlaceCategory.values) ...[
      PinStyle(category.color, category.icon),
      PinStyle(AppColors.inactive, category.icon),
    ],
    _devPin,
  ]);
  // _pinIcons once loaded, for building the dev marker.
  Map<PinStyle, BitmapDescriptor> pinIcons = {};

  // The place in range that the card at the bottom is showing, and how far
  // away it was when picked.
  CheckInPlace? selectedPlace;
  double selectedDistance = 0;
  // Why the last check-in from the card failed (touristic places; partner
  // places check in on PlaceScreen, which shows its own errors).
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

  // A group check-in the user started or joined, shown until dismissed.
  String? activeGroupId;
  final FirebaseFunctions functions = cloudFunctions;

  static const double checkInRangeMeters = 22;

  // Soft green land, light blue water and white roads. Also hides Google's
  // own place icons: tapping them opens Google's info popup, which the app
  // can't hook into. The app shows check-in places as markers.
  static const String _mapStyle = '['
      '{"featureType":"landscape","elementType":"geometry","stylers":[{"color":"#dff3e3"}]},'
      '{"featureType":"poi","elementType":"geometry","stylers":[{"color":"#cdeed5"}]},'
      '{"featureType":"water","elementType":"geometry","stylers":[{"color":"#bfe3ff"}]},'
      '{"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#ffffff"}]},'
      '{"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#e4e0f2"}]},'
      '{"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#6b6794"}]},'
      '{"featureType":"administrative","elementType":"labels.text.fill","stylers":[{"color":"#231a5c"}]},'
      '{"featureType":"poi","elementType":"labels","stylers":[{"visibility":"off"}]},'
      '{"featureType":"transit","elementType":"labels.icon","stylers":[{"visibility":"off"}]}]';

  @override
  void initState() {
    super.initState();
    _pinIcons.then((icons) {
      if (mounted) setState(() => pinIcons = icons);
    });
    _getUserLocation();
  }

  BitmapDescriptor _pinIcon(PinStyle style) => pinIcons[style] ?? BitmapDescriptor.defaultMarker;

  @override
  void dispose() {
    mapMessageTimer?.cancel();
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
      List places = useEmulators
          ? emulatorNearbyPlaces(position.latitude, position.longitude)
          : (await functions.httpsCallable('nearbyPlaces').call({
              'latitude': position.latitude,
              'longitude': position.longitude,
            }))
              .data['places'];
      await _pinIcons;
      if (!mounted) return;

      Set<Marker> newMarkers = {};
      for (var data in places) {
        CheckInPlace place = CheckInPlace.fromMap(data);
        newMarkers.add(
          Marker(
            markerId: MarkerId(place.id),
            position: place.position,
            icon: _pinIcon(place.pinStyle),
            anchor: const Offset(0.5, 0.5),
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
      if (selectedPlace?.id != place.id) checkInError = null;
      setState(() {
        selectedPlace = place;
        selectedDistance = distance;
      });
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

  /// Checks in at [place] with the staff's [code] (partner places) and
  /// [friendUids] to invite. On success the card closes and a group check-in
  /// shows its progress; the caller shows the confirmation.
  Future<CheckInOutcome> _performCheckIn(CheckInPlace place, {String? code, List<String> friendUids = const []}) async {
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
        'placeId': place.id,
        ..._deviceFix(position),
        if (place.requiresCode) 'code': code ?? '',
        if (place.requiresCode && friendUids.isNotEmpty) 'friendUids': friendUids,
      });
      String? groupId = response.data['groupId'];
      if (mounted) {
        setState(() {
          selectedPlace = null;
          if (groupId != null) activeGroupId = groupId;
        });
      }
      return CheckInOutcome.succeeded(
        placeName: response.data['placeName'] ?? place.name,
        pointsEarned: (response.data['pointsEarned'] as num).toInt(),
        groupId: groupId,
        pointsNote: _pointsNote(response.data),
        invited: place.requiresCode ? friendUids.length : 0,
      );
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Check-in failed: [${e.code}] ${e.message}');
      return CheckInOutcome.failed(e.message ?? 'Check-in failed. Please try again.');
    } catch (e) {
      debugPrint('Check-in failed: $e');
      return const CheckInOutcome.failed('Something went wrong. Please check your connection and try again.');
    }
  }

  /// The card's Check in button: places without a code check in right
  /// here; partner places open PlaceScreen for the code and friends.
  Future<void> _onCheckInPressed() async {
    CheckInPlace? place = selectedPlace;
    if (place == null || isCheckingIn) return;

    if (place.requiresCode) {
      CheckInOutcome? outcome = await Navigator.of(context).push<CheckInOutcome>(MaterialPageRoute(
        builder: (_) => PlaceScreen(
          place: place,
          distanceMeters: selectedDistance,
          onCheckIn: ({required code, required friendUids}) =>
              _performCheckIn(place, code: code, friendUids: friendUids),
        ),
      ));
      if (outcome != null && mounted) _showOutcome(outcome);
      return;
    }

    setState(() {
      isCheckingIn = true;
      checkInError = null;
    });
    CheckInOutcome outcome = await _performCheckIn(place);
    if (!mounted) return;
    // On failure the card stays open, so it can be retried.
    setState(() {
      isCheckingIn = false;
      checkInError = outcome.error;
    });
    if (outcome.succeeded) _showOutcome(outcome);
  }

  void _showOutcome(CheckInOutcome outcome) {
    int invited = outcome.invited;
    String? pointsNote = outcome.pointsNote;
    String? groupNote = outcome.groupId == null
        ? null
        : 'You invited $invited friend${invited == 1 ? '' : 's'}. They have 10 minutes to join from their '
            'own phones here, and everyone\'s points grow with the group: up to '
            '${formatMultiplier(groupMultipliers[invited + 1]!)} if they all join.';
    _showCheckInConfirmation(
      outcome.placeName,
      outcome.pointsEarned!,
      note: pointsNote == null || groupNote == null ? pointsNote ?? groupNote : '$pointsNote\n\n$groupNote',
    );
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
        icon: const IconSquare(color: AppColors.mint, icon: Icons.check_rounded, size: 64),
        title: Text(title, textAlign: TextAlign.center),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(placeName, textAlign: TextAlign.center, style: AppText.body(size: 16, color: AppColors.muted)),
            const SizedBox(height: 14),
            ColorChip(label: '+$pointsEarned points', color: AppColors.yellow),
            if (note != null) ...[
              const SizedBox(height: 16),
              Text(note, textAlign: TextAlign.center, style: AppText.body(size: 15)),
            ],
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          ElevatedButton(
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
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const IconSquare(color: AppColors.coral, icon: Icons.location_off_rounded, size: 88),
                  const SizedBox(height: 20),
                  Text('Where are you?', style: AppText.heading(size: 26), textAlign: TextAlign.center),
                  const SizedBox(height: 10),
                  Text(locationError!, textAlign: TextAlign.center, style: AppText.body(size: 16)),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _getUserLocation,
                    style: ElevatedButton.styleFrom(minimumSize: const Size(220, AppShapes.buttonHeight)),
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
        ),
      );
    }

    if (currentPosition == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(currentPosition!.latitude, currentPosition!.longitude),
              zoom: 15,
            ),
            myLocationEnabled: true,
            style: _mapStyle,
            markers: {
              ...markers,
              if (devFakePosition != null)
                Marker(
                  markerId: const MarkerId('dev-fake-position'),
                  position: LatLng(devFakePosition!.latitude, devFakePosition!.longitude),
                  icon: _pinIcon(_devPin),
                  anchor: const Offset(0.5, 0.5),
                  infoWindow: const InfoWindow(title: 'DEV: Pretend location'),
                ),
            },
            onMapCreated: (controller) => mapController = controller,
            onLongPress: devTools ? _devTeleport : null,
          ),

          // Top bar, dev hint, legend, messages, group progress and invites.
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: _placesPill()),
                      const SizedBox(width: 10),
                      _pointsPill(),
                    ],
                  ),
                  if (devTools)
                    IgnorePointer(
                      child: Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: ShapeDecoration(color: AppColors.ink, shape: const StadiumBorder()),
                        child: Text(
                          devFakePosition != null
                              ? 'DEV: Using a pretend location. Long-press to move it.'
                              : 'DEV: Long-press the map to pretend you\'re there.',
                          style: AppText.body(size: 14, weight: FontWeight.w700, color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  const IgnorePointer(child: Center(child: PlaceCategoryLegend())),
                  if (mapMessage != null) Padding(padding: const EdgeInsets.only(top: 8), child: _messageBanner()),
                  if (activeGroupId != null)
                    ActiveGroupCard(groupId: activeGroupId!, onDismiss: () => setState(() => activeGroupId = null)),
                  GroupInviteCards(onJoin: _joinGroup),
                ],
              ),
            ),
          ),

          if (selectedPlace != null)
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: _selectedPlaceCard(selectedPlace!),
            ),
        ],
      ),
    );
  }

  /// White pill at the top: what the map shows, and the refresh button.
  Widget _placesPill() {
    return Container(
      height: AppShapes.buttonHeight,
      padding: const EdgeInsets.only(left: 18, right: 4),
      decoration: ShapeDecoration(
        color: AppColors.card,
        shape: const StadiumBorder(),
        shadows: AppShapes.softShadow,
      ),
      child: Row(
        children: [
          const Icon(Icons.near_me_rounded, color: AppColors.purple),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Places near you',
              style: AppText.body(size: 16, weight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (devFakePosition != null)
            IconButton(
              tooltip: 'DEV: Back to real location',
              icon: const Icon(Icons.gps_off_rounded, color: AppColors.error),
              onPressed: _devClearTeleport,
            ),
          IconButton(
            tooltip: 'Find places near me',
            icon: isLoadingPlaces
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Icon(Icons.refresh_rounded, color: AppColors.ink),
            onPressed: isLoadingPlaces ? null : _getUserLocation,
          ),
        ],
      ),
    );
  }

  /// Yellow pill with the user's spendable points.
  Widget _pointsPill() {
    return Semantics(
      label: '${widget.userPoints} points',
      child: Container(
        height: AppShapes.buttonHeight,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: ShapeDecoration(
          color: AppColors.yellow,
          shape: const StadiumBorder(),
          shadows: AppShapes.softShadow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star_rounded, color: AppColors.ink),
            const SizedBox(width: 6),
            Text('${widget.userPoints}', style: AppText.heading(size: 20, weight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _messageBanner() {
    return Material(
      color: AppColors.ink,
      elevation: 4,
      shadowColor: AppColors.ink.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
      child: Padding(
        padding: const EdgeInsets.only(left: 18),
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(mapMessage!, style: AppText.body(size: 15, color: Colors.white)),
              ),
            ),
            if (mapMessageAction != null)
              TextButton(
                onPressed: mapMessageAction,
                style: TextButton.styleFrom(foregroundColor: AppColors.yellow),
                child: Text(mapMessageActionLabel ?? 'OK'),
              ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close_rounded, color: Colors.white70),
              onPressed: _hideMapMessage,
            ),
          ],
        ),
      ),
    );
  }

  /// The place in range: name, category, distance, points and Check in.
  Widget _selectedPlaceCard(CheckInPlace place) {
    String? partnerNote = place.partner
        ? '${tierLabels[place.tier] ?? 'Partner'} partner'
            '${place.budgetUsedUp ? ' · monthly bonus used up' : ''} · code from the staff needed'
        : null;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppShapes.cardRadius),
        boxShadow: [
          BoxShadow(color: AppColors.ink.withValues(alpha: 0.16), blurRadius: 30, offset: const Offset(0, 10)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconSquare(color: place.category.color, icon: place.category.icon, size: 52),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(place.name, style: AppText.heading(size: 20), maxLines: 2, overflow: TextOverflow.ellipsis),
                    Text(
                      '${place.category.label} · ${selectedDistance.toStringAsFixed(0)} m away',
                      style: AppText.body(size: 15, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ColorChip(label: '+${place.points} pts', color: AppColors.mint),
            ],
          ),
          if (partnerNote != null) ...[
            const SizedBox(height: 10),
            Text(partnerNote, style: AppText.body(size: 14, color: AppColors.muted)),
          ],
          if (checkInError != null) ...[
            const SizedBox(height: 12),
            ErrorNote(message: checkInError!),
          ],
          const SizedBox(height: 14),
          if (!appOnlyFeaturesAvailable)
            Text(appOnlyMessage, textAlign: TextAlign.center, style: AppText.body(size: 15))
          else
            ElevatedButton(
              onPressed: isCheckingIn ? null : _onCheckInPressed,
              style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 58)),
              child: isCheckingIn
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5), // on the disabled button
                    )
                  : const Text('Check in', style: TextStyle(fontSize: 20)),
            ),
        ],
      ),
    );
  }
}
