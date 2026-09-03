import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../brand.dart';
import '../strings.dart';

/// Design tokens and shared widgets for the 2.0 redesign.
///
/// The palette is the same on every platform. It comes in two variants
/// (mirroring app.css `.hip-root` and `.hip-root.dark-mode`): light content
/// surfaces, or dark surfaces when the user turns the in-app dark mode on.
/// The hero/onboarding panel is dark in both.
class Hip {
  Hip._();

  /// Dark-mode switch. The shell sets this from [UiPrefs.darkMode] before
  /// each frame; every token below resolves against it at build time, so a
  /// full rebuild (which the prefs change already triggers) recolors the app.
  static bool dm = false;

  // Palette (mirrors app.css .hip-root custom properties).
  static Color get blue =>
      dm ? Brand.hsl(220, 95, 60) : Brand.hsl(220, 95, 55);
  static Color get blueSoft =>
      dm ? Brand.hsl(220, 95, 60, .14) : Brand.hsl(220, 95, 55, .1);
  static Color get blueDeep =>
      dm ? Brand.hsl(220, 95, 72) : Brand.hsl(220, 95, 48);
  static Color get ink => dm ? Brand.hsl(220, 20, 93) : Brand.hsl(0, 0, 7);
  static Color get inkSoft =>
      dm ? Brand.hsl(220, 12, 78) : Brand.hsl(0, 0, 28);
  static Color get muted => dm ? Brand.hsl(220, 8, 58) : Brand.hsl(0, 0, 45);
  // AA contrast pass (app.css brief 10): the dark variant is the lighter
  // of the two, which is the opposite of what it used to be here.
  static Color get muted2 =>
      dm ? Brand.hsl(220, 10, 62) : Brand.hsl(0, 0, 46);
  static Color get line => dm ? Brand.hsl(222, 14, 19) : Brand.hsl(0, 0, 92);
  static Color get line2 => dm ? Brand.hsl(222, 14, 14) : Brand.hsl(0, 0, 96);
  static Color get card => dm ? Brand.hsl(222, 20, 10) : Brand.hsl(0, 0, 100);
  static Color get surface =>
      dm ? Brand.hsl(222, 30, 6) : Brand.hsl(0, 0, 99);
  static Color get success =>
      dm ? Brand.hsl(152, 55, 50) : Brand.hsl(152, 60, 38);
  static Color get successSoft =>
      dm ? Brand.hsl(152, 60, 45, .14) : Brand.hsl(152, 60, 38, .1);
  static Color get danger => dm ? Brand.hsl(4, 80, 64) : Brand.hsl(4, 72, 50);
  static Color get warning =>
      dm ? Brand.hsl(35, 90, 58) : Brand.hsl(35, 90, 44);

  /// Dark-mode-only dot colour (map graticule, status card grid). In light
  /// mode the hairline does the same job.
  static Color get dmDot => dm ? Brand.hsl(222, 12, 24) : line;
  static const dark = Color(0xFF0B0E14); // onboarding / paywall backdrop

  /// Home hero panel: #0B0E14, slightly lifted off the dark-mode surface.
  static Color get hero => dm ? Brand.hsl(222, 24, 8) : dark;

  /// System "reduce motion" switch. The shell reads
  /// `MediaQuery.disableAnimationsOf(context)` into this before each frame,
  /// the same way it resolves [dm]. Everything that animates in this file
  /// takes its duration through [dur], and both ASCII engines read this flag
  /// to draw one frozen frame instead of running a ticker.
  static bool reducedMotion = false;

  /// A duration that collapses to zero when the user asked for less motion.
  static Duration dur(Duration d) => reducedMotion ? Duration.zero : d;

  static const double radius = 18;

  // --- glass (app.css `.statcard`, the card on the dark hero panel) --------

  /// The card's own corner radius, and the slightly tighter one its `::after`
  /// sheen is clipped to.
  static const double glassRadius = 22;
  static const double glassSheenRadius = 21;

  /// `backdrop-filter: blur(7px)`. A CSS blur radius is about twice the
  /// Gaussian sigma, so 7px lands on 3.5.
  static const double glassBlurSigma = 3.5;

