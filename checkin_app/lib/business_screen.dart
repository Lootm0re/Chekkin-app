import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_only.dart';
import 'check_in_place.dart';
import 'emulators.dart';
import 'location_access.dart';

/// For restaurant, café, hotel and shop owners: register a place, and once
/// it's a partner, show customers the current check-in code.
class BusinessScreen extends StatelessWidget {
  const BusinessScreen({super.key});

  @override
  Widget build(BuildContext context) {
    String uid = FirebaseAuth.instance.currentUser!.uid;

    if (!appOnlyFeaturesAvailable) {
      return Scaffold(
        appBar: AppBar(title: const Text('My Business')),
        body: const Center(
          child: Padding(padding: EdgeInsets.all(24), child: Text(appOnlyMessage, textAlign: TextAlign.center)),
        ),
      );
    }

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
                    'Run a restaurant, café, hotel or shop? Register it, and once it\'s a partner, customers '
                    'enter the code shown here when they check in. Each code works for one customer, who can bring '
                    'friends along as a group.',
                  ),
                ),
              for (var doc in docs) _BusinessCard(placeId: doc.id, data: doc.data() as Map<String, dynamic>),
              if (docs.any((doc) => (doc.data() as Map)['status'] == 'approved'))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.confirmation_number),
                    label: const Text('Verify voucher'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const _VerifyVoucherScreen()),
                    ),
                  ),
                ),
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
              'approved' when tierLabels.containsKey(data['tier']) => Column(
                  children: [
                    _BusinessCode(placeId: placeId, codeSeq: data['codeSeq']),
                    const Divider(height: 32),
                    _BusinessStats(placeId: placeId, codeSeq: data['codeSeq']),
                  ],
                ),
              'approved' => Column(
                  children: [
                    const Text('Approved, but not a partner yet. Customers can\'t check in here until you are.'),
                    const Divider(height: 32),
                    _BusinessStats(placeId: placeId, codeSeq: data['codeSeq']),
                  ],
                ),
              'rejected' => const Text('This registration wasn\'t approved.'),
              _ => const Text('Waiting for approval.'),
            },
          ],
        ),
      ),
    );
  }
}

/// The current check-in code. Each code works for one customer; when it's
/// used, expires or is retired, businesses/{placeId}.codeSeq changes and the
/// new code is fetched.
class _BusinessCode extends StatefulWidget {
  final String placeId;
  final int? codeSeq;

  const _BusinessCode({required this.placeId, required this.codeSeq});

  @override
  State<_BusinessCode> createState() => _BusinessCodeState();
}

class _BusinessCodeState extends State<_BusinessCode> {
  String? code;
  int? seq;
  DateTime? expiresAt;
  String? error;
  String? notice;
  Timer? ticker;
  Timer? noticeTimer;
  bool isLoading = false;
  bool isRetiring = false;

  @override
  void initState() {
    super.initState();
    _loadCode();
    // Redraws the countdown, and fetches a new code once this one expires.
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (expiresAt != null && DateTime.now().isAfter(expiresAt!)) {
        _loadCode();
      }
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(_BusinessCode old) {
    super.didUpdateWidget(old);
    // A customer used the code (or it was retired elsewhere).
    if (widget.codeSeq != null && seq != null && widget.codeSeq! > seq! && !isRetiring) {
      _showNotice('Code used by a customer. Here\'s a new one.');
      _loadCode();
    }
  }

  @override
  void dispose() {
    ticker?.cancel();
    noticeTimer?.cancel();
    super.dispose();
  }

  void _showNotice(String message) {
    noticeTimer?.cancel();
    setState(() => notice = message);
    noticeTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => notice = null);
    });
  }

  void _setCode(Map data) {
    setState(() {
      code = data['code'];
      seq = data['seq'];
      expiresAt = DateTime.fromMillisecondsSinceEpoch((data['expiresAt'] as num).toInt());
      error = null;
    });
  }

  Future<void> _loadCode() async {
    if (isLoading) return;
    isLoading = true;
    try {
      final response = await cloudFunctions.httpsCallable('getBusinessCode').call({
        'placeId': widget.placeId,
      });
      if (mounted) _setCode(response.data);
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => error = e.message ?? 'Couldn\'t load the code.');
    } catch (e) {
      debugPrint('Loading business code failed: $e');
      if (mounted) setState(() => error = 'Couldn\'t load the code. Please check your connection.');
    } finally {
      isLoading = false;
    }
  }

  Future<void> _retire() async {
    setState(() => isRetiring = true);
    try {
      final response = await cloudFunctions.httpsCallable('newBusinessCode').call({
        'placeId': widget.placeId,
      });
      if (!mounted) return;
      _setCode(response.data);
      _showNotice('The old code no longer works.');
    } on FirebaseFunctionsException catch (e) {
      if (mounted) _showNotice(e.message ?? 'Couldn\'t make a new code.');
    } catch (e) {
      debugPrint('Retiring business code failed: $e');
      if (mounted) _showNotice('Couldn\'t make a new code. Please check your connection.');
    } finally {
      if (mounted) setState(() => isRetiring = false);
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
        const Text('Check-in code for the next customer'),
        const SizedBox(height: 4),
        Text(
          '${code!.substring(0, 3)} ${code!.substring(3)}',
          style: Theme.of(context).textTheme.displayMedium?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: 4,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
        ),
        Text('Works once. Expires in $countdown if unused.', style: TextStyle(color: Colors.grey[600])),
        if (notice != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(notice!, style: TextStyle(color: Colors.green[800], fontWeight: FontWeight.w500)),
          ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: isRetiring ? null : _retire,
          icon: isRetiring
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh),
          label: const Text('New code'),
        ),
      ],
    );
  }
}

