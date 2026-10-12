import 'package:flutter/material.dart';

import 'app_only.dart';
import 'check_in_place.dart';
import 'group_check_in.dart';
import 'theme.dart';

/// What a check-in attempt came to, from MapScreen's check-in.
class CheckInOutcome {
  /// Why it failed, or null if it worked.
  final String? error;
  final String placeName;
  final int? pointsEarned;
  final String? groupId;

  /// Why it earned less than usual, if it did.
  final String? pointsNote;
  final int invited;

  const CheckInOutcome.failed(this.error)
      : placeName = '',
        pointsEarned = null,
        groupId = null,
        pointsNote = null,
        invited = 0;

  const CheckInOutcome.succeeded({
    required this.placeName,
    required this.pointsEarned,
    this.groupId,
    this.pointsNote,
    this.invited = 0,
  }) : error = null;

  bool get succeeded => error == null;
}

/// Checking in at a partner business: the code from the staff, optional
/// friends for a group check-in, and the Check in button. Pops with the
/// [CheckInOutcome] once a check-in works; on failure it stays, shows why and
/// clears the code so it can be typed again.
class PlaceScreen extends StatefulWidget {
  final CheckInPlace place;
  final double distanceMeters;
  final Future<CheckInOutcome> Function({required String code, required List<String> friendUids}) onCheckIn;

  const PlaceScreen({super.key, required this.place, required this.distanceMeters, required this.onCheckIn});

  @override
  State<PlaceScreen> createState() => _PlaceScreenState();
}

class _PlaceScreenState extends State<PlaceScreen> {
  static const int codeLength = 6; // keep in sync with BUSINESS_CODE_DIGITS

  final TextEditingController codeController = TextEditingController();

  // Friends to invite to a group check-in (id -> username).
  Map<String, String> groupFriends = {};
  String? checkInError;
  bool isCheckingIn = false;

  @override
  void dispose() {
    codeController.dispose();
    super.dispose();
  }

  Future<void> _checkIn() async {
    if (isCheckingIn) return;
    setState(() {
      isCheckingIn = true;
      checkInError = null;
    });
    CheckInOutcome outcome = await widget.onCheckIn(
      code: codeController.text.trim(),
      friendUids: groupFriends.keys.toList(),
    );
    if (!mounted) return;
    if (outcome.succeeded) {
      Navigator.of(context).pop(outcome);
      return;
    }
    setState(() {
      isCheckingIn = false;
      checkInError = outcome.error;
      codeController.clear();
    });
  }

  Future<void> _pickFriends() async {
    var picked = await pickGroupFriends(context, groupFriends);
    if (picked != null && mounted) setState(() => groupFriends = picked);
  }

  @override
  Widget build(BuildContext context) {
    CheckInPlace place = widget.place;
    Color headerColor = place.category.color;

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _Header(color: headerColor, icon: place.category.icon),
                    Positioned(
                      top: MediaQuery.of(context).padding.top + 8,
                      left: 12,
                      child: _RoundIconButton(
                        icon: Icons.arrow_back_rounded,
                        tooltip: 'Back',
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 130, 20, 0),
                      child: _InfoCard(place: place, distanceMeters: widget.distanceMeters),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (appOnlyFeaturesAvailable) ...[
                        Text('Code from the staff', style: AppText.heading(size: 20)),
                        const SizedBox(height: 4),
                        Text(
                          'Ask the staff at ${place.name} for today\'s $codeLength-digit code.',
                          style: AppText.body(size: 15, color: AppColors.muted),
                        ),
                        const SizedBox(height: 12),
                        CodeBoxes(controller: codeController, length: codeLength, enabled: !isCheckingIn),
                        const SizedBox(height: 20),
                        _FriendsCard(
                          friends: groupFriends,
                          enabled: !isCheckingIn,
                          onToggle: (on) => on ? _pickFriends() : setState(() => groupFriends = {}),
                          onEdit: _pickFriends,
                        ),
                      ] else
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(appOnlyMessage, textAlign: TextAlign.center, style: AppText.body()),
                          ),
                        ),
                      if (checkInError != null) ...[
                        const SizedBox(height: 16),
                        ErrorNote(message: checkInError!),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (appOnlyFeaturesAvailable)
            SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              // Rebuilds as the code is typed, to enable the button.
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: codeController,
                builder: (context, code, _) {
                  bool needsCode = code.text.trim().length != codeLength;
                  return ElevatedButton(
                    onPressed: isCheckingIn || needsCode ? null : _checkIn,
                    style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 60)),
                    child: isCheckingIn
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5), // on the disabled button
                          )
                        : const Text('Check in', style: TextStyle(fontSize: 20)),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// A rounded header in [color] with big decorative circles.
class _Header extends StatelessWidget {
  final Color color;
  final IconData icon;

