import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_only.dart';
import 'emulators.dart';
import 'rewards_screen.dart';

const String _redeemAppOnlyMessage = 'Redeeming rewards works in the Chekkin app for iPhone and Android.';

/// 'ABCD EFGH', easier to read out than one block of eight.
String formatVoucherCode(String code) =>
    code.length == 8 ? '${code.substring(0, 4)} ${code.substring(4)}' : code;

/// Identifies one Redeem, so a double tap or a retry gets the same voucher
/// instead of spending the points twice (see redeemReward).
String _newRequestId() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  Random random = Random.secure();
  return List.generate(24, (_) => chars[random.nextInt(chars.length)]).join();
}

/// Lists the partner places where [reward] can be used; picking one redeems
/// it there and opens the voucher.
class RedeemRewardScreen extends StatefulWidget {
  final Reward reward;
  final int userPoints;

  const RedeemRewardScreen({super.key, required this.reward, required this.userPoints});

  @override
  State<RedeemRewardScreen> createState() => _RedeemRewardScreenState();
}

class _RedeemRewardScreenState extends State<RedeemRewardScreen> {
  List<Map>? places;
  String? error;
  String? redeemingPlaceId;

  /// Kept until a voucher is issued, so retrying after an error the server
  /// never answered can't pay twice.
  final String requestId = _newRequestId();

  @override
  void initState() {
    super.initState();
    if (appOnlyFeaturesAvailable) _loadPlaces();
  }

  Future<void> _loadPlaces() async {
    setState(() {
      places = null;
      error = null;
    });
    try {
      final response = await cloudFunctions.httpsCallable('rewardPartners').call({
        'rewardId': widget.reward.catalogId,
      });
      if (mounted) setState(() => places = List<Map>.from(response.data['places']));
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => error = e.message ?? 'Couldn\'t load the partner places.');
    } catch (e) {
      debugPrint('Loading reward partners failed: $e');
      if (mounted) setState(() => error = 'Couldn\'t load the partner places. Please check your connection.');
    }
  }

  Future<void> _redeem(Map place) async {
    bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Redeem ${widget.reward.name} at ${place['placeName']}?'),
        content: Text(
          'This uses ${widget.reward.pointsRequired} of your ${widget.userPoints} points. You\'ll get a voucher '
          'to show the staff, and it only works at ${place['placeName']}.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Redeem')),
        ],
      ),
    );
    if (confirmed != true || !mounted || redeemingPlaceId != null) return;

    setState(() => redeemingPlaceId = place['placeId']);
    try {
      final response = await cloudFunctions.httpsCallable('redeemReward').call({
        'rewardId': widget.reward.catalogId,
        'placeId': place['placeId'],
        'requestId': requestId,
      });
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => VoucherScreen(code: response.data['code'])),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Couldn\'t redeem that reward.')),
      );
    } catch (e) {
      debugPrint('Redeeming failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn\'t redeem that reward. Please check your connection.')),
      );
    } finally {
      if (mounted) setState(() => redeemingPlaceId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (!appOnlyFeaturesAvailable) {
      body = const Center(
        child: Padding(padding: EdgeInsets.all(24), child: Text(_redeemAppOnlyMessage, textAlign: TextAlign.center)),
      );
    } else if (error != null) {
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
          child: Text('No partner places offer this reward yet.', textAlign: TextAlign.center),
        ),
      );
    } else {
      body = ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('${widget.reward.description}. Choose where you\'ll use it:'),
          ),
          for (var place in places!)
            ListTile(
              leading: const Icon(Icons.restaurant),
              title: Text(place['placeName'] ?? 'Unnamed place'),
              trailing: redeemingPlaceId == place['placeId']
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.chevron_right),
              onTap: redeemingPlaceId == null ? () => _redeem(place) : null,
            ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.reward.name)),
      body: body,
    );
  }
}

/// A voucher to show the staff, who enter its code in Verify voucher. The
/// ticking clock shows it's the live app, not a screenshot, and the screen
/// follows vouchers/{code}, so it says "Used" as soon as staff accept it.
class VoucherScreen extends StatelessWidget {
  final String code;

  const VoucherScreen({super.key, required this.code});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Voucher')),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('vouchers').doc(code).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            debugPrint('Loading voucher failed: ${snapshot.error}');
            return const Center(child: Text('Couldn\'t load this voucher. Please try again later.'));
          }
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          if (!snapshot.data!.exists) return const Center(child: Text('This voucher doesn\'t exist.'));
          return _VoucherCard(data: snapshot.data!.data() as Map<String, dynamic>);
        },
      ),
    );
  }
}

