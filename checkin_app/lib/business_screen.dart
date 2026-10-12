import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_only.dart';
import 'check_in_place.dart';
import 'emulators.dart';
import 'location_access.dart';
import 'theme.dart';

/// For restaurant, café, hotel and shop owners: register a place, and once
/// it's a partner, show customers the current check-in code.
class BusinessScreen extends StatelessWidget {
  const BusinessScreen({super.key});

  @override
  Widget build(BuildContext context) {
    String uid = FirebaseAuth.instance.currentUser!.uid;

    if (!appOnlyFeaturesAvailable) {
      return Scaffold(
        body: ListView(
          padding: EdgeInsets.zero,
          children: [
            const _MintHeader(),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(appOnlyMessage, textAlign: TextAlign.center, style: AppText.body(size: 16)),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('businesses').where('ownerUid', isEqualTo: uid).snapshots(),
        builder: (context, snapshot) {
          Widget content;
          if (snapshot.hasError) {
            debugPrint('Loading businesses failed: ${snapshot.error}');
            content = Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Couldn\'t load your businesses. Please try again later.',
                textAlign: TextAlign.center,
                style: AppText.body(size: 16),
              ),
            );
          } else if (!snapshot.hasData) {
            content = const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
          } else {
            var docs = snapshot.data!.docs;
            content = Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (docs.isEmpty)
                    Card(
                      margin: const EdgeInsets.only(bottom: 16),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          'Run a restaurant, café, hotel or shop? Register it, and once it\'s a partner, customers '
                          'enter the code shown here when they check in. Each code works for one customer, who can '
                          'bring friends along as a group.',
                          style: AppText.body(size: 16),
                        ),
                      ),
                    ),
                  if (docs.any((doc) => (doc.data() as Map)['status'] == 'approved'))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _VerifyVoucherCard(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const _VerifyVoucherScreen()),
                        ),
                      ),
                    ),
                  for (var doc in docs) _BusinessCard(placeId: doc.id, data: doc.data() as Map<String, dynamic>),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.add_business_rounded),
                    label: const Text('Register a place'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const _RegisterBusinessScreen()),
                    ),
                  ),
                ],
              ),
            );
          }
          return ListView(
            padding: EdgeInsets.zero,
            children: [const _MintHeader(), content],
          );
        },
      ),
    );
  }
}

/// Mint header with decorative circles, a back button and the title.
class _MintHeader extends StatelessWidget {
  const _MintHeader();

