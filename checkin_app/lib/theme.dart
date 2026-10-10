import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The app's colours. Text on coral, yellow, mint and sky is [ink], never
/// white; only [purple] takes white text.
class AppColors {
  static const Color ink = Color(0xFF231A5C);
  static const Color muted = Color(0xFF6B6794);
  static const Color background = Color(0xFFF5F1FF);
  static const Color card = Colors.white;

  static const Color purple = Color(0xFF6C4DFF);
  static const Color coral = Color(0xFFFF5D7A);
  static const Color yellow = Color(0xFFFFC83D);
  static const Color mint = Color(0xFF1FC8A0);
  static const Color sky = Color(0xFF4C9BFF);

  /// Selected backgrounds (the tab pill, chips).
  static const Color lightPurple = Color(0xFFEDE8FF);

  /// Map pins for businesses that aren't partners (no check-in).
  static const Color inactive = Color(0xFFB8B4CC);

  /// Error text. Coral itself is too light to read as small text on white.
  static const Color error = Color(0xFFD7385A);

  /// The text colour that reads on [background]: white on purple, ink on
  /// everything else.
  static Color onColor(Color background) => background == purple ? Colors.white : ink;
}

/// Corner radii and sizes shared by the components.
class AppShapes {
  static const double cardRadius = 28;
  static const double fieldRadius = 20;
  static const double buttonHeight = 54;
  static const double minTapTarget = 44;

  /// Soft shadow for cards and floating bars.
  static final List<BoxShadow> softShadow = [
    BoxShadow(color: AppColors.ink.withValues(alpha: 0.08), blurRadius: 24, offset: const Offset(0, 8)),
  ];
}

/// Headings, numbers and buttons use Fredoka; body text uses Nunito. No
/// style is smaller than 14.
class AppText {
  static TextStyle heading({double size = 22, FontWeight weight = FontWeight.w700, Color color = AppColors.ink}) =>
      GoogleFonts.fredoka(fontSize: size, fontWeight: weight, color: color, height: 1.2);

  static TextStyle body({double size = 16, FontWeight weight = FontWeight.w600, Color color = AppColors.ink}) =>
      GoogleFonts.nunito(fontSize: size, fontWeight: weight, color: color, height: 1.35);

  static TextTheme textTheme() => TextTheme(
        displayLarge: heading(size: 56),
        displayMedium: heading(size: 44),
        displaySmall: heading(size: 36),
        headlineLarge: heading(size: 32),
        headlineMedium: heading(size: 28),
        headlineSmall: heading(size: 24),
        titleLarge: heading(size: 22),
        titleMedium: heading(size: 18, weight: FontWeight.w600),
        titleSmall: heading(size: 16, weight: FontWeight.w600),
        bodyLarge: body(size: 16),
        bodyMedium: body(size: 15),
        bodySmall: body(size: 14, color: AppColors.muted),
        labelLarge: heading(size: 17, weight: FontWeight.w600),
        labelMedium: body(size: 14, weight: FontWeight.w700),
        labelSmall: body(size: 14, weight: FontWeight.w700),
      );
}