  /// The named type scale from app.css (lines 795 to 796). It maps onto
  /// Dynamic Type on iOS and the Material scale on Android; anything not on
  /// this list stays an ad hoc value at its call site.
  static const double titleSize = 17;
  static const double bodySize = 14;
  static const double calloutSize = 13;
  static const double captionSize = 13;
  static const double legalSize = 12;

  /// Inter with a precise variable weight (the design uses 550/650/750).
  static TextStyle sans(double weight, double size,
          {Color? color, double? letterSpacing, double? height}) =>
      TextStyle(
        fontFamily: Brand.bodyFont,
        fontVariations: [FontVariation('wght', weight)],
        fontSize: size,
        color: color,
        letterSpacing: letterSpacing,
        height: height,
      );

  /// JetBrains Mono for IPs, ports, hosts and latencies.
  static TextStyle mono(double weight, double size,
          {Color? color, double? letterSpacing, double? height}) =>
      TextStyle(
        fontFamily: Brand.monoFont,
        fontVariations: [FontVariation('wght', weight)],
        fontFeatures: const [FontFeature.tabularFigures()],
        fontSize: size,
        color: color,
        letterSpacing: letterSpacing,
        height: height,
      );
}

/// Wordmark: bold "hide", the blue "IP" chip, then muted ".net".
/// Display face per the brand kit; the chip digits are JetBrains Mono.
class HipWordmark extends StatelessWidget {
  final double size;
  final Color? color;
  final Color? tldColor;
  const HipWordmark({super.key, this.size = 20, this.color, this.tldColor});

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontFamily: Brand.wordmarkFont,
      fontVariations: const [FontVariation('wght', 700)],
      fontFeatures: const [FontFeature('ss01'), FontFeature('ss02')],
      fontSize: size,
      letterSpacing: -.045 * size,
      color: color ?? Hip.ink,
    );
    return Text.rich(TextSpan(children: [
      TextSpan(text: 'hide', style: base),
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        // The chip's CSS em paddings resolve against its own font size.
        child: Builder(builder: (context) {
          // `.wm .chip`: font-size .86em, weight 800, padding .113em .17em .107em.
          final em = .86 * size;
          // `middle` centres on the full line box (descender included);
          // the CSS flexbox centres on the glyphs, so lift the chip a bit.
          return Transform.translate(
            offset: Offset(0, -.05 * size),
            child: Container(
              margin: EdgeInsets.only(left: .09 * em),
              padding: EdgeInsets.fromLTRB(
                  .17 * em, .113 * em, .17 * em, .107 * em),
              decoration: BoxDecoration(
                color: Brand.hsl(220, 95, 55),
                borderRadius: BorderRadius.circular(.22 * em),
              ),
              child: Text('IP',
                  style: Hip.mono(800, em,
                      color: Colors.white,
                      letterSpacing: -.02 * em,
                      height: 1)),
            ),
          );
        }),
      ),
      WidgetSpan(child: SizedBox(width: .1 * size)),
      TextSpan(
        text: '.net',
        style: base.copyWith(
          color: tldColor ?? Hip.muted2,
          fontVariations: const [FontVariation('wght', 500)],
        ),
      ),
    ]));
  }
}

/// Square "flag": country code in mono on a soft blue tile.
class HipFlag extends StatelessWidget {
  final String cc;
  final bool small;
  final Widget? child; // overrides the code (e.g. the Auto zap icon)
  const HipFlag({super.key, required this.cc, this.small = false, this.child});

  /// Two ASCII letters become the country's emoji flag (regional indicator
  /// pair); anything else (Auto, "+", unknown) keeps the mono code badge.
  static String? _emojiFlag(String cc) {
    if (cc.length != 2) return null;
    final up = cc.toUpperCase();
    final a = up.codeUnitAt(0), b = up.codeUnitAt(1);
    if (a < 0x41 || a > 0x5A || b < 0x41 || b > 0x5A) return null;
    return String.fromCharCodes([0x1F1E6 + a - 0x41, 0x1F1E6 + b - 0x41]);
  }