  @override
  Widget build(BuildContext context) {
    double top = MediaQuery.of(context).padding.top;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(40)),
      child: Container(
        color: AppColors.mint,
        child: Stack(
          children: [
            const Positioned(right: -40, top: -50, child: DecorCircle(size: 170, color: AppColors.yellow)),
            Positioned(left: -50, bottom: -70, child: DecorCircle(size: 160, color: Colors.white.withValues(alpha: 0.25))),
            const Positioned(right: 36, bottom: 14, child: DecorCircle(size: 24, color: AppColors.coral)),
            Padding(
              padding: EdgeInsets.fromLTRB(8, top + 8, 20, 30),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (Navigator.of(context).canPop())
                    IconButton(
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('My Business', style: AppText.heading(size: 30)),
                        const SizedBox(height: 4),
                        Text(
                          'Check-in codes, vouchers and stats for your places.',
                          style: AppText.body(size: 16, weight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens Verify voucher.
class _VerifyVoucherCard extends StatelessWidget {
  final VoidCallback onTap;

  const _VerifyVoucherCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppShapes.cardRadius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const IconSquare(color: AppColors.yellow, icon: Icons.confirmation_number_rounded, size: 52),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Verify voucher', style: AppText.heading(size: 19)),
                    Text(
                      'Enter the code from a customer\'s reward voucher.',
                      style: AppText.body(size: 14, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.purple),
            ],
          ),
        ),
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

    String? tier = tierLabels[data['tier']];
    bool partner = status == 'approved' && tier != null;
    TextStyle note = AppText.body(size: 15, color: AppColors.muted);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconSquare(color: category.color, icon: category.icon, size: 52),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(data['placeName'] ?? 'Unnamed place', style: AppText.heading(size: 20)),
                      Text(category.label, style: AppText.body(size: 15, color: AppColors.muted)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (partner)
                  ColorChip(label: '$tier plan', color: AppColors.yellow, icon: Icons.workspace_premium_rounded)
                else
                  switch (status) {
                    'approved' => const ColorChip(
                        label: 'Approved',
                        color: AppColors.lightPurple,
                        icon: Icons.check_rounded,
                      ),
                    'rejected' => const ColorChip(label: 'Not approved', color: AppColors.coral, icon: Icons.close_rounded),
                    _ => const ColorChip(
                        label: 'Waiting for approval',
                        color: AppColors.lightPurple,
                        icon: Icons.hourglass_top_rounded,
                      ),
                  },
              ],
            ),
            const SizedBox(height: 16),
            switch (status) {
              'approved' when partner => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _BusinessCode(placeId: placeId, codeSeq: data['codeSeq']),
                    const Divider(height: 36),
                    _BusinessStats(placeId: placeId, codeSeq: data['codeSeq']),
                  ],
                ),
              'approved' => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Approved, but not a partner yet. Customers can\'t check in here until you are.', style: note),
                    const Divider(height: 36),
                    _BusinessStats(placeId: placeId, codeSeq: data['codeSeq']),
                  ],
                ),
              'rejected' => Text('This registration wasn\'t approved.', style: note),
              _ => Text('Waiting for approval.', style: note),
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
            Expanded(child: Text(error!, style: AppText.body(size: 15))),
            TextButton(onPressed: _loadCode, child: const Text('Retry')),
          ],
        );
      }
      return const Center(child: CircularProgressIndicator());
    }

    Duration left = expiresAt!.difference(DateTime.now());
    if (left.isNegative) left = Duration.zero;
    String countdown = '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      decoration: BoxDecoration(
        color: AppColors.lightPurple,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          Text('Check-in code for the next customer', style: AppText.body(size: 15, weight: FontWeight.w800)),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '${code!.substring(0, 3)} ${code!.substring(3)}',
                style: AppText.heading(size: 52).copyWith(
                  letterSpacing: 6,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Works once. Expires in $countdown if unused.',
            style: AppText.body(size: 14, color: AppColors.muted),
            textAlign: TextAlign.center,
          ),
          if (notice != null)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.lightMint,
                borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_rounded, color: AppColors.ink, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text(notice!, style: AppText.body(size: 15, weight: FontWeight.w700))),
                ],
              ),
            ),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: isRetiring ? null : _retire,
            icon: isRetiring
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded),
            label: const Text('New code'),
          ),
        ],
      ),
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
          ? Text(error!, style: AppText.body(size: 15))
          : const Padding(padding: EdgeInsets.all(8), child: Center(child: CircularProgressIndicator()));
    } else {
      num? average = stats!['averageGroupSize'];
      String? tier = stats!['tierLabel'];
      num? budget = stats!['monthlyBudget'];
      int used = (stats!['usedThisMonth'] as num).toInt();
      String budgetText = budget == null
          ? '${formatNumber(used)} check-ins this month (unlimited).'
          : '${formatNumber(used)} of ${formatNumber(budget)} full-point check-ins used this month; after that, customers earn 5 points '
              'until next month.';
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (tier != null) ...[
            Text(
              '$tier partner: ${formatNumber(stats!['tierPoints'])} points a check-in.',
              style: AppText.body(size: 15, weight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text('Monthly budget', style: AppText.body(size: 14, color: AppColors.muted)),
                const Spacer(),
                Text(budget == null ? '${formatNumber(used)} · unlimited' : '${formatNumber(used)} / ${formatNumber(budget)}', style: AppText.heading(size: 16)),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: budget == null ? 1 : (used / budget).clamp(0, 1).toDouble(),
                minHeight: 14,
                color: budget == null ? AppColors.mint : AppColors.yellow,
                backgroundColor: AppColors.lightPurple,
              ),
            ),
            const SizedBox(height: 6),
            Text(budgetText, style: AppText.body(size: 14, color: AppColors.muted)),
            const SizedBox(height: 16),
          ],
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.9,
            children: [
              _Stat(label: 'Today', value: formatNumber(stats!['today'])),
              _Stat(label: 'Last 7 days', value: formatNumber(stats!['week'])),
              _Stat(label: 'Since approval', value: formatNumber(stats!['sinceApproval'])),
              _Stat(label: 'Group check-ins', value: formatNumber(stats!['groupCheckIns'])),
              _Stat(label: 'Avg. group size', value: average == null ? '–' : '$average'),
            ],
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Check-ins', style: AppText.heading(size: 19))),
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh_rounded),
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FittedBox(fit: BoxFit.scaleDown, child: Text(value, style: AppText.heading(size: 26))),
          Text(label, style: AppText.body(size: 14, color: AppColors.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
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
    Widget body;
    if (accepted != null) {
      // Accepted: a light mint card with the discount and the customer.
      body = Container(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        decoration: BoxDecoration(
          color: AppColors.lightMint,
          borderRadius: BorderRadius.circular(AppShapes.cardRadius),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const IconSquare(color: AppColors.mint, icon: Icons.check_rounded, size: 72),
            const SizedBox(height: 12),
            Text('${accepted!['discountPercent']}% off', style: AppText.heading(size: 48)),
            Text(
              '${accepted!['rewardName'] ?? 'Voucher'} at ${accepted!['placeName']}',
              textAlign: TextAlign.center,
              style: AppText.body(size: 16, weight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            ColorChip(label: '@${accepted!['username']}', color: AppColors.card, icon: Icons.person_rounded),
            const SizedBox(height: 14),
            Text(
              'The voucher is now used. Check the username and the ticking clock on the customer\'s screen.',
              textAlign: TextAlign.center,
              style: AppText.body(size: 15),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _reset,
              style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, AppShapes.buttonHeight)),
              child: const Text('Check another voucher'),
            ),
          ],
        ),
      );
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: IconSquare(color: AppColors.yellow, icon: Icons.confirmation_number_rounded, size: 80)),
          const SizedBox(height: 16),
          Text('Enter the voucher code', textAlign: TextAlign.center, style: AppText.heading(size: 24)),
          const SizedBox(height: 6),
          Text(
            'Enter the 8-character code from the customer\'s voucher screen.',
            textAlign: TextAlign.center,
            style: AppText.body(size: 16, color: AppColors.muted),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: codeController,
            autofocus: true,
            textAlign: TextAlign.center,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 9, // with a space or dash in the middle
            buildCounter: (context, {required currentLength, required isFocused, maxLength}) => null,
            style: AppText.heading(size: 34).copyWith(letterSpacing: 6),
            decoration: InputDecoration(
              hintText: 'ABCD EFGH',
              hintStyle: AppText.heading(size: 34, color: AppColors.lightPurple).copyWith(letterSpacing: 6),
              errorText: error,
              errorMaxLines: 3,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            ),
            onSubmitted: (_) => _verify(),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: isVerifying ? null : _verify,
            style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 60)),
            child: isVerifying
                ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Text('Verify and use', style: TextStyle(fontSize: 19)),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Verify Voucher')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: body),
        ),
      ),
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
      List data = useEmulators
          ? emulatorNearbyPlaces(position.latitude, position.longitude)
          : (await cloudFunctions.httpsCallable('nearbyPlaces').call({
              'latitude': position.latitude,
              'longitude': position.longitude,
            }))
              .data['places'];
      if (!mounted) return;
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
      body = _CenteredMessage(
        icon: Icons.location_searching_rounded,
        text: error!,
        action: ElevatedButton(onPressed: _loadPlaces, child: const Text('Try Again')),
      );
    } else if (places == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (places!.isEmpty) {
      body = const _CenteredMessage(
        icon: Icons.storefront_rounded,
        text: 'No restaurants, cafés, hotels or shops found near you. Open this screen at your business.',
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text(
              'Restaurants, cafés, hotels and shops near you:',
              style: AppText.body(size: 16, weight: FontWeight.w700),
            ),
          ),
          for (var place in places!)
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.fromLTRB(14, 8, 16, 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppShapes.cardRadius)),
                leading: IconSquare(color: place.category.color, icon: place.category.icon, size: 44),
                title: Text(place.name, style: AppText.heading(size: 18)),
                subtitle: Text(place.category.label),
                trailing: submittingPlaceId == place.id
                    ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : const Icon(Icons.add_circle_rounded, color: AppColors.purple),
                onTap: submittingPlaceId == null ? () => _register(place) : null,
              ),
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

/// An icon square with a message and an optional button.
class _CenteredMessage extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;

  const _CenteredMessage({required this.icon, required this.text, this.action});

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
            Text(text, textAlign: TextAlign.center, style: AppText.body(size: 16)),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}
