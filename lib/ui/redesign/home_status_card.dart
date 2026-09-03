import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/haptics.dart';
import '../brand.dart';
import '../strings.dart';
import 'hip.dart';

/// The four tones the status card can be in. They are what the whole card
/// is coloured from, so a state can never say one thing and look another.
enum StatusTone {
  /// No network at all: neutral grey, nothing to alarm anyone with.
  off,

  /// A handshake is in flight.
  busy,

  /// The tunnel is up.
  safe,

  /// The real address is on show.
  risk,
}

/// The glass status card on the hero panel (`hero-compact` in
/// `design/app-1_1_0/screens-home.jsx`, `.statcard` in `app.css`).
///
/// Everything it shows arrives as a plain value: the card has no idea what a
/// tunnel is, which keeps it honest and makes every state testable without a
/// running app. The one thing it owns is the copy affordance, because the
/// check mark that replaces the icon for 1200 ms is purely local.
///
/// The whole row is the copy target, not just the icon: on a phone the icon
/// alone was a small thing to hit, and there is nothing else on the card a
/// tap could mean. A long press opens whatever the hero hands in through
/// [onLongPress] (the address details sheet); without it the row only copies.
///
/// It is real glass rather than a flat panel, and the depth comes from five
/// layers that all sit in `.statcard`:
///
///  * `backdrop-filter: blur(7px) saturate(1.45)` over the ASCII field and
///    the tone glow behind it,
///  * a white gradient across the WHOLE card (the `border-box` background):
///    42% at the top-left corner, fading to almost nothing by the middle and
///    back up to 22% at the bottom-right. It is what lights the glass,
///  * a translucent dark vertical fill over it, inset by the 1px border (the
///    `padding-box` background), dark enough to keep the text legible. The
///    ring of white left uncovered around it is the rim,
///  * three inset shadows: a white line under the top edge, a fainter one
///    over the bottom edge, and a 1px ring in the tone colour,
///  * two outer shadows: a wide glow in the tone colour and a short dark drop.
class HomeStatusCard extends StatefulWidget {
  final StatusTone tone;

  /// The status word: `Exposed`, `Protected`, `Connecting…`, `No connection`.
  final String status;

  /// The address on show, or null while there is nothing to show (offline).
  final String? ip;

  /// The line under the address: `ISP · City, CC` exposed, `City, Country`
  /// connected, the offline explanation when there is no network.
  final String context;

  /// The extra line a slow handshake earns after ten seconds (B16).
  final String? slowLine;

  /// A long press on the address row, when there is somewhere for it to go.
  final VoidCallback? onLongPress;

  const HomeStatusCard({
    super.key,
    required this.tone,
    required this.status,
    required this.context,
    this.ip,
    this.slowLine,
    this.onLongPress,
  });

  @override
  State<HomeStatusCard> createState() => _HomeStatusCardState();
}

