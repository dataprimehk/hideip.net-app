import 'package:flutter/material.dart';

import '../brand.dart';
import '../strings.dart';
import 'hip.dart';
import 'hip_sheet.dart';

/// Everything Home says next to the status card: the three banners on the
/// dark panel, the upsell row in the list, the empty block, and the two
/// sheets Home can raise.
///
/// Every piece takes plain values and plain callbacks. None of them knows
/// about the app state, which is what makes each Atlas state buildable on its
/// own in a test.
///
/// Ported from `design/app-1_1_0/screens-home.jsx` (`ClipboardBanner`,
/// `TrialBanner`, the `.banner.deny` block, the `.upsell` row, `.empty-home`)
/// and `app.css`.

/// Shared shell for the three banners that sit on the dark hero panel.
class _DarkBanner extends StatelessWidget {
  final Widget child;
  final Color background;
  final Color border;
  const _DarkBanner({
    required this.child,
    required this.background,
    required this.border,
  });

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 14),
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border, width: 1.5),
        ),
        child: child,
      );
}

/// A quiet text action inside a dark banner, with a full 44px touch target.
class _BannerAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Color color;
  final Color? background;
  const _BannerAction({
    required this.label,
    required this.onTap,
    required this.color,
    this.background,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
          child: Center(
            widthFactor: 1,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: background == null
                  ? null
                  : BoxDecoration(
                      color: background,
                      borderRadius: BorderRadius.circular(999),
                    ),
              child: Text(label,
                  style: Hip.sans(650, 12.5, color: color)),
            ),
          ),
        ),
      );
}

/// B9: a connection link was found in the clipboard. Offered once,
/// dismissible, and it never imports anything on its own: Add opens Import
/// with the link prefilled and the user still decides.
class HomeClipboardBanner extends StatelessWidget {
  /// A short, readable stand-in for the link, e.g. `vless://…@quietproxy`.
  final String preview;
  final VoidCallback onAdd;
  final VoidCallback onDismiss;

  const HomeClipboardBanner({
    super.key,
    required this.preview,
    required this.onAdd,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final white = Colors.white;
    return _DarkBanner(
      background: Brand.hsl(220, 95, 60, .13),
      border: Brand.hsl(220, 95, 60, .28),
      child: Row(children: [
        Icon(Icons.link, size: 19, color: Brand.hsl(220, 95, 74)),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(S.b9Line,
                  style: Hip.sans(550, 13, color: white, height: 1.3)),
              const SizedBox(height: 2),
              Text(preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Hip.mono(600, 11.5,
                      color: white.withValues(alpha: .62))),
            ],
          ),
        ),
        _BannerAction(
          label: S.b9Add,
          onTap: onAdd,
          color: Brand.hsl(220, 95, 74),
        ),
        Semantics(
          button: true,
          label: S.b9Dismiss,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(Icons.close,
                  size: 16, color: white.withValues(alpha: .4)),
            ),
          ),
        ),
      ]),
    );
  }
}

/// B14: the system VPN configuration was declined. One calm line, one way
/// out, no red and no blame. The way out is the request itself: the system
/// shows it again on the next attempt, and there is no settings switch that
/// grants it instead.
class HomeDeniedBanner extends StatelessWidget {
  final VoidCallback onTryAgain;
  const HomeDeniedBanner({super.key, required this.onTryAgain});

  @override
  Widget build(BuildContext context) {
    final white = Colors.white;
    return _DarkBanner(
      background: white.withValues(alpha: .07),
      border: white.withValues(alpha: .16),
      child: Row(children: [
        Expanded(
          child: Text(S.b14Line,
              style: Hip.sans(550, 13, color: white, height: 1.3)),
        ),
        const SizedBox(width: 8),
        _BannerAction(
          label: S.b14Action,
          onTap: onTryAgain,
          color: white,
          background: white.withValues(alpha: .12),
        ),
      ]),
    );
  }
}

/// B8: the day before the free trial renews. The value first, the price
/// second, one solid action. No countdown and no pressure.
class HomeTrialBanner extends StatelessWidget {
  /// The yearly price as the store formats it.
  final String price;
  final VoidCallback onKeep;

  const HomeTrialBanner({
    super.key,
    required this.price,
    required this.onKeep,
  });