  @override
  Widget build(BuildContext context) {
    final s = small ? 30.0 : 38.0;
    final flag = child == null ? _emojiFlag(cc) : null;
    return Container(
      width: s,
      height: s,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Hip.blueSoft,
        borderRadius: BorderRadius.circular(small ? 9 : 12),
      ),
      child: child ??
          (flag != null
              ? Text(flag,
                  style: TextStyle(fontSize: small ? 15 : 19, height: 1))
              : Text(cc,
                  style: Hip.mono(700, small ? 11 : 13,
                      color: Hip.blueDeep, letterSpacing: .5))),
    );
  }
}

/// Four ascending ping bars; [level] 0-4 are lit green.
class HipBars extends StatelessWidget {
  final int level;
  const HipBars({super.key, required this.level});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 1; i <= 4; i++)
          Container(
            width: 3.5,
            height: 2 + i * 3.0,
            margin: EdgeInsets.only(left: i == 1 ? 0 : 2.5),
            decoration: BoxDecoration(
              color: i <= level ? Hip.success : Hip.line,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ],
    );
  }
}

/// iOS-style toggle in brand colors (green when on).
class HipToggle extends StatelessWidget {
  final bool on;
  final ValueChanged<bool> onChanged;
  const HipToggle({super.key, required this.on, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Haptics.selection();
        onChanged(!on);
      },
      child: AnimatedContainer(
        duration: Hip.dur(const Duration(milliseconds: 200)),
        width: 46,
        height: 28,
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(
          color: on
              ? Hip.success
              : (Hip.dm ? Brand.hsl(222, 12, 25) : Hip.line),
          borderRadius: BorderRadius.circular(999),
        ),
        child: AnimatedAlign(
          duration: Hip.dur(const Duration(milliseconds: 200)),
          curve: Curves.easeOutCubic,
          alignment: on ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 23,
            height: 23,
            decoration: BoxDecoration(
              color: Hip.dm ? Brand.hsl(220, 15, 96) : Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .25),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pill badge (protocol, Verified, provider handle).
class HipBadge extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  final bool monoFont;
  final IconData? icon;
  const HipBadge(this.text,
      {super.key,
      required this.bg,
      required this.fg,
      this.monoFont = false,
      this.icon});

  factory HipBadge.proto(String text) => HipBadge(text,
      bg: Hip.line2, fg: Hip.inkSoft, monoFont: true);
  factory HipBadge.ok(String text, {IconData? icon}) => HipBadge(text,
      bg: Hip.successSoft,
      fg: Hip.dm ? Brand.hsl(152, 55, 55) : Hip.success,
      icon: icon);
  factory HipBadge.blue(String text) =>
      HipBadge(text, bg: Hip.blueSoft, fg: Hip.blueDeep);

  /// A location the votes brought in (app.css `.badge.won`). Amber, not
  /// blue: it marks something the people who voted earned, so it reads apart
  /// from the blue the rest of the app spends on Premium.
  factory HipBadge.won(String text, {IconData? icon}) => HipBadge(text,
      bg: Brand.hsl(42, 92, 52, .16),
      fg: Hip.dm ? Brand.hsl(42, 92, 66) : Brand.hsl(38, 85, 38),
      icon: icon);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 5),
        ],
        Text(text,
            style: monoFont
                ? Hip.mono(600, 10.5, color: fg)
                : Hip.sans(600, 11.5, color: fg, letterSpacing: .1)),
      ]),
    );
  }
}

/// Bordered white card, radius 18.
class HipCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? borderColor;
  const HipCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
    this.onTap,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Hip.card,
        border: Border.all(color: borderColor ?? Hip.line, width: 1.5),
        borderRadius: BorderRadius.circular(Hip.radius),
      ),
      child: child,
    );
    if (onTap == null) return box;
    return GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: box);
  }
}