class _HomeStatusCardState extends State<HomeStatusCard>
    with SingleTickerProviderStateMixin {
  bool _copied = false;
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _syncSpin();
  }

  @override
  void didUpdateWidget(HomeStatusCard old) {
    super.didUpdateWidget(old);
    if (old.tone != widget.tone) _syncSpin();
  }

  // Reduced motion keeps the icon still: the word "Connecting…" already says
  // everything the spin was there to say.
  void _syncSpin() {
    if (widget.tone == StatusTone.busy && !Hip.reducedMotion) {
      _spin.repeat();
    } else {
      _spin.stop();
      _spin.value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    final ip = widget.ip;
    if (ip == null || ip.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: ip));
    Haptics.selection();
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (mounted) setState(() => _copied = false);
  }

  Color get _sc => switch (widget.tone) {
        StatusTone.off => Brand.hsl(220, 8, 60),
        StatusTone.busy => Brand.hsl(220, 95, 62),
        StatusTone.safe => Brand.hsl(152, 60, 52),
        StatusTone.risk => Brand.hsl(4, 82, 64),
      };

  IconData get _icon => switch (widget.tone) {
        StatusTone.off => Icons.public,
        StatusTone.busy => Icons.autorenew,
        StatusTone.safe => Icons.shield_outlined,
        StatusTone.risk => Icons.visibility_outlined,
      };

  @override
  Widget build(BuildContext context) {
    // `transition: box-shadow .9s ease` on the card, and the same duration on
    // the icon and the status word. One tween drives every tone-coloured
    // layer, so the glow, the ring and the label cannot disagree mid-change.
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: _sc),
      duration: Hip.dur(const Duration(milliseconds: 900)),
      curve: Curves.easeOut,
      builder: (context, tone, _) => _card(tone ?? _sc),
    );
  }

  Widget _card(Color sc) {
    return CustomPaint(
      // The outer half of the box-shadow. It has to be painted outside the
      // clip below, or the clip would eat it.
      painter: _StatCardShadows(sc),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Hip.glassRadius),
        child: BackdropFilter(
          // backdrop-filter: blur(7px) saturate(1.45)
          filter: _glassBackdrop,
          child: CustomPaint(
            // The two background layers of `.statcard`.
            painter: const _StatCardFill(),
            // The inset shadows and the ::after sheen, which sit above them.
            foregroundPainter: _StatCardGlass(sc),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
              child: _row(sc),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(Color sc) {
    final ip = widget.ip;
    const white = Colors.white;
    final row = Row(children: [
      // --- tone icon --------------------------------------------------------
      Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          // background-color: color-mix(in oklab, var(--sc) 14%, transparent)
          color: sc.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(14),
          // box-shadow: 0 0 0 1px color-mix(--sc 26%, transparent) inset
          border: Border.all(color: sc.withValues(alpha: .26)),
        ),
        child: Center(
          child: RotationTransition(
            turns: _spin,
            child: Icon(_icon, size: 20, color: sc),
          ),
        ),
      ),
      const SizedBox(width: 13),

      // --- status, address, context -----------------------------------------
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              _ToneDot(color: sc, fast: widget.tone == StatusTone.busy),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  widget.status.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Hip.sans(750, 10.5,
                      color: sc, letterSpacing: .95, height: 1.1),
                ),
              ),
            ]),
            if (ip != null) ...[
              const SizedBox(height: 2.5),
              AnimatedOpacity(
                duration: Hip.dur(const Duration(milliseconds: 300)),
                opacity: widget.tone == StatusTone.busy ? .55 : 1,
                child: Text(
                  ip,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Hip.mono(650, 18,
                      color: white, letterSpacing: .27, height: 1.15),
                ),
              ),
            ],
            const SizedBox(height: 2.5),
            Text(
              widget.context,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Hip.sans(400, 11.5,
                  color: white.withValues(alpha: .5), height: 1.2),
            ),
            if (widget.slowLine != null) ...[
              const SizedBox(height: 4),
              Text(
                widget.slowLine!,
                style: Hip.sans(400, 12,
                    color: white.withValues(alpha: .66), height: 1.4),
              ),
            ],
          ],
        ),
      ),

      // --- copy mark --------------------------------------------------------
      // The icon only shows what a tap does; the row below it is the target.
      if (ip != null) ...[
        const SizedBox(width: 8),
        SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                // background: hsl(0 0% 100% / .05)
                color: white.withValues(alpha: .05),
                borderRadius: BorderRadius.circular(11),
                // box-shadow: 0 0 0 1px hsl(0 0% 100% / .08) inset
                border: Border.all(color: white.withValues(alpha: .08)),
              ),
              child: Icon(
                _copied ? Icons.check : Icons.copy_outlined,
                size: 15,
                color: _copied
                    ? Brand.hsl(152, 60, 60)
                    : white.withValues(alpha: .45),
              ),
            ),
          ),
        ),
      ],
    ]);
    if (ip == null) return row;
    final hold = widget.onLongPress;
    return Semantics(
      button: true,
      label: _copied ? S.homeCopiedIp : S.homeCopyIp,
      hint: hold == null ? null : S.homeIpHoldHint,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _copy,
        onLongPress: hold == null
            ? null
            : () {
                Haptics.selection();
                hold();
              },
        child: row,
      ),
    );
  }
}

/// `backdrop-filter: blur(7px) saturate(1.45)` on `.statcard`.
///
/// A CSS blur radius is about twice the Gaussian sigma, so 7px is sigma 3.5.
/// The saturation is the CSS filter matrix with the sRGB luminance weights
/// (.213 / .715 / .072), and it is what keeps the tone glow behind the glass
/// a colour rather than a grey smudge. `compose` runs the inner filter first,
/// which is the CSS order: blur, then saturate.
final ui.ImageFilter _glassBackdrop = ui.ImageFilter.compose(
  outer: const ColorFilter.matrix(_saturate145),
  inner: ui.ImageFilter.blur(
      sigmaX: Hip.glassBlurSigma, sigmaY: Hip.glassBlurSigma),
);

