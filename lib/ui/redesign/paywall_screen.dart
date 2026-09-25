import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/account_number.dart';
import '../../core/haptics.dart';
import '../../core/location.dart';
import '../../core/ping.dart';
import '../../core/premium.dart';
import '../../core/purchase_service.dart';
import '../../state/app_state.dart';
import '../brand.dart';
import '../strings.dart';
import 'hip.dart';
import 'locked_row.dart';
import 'shell.dart';

bool get _ios => defaultTargetPlatform == TargetPlatform.iOS;

/// "App Store" / "Google Play" in purchase copy, per platform.
String get _storeName => _ios ? 'App Store' : 'Google Play';

/// The store's own subscription-management page.
String get _manageUrl => _ios
    ? 'https://apps.apple.com/account/subscriptions'
    : 'https://play.google.com/store/account/subscriptions';

/// Apple requires a Terms of Use (EULA) link on the paywall; the standard
/// Apple EULA is the one the App Store listing declares.
String get _termsUrl => _ios
    ? 'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/'
    : 'https://hideip.net/terms';

const _privacyUrl = 'https://hideip.net/privacy';

void _openUrl(String url) =>
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

// The paywall keeps the dark surface whatever the app theme is (app.css
// `.scr.dark`), so its accents are the dark-mode values of the tokens rather
// than the ones that follow the theme.
//
/// `.pw-seg button.on` background: the literal blue, not `var(--blue)`.
final _pwBlue = Brand.hsl(220, 95, 55);

/// `.pw-list li svg`: the check in front of every promise.
final _pwCheck = Brand.hsl(220, 95, 68);

/// `.badge.blue` on a dark surface: `--blue-soft` / `--blue-deep` as the
/// dark-mode block defines them.
final _pwBrandBg = Brand.hsl(220, 95, 60, .14);
final _pwBrandFg = Brand.hsl(220, 95, 72);

/// Legal footnote on a dark surface. A `|segment|` renders in mono at full
/// opacity: it is always a price or a date. (app.css `.pw-legal`.)
Widget _legal(String text, [double density = 1]) {
  final parts = text.split('|');
  return Padding(
    padding: EdgeInsets.only(top: 10 * density),
    child: Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < parts.length; i++)
            TextSpan(
              text: parts[i],
              style: i.isOdd
                  ? Hip.mono(
                      600,
                      12,
                      color: Colors.white.withValues(alpha: .7),
                      height: 1.5,
                    )
                  : Hip.sans(
                      400,
                      12,
                      color: Colors.white.withValues(alpha: .65),
                      height: 1.5,
                    ),
            ),
        ],
      ),
      textAlign: TextAlign.center,
    ),
  );
}

/// The brand lockup that heads the paywall (core.jsx `BrandIcon sm` inside
/// `.pw-kicker`): the wordmark on a soft blue pill, then the word Premium.
/// Not the app icon and not the gradient Premium pill: Premium is a plan
/// inside the product, so it is carried by the name.
class PaywallBrandBadge extends StatelessWidget {
  const PaywallBrandBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // `.badge.brand.sm`: 10px wordmark, 2px/6px pill.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: _pwBrandBg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: HipWordmark(
            size: 10,
            color: _pwBrandFg,
            tldColor: _pwBrandFg.withValues(alpha: .65),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          S.tPremium,
          style: Hip.sans(
            600,
            13,
            color: Colors.white.withValues(alpha: .72),
            letterSpacing: -.13,
          ),
        ),
      ],
    );
  }
}

/// The stroked check in front of a promise (core.jsx `IcCheck`: the path
/// `M20 6 9 17l-5-5` on a 24 box, stroke 2.6, round joins). Material's own
/// check is a filled glyph with a different weight and angle.
class PaywallCheck extends StatelessWidget {
  final double size;
  final Color color;
  const PaywallCheck({super.key, this.size = 16, required this.color});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _CheckPainter(color));
}

class _CheckPainter extends CustomPainter {
  final Color color;
  const _CheckPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 24;
    final path = Path()
      ..moveTo(20 * u, 6 * u)
      ..lineTo(9 * u, 17 * u)
      ..lineTo(4 * u, 12 * u);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6 * u
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.color != color;
}

/// Locations ordered by measured latency, quickest first. An unmeasured one
/// sorts last rather than pretending to be instant.
List<Location> sortedByPing(AppState state, List<Location> src) {
  final list = [...src];
  list.sort((a, b) {
    final pa = state.pingFor(a.profile);
    final pb = state.pingFor(b.profile);
    final ma = pa is PingOk ? pa.ms : 1 << 30;
    final mb = pb is PingOk ? pb.ms : 1 << 30;
    return ma.compareTo(mb);
  });
  return list;
}