/// Primary CTA. `connect: true` is the flat brand blue with a lifted glow.
///
/// It used to be a gradient that slid forever behind the label. The 29.8
/// revision retired that (app.css dropped `@keyframes cta-grad`): the primary
/// button is flat blue, so nothing on the home screen holds a ticker open
/// just to decorate itself.
class HipCta extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool connect;
  final bool ghost;
  final bool quiet;
  final bool darkGhost; // ghost on a dark (onboarding) surface
  final bool danger; // red-tinted ghost, for disconnect-style actions

  /// The onboarding ghost (ob3.css `.ob3-root .cta.ghost`): a fainter fill
  /// than [darkGhost], a hairline rim around it, and a label held just under
  /// full white so the secondary way out sits behind the primary action on
  /// the same dark panel. Implies [ghost] on a dark surface.
  final bool obGhost;
  final Widget? leading;
  const HipCta(this.label,
      {super.key,
      this.onTap,
      this.connect = false,
      this.ghost = false,
      this.quiet = false,
      this.darkGhost = false,
      this.danger = false,
      this.obGhost = false,
      this.leading});

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final height = quiet ? 44.0 : 54.0;
    final isGhost = ghost || obGhost;
    final onDark = darkGhost || obGhost;

    Color fg;
    if (connect) {
      fg = Colors.white;
    } else if (isGhost) {
      // The danger tint reads on light and dark surfaces alike; the same red
      // the IP pill uses for EXPOSED, so "stop protecting" wears its color.
      fg = danger
          ? (onDark ? Brand.hsl(4, 85, 70) : Brand.hsl(4, 68, 50))
          : obGhost
              ? Colors.white.withValues(alpha: .88)
              : (onDark ? Colors.white : Hip.ink);
    } else if (quiet) {
      fg = onDark ? Colors.white.withValues(alpha: .55) : Hip.muted;
    } else {
      fg = Colors.white;
    }

    final content = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (leading != null) ...[
          IconTheme(data: IconThemeData(color: fg, size: 18), child: leading!),
          const SizedBox(width: 8),
        ],
        Text(label,
            style: Hip.sans(quiet ? 550 : 600, quiet ? 15 : 16.5, color: fg)),
      ],
    );

    Color bg;
    BoxBorder? border;
    List<BoxShadow>? shadow;
    if (connect) {
      // app.css `.cta.connect`: flat --blue, a 1.5px lighter rim and one
      // lifted shadow. No animation of any kind.
      bg = Hip.blue;
      border = Border.all(color: Brand.hsl(220, 95, 72, .8), width: 1.5);
      shadow = [
        BoxShadow(
          color: Brand.hsl(220, 95, 55, .55),
          blurRadius: 26,
          offset: const Offset(0, 10),
          spreadRadius: -12,
        ),
      ];
    } else if (isGhost) {
      if (danger) {
        bg = Brand.hsl(4, 80, 60, onDark ? .14 : .08);
        border = Border.all(color: Brand.hsl(4, 80, 60, .35), width: 1.5);
      } else if (obGhost) {
        bg = Colors.white.withValues(alpha: .07);
        border =
            Border.all(color: Colors.white.withValues(alpha: .17), width: 1.5);
      } else {
        bg = onDark
            ? Colors.white.withValues(alpha: .09)
            : (Hip.dm ? Brand.hsl(222, 14, 16) : Hip.line2);
      }
    } else if (quiet) {
      bg = Colors.transparent;
    } else {
      bg = Hip.blue;
    }

    final button = Container(
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        border: border,
        boxShadow: shadow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: content,
    );

    return GestureDetector(
      onTap: disabled
          ? null
          : () {
              Haptics.tap();
              onTap!();
            },
      child: Opacity(opacity: disabled ? .55 : 1, child: button),
    );
  }
}

/// Round-cornered icon button used in headers.
class HipIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;
  const HipIconButton(this.icon, {super.key, required this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    // app.css `.iconbtn` is a 38px square with a 12px corner. The touch
    // target around it is 48x48 (the CSS widens it with an ::after pad, we
    // widen it with the box), which is over both platform minimums.
    return Semantics(
      button: true,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 38,
              height: 38,
              child: Icon(icon, size: 22, color: color ?? Hip.inkSoft),
            ),
          ),
        ),
      ),
    );
  }
}