/// Check-in counts for the owner. Counts only: owners never see who checked in.
class _BusinessStats extends StatefulWidget {
  final String placeId;
  final int? codeSeq;

  const _BusinessStats({required this.placeId, required this.codeSeq});

  @override
  State<_BusinessStats> createState() => _BusinessStatsState();
}

class _BusinessStatsState extends State<_BusinessStats> {
  Map? stats;
  String? error;
  bool isLoading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_BusinessStats old) {
    super.didUpdateWidget(old);
    // A code was used, so there's a new check-in.
    if (widget.codeSeq != old.codeSeq) _load();
  }

  Future<void> _load() async {
    if (isLoading) return;
    setState(() => isLoading = true);
    DateTime now = DateTime.now();
    try {
      final response = await cloudFunctions.httpsCallable('getBusinessStats').call({
        'placeId': widget.placeId,
        'todayStart': DateTime(now.year, now.month, now.day).millisecondsSinceEpoch,
      });
      if (mounted) {
        setState(() {
          stats = response.data;
          error = null;
        });
      }
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Loading business stats failed: [${e.code}] ${e.message}');
      if (mounted) setState(() => error = 'Couldn\'t load your stats.');
    } catch (e) {
      debugPrint('Loading business stats failed: $e');
      if (mounted) setState(() => error = 'Couldn\'t load your stats. Please check your connection.');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (stats == null) {
      body = error != null
          ? Text(error!)
          : const Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator());
    } else {
      num? average = stats!['averageGroupSize'];
      String? tier = stats!['tierLabel'];
      num? budget = stats!['monthlyBudget'];
      int used = (stats!['usedThisMonth'] as num).toInt();
      String budgetText = budget == null
          ? '$used check-ins this month (unlimited).'
          : '$used of $budget full-point check-ins used this month; after that, customers earn 5 points '
              'until next month.';
      body = Column(
        children: [
          if (tier != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '$tier partner: ${stats!['tierPoints']} points a check-in. $budgetText',
                textAlign: TextAlign.center,
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _Stat(label: 'Today', value: '${stats!['today']}'),
              _Stat(label: 'Last 7 days', value: '${stats!['week']}'),
              _Stat(label: 'Since approval', value: '${stats!['sinceApproval']}'),
              _Stat(label: 'Group check-ins', value: '${stats!['groupCheckIns']}'),
              _Stat(label: 'Avg. group size', value: average == null ? '–' : '$average'),
            ],
          ),
        ],
      );
    }

    return Column(
      children: [
        Row(
          children: [
            Text('Check-ins', style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: isLoading ? null : _load,
            ),
          ],
        ),
        body,
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;

  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 100,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          Text(label, style: const TextStyle(fontSize: 12), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

/// For staff: enter the code from a customer's voucher screen. A valid code
/// is used up at once, and the discount and the customer's username are shown
/// to compare with their screen. Wrong codes count towards a lockout.
class _VerifyVoucherScreen extends StatefulWidget {
  const _VerifyVoucherScreen();

  @override
  State<_VerifyVoucherScreen> createState() => _VerifyVoucherScreenState();
}

class _VerifyVoucherScreenState extends State<_VerifyVoucherScreen> {
  final codeController = TextEditingController();
  Map? accepted;
  String? error;
  bool isVerifying = false;

  @override
  void dispose() {
    codeController.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (isVerifying) return;
    setState(() {
      isVerifying = true;
      error = null;
    });
    try {
      final response = await cloudFunctions.httpsCallable('verifyVoucher').call({
        'code': codeController.text,
      });
      if (mounted) setState(() => accepted = response.data);
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => error = e.message ?? 'Couldn\'t check that voucher.');
    } catch (e) {
      debugPrint('Verifying voucher failed: $e');
      if (mounted) setState(() => error = 'Couldn\'t check that voucher. Please check your connection.');
    } finally {
      if (mounted) setState(() => isVerifying = false);
    }
  }

  void _reset() {
    codeController.clear();
    setState(() {
      accepted = null;
      error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    TextTheme text = Theme.of(context).textTheme;
    Widget body;
    if (accepted != null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, color: Colors.green[700], size: 64),
          const SizedBox(height: 8),
          Text('${accepted!['discountPercent']}% off', style: text.displaySmall?.copyWith(fontWeight: FontWeight.bold)),
          Text('${accepted!['rewardName'] ?? 'Voucher'} at ${accepted!['placeName']}', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Text('@${accepted!['username']}', style: text.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            'The voucher is now used. Check the username and the ticking clock on the customer\'s screen.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton(onPressed: _reset, child: const Text('Check another voucher')),
        ],
      );
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Enter the 8-character code from the customer\'s voucher screen.', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          TextField(
            controller: codeController,
            autofocus: true,
            textAlign: TextAlign.center,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 9, // with a space or dash in the middle
            style: text.headlineMedium?.copyWith(letterSpacing: 4),
            decoration: InputDecoration(border: const OutlineInputBorder(), errorText: error, errorMaxLines: 3),
            onSubmitted: (_) => _verify(),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: isVerifying ? null : _verify,
            child: isVerifying
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Verify and use'),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Verify Voucher')),
      body: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: body)),
    );
  }
}

/// Lists restaurants, cafés, hotels and shops near you to register.
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
      final response = await cloudFunctions.httpsCallable('nearbyPlaces').call({
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
          'Only register a place you own or manage. We\'ll review it, and once it\'s a partner, customers will '
          'need your code to check in there.',
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
      await cloudFunctions.httpsCallable('requestBusinessClaim').call({'placeId': place.id});
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
            'No restaurants, cafés, hotels or shops found near you. Open this screen at your business.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    } else {
      body = ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Restaurants, cafés, hotels and shops near you:'),
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
