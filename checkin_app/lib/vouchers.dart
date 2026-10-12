import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import 'app_only.dart';
import 'backend.dart';
import 'check_in_place.dart';
import 'emulators.dart';
import 'rewards_screen.dart';
import 'theme.dart';

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
          'This uses ${formatNumber(widget.reward.pointsRequired)} of your ${formatNumber(widget.userPoints)} points. You\'ll get a voucher '
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
      body = const _Message(icon: Icons.phone_iphone_rounded, text: _redeemAppOnlyMessage);
    } else if (error != null) {
      body = _Message(
        icon: Icons.cloud_off_rounded,
        text: error!,
        action: ElevatedButton(onPressed: _loadPlaces, child: const Text('Try Again')),
      );
    } else if (places == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (places!.isEmpty) {
      body = const _Message(icon: Icons.storefront_rounded, text: 'No partner places offer this reward yet.');
    } else {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Card(
            color: AppColors.lightPurple,
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  IconSquare(color: widget.reward.color, icon: widget.reward.icon, size: 48),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      '${widget.reward.description}. Choose where you\'ll use it:',
                      style: AppText.body(size: 15, weight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (var place in places!)
            Builder(builder: (context) {
              PlaceCategory category = PlaceCategory.fromName(place['category']);
              return Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppShapes.cardRadius)),
                  leading: IconSquare(color: category.color, icon: category.icon, size: 44),
                  title: Text(place['placeName'] ?? 'Unnamed place', style: AppText.heading(size: 18)),
                  subtitle: Text(category.label),
                  trailing: redeemingPlaceId == place['placeId']
                      ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : const Icon(Icons.chevron_right_rounded, color: AppColors.purple),
                  onTap: redeemingPlaceId == null ? () => _redeem(place) : null,
                ),
              );
            }),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.reward.name)),
      body: body,
    );
  }
}

/// An icon square with a message, and an optional button, for empty and
/// error states.
class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  final Color textColor;

  const _Message({required this.icon, required this.text, this.action, this.textColor = AppColors.ink});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconSquare(color: AppColors.lightPurple, icon: icon, size: 80),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center, style: AppText.body(size: 16, color: textColor)),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
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
      backgroundColor: AppColors.purple,
      appBar: AppBar(
        title: const Text('Voucher'),
        backgroundColor: AppColors.purple,
        foregroundColor: Colors.white,
        titleTextStyle: AppText.heading(size: 24, color: Colors.white),
      ),
      body: Stack(
        children: [
          const Positioned(left: -60, top: 40, child: DecorCircle(size: 160, color: AppColors.coral)),
          const Positioned(right: -50, bottom: 60, child: DecorCircle(size: 190, color: AppColors.sky)),
          StreamBuilder<DocumentSnapshot>(
            stream: firestore.collection('vouchers').doc(code).snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                debugPrint('Loading voucher failed: ${snapshot.error}');
                return const _Message(
                  icon: Icons.cloud_off_rounded,
                  text: 'Couldn\'t load this voucher. Please try again later.',
                  textColor: Colors.white,
                );
              }
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: Colors.white));
              if (!snapshot.data!.exists) {
                return const _Message(
                  icon: Icons.search_off_rounded,
                  text: 'This voucher doesn\'t exist.',
                  textColor: Colors.white,
                );
              }
              return _VoucherTicket(data: snapshot.data!.data() as Map<String, dynamic>);
            },
          ),
        ],
      ),
    );
  }
}

/// The white ticket: discount on a yellow top, a dashed tear line with
/// notches, then the code, username, place, expiry and the live clock.
class _VoucherTicket extends StatelessWidget {
  final Map<String, dynamic> data;

  const _VoucherTicket({required this.data});