/// The brand cube outline used everywhere Premium is referenced. Proportions
/// follow the prototype icon (a 15/24 rounded square at stroke 2).
class PremiumCubeIcon extends StatelessWidget {
  final double size;
  final Color? color;
  const PremiumCubeIcon({super.key, this.size = 19, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Hip.blueDeep;
    return Center(
      child: Container(
        width: size * 15 / 24,
        height: size * 15 / 24,
        decoration: BoxDecoration(
          border: Border.all(color: c, width: size * 2 / 24),
          borderRadius: BorderRadius.circular(size * 3.5 / 24),
        ),
      ),
    );
  }
}

/// Gradient "Premium" pill.
class PremiumBadge extends StatelessWidget {
  final bool dim;
  const PremiumBadge({super.key, this.dim = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: dim ? Hip.line2 : null,
        gradient: dim
            ? null
            : LinearGradient(colors: [Hip.blue, Brand.hsl(197, 85, 49)]),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PremiumCubeIcon(size: 13, color: dim ? Hip.muted : Colors.white),
          const SizedBox(width: 5),
          Text(
            S.tPremium,
            style: Hip.sans(
              600,
              11.5,
              color: dim ? Hip.muted : Colors.white,
              letterSpacing: .35,
            ),
          ),
        ],
      ),
    );
  }
}

/// What the primary button says. The yearly plan starts with seven free days
/// and says so; the monthly plan bills right away.
String paywallCtaLabel(PlanInfo info, {required bool failed}) => failed
    ? S.aTryAgain
    : info.trial
    ? S.pwCtaTrial
    : S.pwCtaBuy;

/// Everything on the paywall below the header: what the plan gives, which of
/// its two variants is picked, one price in large type, the legal line for
/// that variant and the primary button.
///
/// Plain parameters on purpose: the offer can be laid out and read without a
/// store, a subscription, or any app state behind it.
class PaywallOffer extends StatelessWidget {
  final PlanInfo yearly;
  final PlanInfo monthly;
  final PremiumPlan plan;
  final ValueChanged<PremiumPlan> onPlan;

  /// The city of the locked location that led here, when one did.
  final String? city;

  /// How many hideip.net locations the plan covers, or null while the catalog
  /// has not been read and there is no honest number to print.
  final int? locationCount;

  /// The first charge date for the yearly plan, already formatted.
  final String trialEnds;

  /// "App Store" or "Google Play".
  final String storeName;

  /// The previous attempt failed: the banner shows and the button retries.
  final bool failed;

  /// The store's own words for that failure, when it gave any.
  final String? storeMessage;

  final VoidCallback onBuy;
  final VoidCallback onRestore;
  final VoidCallback onTerms;
  final VoidCallback onPrivacy;

  const PaywallOffer({
    super.key,
    required this.yearly,
    required this.monthly,
    required this.plan,
    required this.onPlan,
    required this.trialEnds,
    required this.storeName,
    required this.onBuy,
    required this.onRestore,
    required this.onTerms,
    required this.onPrivacy,
    this.city,
    this.locationCount,
    this.failed = false,
    this.storeMessage,
  });

  PlanInfo get _info => plan == PremiumPlan.yearly ? yearly : monthly;