class _VoucherCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const _VoucherCard({required this.data});

  @override
  Widget build(BuildContext context) {
    MaterialLocalizations localizations = MaterialLocalizations.of(context);
    DateTime expiresAt = (data['expiresAt'] as Timestamp).toDate();
    DateTime? usedAt = (data['usedAt'] as Timestamp?)?.toDate();
    VoucherStatus status = voucherStatus(data);
    TextTheme text = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          '${data['discountPercent']}% off',
          textAlign: TextAlign.center,
          style: text.displaySmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        Text(data['placeName'] ?? '', textAlign: TextAlign.center, style: text.titleLarge),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: Border.all(color: status.color, width: 2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              SelectableText(
                formatVoucherCode(data['code']),
                style: text.displaySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 4,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  decoration: status == VoucherStatus.valid ? null : TextDecoration.lineThrough,
                ),
              ),
              const SizedBox(height: 4),
              Text('@${data['username']}', style: text.titleMedium),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Center(child: Chip(label: Text(status.label), backgroundColor: status.color.withValues(alpha: 0.15))),
        const SizedBox(height: 8),
        Text(
          switch (status) {
            VoucherStatus.used => 'Used on ${localizations.formatMediumDate(usedAt!)} at '
                '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(usedAt))}.',
            VoucherStatus.expired => 'Expired on ${localizations.formatMediumDate(expiresAt)}.',
            VoucherStatus.valid => 'Valid until ${localizations.formatMediumDate(expiresAt)}. Works once, at this '
                'place only. Show this screen to the staff.',
          },
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        const _LiveClock(),
      ],
    );
  }
}

/// The current time to the second.
class _LiveClock extends StatefulWidget {
  const _LiveClock();

  @override
  State<_LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<_LiveClock> {
  late final Timer ticker;

  @override
  void initState() {
    super.initState();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    DateTime now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return Column(
      children: [
        Text(
          '${two(now.hour)}:${two(now.minute)}:${two(now.second)}',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
        ),
        Text(MaterialLocalizations.of(context).formatFullDate(now), style: TextStyle(color: Colors.grey[600])),
      ],
    );
  }
}

enum VoucherStatus {
  valid('Valid', Colors.green),
  used('Used', Colors.grey),
  expired('Expired', Colors.red);

  const VoucherStatus(this.label, this.color);

  final String label;
  final Color color;
}

VoucherStatus voucherStatus(Map<String, dynamic> data) {
  if (data['usedAt'] != null) return VoucherStatus.used;
  if ((data['expiresAt'] as Timestamp).toDate().isBefore(DateTime.now())) return VoucherStatus.expired;
  return VoucherStatus.valid;
}

/// The user's vouchers, newest first.
class MyVouchersScreen extends StatelessWidget {
  const MyVouchersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    String uid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      appBar: AppBar(title: const Text('My Vouchers')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('vouchers').where('userId', isEqualTo: uid).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            debugPrint('Loading vouchers failed: ${snapshot.error}');
            return const Center(child: Text('Couldn\'t load your vouchers. Please try again later.'));
          }
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          // Sorted here rather than in the query, which would need an index.
          var vouchers = snapshot.data!.docs.map((d) => d.data() as Map<String, dynamic>).toList()
            ..sort((a, b) => (b['createdAt'] as Timestamp).compareTo(a['createdAt'] as Timestamp));
          if (vouchers.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No vouchers yet. Redeem a reward to get one.', textAlign: TextAlign.center),
              ),
            );
          }

          MaterialLocalizations localizations = MaterialLocalizations.of(context);
          return ListView(
            children: [
              for (var voucher in vouchers)
                Builder(builder: (context) {
                  VoucherStatus status = voucherStatus(voucher);
                  DateTime expiresAt = (voucher['expiresAt'] as Timestamp).toDate();
                  return ListTile(
                    leading: Icon(Icons.confirmation_number, color: status.color),
                    title: Text('${voucher['discountPercent']}% off at ${voucher['placeName']}'),
                    subtitle: Text(status == VoucherStatus.valid
                        ? 'Valid until ${localizations.formatMediumDate(expiresAt)}'
                        : status.label),
                    trailing: Text(formatVoucherCode(voucher['code'])),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => VoucherScreen(code: voucher['code'])),
                    ),
                  );
                }),
            ],
          );
        },
      ),
    );
  }
}
