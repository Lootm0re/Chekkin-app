import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import 'emulators.dart';
import 'leaderboard_screen.dart';
import 'theme.dart';

/// "1234 5678": an 8-digit check-in code in two halves, easier to read out.
String formatCheckInCode(String code) =>
    code.length == 8 ? '${code.substring(0, 4)} ${code.substring(4)}' : code;

/// "23 h" or "45 min": how long until [expiresAt].
String _timeLeft(DateTime expiresAt) {
  Duration left = expiresAt.difference(DateTime.now());
  if (left.inHours >= 1) return '${left.inHours} h';
  return '${left.inMinutes < 1 ? 1 : left.inMinutes} min';
}

/// A card's heading: an icon square, a title and a line under it.
class _CardHeading extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;

  const _CardHeading({required this.icon, required this.color, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconSquare(color: color, icon: icon, size: 52),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppText.heading(size: 20)),
              Text(subtitle, style: AppText.body(size: 14, color: AppColors.muted)),
            ],
          ),
        ),
      ],
    );
  }
}

/// The place's check-in codes: buttons to create 1, 10 or 50, the newest code
/// large and the other active ones in a grid. Each code works for one
/// customer, for 24 hours. When a code is created or used,
/// businesses/{placeId}.codeSeq changes and the list is fetched again.
class CheckInCodesCard extends StatefulWidget {
  final String placeId;
  final int? codeSeq;

  const CheckInCodesCard({super.key, required this.placeId, required this.codeSeq});

  @override
  State<CheckInCodesCard> createState() => _CheckInCodesCardState();
}

class _CheckInCodesCardState extends State<CheckInCodesCard> {
  static const List<int> batchSizes = [1, 10, 50];
  static const int collapsedCount = 10;