class AppTheme {
  static ThemeData light() {
    TextTheme text = AppText.textTheme();
    const pill = StadiumBorder();
    const buttonSize = Size(64, AppShapes.buttonHeight);
    TextStyle buttonText = AppText.heading(size: 17, weight: FontWeight.w600);

    return ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme(
        brightness: Brightness.light,
        primary: AppColors.purple,
        onPrimary: Colors.white,
        primaryContainer: AppColors.lightPurple,
        onPrimaryContainer: AppColors.ink,
        secondary: AppColors.coral,
        onSecondary: AppColors.ink,
        secondaryContainer: AppColors.lightPurple,
        onSecondaryContainer: AppColors.ink,
        tertiary: AppColors.mint,
        onTertiary: AppColors.ink,
        error: AppColors.error,
        onError: Colors.white,
        surface: AppColors.card,
        onSurface: AppColors.ink,
        onSurfaceVariant: AppColors.muted,
        surfaceContainerHighest: AppColors.lightPurple,
        outline: AppColors.inactive,
        outlineVariant: AppColors.lightPurple,
      ),
      scaffoldBackgroundColor: AppColors.background,
      textTheme: text,
      iconTheme: const IconThemeData(color: AppColors.ink),
      materialTapTargetSize: MaterialTapTargetSize.padded,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: AppText.heading(size: 24),
      ),
      cardTheme: CardThemeData(
        color: AppColors.card,
        elevation: 2,
        shadowColor: AppColors.ink.withValues(alpha: 0.25),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppShapes.cardRadius)),
        margin: const EdgeInsets.symmetric(vertical: 6),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.purple,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.lightPurple,
          disabledForegroundColor: AppColors.muted,
          minimumSize: buttonSize,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          shape: pill,
          elevation: 3,
          shadowColor: AppColors.purple.withValues(alpha: 0.4),
          textStyle: buttonText,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.purple,
          foregroundColor: Colors.white,
          minimumSize: buttonSize,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          shape: pill,
          textStyle: buttonText,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.purple,
          backgroundColor: AppColors.card,
          minimumSize: buttonSize,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          shape: pill,
          side: const BorderSide(color: AppColors.purple, width: 2),
          textStyle: buttonText,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.purple,
          minimumSize: const Size(AppShapes.minTapTarget, AppShapes.minTapTarget),
          shape: pill,
          textStyle: AppText.heading(size: 16, weight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(AppShapes.minTapTarget, AppShapes.minTapTarget),
          foregroundColor: AppColors.ink,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          minimumSize: const Size(AppShapes.minTapTarget, AppShapes.minTapTarget),
          selectedBackgroundColor: AppColors.lightPurple,
          selectedForegroundColor: AppColors.purple,
          foregroundColor: AppColors.ink,
          side: const BorderSide(color: AppColors.lightPurple, width: 2),
          shape: pill,
          textStyle: AppText.body(size: 14, weight: FontWeight.w700),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.lightPurple,
        selectedColor: AppColors.lightPurple,
        labelStyle: AppText.body(size: 14, weight: FontWeight.w700),
        side: BorderSide.none,
        shape: pill,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.card,
        labelStyle: AppText.body(size: 16, color: AppColors.muted),
        hintStyle: AppText.body(size: 16, color: AppColors.muted),
        errorStyle: AppText.body(size: 14, color: AppColors.error),
        helperStyle: AppText.body(size: 14, color: AppColors.muted),
        counterStyle: AppText.body(size: 14, color: AppColors.muted),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
          borderSide: const BorderSide(color: AppColors.lightPurple, width: 2),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
          borderSide: const BorderSide(color: AppColors.lightPurple, width: 2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
          borderSide: const BorderSide(color: AppColors.purple, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
          borderSide: const BorderSide(color: AppColors.error, width: 2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppShapes.fieldRadius),
          borderSide: const BorderSide(color: AppColors.error, width: 2),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: AppColors.ink,
        titleTextStyle: AppText.body(size: 16, weight: FontWeight.w700),
        subtitleTextStyle: AppText.body(size: 14, color: AppColors.muted),
        minTileHeight: 56,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppShapes.fieldRadius)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? Colors.white : AppColors.inactive),
        trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? AppColors.purple : AppColors.lightPurple),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.purple,
        linearTrackColor: AppColors.lightPurple,
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      dividerTheme: const DividerThemeData(color: AppColors.lightPurple, thickness: 2),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppShapes.cardRadius)),
        titleTextStyle: AppText.heading(size: 22),
        contentTextStyle: AppText.body(size: 16),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.ink,
        contentTextStyle: AppText.body(size: 15, color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppShapes.fieldRadius)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppShapes.cardRadius))),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.purple,
        foregroundColor: Colors.white,
        shape: StadiumBorder(),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 76,
        indicatorColor: AppColors.lightPurple,
        indicatorShape: pill,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              color: states.contains(WidgetState.selected) ? AppColors.purple : AppColors.muted,
              size: 26,
            )),
        labelTextStyle: WidgetStateProperty.resolveWith((states) => AppText.heading(
              size: 14,
              weight: FontWeight.w600,
              color: states.contains(WidgetState.selected) ? AppColors.purple : AppColors.muted,
            )),
      ),
    );
  }
}

/// One tab of [AppTabBar].
class AppTab {
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  const AppTab({required this.icon, required this.selectedIcon, required this.label});
}

/// The white bottom tab bar with rounded top corners. The selected tab sits
/// in a light purple pill (navigationBarTheme above).
class AppTabBar extends StatelessWidget {
  final List<AppTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const AppTabBar({super.key, required this.tabs, required this.selectedIndex, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(AppShapes.cardRadius)),
        boxShadow: AppShapes.softShadow,
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(AppShapes.cardRadius)),
        child: NavigationBar(
          selectedIndex: selectedIndex,
          onDestinationSelected: onSelected,
          destinations: [
            for (var tab in tabs)
              NavigationDestination(icon: Icon(tab.icon), selectedIcon: Icon(tab.selectedIcon), label: tab.label),
          ],
        ),
      ),
    );
  }
}