/// The 4x5 colour matrix for `saturate(1.45)`.
const List<double> _saturate145 = <double>[
  1.35415, -0.32175, -0.03240, 0, 0, //
  -0.09585, 1.12825, -0.03240, 0, 0, //
  -0.09585, -0.32175, 1.41760, 0, 0, //
  0, 0, 0, 1, 0, //
];

/// The two outer shadows of `.statcard`:
///
/// ```css
/// 0 12px 30px -12px color-mix(in oklab, var(--sc) 42%, transparent),
/// 0  3px 10px  -4px hsl(222 40% 4% / .5)
/// ```
///
/// CSS knocks the border box out of an outer shadow, and here it has to be
/// knocked out too. The card is translucent glass: a shadow left underneath
/// would tint the fill from below and then be smeared straight back into it
/// by the backdrop blur, which is the muddy look the design avoids.
class _StatCardShadows extends CustomPainter {
  final Color tone;
  const _StatCardShadows(this.tone);

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(Hip.glassRadius));
    // Everything outside the card, with room for the widest blur (sigma 15).
    final outside = Path.combine(
      PathOperation.difference,
      Path()
        ..addRect(Rect.fromLTRB(-60, -60, size.width + 60, size.height + 60)),
      Path()..addRRect(rrect),
    );
    canvas.save();
    canvas.clipPath(outside);
    // A CSS blur radius is about twice the Gaussian sigma, and a spread
    // shrinks the shadow's own rounded rect, corner radii included.
    canvas.drawRRect(
      rrect.shift(const Offset(0, 12)).deflate(12),
      Paint()
        ..color = tone.withValues(alpha: .42)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15),
    );
    canvas.drawRRect(
      rrect.shift(const Offset(0, 3)).deflate(4),
      Paint()
        ..color = Brand.hsl(222, 40, 4, .5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StatCardShadows old) => old.tone != tone;
}

/// The `background` of `.statcard`, two layers painted bottom-up:
///
/// ```css
/// background:
///   linear-gradient(hsl(222 18% 15% / .3), hsl(222 22% 9% / .46)) padding-box,
///   linear-gradient(165deg, hsl(0 0% 100% / .42), hsl(0 0% 100% / .06) 42%,
///                   hsl(0 0% 100% / .03) 70%, hsl(0 0% 100% / .22)) border-box;
/// border: 1px solid transparent;
/// ```
///
/// The second layer covers the whole card and the first only the padding
/// box, and since the first is translucent the white shows through it
/// everywhere, not just in the 1px ring the transparent border leaves
/// uncovered. That ring is the rim; the rest is what makes the glass look
/// lit from the top-left rather than merely tinted.
class _StatCardFill extends CustomPainter {
  const _StatCardFill();

  static const _white = Colors.white;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final outer =
        RRect.fromRectAndRadius(rect, const Radius.circular(Hip.glassRadius));
    canvas.drawRRect(
      outer,
      Paint()
        ..shader = _cssLinearGradient(rect, 165, [
          _white.withValues(alpha: .42),
          _white.withValues(alpha: .06),
          _white.withValues(alpha: .03),
          _white.withValues(alpha: .22),
        ], const [0, .42, .70, 1]),
    );
    // The padding box: one pixel in on every side, its corners one pixel
    // tighter, as CSS rounds the inner edge of a border.
    final inner = rect.deflate(1);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          inner, const Radius.circular(Hip.glassRadius - 1)),
      Paint()
        ..shader = ui.Gradient.linear(
          inner.topCenter,
          inner.bottomCenter,
          [Brand.hsl(222, 18, 15, .30), Brand.hsl(222, 22, 9, .46)],
        ),
    );
  }

  @override
  bool shouldRepaint(_StatCardFill old) => false;
}

/// A CSS `linear-gradient(<angle>, ...)` as a shader over [rect].
///
/// CSS runs the gradient line through the centre of the box at [angleDeg]
/// (0 points up, 90 right) and makes it just long enough for the 0% and 100%
/// stops to touch the two corners the line points at, which is
/// `w·|sin θ| + h·|cos θ|`. Flutter's alignment-based gradients scale the
/// endpoints per axis instead, so the same numbers land in different places.
Shader _cssLinearGradient(
    Rect rect, double angleDeg, List<Color> colors, List<double> stops) {
  final theta = angleDeg * math.pi / 180;
  final dir = Offset(math.sin(theta), -math.cos(theta));
  final half =
      (rect.width * dir.dx.abs() + rect.height * dir.dy.abs()) / 2;
  final centre = rect.center;
  return ui.Gradient.linear(
    centre - dir * half,
    centre + dir * half,
    colors,
    stops,
  );
}

