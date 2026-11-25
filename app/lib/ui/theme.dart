import 'package:material_ui/material_ui.dart';

import '../core/node_catalog.dart';
import 'icons.dart';

/// The app's design tokens and Material theme (see DESIGN.md): white cards with
/// hairline borders on a soft grey page, small radii, compact Inter type.
abstract final class AppTheme {
  static const fontFamily = 'Inter';
  static const monoFamily = 'JetBrains Mono';

  static ThemeData light() => _build(AppColors.light, Brightness.light);

  static ThemeData dark() => _build(AppColors.dark, Brightness.dark);

  static ThemeData _build(AppColors c, Brightness brightness) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: c.accent,
      onPrimary: Colors.white,
      primaryContainer: c.accentSoft,
      onPrimaryContainer: c.accent,
      secondary: c.textSecondary,
      onSecondary: c.background,
      secondaryContainer: c.grouped,
      onSecondaryContainer: c.text,
      error: c.danger,
      onError: Colors.white,
      errorContainer: c.dangerSoft,
      onErrorContainer: c.danger,
      surface: c.background,
      onSurface: c.text,
      onSurfaceVariant: c.textSecondary,
      surfaceContainerLowest: c.canvas,
      surfaceContainerLow: c.surface,
      surfaceContainer: c.surface,
      surfaceContainerHigh: c.surface,
      surfaceContainerHighest: c.grouped,
      outline: c.outline,
      outlineVariant: c.hairline,
      inverseSurface: c.text,
      onInverseSurface: c.background,
      inversePrimary: c.accentSoft,
      shadow: Colors.black,
      scrim: Colors.black,
      surfaceTint: Colors.transparent,
    );
    final text = _textTheme(c);
    final radius = BorderRadius.circular(Radii.control);
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: fontFamily,
      textTheme: text,
      scaffoldBackgroundColor: c.background,
      canvasColor: c.background,
      dividerColor: c.hairline,
      splashFactory: InkRipple.splashFactory,
      extensions: [c],
      appBarTheme: AppBarTheme(
        backgroundColor: c.background,
        foregroundColor: c.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: text.titleMedium,
        iconTheme: IconThemeData(color: c.text, size: 22),
        actionsIconTheme: IconThemeData(color: c.textSecondary, size: 22),
      ),
      iconTheme: IconThemeData(color: c.textSecondary, size: 22),
      dividerTheme: DividerThemeData(color: c.hairline, thickness: 1, space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: Colors.white,
          minimumSize: const Size(44, 42),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(borderRadius: radius),
          textStyle: text.labelLarge,
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.accent,
          minimumSize: const Size(44, 44),
          textStyle: text.labelLarge,
          shape: RoundedRectangleBorder(borderRadius: radius),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.text,
          backgroundColor: c.surface,
          minimumSize: const Size(44, 42),
          side: BorderSide(color: c.outline),
          textStyle: text.labelLarge,
          shape: RoundedRectangleBorder(borderRadius: radius),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: c.textSecondary,
          minimumSize: const Size(44, 44),
          shape: RoundedRectangleBorder(borderRadius: radius),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: c.accent,
        foregroundColor: Colors.white,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        extendedTextStyle: text.labelLarge,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.card)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Colors.white),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.switchOff),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        hintStyle: text.bodyMedium?.copyWith(color: c.textTertiary),
        border: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: c.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: c.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: c.accent, width: 1.2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: c.danger, width: 1.5),
        ),
        prefixIconColor: c.textTertiary,
        suffixIconColor: c.textTertiary,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: c.outline,
        dragHandleSize: const Size(36, 4),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet))),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sheet)),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium?.copyWith(color: c.textSecondary),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.card),
          side: BorderSide(color: c.hairline),
        ),
        textStyle: text.bodyMedium,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.text,
        contentTextStyle: text.bodyMedium?.copyWith(color: c.background),
        actionTextColor: c.accentSoft,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control)),
        elevation: 0,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: c.accent,
        unselectedLabelColor: c.textSecondary,
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w500),
        indicator: UnderlineTabIndicator(borderSide: BorderSide(color: c.accent, width: 2)),
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: c.hairline,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: Space.page),
        titleTextStyle: text.bodyLarge,
        subtitleTextStyle: text.bodySmall?.copyWith(color: c.textSecondary),
        iconColor: c.textSecondary,
        minVerticalPadding: 10,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? c.accentSoft : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? c.accent : c.textSecondary,
          ),
          side: WidgetStatePropertyAll(BorderSide(color: c.outline)),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: radius)),
          textStyle: WidgetStatePropertyAll(text.labelLarge),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: c.text, borderRadius: BorderRadius.circular(Radii.tag)),
        textStyle: text.bodySmall?.copyWith(color: c.background),
      ),
      badgeTheme: BadgeThemeData(backgroundColor: c.danger, textColor: Colors.white),
      chipTheme: ChipThemeData(
        backgroundColor: c.surface,
        side: BorderSide(color: c.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.tag)),
        labelStyle: text.labelMedium?.copyWith(color: c.text),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: BorderSide(color: c.outline, width: 1.5),
      ),
    );
  }

  static TextTheme _textTheme(AppColors c) {
    TextStyle s(double size, FontWeight weight, {double height = 1.3, double tracking = 0, Color? color}) => TextStyle(
      fontFamily: fontFamily,
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: tracking,
      color: color ?? c.text,
    );
    return TextTheme(
      headlineMedium: s(24, FontWeight.w600, height: 1.2, tracking: -0.5),
      titleLarge: s(19, FontWeight.w600, height: 1.25, tracking: -0.3),
      titleMedium: s(15.5, FontWeight.w600, height: 1.3, tracking: -0.15),
      titleSmall: s(14, FontWeight.w600, height: 1.3, tracking: -0.1),
      bodyLarge: s(14.5, FontWeight.w400, height: 1.45),
      bodyMedium: s(14, FontWeight.w400, height: 1.45),
      bodySmall: s(12.5, FontWeight.w400, height: 1.4, color: c.textSecondary),
      labelLarge: s(14, FontWeight.w600, height: 1.2),
      labelMedium: s(12.5, FontWeight.w500, height: 1.2, color: c.textSecondary),
      labelSmall: s(11, FontWeight.w600, height: 1.2, tracking: 0.5, color: c.textTertiary),
    );
  }

  static const monospace = TextStyle(fontFamily: monoFamily, fontSize: 13, height: 1.45);
}