  /// How tight the fixed vertical rhythm is on the screen at hand.
  ///
  /// The design's `.pw-body` is a flex column: the three `.pw-sp` gaps take
  /// whatever is left over, and on a screen too short for the whole offer the
  /// prototype simply clips (`overflow-y:hidden`). Clipping a price is not an
  /// option, and neither is scrolling an offer that has to be read at a
  /// glance, so the paddings give ground first: full design rhythm from
  /// roughly 720dp of body height up (a Pixel 6a and anything taller), down
  /// to about three quarters of it on a small phone (a 390x844 iPhone with
  /// its status bar and home indicator). Below that the scroll view takes
  /// over.
  static double density(double available) =>
      (.78 + .22 * (available - 600) / 120).clamp(.78, 1.0);

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Column(
      children: [
        Expanded(
          // The scroll view never moves at the sizes this app ships to; it is
          // the fallback for a screen (or a text scale) that cannot hold the
          // column at all, where clipping would be worse.
          child: LayoutBuilder(
            builder: (context, box) {
              final d = density(box.maxHeight);
              // `.pw-body` keeps 24 of padding on each side; the text inside is
              // measured against what is left.
              final width = box.maxWidth - 48;
              // `.pw-sp` (flex:1 0 6px): a small gap that grows into the space
              // left over, so the offer fills the height it is given.
              final gap = SizedBox(height: 6 * d);
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight),
                  child: IntrinsicHeight(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        children: [
                          _hero(d, width),
                          gap,
                          const Spacer(),
                          _benefits(d),
                          gap,
                          const Spacer(),
                          _segment(d),
                          _price(info, d),
                          gap,
                          const Spacer(),
                          if (failed) _errorBanner(),
                          _legal(
                            info.trial
                                ? S.pwLegalTrial(trialEnds, storeName)
                                : S.pwLegalNow(storeName),
                            d,
                          ),
                          _links(d),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          // `.ctabar.pw`; the 30px it reserves under the button is the home
          // indicator, which the SafeArea around the screen already holds.
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
          child: HipCta(
            paywallCtaLabel(info, failed: failed),
            connect: true,
            onTap: onBuy,
          ),
        ),
      ],
    );
  }

  Widget _hero(double d, double width) {
    final where = city;
    // `.pw-hero p{ max-width:280px }` as symmetric padding rather than a
    // `ConstrainedBox`: a constrained box answers an intrinsic-height query
    // with its parent's width (framework behaviour), so the column that
    // measures this screen would read a wrapped paragraph as one line.
    final side = ((width - 280) / 2).clamp(0.0, double.infinity);
    return Column(
      children: [
        SizedBox(height: 2 * d),
        const PaywallBrandBadge(),
        SizedBox(height: 11 * d),
        Text(
          where == null ? S.pwTitle : S.pwTitleCity(where),
          textAlign: TextAlign.center,
          style: Hip.sans(
            750,
            23,
            color: Colors.white,
            height: 1.18,
            letterSpacing: -.64,
          ),
        ),
        SizedBox(height: 6 * d),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: side),
          child: Text(
            S.pwSub,
            textAlign: TextAlign.center,
            style: Hip.sans(
              400,
              13,
              color: Colors.white.withValues(alpha: .58),
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }

  /// Five rows, one promise each, divided by hairlines. The first carries the
  /// number of locations, which is the claim that does the selling.
  Widget _benefits(double d) {
    final titleStyle = Hip.sans(
      550,
      14.5,
      color: Colors.white,
      letterSpacing: -.17,
    );
    Widget row(
      String title, {
      String? sub,
      bool badge = false,
      bool first = false,
    }) => Container(
      padding: EdgeInsets.symmetric(vertical: 12 * d, horizontal: 2),
      decoration: first
          ? null
          : BoxDecoration(
              border: Border(
                top: BorderSide(color: Colors.white.withValues(alpha: .09)),
              ),
            ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // `.pw-list li svg{ margin-top:3px }` (brief B16 aligns the check
          // with the first line, not with the middle of a wrapped row).
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: PaywallCheck(color: _pwCheck),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The NEW pill is a span inside the sentence, so it
                // follows the last word instead of parking at the right
                // edge of a wrapped row.
                if (badge)
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: title),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Brand.hsl(220, 95, 60, .2),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                S.setBadgeNew.toUpperCase(),
                                style: Hip.sans(
                                  700,
                                  9.5,
                                  color: Brand.hsl(220, 95, 78),
                                  letterSpacing: .475,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    style: titleStyle,
                  )
                else
                  Text(title, style: titleStyle),
                if (sub != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      sub,
                      style: Hip.sans(
                        500,
                        12,
                        color: Colors.white.withValues(alpha: .55),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    final count = locationCount;
    return Padding(
      padding: EdgeInsets.only(top: 14 * d),
      child: Column(
        children: [
          // "All 1 locations" is no sentence; below two the plain line stands.
          row(
            count == null || count < 2
                ? S.pwAllLocationsPlain
                : S.pwAllLocations(count),
            first: true,
          ),
          row(S.pwSpeed, sub: S.pwSpeedSub, badge: true),
          row(S.pwBlocked),
          row(S.pwNoLogs),
          row(S.pwDevices),
        ],
      ),
    );
  }

  /// One choice, then one price. Two priced cards side by side make the
  /// reader compare offers; a segment makes them pick a rhythm.
  Widget _segment(double d) {
    final yearlyOn = plan == PremiumPlan.yearly;
    Widget tab(PremiumPlan p, PlanInfo info, {Widget? badge}) {
      final on = plan == p;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (!on) Haptics.selection();
            onPlan(p);
          },
          child: AnimatedContainer(
            duration: Hip.dur(const Duration(milliseconds: 180)),
            // `.pw-seg button`: 11px above and below the label.
            padding: EdgeInsets.symmetric(vertical: 11 * d, horizontal: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? _pwBlue : Colors.transparent,
              borderRadius: BorderRadius.circular(13),
              boxShadow: on
                  ? [
                      BoxShadow(
                        color: Brand.hsl(220, 95, 55, .9),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                        spreadRadius: -8,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  info.name,
                  style: Hip.sans(
                    600,
                    14,
                    color: on
                        ? Colors.white
                        : Colors.white.withValues(alpha: .6),
                    letterSpacing: -.14,
                  ),
                ),
                if (badge != null) ...[const SizedBox(width: 8), badge],
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .06),
        border: Border.all(color: Colors.white.withValues(alpha: .1)),
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        children: [
          tab(
            PremiumPlan.yearly,
            yearly,
            badge: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: yearlyOn
                    ? Colors.white.withValues(alpha: .22)
                    : Brand.hsl(152, 60, 46, .18),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                S.pwSave,
                style: Hip.sans(
                  650,
                  10.5,
                  color: yearlyOn ? Colors.white : Brand.hsl(152, 60, 60),
                  letterSpacing: .21,
                ),
              ),
            ),
          ),
          // `.pw-seg{ gap:5px }`.
          const SizedBox(width: 5),
          tab(PremiumPlan.monthly, monthly),
        ],
      ),
    );
  }

  Widget _price(PlanInfo info, double d) {
    final perMonth = info.perMonth;
    return Padding(
      padding: EdgeInsets.only(top: 16 * d),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                // `.pw-price .big`: the display face, not the mono one. The
                // price is a headline here, and only its figures are lined up
                // (font-variant-numeric: tabular-nums).
                child: Text(
                  info.price,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      Hip.sans(
                        750,
                        28,
                        color: Colors.white,
                        letterSpacing: -.7,
                      ).copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                S.pwPer(info.per),
                style: Hip.sans(
                  550,
                  14,
                  color: Colors.white.withValues(alpha: .55),
                ),
              ),
            ],
          ),
          SizedBox(height: 6 * d),
          Text(
            info.trial
                ? (perMonth == null ? S.pwTrialFree : S.pwPerMonth(perMonth))
                : S.pwMonthlyNote,
            textAlign: TextAlign.center,
            style: Hip.sans(
              400,
              12.5,
              color: Colors.white.withValues(alpha: .5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner() {
    final msg = storeMessage;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: Brand.hsl(35, 90, 55, .1),
        border: Border.all(color: Brand.hsl(35, 90, 55, .28), width: 1.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: Brand.hsl(35, 90, 78)),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              '${S.pwFailed}${msg != null && msg.isNotEmpty ? '\n($msg)' : ''}',
              style: Hip.sans(
                400,
                12.5,
                color: Brand.hsl(35, 90, 78),
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _links(double d) {
    final style = Hip.sans(550, 12, color: Colors.white.withValues(alpha: .72));
    Widget dot() => Container(
      width: 3,
      height: 3,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .25),
        shape: BoxShape.circle,
      ),
    );
    // FittedBox: the three links brush past narrow widths otherwise
    // (a 38px overflow on a 402pt screen).
    return Padding(
      padding: EdgeInsets.fromLTRB(0, 11 * d, 0, 4 * d),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: onRestore,
              child: Text(S.pwRestore, style: style),
            ),
            dot(),
            GestureDetector(
              onTap: onTerms,
              child: Text(S.setTerms, style: style),
            ),
            dot(),
            GestureDetector(
              onTap: onPrivacy,
              child: Text(S.setPrivacyPolicy, style: style),
            ),
          ],
        ),
      ),
    );
  }
}

/// The quiet way out of a paywall for someone who already has an account
/// number: one line of text, below everything else, never a button that
/// competes with the offer.
class AccountSignInLink extends StatelessWidget {
  final VoidCallback onTap;

  /// On the paywall's dark surface rather than the app's own.
  final bool onDark;
  const AccountSignInLink({
    super.key,
    required this.onTap,
    this.onDark = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
          child: Text(
            S.accountSignInLink,
            textAlign: TextAlign.center,
            style: Hip.sans(
              500,
              14,
              color: onDark ? Colors.white.withValues(alpha: .55) : Hip.muted,
            ),
          ),
        ),
      ),
    );
  }
}

/// The paywall as it is laid out: the close header, then the offer filling
/// everything under it. Split out from the screen so the whole thing can be
/// measured at a given screen size without a store behind it.
class PaywallLayout extends StatelessWidget {
  final VoidCallback onClose;
  final Widget offer;
  const PaywallLayout({super.key, required this.onClose, required this.offer});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Hip.dark,
      child: SafeArea(
        child: Column(
          children: [
            // The design's paywall header carries one control: the X on the
            // right (screens-paywall.jsx `NavHead title="" right=…`). No back
            // chevron, because leaving this screen is closing the offer.
            Padding(
              // `.navhead` is 52dp tall (4 + a 38px button + 10). The button
              // here is the 48dp touch target the platforms ask for, so the
              // padding around it is what gives way.
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
              child: Row(
                children: [
                  const Spacer(),
                  HipIconButton(
                    Icons.close,
                    onTap: onClose,
                    color: Colors.white.withValues(alpha: .6),
                  ),
                ],
              ),
            ),
            Expanded(child: offer),
          ],
        ),
      ),
    );
  }
}

/// The paywall: one plan in two variants, priced and disclosed before the
/// purchase, with restore and the legal links (App Store guideline 3.1.2).
/// Always on the dark surface, like onboarding.
class PaywallScreen extends StatefulWidget {
  final AppState state;
  final HipNav nav;
  final HipScreen from;