/// Everything painted over the fill of `.statcard`: the three inset shadows
/// and the `::after` sheen.
class _StatCardGlass extends CustomPainter {
  final Color tone;
  const _StatCardGlass(this.tone);

  static const _white = Colors.white;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // Inset shadows are drawn inside the padding box, so they start one
    // pixel in, just inside the rim.
    final inner = rect.deflate(1);
    final rrect = RRect.fromRectAndRadius(
        inner, const Radius.circular(Hip.glassRadius - 1));

    // box-shadow: 0 0 0 1px color-mix(in oklab, var(--sc) 22%, transparent)
    // inset. A stroke on the rect deflated by half the stroke width lands
    // exactly one pixel inside the edge.
    canvas.drawRRect(
      rrect.deflate(.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = tone.withValues(alpha: .22),
    );

    // The inset highlights, in CSS order (the last declared paints first):
    // 0 -1px 1px hsl(0 0% 100% / .04) inset
    _insetEdge(
        canvas, rrect, inner, _white.withValues(alpha: .04), top: false);
    // 0 1px 1px hsl(0 0% 100% / .1) inset
    _insetEdge(canvas, rrect, inner, _white.withValues(alpha: .10), top: true);

    // ::after, two very wide radial sheens clipped to a 21px radius.
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(
        rect, const Radius.circular(Hip.glassSheenRadius)));
    // radial-gradient(130% 100% at 20% -14%, hsl(0 0% 100% / .08), transparent 46%)
    _sheen(canvas, size,
        cx: .20,
        cy: -.14,
        rx: 1.30,
        ry: 1.00,
        edge: .46,
        color: _white.withValues(alpha: .08));
    // radial-gradient(90% 60% at 85% 115%, hsl(0 0% 100% / .04), transparent 55%)
    _sheen(canvas, size,
        cx: .85,
        cy: 1.15,
        rx: .90,
        ry: .60,
        edge: .55,
        color: _white.withValues(alpha: .04));
    canvas.restore();
  }

  /// One inset edge highlight: a hairline hugging the inside of the top (or
  /// the bottom) edge, corners included, gone within three pixels. The stroke
  /// is centred on the edge and clipped to the card, so half of its two
  /// pixels survive, which is the 1px offset plus 1px blur of the CSS shadow.
  static void _insetEdge(Canvas canvas, RRect rrect, Rect rect, Color color,
      {required bool top}) {
    const band = 3.0;
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, .5)
        ..shader = ui.Gradient.linear(
          top ? rect.topCenter : rect.bottomCenter,
          top
              ? rect.topCenter + const Offset(0, band)
              : rect.bottomCenter - const Offset(0, band),
          [color, color.withValues(alpha: 0)],
        ),
    );
    canvas.restore();
  }

  /// A CSS elliptical radial gradient. [rx] and [ry] are fractions of the
  /// card's width and height, [cx] and [cy] place the centre the same way,
  /// and [edge] is the stop at which the colour reaches transparent.
  /// Flutter's radial gradients are round, so the ellipse comes from
  /// squashing the shader's own matrix about that centre.
  static void _sheen(Canvas canvas, Size size,
      {required double cx,
      required double cy,
      required double rx,
      required double ry,
      required double edge,
      required Color color}) {
    final center = Offset(cx * size.width, cy * size.height);
    final radius = rx * size.width;
    if (radius <= 0) return;
    final squash = (ry * size.height) / radius;
    final m = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(1, squash, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          center,
          radius,
          [color, color.withValues(alpha: 0)],
          [0, edge],
          TileMode.clamp,
          m.storage,
        ),
    );
  }

  @override
  bool shouldRepaint(_StatCardGlass old) => old.tone != tone;
}

/// The small pulsing dot in front of the status word (`.statcard .st .d`).
class _ToneDot extends StatefulWidget {
  final Color color;
  final bool fast;
  const _ToneDot({required this.color, required this.fast});

  @override
  State<_ToneDot> createState() => _ToneDotState();
}

class _ToneDotState extends State<_ToneDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.fast ? 1000 : 2400),
  );

  @override
  void initState() {
    super.initState();
    if (!Hip.reducedMotion) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_ToneDot old) {
    super.didUpdateWidget(old);
    if (old.fast != widget.fast) {
      _c.duration = Duration(milliseconds: widget.fast ? 1000 : 2400);
      if (!Hip.reducedMotion) _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: .45).animate(_c),
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