  @override
  Widget build(BuildContext context) {
    MaterialLocalizations localizations = MaterialLocalizations.of(context);
    DateTime expiresAt = (data['expiresAt'] as Timestamp).toDate();
    DateTime? usedAt = (data['usedAt'] as Timestamp?)?.toDate();
    VoucherStatus status = voucherStatus(data);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppShapes.cardRadius),
              boxShadow: [
                BoxShadow(color: AppColors.ink.withValues(alpha: 0.3), blurRadius: 30, offset: const Offset(0, 12)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppShapes.cardRadius),
              child: ColoredBox(
                color: AppColors.card,
                child: Column(
                  children: [
                    // Top: the discount.
                    Container(
                      width: double.infinity,
                      color: AppColors.yellow,
                      padding: const EdgeInsets.fromLTRB(20, 26, 20, 22),
                      child: Column(
                        children: [
                          Text(
                            '${data['discountPercent']}% off',
                            textAlign: TextAlign.center,
                            style: AppText.heading(size: 52),
                          ),
                          Text(
                            data['placeName'] ?? '',
                            textAlign: TextAlign.center,
                            style: AppText.heading(size: 20, weight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    const _TearLine(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                      child: Column(
                        children: [
                          Text('Voucher code', style: AppText.body(size: 14, color: AppColors.muted)),
                          const SizedBox(height: 4),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: SelectableText(
                              formatVoucherCode(data['code']),
                              style: AppText.heading(size: 40).copyWith(
                                letterSpacing: 5,
                                fontFeatures: const [FontFeature.tabularFigures()],
                                decoration: status == VoucherStatus.valid ? null : TextDecoration.lineThrough,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text('@${data['username']}', style: AppText.heading(size: 20, color: AppColors.purple)),
                          const SizedBox(height: 14),
                          ColorChip(label: status.label, color: status.color, icon: status.icon),
                          const SizedBox(height: 10),
                          Text(
                            switch (status) {
                              VoucherStatus.used => 'Used on ${localizations.formatMediumDate(usedAt!)} at '
                                  '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(usedAt))}.',
                              VoucherStatus.expired => 'Expired on ${localizations.formatMediumDate(expiresAt)}.',
                              VoucherStatus.valid => 'Valid until ${localizations.formatMediumDate(expiresAt)}. Works '
                                  'once, at this place only. Show this screen to the staff.',
                            },
                            textAlign: TextAlign.center,
                            style: AppText.body(size: 15, color: AppColors.muted),
                          ),
                          const SizedBox(height: 18),
                          const _LiveClock(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A dashed line across the ticket with a round notch at each end, cut in
/// the screen's purple.
class _TearLine extends StatelessWidget {
  const _TearLine();

  static const double notch = 28;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: notch + 8,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: notch / 2 + 10),
            child: CustomPaint(size: const Size(double.infinity, 2), painter: _DashPainter()),
          ),
          const Positioned(left: -notch / 2, child: DecorCircle(size: notch, color: AppColors.purple)),
          const Positioned(right: -notch / 2, child: DecorCircle(size: notch, color: AppColors.purple)),
        ],
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    Paint paint = Paint()
      ..color = AppColors.lightPurple
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (double x = 0; x < size.width; x += 14) {
      canvas.drawLine(Offset(x, size.height / 2), Offset((x + 7).clamp(0, size.width), size.height / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_DashPainter oldDelegate) => false;
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
      ),
      child: Column(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.schedule_rounded, color: AppColors.purple, size: 22),
              const SizedBox(width: 6),
              Text(
                '${two(now.hour)}:${two(now.minute)}:${two(now.second)}',
                style: AppText.heading(size: 30).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ],
          ),
          Text(
            MaterialLocalizations.of(context).formatFullDate(now),
            style: AppText.body(size: 14, color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}

enum VoucherStatus {
  valid('Valid', AppColors.mint, Icons.check_circle_rounded),
  used('Used', AppColors.lightPurple, Icons.done_all_rounded),
  expired('Expired', AppColors.coral, Icons.event_busy_rounded);

  const VoucherStatus(this.label, this.color, this.icon);

  final String label;
  final Color color;
  final IconData icon;
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
    String uid = firebaseAuth.currentUser!.uid;

    return Scaffold(
      appBar: AppBar(title: const Text('My Vouchers')),
      body: StreamBuilder<QuerySnapshot>(
        stream: firestore.collection('vouchers').where('userId', isEqualTo: uid).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            debugPrint('Loading vouchers failed: ${snapshot.error}');
            return const _Message(
              icon: Icons.cloud_off_rounded,
              text: 'Couldn\'t load your vouchers. Please try again later.',
            );
          }
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          // Sorted here rather than in the query, which would need an index.
          var vouchers = snapshot.data!.docs.map((d) => d.data() as Map<String, dynamic>).toList()
            ..sort((a, b) => (b['createdAt'] as Timestamp).compareTo(a['createdAt'] as Timestamp));
          if (vouchers.isEmpty) {
            return const _Message(
              icon: Icons.confirmation_number_rounded,
              text: 'No vouchers yet. Redeem a reward to get one.',
            );
          }

          MaterialLocalizations localizations = MaterialLocalizations.of(context);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              for (var voucher in vouchers)
                Builder(builder: (context) {
                  VoucherStatus status = voucherStatus(voucher);
                  DateTime expiresAt = (voucher['expiresAt'] as Timestamp).toDate();
                  bool valid = status == VoucherStatus.valid;
                  return Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppShapes.cardRadius),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => VoucherScreen(code: voucher['code'])),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            IconSquare(
                              color: valid ? AppColors.yellow : AppColors.lightPurple,
                              icon: Icons.confirmation_number_rounded,
                              size: 52,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${voucher['discountPercent']}% off at ${voucher['placeName']}',
                                    style: AppText.heading(size: 17, color: valid ? AppColors.ink : AppColors.muted),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    formatVoucherCode(voucher['code']),
                                    style: AppText.heading(size: 16, weight: FontWeight.w600, color: AppColors.muted)
                                        .copyWith(letterSpacing: 2),
                                  ),
                                  const SizedBox(height: 6),
                                  valid
                                      ? Text(
                                          'Valid until ${localizations.formatMediumDate(expiresAt)}',
                                          style: AppText.body(size: 14, color: AppColors.muted),
                                        )
                                      : ColorChip(label: status.label, color: status.color, compact: true),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right_rounded, color: AppColors.purple),
                          ],
                        ),
                      ),
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
