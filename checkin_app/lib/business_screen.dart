import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'check_in_place.dart';
import 'location_access.dart';

/// For restaurant, café and hotel owners: register a place, and once it's
/// approved, show customers the current check-in code.
class BusinessScreen extends StatelessWidget {
  const BusinessScreen({super.key});

  @override
  Widget build(BuildContext context) {
    String uid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      appBar: AppBar(title: const Text('My Business')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('businesses').where('ownerUid', isEqualTo: uid).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            debugPrint('Loading businesses failed: ${snapshot.error}');
            return const Center(child: Text('Couldn\'t load your businesses. Please try again later.'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          var docs = snapshot.data!.docs;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (docs.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(
                    'Run a restaurant, café or hotel? Register it, and once it\'s approved, customers '
                    'enter the code shown here when they check in.',
                  ),
                ),
              for (var doc in docs) _BusinessCard(placeId: doc.id, data: doc.data() as Map<String, dynamic>),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.add_business),
                label: const Text('Register a place'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const _RegisterBusinessScreen()),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BusinessCard extends StatelessWidget {
  final String placeId;
  final Map<String, dynamic> data;

  const _BusinessCard({required this.placeId, required this.data});

  @override
  Widget build(BuildContext context) {
    PlaceCategory category = PlaceCategory.fromName(data['category']);
    String status = data['status'] ?? 'pending';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.location_on, color: category.color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(data['placeName'] ?? 'Unnamed place', style: Theme.of(context).textTheme.titleMedium),
                ),
                Text(category.label, style: TextStyle(color: Colors.grey[600])),
              ],
            ),
            const SizedBox(height: 12),
            switch (status) {
              'approved' => _BusinessCode(placeId: placeId),
              'rejected' => const Text('This registration wasn\'t approved.'),
              _ => const Text('Waiting for approval. Check-ins here stay location-only until then.'),
            },
          ],
        ),
      ),
    );
  }
}

/// The current check-in code, refreshed when it changes.
class _BusinessCode extends StatefulWidget {
  final String placeId;

  const _BusinessCode({required this.placeId});

  @override
  State<_BusinessCode> createState() => _BusinessCodeState();
}

class _BusinessCodeState extends State<_BusinessCode> {
  String? code;
  DateTime? expiresAt;
  String? error;
  Timer? ticker;
  bool isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadCode();
    // Redraws the countdown, and fetches the next code once this one expires.
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (expiresAt != null && DateTime.now().isAfter(expiresAt!)) {
        _loadCode();
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    ticker?.cancel();
    super.dispose();
  }

  Future<void> _loadCode() async {
    if (isLoading) return;
    isLoading = true;
    try {
      final response = await FirebaseFunctions.instance.httpsCallable('getBusinessCode').call({
        'placeId': widget.placeId,
      });
      if (!mounted) return;
      setState(() {
        code = response.data['code'];
        expiresAt = DateTime.fromMillisecondsSinceEpoch((response.data['expiresAt'] as num).toInt());
        error = null;
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => error = e.message ?? 'Couldn\'t load the code.');
    } catch (e) {
      debugPrint('Loading business code failed: $e');
      if (!mounted) return;
      setState(() => error = 'Couldn\'t load the code. Please check your connection.');
    } finally {
      isLoading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (code == null) {
      if (error != null) {
        return Row(
          children: [
            Expanded(child: Text(error!)),
            TextButton(onPressed: _loadCode, child: const Text('Retry')),
          ],
        );
      }
      return const Center(child: CircularProgressIndicator());
    }

    Duration left = expiresAt!.difference(DateTime.now());
    if (left.isNegative) left = Duration.zero;
    String countdown = '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';

    return Column(
      children: [
        const Text('Check-in code for customers'),
        const SizedBox(height: 4),
        Text(
          '${code!.substring(0, 3)} ${code!.substring(3)}',
          style: Theme.of(context).textTheme.displayMedium?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: 4,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
        ),
        Text('Changes in $countdown', style: TextStyle(color: Colors.grey[600])),
      ],
    );
  }
}

/// Lists restaurants, cafés and hotels near you to register.
class _RegisterBusinessScreen extends StatefulWidget {
  const _RegisterBusinessScreen();

  @override
  State<_RegisterBusinessScreen> createState() => _RegisterBusinessScreenState();
}

class _RegisterBusinessScreenState extends State<_RegisterBusinessScreen> {
  List<CheckInPlace>? places;
  String? error;
  String? submittingPlaceId;

  @override
  void initState() {
    super.initState();
    _loadPlaces();
  }

  Future<void> _loadPlaces() async {
    setState(() {
      places = null;
      error = null;
    });
    try {
      final position = await getPositionWithPermission();
      final response = await FirebaseFunctions.instance.httpsCallable('nearbyPlaces').call({
        'latitude': position.latitude,
        'longitude': position.longitude,
      });
      if (!mounted) return;
      List data = response.data['places'];
      setState(() {
        places = data.map((p) => CheckInPlace.fromMap(p)).where((p) => p.category.isBusiness).toList();
      });
    } on LocationAccessException catch (e) {
      if (mounted) setState(() => error = e.message);
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => error = e.message ?? 'Couldn\'t load nearby places.');
    } catch (e) {
      debugPrint('Loading places to register failed: $e');
      if (mounted) setState(() => error = 'Couldn\'t load nearby places. Please try again.');
    }
  }

  Future<void> _register(CheckInPlace place) async {
    bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Register ${place.name}?'),
        content: const Text(
          'Only register a place you own or manage. We\'ll review it, and once approved, customers will need '
          'your code to check in there.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Register')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => submittingPlaceId = place.id);
    try {
      await FirebaseFunctions.instance.httpsCallable('requestBusinessClaim').call({'placeId': place.id});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${place.name} has been sent for approval.')),
      );
      Navigator.of(context).pop();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Couldn\'t register that place.')),
      );
    } finally {
      if (mounted) setState(() => submittingPlaceId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _loadPlaces, child: const Text('Try Again')),
            ],
          ),
        ),
      );
    } else if (places == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (places!.isEmpty) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No restaurants, cafés or hotels found near you. Open this screen at your business.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    } else {
      body = ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Restaurants, cafés and hotels near you:'),
          ),
          for (var place in places!)
            ListTile(
              leading: Icon(Icons.location_on, color: place.category.color),
              title: Text(place.name),
              subtitle: Text(place.category.label),
              trailing: submittingPlaceId == place.id
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : null,
              onTap: submittingPlaceId == null ? () => _register(place) : null,
            ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Register a Place')),
      body: body,
    );
  }
}