  /// The locked location the user tapped to get here ([Location.id]), when
  /// there was one. It is what personalises the headline.
  final String? locId;
  const PaywallScreen({
    super.key,
    required this.state,
    required this.nav,
    required this.from,
    this.locId,
  });

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

enum _PwPhase { plans, buying, success, error }

class _PaywallScreenState extends State<PaywallScreen> {
  PremiumPlan _plan = PremiumPlan.yearly;
  _PwPhase _phase = _PwPhase.plans;
  String _busyMsg = '';

  /// The locations that were locked when this screen opened. Kept because
  /// they are exactly what a purchase unlocks: the success screen owes the
  /// user those, not whatever happens to be in the server list.
  late final List<Location> _wasLocked;

  @override
  void initState() {
    super.initState();
    _wasLocked = sortedByPing(widget.state, widget.state.lockedLocations);
  }

  void _back() => widget.nav.go(widget.from);

  Future<void> _buy() async {
    setState(() {
      _busyMsg = S.pwConfirming(_storeName);
      _phase = _PwPhase.buying;
    });
    final outcome = await widget.state.purchasePremium(_plan);
    if (!mounted) return;
    switch (outcome) {
      case PurchaseOutcome.success:
        Haptics.success();
        setState(() => _phase = _PwPhase.success);
      case PurchaseOutcome.canceled:
        // Their choice, not a failure: back to the plans without a banner.
        setState(() => _phase = _PwPhase.plans);
      case PurchaseOutcome.failed:
        Haptics.error();
        setState(() => _phase = _PwPhase.error);
    }
  }