/// App header: wordmark left, action icons right.
class HipAppHead extends StatelessWidget {
  final VoidCallback? onServers;
  final VoidCallback? onSettings;
  final bool onDark;
  const HipAppHead({super.key, this.onServers, this.onSettings, this.onDark = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
      child: Row(children: [
        HipWordmark(
            color: onDark ? Colors.white : null,
            tldColor: onDark ? Colors.white.withValues(alpha: .4) : null),
        const Spacer(),
        if (onServers != null)
          HipIconButton(Icons.dns_outlined,
              onTap: onServers!,
              color: onDark ? Colors.white.withValues(alpha: .7) : null),
        if (onSettings != null) ...[
          const SizedBox(width: 10),
          HipIconButton(Icons.settings_outlined,
              onTap: onSettings!,
              color: onDark ? Colors.white.withValues(alpha: .7) : null),
        ],
      ]),
    );
  }
}

/// Sub-screen header: back chevron + title + optional trailing action.
class HipNavHead extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  final Widget? trailing;
  final bool onDark;
  const HipNavHead({
    super.key,
    required this.title,
    required this.onBack,
    this.trailing,
    this.onDark = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      child: Row(children: [
        HipIconButton(Icons.chevron_left,
            onTap: onBack,
            color: onDark ? Colors.white.withValues(alpha: .75) : null),
        const SizedBox(width: 6),
        Text(title,
            style: Hip.sans(650, 19,
                color: onDark ? Colors.white : Hip.ink, letterSpacing: -.38)),
        const Spacer(),
        ?trailing,
      ]),
    );
  }
}

/// Section label above a list group (uppercase, tracked out).
class HipSectionLabel extends StatelessWidget {
  final String text;
  const HipSectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 7),
      child: Text(text.toUpperCase(),
          style: Hip.sans(650, Hip.captionSize,
              color: Hip.muted2, letterSpacing: .91)),
    );
  }
}

/// Card-backed group of list rows with hairline separators.
class HipListGroup extends StatelessWidget {
  final List<Widget> children;
  const HipListGroup({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Hip.card,
        border: Border.all(color: Hip.line, width: 1.5),
        borderRadius: BorderRadius.circular(Hip.radius),
      ),
      child: Column(children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) Container(height: 1, color: Hip.line2),
          HipRowSlot(
            first: i == 0,
            last: i == children.length - 1,
            child: children[i],
          ),
        ],
      ]),
    );
  }
}

/// One row inside a [HipListGroup].
class HipListRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final Widget? titleBadge;
  final String? subtitle;
  final bool subtitleMono;

  /// A subtitle built from spans, for the lines that mix the body face with
  /// mono runs (a date, a price). It wins over [subtitle] when both are
  /// given; the span carries its own styles, so [subtitleMono] does not
  /// apply to it.
  final InlineSpan? subtitleSpan;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected; // the currently chosen server: soft blue field
  final bool live; // selected AND the tunnel is up: green live dot
  const HipListRow({
    super.key,
    this.leading,
    required this.title,
    this.titleBadge,
    this.subtitle,
    this.subtitleMono = false,
    this.subtitleSpan,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.live = false,
  });

  @override
  Widget build(BuildContext context) {
    final green = Brand.hsl(152, 60, 42);
    final corners = HipRowSlot.cornersOf(context);
    final row = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: selected
          ? BoxDecoration(
              color: Hip.dm
                  ? Brand.hsl(220, 60, 55, .12)
                  : Brand.hsl(220, 95, 55, .07),
              borderRadius: corners,
            )
          : null,
      child: Row(children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                child: Text(title,
                    overflow: TextOverflow.ellipsis,
                    style: Hip.sans(650, Hip.titleSize,
                        color: Hip.ink, letterSpacing: -.17)),
              ),
              if (live) ...[
                const SizedBox(width: 7),
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: green,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                          color: green.withValues(alpha: .35), spreadRadius: 2.5),
                    ],
                  ),
                ),
              ],
              if (titleBadge != null) ...[
                const SizedBox(width: 7),
                titleBadge!,
              ],
            ]),
            if (subtitleSpan != null)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text.rich(subtitleSpan!,
                    overflow: TextOverflow.ellipsis,
                    style: Hip.sans(400, Hip.bodySize, color: Hip.muted)),
              )
            else if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(subtitle!,
                    overflow: TextOverflow.ellipsis,
                    style: subtitleMono
                        ? Hip.mono(600, 12, color: Hip.muted)
                        : Hip.sans(400, Hip.bodySize, color: Hip.muted)),
              ),
          ]),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ]),
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: corners,
      child: row,
    );
  }
}