  List<({String code, DateTime expiresAt})>? codes;
  int activeCount = 0;
  int lifetimeHours = 24;
  String? error;
  String? notice;
  int? creating;
  bool showAll = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CheckInCodesCard old) {
    super.didUpdateWidget(old);
    if (widget.codeSeq != old.codeSeq) _load(fromChange: true);
  }

  Future<void> _load({bool fromChange = false}) async {
    try {
      final response = await cloudFunctions.httpsCallable('getBusinessCodes').call({'placeId': widget.placeId});
      if (!mounted) return;
      Map data = response.data;
      int newCount = (data['activeCount'] as num).toInt();
      setState(() {
        if (fromChange && creating == null && newCount < activeCount) notice = 'A customer used a code.';
        codes = [
          for (Map c in data['codes'])
            (code: c['code'] as String, expiresAt: DateTime.fromMillisecondsSinceEpoch((c['expiresAt'] as num).toInt())),
        ];
        activeCount = newCount;
        lifetimeHours = (data['lifetimeHours'] as num?)?.toInt() ?? lifetimeHours;
        error = null;
      });
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => error = e.message ?? 'Couldn\'t load your codes.');
    } catch (e) {
      debugPrint('Loading business codes failed: $e');
      if (mounted) setState(() => error = 'Couldn\'t load your codes. Please check your connection.');
    }
  }

  Future<void> _create(int count) async {
    setState(() {
      creating = count;
      error = null;
      notice = null;
    });
    try {
      await cloudFunctions.httpsCallable('createBusinessCodes').call({'placeId': widget.placeId, 'count': count});
      await _load();
      if (mounted) setState(() => notice = count == 1 ? 'New code ready.' : '${formatNumber(count)} new codes ready.');
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => error = e.message ?? 'Couldn\'t create codes.');
    } catch (e) {
      debugPrint('Creating business codes failed: $e');
      if (mounted) setState(() => error = 'Couldn\'t create codes. Please check your connection.');
    } finally {
      if (mounted) setState(() => creating = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    var active = (codes ?? []).where((c) => c.expiresAt.isAfter(DateTime.now())).toList();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CardHeading(
              icon: Icons.pin_rounded,
              color: AppColors.mint,
              title: 'Check-in codes',
              subtitle: 'Each code works once, for $lifetimeHours hours.',
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                for (int count in batchSizes) ...[
                  if (count != batchSizes.first) const SizedBox(width: 8),
                  Expanded(child: _batchButton(count)),
                ],
              ],
            ),
            const SizedBox(height: 16),
            if (error != null) ...[
              ErrorNote(message: error!),
              const SizedBox(height: 12),
            ],
            if (notice != null) ...[
              _Notice(text: notice!),
              const SizedBox(height: 12),
            ],
            if (codes == null && error == null)
              const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()))
            else if (active.isEmpty)
              _EmptyNote(
                icon: Icons.pin_outlined,
                title: 'No active codes',
                text: 'Create one when a customer is ready to check in.',
              )
            else
              _codes(active),
          ],
        ),
      ),
    );
  }

  Widget _batchButton(int count) {
    String label = count == 1 ? '1 code' : '${formatNumber(count)} codes';
    Widget child = creating == count
        ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
        : FittedBox(fit: BoxFit.scaleDown, child: Text(label));
    VoidCallback? onPressed = creating == null ? () => _create(count) : null;
    const padding = EdgeInsets.symmetric(horizontal: 8);
    // One code is the everyday action; batches are secondary.
    return count == 1
        ? ElevatedButton(onPressed: onPressed, style: ElevatedButton.styleFrom(padding: padding), child: child)
        : OutlinedButton(onPressed: onPressed, style: OutlinedButton.styleFrom(padding: padding), child: child);
  }

  Widget _codes(List<({String code, DateTime expiresAt})> active) {
    var newest = active.first;
    var others = active.skip(1).toList();
    int hiddenOnServer = activeCount - active.length;
    var shown = showAll ? others : others.take(collapsedCount).toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.lightPurple, borderRadius: BorderRadius.circular(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Newest code', textAlign: TextAlign.center, style: AppText.body(size: 15, weight: FontWeight.w800)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(AppShapes.fieldRadius)),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                formatCheckInCode(newest.code),
                style: AppText.heading(size: 44).copyWith(
                  letterSpacing: 4,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Works once. Expires in ${_timeLeft(newest.expiresAt)} if unused.',
            textAlign: TextAlign.center,
            style: AppText.body(size: 14, color: AppColors.muted),
          ),
          if (others.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              '${formatNumber(activeCount - 1)} more active ${activeCount - 1 == 1 ? 'code' : 'codes'}',
              style: AppText.body(size: 15, weight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                double width = (constraints.maxWidth - 8) / 2;
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var c in shown)
                      Container(
                        width: width,
                        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                        decoration: BoxDecoration(
                          color: AppColors.card,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            formatCheckInCode(c.code),
                            style: AppText.heading(size: 20, weight: FontWeight.w600)
                                .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            if (others.length > collapsedCount)
              TextButton(
                onPressed: () => setState(() => showAll = !showAll),
                child: Text(showAll ? 'Show fewer' : 'Show all ${formatNumber(others.length + 1)}'),
              ),
            if (hiddenOnServer > 0 && showAll)
              Text(
                'Showing the newest ${formatNumber(active.length)}. Older codes still work.',
                textAlign: TextAlign.center,
                style: AppText.body(size: 14, color: AppColors.muted),
              ),
          ],
        ],
      ),
    );
  }
}

/// This month's league: partner places of the same tier (small tiers
/// merged), ranked by check-ins. Shows the top 5, the owner's place and the
/// places either side of it, with the owner's row outlined in purple.
class BusinessLeagueCard extends StatefulWidget {
  final String placeId;
  final int? codeSeq;

  const BusinessLeagueCard({super.key, required this.placeId, required this.codeSeq});

  @override
  State<BusinessLeagueCard> createState() => _BusinessLeagueCardState();
}

class _BusinessLeagueCardState extends State<BusinessLeagueCard> {
  Map? board;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(BusinessLeagueCard old) {
    super.didUpdateWidget(old);
    // A code was used, so there's a new check-in.
    if (widget.codeSeq != old.codeSeq) _load();
  }

  Future<void> _load() async {
    try {
      final response =
          await cloudFunctions.httpsCallable('getBusinessLeaderboard').call({'placeId': widget.placeId});
      if (!mounted) return;
      setState(() {
        board = response.data;
        error = null;
      });
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Loading business leaderboard failed: [${e.code}] ${e.message}');
      if (mounted) setState(() => error = 'Couldn\'t load the leaderboard.');
    } catch (e) {
      debugPrint('Loading business leaderboard failed: $e');
      if (mounted) setState(() => error = 'Couldn\'t load the leaderboard. Please check your connection.');
    }
  }