  Future<void> _restore() async {
    final prev = _phase;
    setState(() {
      _busyMsg = S.pwChecking;
      _phase = _PwPhase.buying;
    });
    await widget.state.restorePurchases();
    if (!mounted) return;
    setState(
      () => _phase = widget.state.premium.isOn ? _PwPhase.success : prev,
    );
  }

  String get _trialEnds =>
      formatPremiumDate(DateTime.now().add(const Duration(days: 7)));

  /// The city of the locked row that opened this screen, if it is still
  /// known. Nothing is invented: an id that matches nothing leaves the
  /// headline generic.
  String? get _city {
    final id = widget.locId;
    if (id == null) return null;
    for (final l in [
      ...widget.state.lockedLocations,
      ..._wasLocked,
      ...widget.state.locations,
    ]) {
      if (l.id == id) return l.city;
    }
    return null;
  }

  /// How many hideip.net locations the plan covers right now, or null while
  /// the catalog has not answered and there is nothing true to count.
  int? get _locationCount {
    final locked = widget.state.lockedLocations.length;
    if (locked > 0) return locked;
    if (_wasLocked.isNotEmpty) return _wasLocked.length;
    final owned = widget.state.locations.where((l) => l.premium).length;
    return owned > 0 ? owned : null;
  }

  @override
  Widget build(BuildContext context) {
    if (_phase == _PwPhase.success) return _success();

    return Stack(
      children: [
        PaywallLayout(
          onClose: _back,
          offer: Column(
            children: [
              Expanded(
                child: PaywallOffer(
                  yearly: widget.state.planInfo(PremiumPlan.yearly),
                  monthly: widget.state.planInfo(PremiumPlan.monthly),
                  plan: _plan,
                  onPlan: (p) => setState(() => _plan = p),
                  city: _city,
                  locationCount: _locationCount,
                  trialEnds: _trialEnds,
                  storeName: _storeName,
                  failed: _phase == _PwPhase.error,
                  storeMessage: widget.state.purchases.lastError,
                  onBuy: _buy,
                  onRestore: _restore,
                  onTerms: () => _openUrl(_termsUrl),
                  onPrivacy: () => _openUrl(_privacyUrl),
                ),
              ),
              if (kAccountSignIn)
                AccountSignInLink(
                  onDark: true,
                  onTap: () => widget.nav.go(HipScreen.account),
                ),
            ],
          ),
        ),
        if (_phase == _PwPhase.buying) _buyingOverlay(),
      ],
    );
  }