  const _Header({required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    Color onColor = AppColors.onColor(color);
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(40)),
      child: Container(
        height: MediaQuery.of(context).padding.top + 190,
        color: color,
        child: Stack(
          children: [
            Positioned(right: -40, top: -30, child: _circle(170, AppColors.yellow)),
            Positioned(left: -30, bottom: -50, child: _circle(130, Colors.white.withValues(alpha: 0.25))),
            Positioned(right: 70, bottom: 30, child: _circle(36, Colors.white.withValues(alpha: 0.35))),
            Positioned(
              right: 28,
              top: MediaQuery.of(context).padding.top + 34,
              child: Icon(icon, size: 56, color: onColor.withValues(alpha: 0.85)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _circle(double size, Color color) =>
      Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _RoundIconButton({required this.icon, required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card,
      shape: const CircleBorder(),
      elevation: 2,
      shadowColor: AppColors.ink.withValues(alpha: 0.3),
      child: IconButton(tooltip: tooltip, icon: Icon(icon, color: AppColors.ink), onPressed: onPressed),
    );
  }
}

/// Name, category, tier, distance and what a check-in is worth.
class _InfoCard extends StatelessWidget {
  final CheckInPlace place;
  final double distanceMeters;

  const _InfoCard({required this.place, required this.distanceMeters});

  @override
  Widget build(BuildContext context) {
    String? tier = place.partner ? '${tierLabels[place.tier] ?? 'Partner'} partner' : null;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppShapes.cardRadius),
        boxShadow: AppShapes.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconSquare(color: place.category.color, icon: place.category.icon),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(place.name, style: AppText.heading(size: 24)),
                    Text(
                      [place.category.label, ?tier].join(' · '),
                      style: AppText.body(size: 15, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ColorChip(label: '+${place.points} pts', color: AppColors.mint),
              ColorChip(
                label: '${distanceMeters.toStringAsFixed(0)} m away',
                color: AppColors.lightPurple,
                icon: Icons.near_me_rounded,
              ),
            ],
          ),
          if (place.budgetUsedUp) ...[
            const SizedBox(height: 10),
            Text(
              'This partner\'s monthly bonus is used up, so check-ins earn the touristic rate until next month.',
              style: AppText.body(size: 14, color: AppColors.muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// Group check-ins: a switch that opens the friend picker, with the bonus.
class _FriendsCard extends StatelessWidget {
  final Map<String, String> friends;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;

  const _FriendsCard({required this.friends, required this.enabled, required this.onToggle, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    bool on = friends.isNotEmpty;
    String bonus = formatMultiplier(groupMultipliers[on ? friends.length + 1 : 2]!);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppShapes.cardRadius),
        onTap: !enabled ? null : (on ? onEdit : () => onToggle(true)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
          child: Row(
            children: [
              const IconSquare(color: AppColors.yellow, icon: Icons.group_add_rounded, size: 48),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(child: Text('Check in with friends', style: AppText.heading(size: 17))),
                        const SizedBox(width: 8),
                        ColorChip(label: bonus, color: AppColors.yellow, compact: true),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      on
                          ? 'With ${friends.values.map((u) => '@$u').join(', ')}. Tap to change.'
                          : 'Optional. Friends join from their own phones within 10 minutes.',
                      style: AppText.body(size: 14, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              Switch(value: on, onChanged: enabled ? onToggle : null),
            ],
          ),
        ),
      ),
    );
  }
}

/// [length] boxes, one per digit, over an invisible text field that takes
/// the typing. Filled boxes get a purple border.
class CodeBoxes extends StatefulWidget {
  final TextEditingController controller;
  final int length;
  final bool enabled;

  /// What screen readers call it; defaults to the check-in code.
  final String? semanticsLabel;

  const CodeBoxes({
    super.key,
    required this.controller,
    required this.length,
    this.enabled = true,
    this.semanticsLabel,
  });

  @override
  State<CodeBoxes> createState() => _CodeBoxesState();
}

class _CodeBoxesState extends State<CodeBoxes> {
  final FocusNode focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    focusNode.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.semanticsLabel ?? 'Check-in code, ${widget.length} digits',
      child: SizedBox(
        height: 64,
        child: Stack(
          children: [
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (context, value, _) {
                String text = value.text;
                return Row(
                  children: [
                    for (int i = 0; i < widget.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(child: _box(i < text.length ? text[i] : '', i, text.length)),
                    ],
                  ],
                );
              },
            ),
            // Takes taps and typing; its own text and cursor are invisible.
            Positioned.fill(
              child: TextField(
                controller: widget.controller,
                focusNode: focusNode,
                enabled: widget.enabled,
                keyboardType: TextInputType.number,
                maxLength: widget.length,
                showCursor: false,
                enableInteractiveSelection: false,
                style: const TextStyle(color: Colors.transparent, fontSize: 1),
                decoration: const InputDecoration(
                  isCollapsed: true,
                  filled: false,
                  counterText: '',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _box(String digit, int index, int filledCount) {
    bool filled = digit.isNotEmpty;
    bool next = focusNode.hasFocus && index == filledCount;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: filled ? AppColors.purple : (next ? AppColors.purple.withValues(alpha: 0.45) : AppColors.lightPurple),
          width: filled ? 2.5 : 2,
        ),
      ),
      alignment: Alignment.center,
      child: Text(digit, style: AppText.heading(size: 28)),
    );
  }
}