  @override
  Widget build(BuildContext context) {
    Map? data = board;
    Map? league = data?['league'];
    String subtitle = league == null
        ? 'Check-ins this month'
        : '${league['label']} league · ${formatNumber(league['size'])} places · check-ins this month';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CardHeading(
              icon: Icons.emoji_events_rounded,
              color: AppColors.yellow,
              title: 'This month\'s league',
              subtitle: subtitle,
            ),
            if (data?['lastMonthWinner'] == true) ...[
              const SizedBox(height: 12),
              const Align(
                alignment: Alignment.centerLeft,
                child: ColorChip(label: 'Last month\'s winner', color: AppColors.yellow, icon: Icons.emoji_events_rounded),
              ),
            ],
            const SizedBox(height: 12),
            if (error != null)
              ErrorNote(message: error!)
            else if (data == null)
              const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()))
            else
              ..._rows(data),
          ],
        ),
      ),
    );
  }

  List<Widget> _rows(Map data) {
    List<Map> top = [for (Map r in data['top']) r];
    bool noCheckIns = top.every((r) => (r['checkIns'] as num) == 0);
    if (noCheckIns) {
      return [
        const _EmptyNote(
          icon: Icons.leaderboard_rounded,
          title: 'No check-ins yet this month',
          text: 'Your league fills up as customers check in. Rankings start again each month.',
        ),
      ];
    }

    // The owner's place and its neighbours, unless they're already in the top 5.
    List<Map> extra = [
      for (Map? r in [data['above'], data['you'], data['below']])
        if (r != null && !top.any((t) => t['rank'] == r['rank'] && t['placeName'] == r['placeName'])) r,
    ];
    int lastTopRank = top.isEmpty ? 0 : (top.last['rank'] as num).toInt();
    bool gap = extra.isNotEmpty && (extra.first['rank'] as num).toInt() > lastTopRank + 1;

    return [
      for (Map r in top) _LeagueRow(row: r),
      if (gap)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Center(child: Text('•  •  •', style: AppText.heading(size: 16, color: AppColors.muted))),
        ),
      for (Map r in extra) _LeagueRow(row: r),
    ];
  }
}

/// One place in the league: rank circle, name and check-ins this month. The
/// owner's own place has a purple border and name.
class _LeagueRow extends StatelessWidget {
  final Map row;

  const _LeagueRow({required this.row});

  @override
  Widget build(BuildContext context) {
    int rank = (row['rank'] as num).toInt();
    bool isYou = row['isYou'] == true;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
        border: Border.all(color: isYou ? AppColors.purple : AppColors.lightPurple, width: isYou ? 2.5 : 2),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: LeaderboardRow.rankColor(rank), shape: BoxShape.circle),
            child: Text(formatNumber(rank), style: AppText.heading(size: rank < 100 ? 16 : 14)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${row['placeName']}',
              semanticsLabel: isYou ? '${row['placeName']}, your place' : null,
              style: AppText.body(size: 16, weight: FontWeight.w800, color: isYou ? AppColors.purple : AppColors.ink),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(formatNumber(row['checkIns']), style: AppText.heading(size: 18)),
        ],
      ),
    );
  }
}

/// A light mint confirmation line.
class _Notice extends StatelessWidget {
  final String text;

  const _Notice({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: AppColors.lightMint, borderRadius: BorderRadius.circular(AppShapes.fieldRadius)),
      child: Row(
        children: [
          const Icon(Icons.check_circle_rounded, color: AppColors.ink, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: AppText.body(size: 15, weight: FontWeight.w700))),
        ],
      ),
    );
  }
}

/// An empty state inside a card: an icon square, a title and a line of text.
class _EmptyNote extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;

  const _EmptyNote({required this.icon, required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(24)),
      child: Row(
        children: [
          IconSquare(color: AppColors.lightPurple, icon: icon, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.heading(size: 17)),
                Text(text, style: AppText.body(size: 14, color: AppColors.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