/// Corner radii: small and consistent, never pills.
abstract final class Radii {
  /// Tags and badges.
  static const tag = 6.0;

  /// Buttons, fields and small tiles.
  static const control = 10.0;

  /// Cards, steps on the canvas, menus.
  static const card = 12.0;

  /// Bottom sheets and dialogs.
  static const sheet = 16.0;
}

/// Spacing steps (dp), on a 4-pt base.
abstract final class Space {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const page = 20.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// Color tokens; see DESIGN.md. Read with `AppColors.of(context)`.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.background,
    required this.canvas,
    required this.surface,
    required this.grouped,
    required this.hairline,
    required this.outline,
    required this.switchOff,
    required this.text,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentSoft,
    required this.success,
    required this.successSoft,
    required this.warning,
    required this.warningSoft,
    required this.danger,
    required this.dangerSoft,
    required this.shadow,
    required this.groups,
  });

  static const light = AppColors(
    // A soft grey page; cards and sheets are white on it.
    background: Color(0xFFF4F4F5),
    canvas: Color(0xFFF4F4F5),
    surface: Color(0xFFFFFFFF),
    grouped: Color(0xFFF1F1F3),
    hairline: Color(0xFFE7E7EA),
    outline: Color(0xFFDCDCE0),
    switchOff: Color(0xFFE4E4E7),
    text: Color(0xFF18181B),
    textSecondary: Color(0xFF6B6B73),
    textTertiary: Color(0xFF9A9AA2),
    accent: Color(0xFF2F7CF6),
    accentSoft: Color(0xFFE6F0FE),
    success: Color(0xFF2E9E52),
    successSoft: Color(0xFFE7F6EC),
    warning: Color(0xFFE8920C),
    warningSoft: Color(0xFFFFF4E0),
    danger: Color(0xFFE5484D),
    dangerSoft: Color(0xFFFDECEC),
    shadow: Color(0x14000000),
    groups: {
      NodeGroup.trigger: Color(0xFFD9820A),
      NodeGroup.flow: Color(0xFF7A5AF0),
      NodeGroup.data: Color(0xFF0F9D8F),
      NodeGroup.network: Color(0xFF2F7CF6),
      NodeGroup.android: Color(0xFF2E9E52),
      NodeGroup.ai: Color(0xFFD6409F),
      NodeGroup.communication: Color(0xFF5B5BD6),
      NodeGroup.database: Color(0xFF0E8AA8),
      NodeGroup.productivity: Color(0xFFE0562B),
      NodeGroup.system: Color(0xFF5F6168),
    },
  );

  static const dark = AppColors(
    background: Color(0xFF0E0E10),
    canvas: Color(0xFF0E0E10),
    surface: Color(0xFF18181B),
    grouped: Color(0xFF222226),
    hairline: Color(0xFF29292E),
    outline: Color(0xFF36363C),
    switchOff: Color(0xFF3A3A40),
    text: Color(0xFFF2F2F4),
    textSecondary: Color(0xFFA1A1A8),
    textTertiary: Color(0xFF7C7C84),
    accent: Color(0xFF4C8DFF),
    accentSoft: Color(0xFF1A2A47),
    success: Color(0xFF4CC26E),
    successSoft: Color(0xFF173322),
    warning: Color(0xFFF2A93B),
    warningSoft: Color(0xFF3A2A12),
    danger: Color(0xFFFF6369),
    dangerSoft: Color(0xFF3D1A1C),
    shadow: Color(0x66000000),
    // Lighter tints of the same hues, so icons stay clear on dark surfaces.
    groups: {
      NodeGroup.trigger: Color(0xFFF2A93B),
      NodeGroup.flow: Color(0xFFA48DFF),
      NodeGroup.data: Color(0xFF3CC7B8),
      NodeGroup.network: Color(0xFF6EA4FF),
      NodeGroup.android: Color(0xFF55C878),
      NodeGroup.ai: Color(0xFFF06BBF),
      NodeGroup.communication: Color(0xFF9191F7),
      NodeGroup.database: Color(0xFF45BEDB),
      NodeGroup.productivity: Color(0xFFF2825C),
      NodeGroup.system: Color(0xFFA1A1A8),
    },
  );

  final Color background;
  final Color canvas;
  final Color surface;
  final Color grouped;
  final Color hairline;
  final Color outline;
  final Color switchOff;
  final Color text;
  final Color textSecondary;
  final Color textTertiary;
  final Color accent;
  final Color accentSoft;
  final Color success;
  final Color successSoft;
  final Color warning;
  final Color warningSoft;
  final Color danger;
  final Color dangerSoft;
  final Color shadow;

  /// Each node group's color: its icons and its mark in lists.
  final Map<NodeGroup, Color> groups;

  /// The color of [group] in this theme.
  Color groupColor(NodeGroup group) => groups[group] ?? textSecondary;

  static AppColors of(BuildContext context) => Theme.of(context).extension<AppColors>() ?? light;

  /// The soft shadow used by nodes and floating controls.
  List<BoxShadow> get softShadow => [
    BoxShadow(
      color: shadow.withValues(alpha: shadow.a * 0.6),
      blurRadius: 2,
      offset: const Offset(0, 1),
    ),
    BoxShadow(
      color: shadow.withValues(alpha: shadow.a * 0.5),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
  ];

  /// A white card on the grey page: hairline border and a barely-there shadow.
  BoxDecoration card({double radius = Radii.card}) => BoxDecoration(
    color: surface,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: hairline),
    boxShadow: [
      BoxShadow(
        color: shadow.withValues(alpha: shadow.a * 0.4),
        blurRadius: 3,
        offset: const Offset(0, 1),
      ),
    ],
  );

  @override
  AppColors copyWith() => this;

  /// Blends every color, so switching light and dark mode fades instead of jumping.
  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      background: l(background, other.background),
      canvas: l(canvas, other.canvas),
      surface: l(surface, other.surface),
      grouped: l(grouped, other.grouped),
      hairline: l(hairline, other.hairline),
      outline: l(outline, other.outline),
      switchOff: l(switchOff, other.switchOff),
      text: l(text, other.text),
      textSecondary: l(textSecondary, other.textSecondary),
      textTertiary: l(textTertiary, other.textTertiary),
      accent: l(accent, other.accent),
      accentSoft: l(accentSoft, other.accentSoft),
      success: l(success, other.success),
      successSoft: l(successSoft, other.successSoft),
      warning: l(warning, other.warning),
      warningSoft: l(warningSoft, other.warningSoft),
      danger: l(danger, other.danger),
      dangerSoft: l(dangerSoft, other.dangerSoft),
      shadow: l(shadow, other.shadow),
      groups: {for (final g in NodeGroup.values) g: l(groupColor(g), other.groupColor(g))},
    );
  }
}