  Widget _buyingOverlay() {
    return Positioned.fill(
      child: Container(
        color: Brand.hsl(222, 25, 7, .97),
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: Brand.hsl(220, 95, 68),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              _busyMsg,
              textAlign: TextAlign.center,
              style: Hip.sans(650, 15, color: Colors.white),
            ),
            const SizedBox(height: 4),
            Text(
              S.pwBusySub,
              textAlign: TextAlign.center,
              style: Hip.sans(
                400,
                13.5,
                color: Colors.white.withValues(alpha: .55),
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// What the purchase actually bought: the locations that carried a padlock
  /// a moment ago. Once provisioning has landed they are real servers on the
  /// same endpoints, so the live ones are preferred; until then the catalog
  /// rows stand in, with the latencies already measured on them.
  List<Location> get _unlocked {
    if (_wasLocked.isEmpty) return const [];
    final ids = {for (final l in _wasLocked) l.id};
    final live = widget.state.locations
        .where((l) => ids.contains(l.id))
        .toList();
    final shown = live.isEmpty ? _wasLocked : sortedByPing(widget.state, live);
    return shown.take(4).toList();
  }

  Widget _success() {
    final p = widget.state.premium;
    final trial = p.status == PremiumStatus.trial;
    final renewsDate = p.renews != null
        ? formatPremiumDate(p.renews!)
        : _trialEnds;
    final locations = _unlocked;
    return Container(
      color: Hip.dark,
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 46),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: Brand.hsl(152, 60, 46, .16),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.check,
                        size: 30,
                        color: Brand.hsl(152, 60, 58),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      S.pwDoneTitle,
                      style: Hip.sans(
                        750,
                        23,
                        color: Colors.white,
                        letterSpacing: -.64,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      locations.isEmpty
                          ? (trial ? S.pwDoneTrial : S.pwDonePaid)
                          : (trial ? S.pwDoneTrialNew : S.pwDonePaidNew),
                      textAlign: TextAlign.center,
                      style: Hip.sans(
                        400,
                        13,
                        color: Colors.white.withValues(alpha: .58),
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 18),
                    for (var i = 0; i < locations.length; i++)
                      UnlockIn(index: i, child: _unlockRow(locations[i])),
                    const Spacer(),
                    _legal(
                      trial
                          ? S.pwDoneLegalTrial(renewsDate)
                          : S.pwDoneLegalPaid(renewsDate),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
              child: HipCta(
                S.pwDoneCta,
                onTap: () => widget.nav.go(HipScreen.home),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _unlockRow(Location l) {
    final ping = widget.state.pingFor(l.profile);
    final ms = ping is PingOk ? S.pwPing(ping.ms) : '';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .06),
        border: Border.all(color: Colors.white.withValues(alpha: .1)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Brand.hsl(220, 95, 60, .18),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              l.cc,
              style: Hip.mono(
                700,
                11,
                color: Brand.hsl(220, 95, 72),
                letterSpacing: .5,
              ),
            ),
          ),
          const SizedBox(width: 11),
          Text(l.city, style: Hip.sans(600, 14, color: Colors.white)),
          const Spacer(),
          Text(
            ms,
            style: Hip.mono(600, 11, color: Colors.white.withValues(alpha: .5)),
          ),
        ],
      ),
    );
  }
}

/// Deals one unlocked location in, a beat after the one above it.
///
/// app.css `.unlock`: a 450 ms rise from 10px down, the first row starting at
/// 250 ms and every next one 160 ms later. The stagger is what makes the list
/// read as things gained one by one instead of a block that appears. The
/// timing goes through [Hip.dur], so "reduce motion" draws every row in place
/// at once.
class UnlockIn extends StatefulWidget {
  final int index;
  final Widget child;
  const UnlockIn({super.key, required this.index, required this.child});

  static const first = Duration(milliseconds: 250);
  static const step = Duration(milliseconds: 160);
  static const run = Duration(milliseconds: 450);

  @override
  State<UnlockIn> createState() => _UnlockInState();
}

class _UnlockInState extends State<UnlockIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final CurvedAnimation _rise;

  @override
  void initState() {
    super.initState();
    final delay = UnlockIn.first + UnlockIn.step * widget.index;
    final total = delay + UnlockIn.run;
    _c = AnimationController(vsync: this, duration: Hip.dur(total));
    // One controller per row rather than a shared clock: the delay is the
    // dead part of its own curve, which keeps a row that is added later
    // (the catalog answering after the purchase) on the same rhythm.
    _rise = CurvedAnimation(
      parent: _c,
      curve: Interval(
        delay.inMilliseconds / total.inMilliseconds,
        1,
        curve: const Cubic(.22, .61, .36, 1),
      ),
    );
    _c.forward();
  }

  @override
  void dispose() {
    _rise.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _rise,
      child: widget.child,
      builder: (_, child) => Opacity(
        opacity: _rise.value,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - _rise.value)),
          child: child,
        ),
      ),
    );
  }
}

/// Settings → Premium: the subscription at a glance plus billing shortcuts.
class PremiumManageScreen extends StatefulWidget {
  final AppState state;
  final HipNav nav;
  const PremiumManageScreen({
    super.key,
    required this.state,
    required this.nav,
  });

  @override
  State<PremiumManageScreen> createState() => _PremiumManageScreenState();
}

class _PremiumManageScreenState extends State<PremiumManageScreen> {
  bool _restoring = false;