/// Where a row sits inside its [HipListGroup], so it can round only the
/// corners that touch the group's outer edge. app.css: first 15/15/8/8, last
/// 8/8/15/15, a lone row 15 all round, everything between 8.
class HipRowSlot extends InheritedWidget {
  final bool first;
  final bool last;
  const HipRowSlot({
    super.key,
    required this.first,
    required this.last,
    required super.child,
  });

  static const double _outer = 15;
  static const double _inner = 8;

  /// The corner radii for the row built under [context]. A row with no group
  /// above it (a card, a search result) is treated as a lone row.
  static BorderRadius cornersOf(BuildContext context) {
    final slot = context.dependOnInheritedWidgetOfExactType<HipRowSlot>();
    final first = slot?.first ?? true;
    final last = slot?.last ?? true;
    return BorderRadius.vertical(
      top: Radius.circular(first ? _outer : _inner),
      bottom: Radius.circular(last ? _outer : _inner),
    );
  }

  @override
  bool updateShouldNotify(HipRowSlot old) =>
      old.first != first || old.last != last;
}

/// Centered footnote under lists/CTAs.
class HipSubnote extends StatelessWidget {
  final String text;
  final bool onDark;
  const HipSubnote(this.text, {super.key, this.onDark = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
      child: Text(text,
          textAlign: TextAlign.center,
          style: Hip.sans(400, Hip.captionSize,
              color: onDark ? Colors.white.withValues(alpha: .4) : Hip.muted2,
              height: 1.5)),
    );
  }
}

/// Floating dark toast with a green check, shown near the bottom.
class HipToast extends StatelessWidget {
  final String message;
  const HipToast(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
      decoration: BoxDecoration(
        color: Hip.dm ? Brand.hsl(222, 18, 16) : Brand.hsl(220, 15, 12),
        border: Hip.dm
            ? Border.all(color: Brand.hsl(222, 12, 27))
            : null,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .4),
            blurRadius: 30,
            offset: const Offset(0, 12),
            spreadRadius: -8,
          ),
        ],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.check, size: 16, color: Brand.hsl(152, 60, 55)),
        const SizedBox(width: 8),
        Text(message, style: Hip.sans(600, 13.5, color: Colors.white)),
      ]),
    );
  }
}

// --- 1.1.1, servers ----------------------------------------------------------

/// A list row that slides left to stop on two buttons, Edit and Delete.
///
/// Sliding is all it does: a swipe that runs the whole way settles on the
/// same two buttons, never past them, so nothing is removed without the
/// Delete tap and the confirmation behind it. One row is open at a time; a
/// tap on the open row or anywhere else, and any scroll inside a
/// [HipSwipeArea], closes it. [enabled] false renders the child on its own,
/// which is how managed and locked rows stay still.
class HipSwipeRow extends StatefulWidget {
  final Widget child;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool enabled;
  const HipSwipeRow({
    super.key,
    required this.child,
    required this.onEdit,
    required this.onDelete,
    this.enabled = true,
  });

  /// Width of one button, and so half of what the row slides by.
  static const double buttonWidth = 72;
  static const double actionsWidth = buttonWidth * 2;

  static _HipSwipeRowState? _openRow;

  /// Whether any row is open right now.
  static bool get anyOpen => _openRow != null;

  /// Closes the open row, if there is one.
  static void closeOpen() => _openRow?.close();

  /// Closes the open row unless [position] (global) lands on it: a tap on
  /// the buttons must reach them, and a tap on the open row's own content is
  /// the row's to handle.
  static void closeOpenUnlessAt(Offset position) {
    final row = _openRow;
    if (row == null) return;
    final box = row.context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.contains(position)) return;
    }
    row.close();
  }

  @override
  State<HipSwipeRow> createState() => _HipSwipeRowState();
}