  @override
  Widget build(BuildContext context) {
    final white = Colors.white;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.fromLTRB(15, 12, 12, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Brand.hsl(220, 95, 60, .16),
            Brand.hsl(220, 95, 60, .08),
          ],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Brand.hsl(220, 95, 60, .3), width: 1.5),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(S.b8Title, style: Hip.sans(650, 13, color: white)),
              const SizedBox(height: 2),
              // The price is a number, so it stays mono even mid-sentence.
              Text.rich(
                TextSpan(
                  children: _split(S.b8Body(price), price, white),
                ),
                style: Hip.sans(500, 12,
                    color: white.withValues(alpha: .62), height: 1.35),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onKeep,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Center(
              widthFactor: 1,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Hip.blue,
                  borderRadius: BorderRadius.circular(999),
                ),
                child:
                    Text(S.b8Action, style: Hip.sans(650, 12.5, color: white)),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  /// Splits a sentence around [needle] so the price alone renders in mono
  /// without the sentence itself being assembled here.
  static List<TextSpan> _split(String sentence, String needle, Color white) {
    final at = sentence.indexOf(needle);
    if (at < 0) return [TextSpan(text: sentence)];
    return [
      TextSpan(text: sentence.substring(0, at)),
      TextSpan(
        text: needle,
        style: Hip.mono(600, 12, color: white),
      ),
      TextSpan(text: sentence.substring(at + needle.length)),
    ];
  }
}

/// B7: connected without a subscription. One dismissible row sells Speed
/// mode in the moment it would help; dismissing snoozes it for 14 days.
class HomeUpsellRow extends StatelessWidget {
  final VoidCallback onTap;
  final VoidCallback onDismiss;
  const HomeUpsellRow({
    super.key,
    required this.onTap,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.fromLTRB(14, 13, 8, 13),
        decoration: BoxDecoration(
          color: Hip.blueSoft,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Brand.hsl(220, 95, 55, .18), width: 1.5),
        ),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Brand.hsl(220, 95, 55, .14),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(Icons.speed, size: 19, color: Hip.blueDeep),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(S.b7Title,
                    style: Hip.sans(650, 13.5,
                        color: Hip.ink, letterSpacing: -.135)),
                const SizedBox(height: 2),
                Text(S.b7Body,
                    style:
                        Hip.sans(400, 11.5, color: Hip.muted, height: 1.35)),
              ],
            ),
          ),
          Semantics(
            button: true,
            label: S.b7Dismiss,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onDismiss,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(Icons.close, size: 15, color: Hip.muted2),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// B0: nothing has been imported and no subscription is running. The block
/// explains what sets a connection up; the actions live in the CTA bar, where
/// Connect would otherwise be.
class HomeEmptyBlock extends StatelessWidget {
  const HomeEmptyBlock({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
        decoration: BoxDecoration(
          color: Hip.card,
          borderRadius: BorderRadius.circular(Hip.radius),
          border: Border.all(
              color: Hip.line, width: 1.5, strokeAlign: BorderSide.strokeAlignInside),
        ),
        child: Column(children: [
          Text(S.b0Title,
              textAlign: TextAlign.center,
              style: Hip.sans(700, Hip.titleSize,
                  color: Hip.ink, letterSpacing: -.34)),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Text(S.b0Body,
                textAlign: TextAlign.center,
                style: Hip.sans(400, Hip.bodySize,
                    color: Hip.muted, height: 1.55)),
          ),
        ]),
      );
}

/// What the user picked in the B6 sheet.
enum ConnectFailedChoice { retry, another, plans }

/// B6: the server did not respond. Try again leads, another location is
/// second, and only without a subscription does a quiet See plans row sit
/// under both. The failure moment never sells first.
///
/// Meant to be passed as the single child of [showHipSheet]; it pops itself
/// with a [ConnectFailedChoice].
class ConnectFailedSheet extends StatelessWidget {
  /// True when there is no subscription, which is the only case that earns
  /// the quiet third row.
  final bool offerPlans;

  const ConnectFailedSheet({super.key, required this.offerPlans});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HipSheetTitle(S.b6Title),
        HipSheetBody(
            offerPlans ? '${S.b6Body} ${S.b6BodyByo}' : S.b6Body),
        HipSheetActions(children: [
          HipCta(S.aTryAgain,
              connect: true,
              onTap: () =>
                  Navigator.of(context).pop(ConnectFailedChoice.retry)),
          HipCta(S.b6Another,
              ghost: true,
              onTap: () =>
                  Navigator.of(context).pop(ConnectFailedChoice.another)),
          if (offerPlans)
            HipCta(S.aSeePlans,
                quiet: true,
                onTap: () =>
                    Navigator.of(context).pop(ConnectFailedChoice.plans)),
        ]),
      ],
    );
  }
}

/// B13: the one system permission, offered once before the first Connect.
/// Continue leads to the system dialog; Not now costs nothing.
///
/// Pops `true` for Continue and `false` for Not now.
class VpnPrimerSheet extends StatelessWidget {
  const VpnPrimerSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HipSheetTitle(S.b13Title),
        const HipSheetBody(S.b13Body),
        HipSheetActions(children: [
          HipCta(S.aContinue,
              connect: true, onTap: () => Navigator.of(context).pop(true)),
          HipCta(S.aNotNow,
              quiet: true, onTap: () => Navigator.of(context).pop(false)),
        ]),
      ],
    );
  }
}

/// Disconnect under a system Always-on profile the app never opted into:
/// Android keeps holding traffic, and only the user can change that.
/// [onOpenSettings] takes them to the OS page; the sheet pops itself first.
class AlwaysOnSheet extends StatelessWidget {
  final VoidCallback onOpenSettings;
  const AlwaysOnSheet({super.key, required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HipSheetTitle(S.alwaysOnTitle),
        const HipSheetBody(S.alwaysOnBody),
        HipSheetActions(children: [
          HipCta(S.alwaysOnOpen, connect: true, onTap: () {
            Navigator.of(context).pop();
            onOpenSettings();
          }),
          HipCta(S.alwaysOnDismiss,
              quiet: true, onTap: () => Navigator.of(context).pop()),
        ]),
      ],
    );
  }
}