/// Icon and label for each node group and type; group colors are in [AppColors.groupColor].
abstract final class NodeVisuals {
  static String groupLabel(NodeGroup group) => switch (group) {
    NodeGroup.trigger => 'Triggers',
    NodeGroup.flow => 'Flow',
    NodeGroup.data => 'Data',
    NodeGroup.network => 'Network',
    NodeGroup.android => 'Phone',
    NodeGroup.ai => 'AI',
    NodeGroup.communication => 'Messaging',
    NodeGroup.database => 'Databases',
    NodeGroup.productivity => 'Google',
    NodeGroup.system => 'System',
  };

  static IconData icon(String type) => _icons[type] ?? AppIcons.node;

  static const _icons = <String, IconData>{
    'trigger.manual': AppIcons.tap,
    'trigger.schedule': AppIcons.clock,
    'trigger.webhook': AppIcons.webhook,
    'trigger.telegram': AppIcons.send,
    'core.if': AppIcons.branch,
    'core.filter': AppIcons.filter,
    'core.switch': AppIcons.route,
    'core.merge': AppIcons.merge,
    'core.noop': AppIcons.forward,
    'core.wait': AppIcons.hourglass,
    'core.respond': AppIcons.reply,
    'core.set': AppIcons.fields,
    'core.splitOut': AppIcons.split,
    'core.aggregate': AppIcons.gather,
    'core.sort': AppIcons.sort,
    'core.removeDuplicates': AppIcons.dedupe,
    'core.limit': AppIcons.limit,
    'http.request': AppIcons.globe,
    'android.notify': AppIcons.bell,
    'android.speak': AppIcons.speak,
    'android.vibrate': AppIcons.vibrate,
    'android.openUrl': AppIcons.external,
    'android.clipboardWrite': AppIcons.copy,
    'android.clipboardRead': AppIcons.paste,
    'android.battery': AppIcons.battery,
    'android.location': AppIcons.locate,
    'ai.chat': AppIcons.sparkle,
    'telegram.send': AppIcons.send,
    'discord.send': AppIcons.chat,
    'db.supabase': AppIcons.database,
    'db.airtable': AppIcons.table,
    'db.notion': AppIcons.document,
    'db.table': AppIcons.rows,
    'google.sheets': AppIcons.sheet,
    'google.gmail': AppIcons.mail,
    'google.calendar': AppIcons.calendar,
    'system.command': AppIcons.terminal,
    'trigger.subworkflow': AppIcons.enter,
    'trigger.error': AppIcons.error,
    'trigger.sms': AppIcons.message,
    'trigger.notification': AppIcons.bellDot,
    'trigger.phone': AppIcons.phone,
    'trigger.place': AppIcons.place,
    'trigger.share': AppIcons.share,
    'trigger.tile': AppIcons.toggle,
    'trigger.rss': AppIcons.rss,
    'trigger.email': AppIcons.mailDot,
    'core.loop': AppIcons.loop,
    'core.executeWorkflow': AppIcons.workflow,
    'core.code': AppIcons.code,
    'ai.agent': AppIcons.agent,
    'mcp.client': AppIcons.connect,
    'trigger.mcp': AppIcons.server,
    'trigger.calendar': AppIcons.calendarDot,
    'android.calendar': AppIcons.calendar,
    'android.ask': AppIcons.ask,
    'android.listen': AppIcons.mic,
    'android.sound': AppIcons.bellOff,
    'android.contacts': AppIcons.person,
    'android.clock': AppIcons.timer,
    'android.photo': AppIcons.camera,
    'browser.run': AppIcons.browser,
    'android.sms': AppIcons.message,
    'email.send': AppIcons.mailSend,
    'rss.read': AppIcons.rss,
    'files': AppIcons.folder,
    'files.extract': AppIcons.document,
    'rag.add': AppIcons.database,
    'rag.search': AppIcons.search,
    'rag.info': AppIcons.rows,
    'google.drive': AppIcons.cloud,
  };
}