class _HipSwipeRowState extends State<HipSwipeRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  double _dragFrom = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: Hip.dur(const Duration(milliseconds: 200)),
    );
  }

  /// How far the content sits to the left, 0 to [HipSwipeRow.actionsWidth].
  double get _offset => _ctrl.value * HipSwipeRow.actionsWidth;
  bool get _isOpen => HipSwipeRow._openRow == this;

  @override
  void dispose() {
    if (HipSwipeRow._openRow == this) HipSwipeRow._openRow = null;
    _ctrl.dispose();
    super.dispose();
  }

  void open() {
    final other = HipSwipeRow._openRow;
    if (other != null && other != this) other.close();
    final wasOpen = _isOpen;
    HipSwipeRow._openRow = this;
    _ctrl.animateTo(1, curve: Curves.easeOutCubic);
    // The tick lands as the buttons snap into place, not on every drag.
    if (!wasOpen) Haptics.selection();
    if (mounted) setState(() {});
  }

  void close() {
    if (HipSwipeRow._openRow == this) HipSwipeRow._openRow = null;
    if (!mounted) return;
    _ctrl.animateBack(0, curve: Curves.easeOutCubic);
    setState(() {});
  }

  void _dragStart(DragStartDetails d) {
    _ctrl.stop();
    _dragFrom = _offset;
  }

  void _dragUpdate(DragUpdateDetails d) {
    // Leftwards opens. Past the buttons the row stays put: there is nothing
    // further along to reach.
    _dragFrom = (_dragFrom - d.delta.dx).clamp(0, HipSwipeRow.actionsWidth);
    _ctrl.value = _dragFrom / HipSwipeRow.actionsWidth;
  }

  void _dragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (v < -300) {
      open();
    } else if (v > 300) {
      close();
    } else if (_offset > HipSwipeRow.actionsWidth / 2) {
      open();
    } else {
      close();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final corners = HipRowSlot.cornersOf(context);
    return ClipRRect(
      borderRadius: corners,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Counted from where the finger went down, so the first few points
        // of a swipe move the row too rather than being spent on deciding.
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: _dragStart,
        onHorizontalDragUpdate: _dragUpdate,
        onHorizontalDragEnd: _dragEnd,
        // While open, a tap on the content closes the row instead of
        // choosing the server; the child is shut off from pointers for it.
        onTap: _isOpen ? close : null,
        child: Stack(children: [
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerRight,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _SwipeButton(
                  icon: Icons.edit_outlined,
                  label: S.srvEdit,
                  fg: Hip.blueDeep,
                  bg: Hip.blueSoft,
                  onTap: () {
                    close();
                    widget.onEdit();
                  },
                ),
                _SwipeButton(
                  icon: Icons.delete_outline,
                  label: S.srvDelete,
                  fg: Hip.danger,
                  bg: Hip.danger.withValues(alpha: Hip.dm ? .14 : .08),
                  onTap: () {
                    close();
                    widget.onDelete();
                  },
                ),
              ]),
            ),
          ),
          AnimatedBuilder(
            animation: _ctrl,
            builder: (context, child) => Transform.translate(
              offset: Offset(-_offset, 0),
              child: child,
            ),
            // The content paints its own ground so the buttons only show in
            // the gap it leaves, not through it.
            child: ColoredBox(
              color: Hip.card,
              child: IgnorePointer(ignoring: _isOpen, child: widget.child),
            ),
          ),
        ]),
      ),
    );
  }
}

class _SwipeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color fg;
  final Color bg;
  final VoidCallback onTap;
  const _SwipeButton({
    required this.icon,
    required this.label,
    required this.fg,
    required this.bg,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: HipSwipeRow.buttonWidth,
          height: double.infinity,
          color: bg,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 18, color: fg),
            const SizedBox(height: 3),
            Text(label, style: Hip.sans(600, 11.5, color: fg)),
          ]),
        ),
      ),
    );
  }
}

/// The region around a list of [HipSwipeRow]s: a pointer landing off the
/// open row, or a scroll starting anywhere inside, closes it.
class HipSwipeArea extends StatelessWidget {
  final Widget child;
  const HipSwipeArea({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollStartNotification>(
      onNotification: (_) {
        HipSwipeRow.closeOpen();
        return false;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) => HipSwipeRow.closeOpenUnlessAt(e.position),
        child: child,
      ),
    );
  }
}