  /// The account number's line under the plan name: the day its time runs
  /// out, with the date in mono, or that it has run out.
  InlineSpan _accountLine(bool expired, DateTime? until) {
    if (expired || until == null) {
      return const TextSpan(text: S.accountOutOfTime);
    }
    final date = formatPremiumDate(until);
    final line = S.accountActiveUntil(date);
    final at = line.indexOf(date);
    if (at < 0) return TextSpan(text: line);
    return TextSpan(
      children: [
        TextSpan(text: line.substring(0, at)),
        TextSpan(
          text: date,
          style: Hip.mono(600, 12.5, color: Hip.muted),
        ),
        TextSpan(text: line.substring(at + date.length)),
      ],
    );
  }

  Future<void> _restore() async {
    if (_restoring) return;
    setState(() => _restoring = true);
    await widget.state.restorePurchases();
    if (mounted) setState(() => _restoring = false);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final nav = widget.nav;
    final p = state.premium;
    final info = state.planInfo(p.plan ?? PremiumPlan.yearly);
    final expired = p.status == PremiumStatus.expired;
    // An account number has no store behind it: no price, no renewal, no
    // store page and nothing to restore. It has a number instead.
    final account = p.source == PremiumSource.account;
    final until = p.renews;
    final statusBadge = switch (p.status) {
      PremiumStatus.active => HipBadge.ok(S.pmActive),
      PremiumStatus.trial => HipBadge.blue(S.tFreeTrial),
      _ => HipBadge(S.pmExpired, bg: Hip.line2, fg: Hip.inkSoft),
    };
    return SafeArea(
      child: Column(
        children: [
          HipNavHead(
            title: S.tPremium,
            onBack: () => nav.go(HipScreen.settings),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                HipCard(
                  // screens-paywall.jsx: the card names the plan with the
                  // wordmark itself (`.crow .v .wm`), no product tile in front
                  // of it. Premium is a plan inside hideip.net, so the name
                  // carries it.
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const HipWordmark(size: 17),
                                const SizedBox(width: 5),
                                Text(
                                  S.tPremium,
                                  style: Hip.sans(
                                    650,
                                    17,
                                    color: Hip.ink,
                                    letterSpacing: -.17,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            if (account)
                              Text.rich(
                                _accountLine(expired, until),
                                style: Hip.sans(550, 13, color: Hip.muted),
                              )
                            else
                              Text(
                                expired
                                    ? S.setPremiumEnded
                                    : S.pmPlanName(info.name),
                                style: Hip.sans(550, 13, color: Hip.muted),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 14),
                      statusBadge,
                    ],
                  ),
                ),
                if (account && kAccountSignIn) ...[
                  const HipSectionLabel(S.setAccount),
                  HipListGroup(
                    children: [
                      HipListRow(
                        title: S.accountNumberTitle,
                        subtitle: state.accountNumber == null
                            ? null
                            : maskAccountNumber(
                                state.accountNumber!,
                                short: true,
                              ),
                        subtitleMono: true,
                        trailing: Icon(
                          Icons.chevron_right,
                          size: 17,
                          color: Hip.muted2,
                        ),
                        onTap: () => nav.go(HipScreen.account),
                      ),
                    ],
                  ),
                  const HipSubnote(S.pmAccountSubnote),
                ],
                if (!expired && !account) ...[
                  const HipSectionLabel(S.pmSubscription),
                  HipListGroup(
                    children: [
                      HipListRow(
                        title: S.pmPlan,
                        trailing: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: info.price,
                                style: Hip.mono(600, 12.5, color: Hip.muted),
                              ),
                              TextSpan(
                                text: ' ${S.pwPer(info.per)}',
                                style: Hip.sans(400, 12.5, color: Hip.muted),
                              ),
                            ],
                          ),
                        ),
                      ),
                      HipListRow(
                        title: p.status == PremiumStatus.trial
                            ? S.pmTrialEnds
                            : S.pmRenews,
                        trailing: Text(
                          p.renews != null ? formatPremiumDate(p.renews!) : '',
                          style: Hip.mono(600, 12.5, color: Hip.muted),
                        ),
                      ),
                    ],
                  ),
                ],
                // A store subscription known on this device keeps its own
                // page reachable, whichever entitlement is in force.
                if (account && state.hasStoreEntitlement) ...[
                  const HipSectionLabel(S.pmBilling),
                  HipListGroup(
                    children: [
                      HipListRow(
                        title: S.pmManage(_storeName),
                        subtitle: S.pmManageSub,
                        trailing: Icon(
                          Icons.open_in_new,
                          size: 17,
                          color: Hip.muted2,
                        ),
                        onTap: () => _openUrl(_manageUrl),
                      ),
                    ],
                  ),
                ],
                if (!account) ...[
                  const HipSectionLabel(S.pmBilling),
                  HipListGroup(
                    children: [
                      HipListRow(
                        title: S.pmManage(_storeName),
                        subtitle: S.pmManageSub,
                        trailing: Icon(
                          Icons.open_in_new,
                          size: 17,
                          color: Hip.muted2,
                        ),
                        onTap: () => _openUrl(_manageUrl),
                      ),
                      HipListRow(
                        title: _restoring ? S.pmChecking : S.pwRestore,
                        trailing: _restoring
                            ? SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Hip.muted2,
                                ),
                              )
                            : Icon(
                                Icons.chevron_right,
                                size: 17,
                                color: Hip.muted2,
                              ),
                        onTap: _restoring ? null : _restore,
                      ),
                    ],
                  ),
                  HipSubnote(S.pmSubnote(_storeName)),
                ],
                if (expired)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 14, 0, 24),
                    child: HipCta(
                      S.pmRestart,
                      onTap: () => nav.openPaywall(from: HipScreen.settings),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the trial lapses: nothing is lost, Premium is just paused.
class TrialExpiredScreen extends StatelessWidget {
  final AppState state;
  final HipNav nav;
  const TrialExpiredScreen({super.key, required this.state, required this.nav});

  @override
  Widget build(BuildContext context) {
    // The paused rows are hideip.net locations, never the user's own imports:
    // an imported server keeps working and was never part of the plan.
    final paused = sortedByPing(state, state.lockedLocations);
    return SafeArea(
      child: Column(
        children: [
          HipNavHead(title: '', onBack: () => nav.go(HipScreen.home)),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                // `.exp-hero`: the product icon, because this is the one
                // screen that stands for the whole app.
                const Padding(
                  padding: EdgeInsets.fromLTRB(0, 22, 0, 18),
                  child: Center(
                    child: HideipProductIcon(size: 64, lifted: true),
                  ),
                ),
                Text(
                  S.expTitle,
                  textAlign: TextAlign.center,
                  style: Hip.sans(750, 23, color: Hip.ink, letterSpacing: -.58),
                ),
                const SizedBox(height: 9),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 290),
                    child: Text(
                      S.expBody,
                      textAlign: TextAlign.center,
                      style: Hip.sans(
                        400,
                        13.5,
                        color: Hip.muted,
                        height: 1.55,
                      ),
                    ),
                  ),
                ),
                // Same rows as Locations: same bars, same padlock, same words.
                // One visual language for Premium, because the comparison is
                // the whole offer.
                if (paused.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: HipSectionLabel(S.expPaused),
                  ),
                  HipListGroup(
                    children: [
                      for (final l in paused)
                        LockedRow(
                          location: l,
                          from: LockedFrom.expired,
                          pingMs: switch (state.pingFor(l.profile)) {
                            PingOk(ms: final ms) => ms,
                            _ => null,
                          },
                          level: state.levelFor(l.profile),
                          advanced: state.prefs.advanced,
                          onTap: (from, locId) => nav.openPaywall(
                            from: HipScreen.trialExpired,
                            locId: locId,
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 20),
            child: Column(
              children: [
                HipCta(
                  S.expCta,
                  onTap: () => nav.openPaywall(from: HipScreen.trialExpired),
                ),
                const SizedBox(height: 8),
                HipCta(
                  S.expCtaImport,
                  quiet: true,
                  onTap: () => nav.openImport(),
                ),
                if (kAccountSignIn)
                  AccountSignInLink(onTap: () => nav.go(HipScreen.account)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The product icon, form A (app.css `.picon`): "hide" over the filled IP
/// block on the dark tile. The only shape allowed to stand for the app
/// itself, as opposed to the wordmark, which stands for the brand.
///
/// Ported here rather than into the shared kit because this file is its only
/// caller today (`.picon.exp-mark` on the trial-expired screen).
class HideipProductIcon extends StatelessWidget {
  final double size;

  /// `.picon.exp-mark` carries a blue drop shadow.
  final bool lifted;
  const HideipProductIcon({super.key, this.size = 64, this.lifted = false});

  @override
  Widget build(BuildContext context) {
    final block = size * .39;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Hip.dark,
        borderRadius: BorderRadius.circular(size * .22),
        boxShadow: lifted
            ? [
                BoxShadow(
                  color: Brand.hsl(220, 95, 55, .5),
                  blurRadius: 34,
                  offset: const Offset(0, 14),
                  spreadRadius: -10,
                ),
              ]
            : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'hide',
            style: TextStyle(
              fontFamily: Brand.wordmarkFont,
              fontVariations: const [FontVariation('wght', 700)],
              fontSize: size * .263,
              letterSpacing: -.03 * size * .263,
              height: 1,
              color: Colors.white,
            ),
          ),
          SizedBox(height: size * .063),
          Container(
            width: block * 1.468,
            height: block * 1.157,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Brand.hsl(220, 95, 55),
              borderRadius: BorderRadius.circular(block * .21),
            ),
            child: Text(
              'IP',
              style: Hip.mono(
                700,
                block,
                color: Colors.white,
                letterSpacing: -.02 * block,
                height: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
