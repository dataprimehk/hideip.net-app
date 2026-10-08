import 'package:flutter/material.dart';

import 'hip.dart';
import 'system_bars.dart';

/// The one modal surface in the app: an explanation that needs a decision.
///
/// Ported from app.css `.sheet` (radius 24 on the top corners, 22px side
/// padding, a grabber, at most two solid actions plus one quiet row). Every
/// sheet in the app is this one, including the linked-device sheets, which
/// pass their own body in as a single child.
///
/// On iOS the contract asks for the system look (detent, grabber, dimming).
/// `showModalBottomSheet` with `useSafeArea` plus this grabber is as close as
/// that gets without native code.
class HipSheet extends StatelessWidget {
  final List<Widget> children;
  const HipSheet({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    // The card reaches the bottom edge, under the navigation bar, so it
    // claims the colour of that bar's icons.
    return HipNavBarRegion(
      bottom: Hip.card,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Hip.card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: Hip.line, width: 1.5),
        ),
        padding: EdgeInsets.fromLTRB(
            22, 10, 22, MediaQuery.paddingOf(context).bottom + 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: Hip.line,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Sheet title: a short label, no full stop (app.css `.sh-t`).
class HipSheetTitle extends StatelessWidget {
  final String text;
  const HipSheetTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Text(text,
      style: Hip.sans(700, 19, color: Hip.ink, letterSpacing: -.42));
}

/// Sheet body: full sentences (app.css `.sh-b`).
class HipSheetBody extends StatelessWidget {
  final String text;
  const HipSheetBody(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(text,
            style: Hip.sans(400, 13.5, color: Hip.muted, height: 1.55)),
      );
}

/// The action stack under a sheet body (app.css `.sh-a`: 8px gaps, 20 above).
class HipSheetActions extends StatelessWidget {
  final List<Widget> children;
  const HipSheetActions({super.key, required this.children});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              children[i],
            ],
          ],
        ),
      );
}

/// Presents [children] inside a [HipSheet]. Returns whatever the sheet popped
/// with, or null when it was dismissed by the scrim or the grabber.
Future<T?> showHipSheet<T>(
  BuildContext context, {
  required List<Widget> children,
  bool dismissible = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    isDismissible: dismissible,
    enableDrag: dismissible,
    useSafeArea: true,
    // "Reduce motion" removes the slide-up rather than shortening it; the
    // sheet still dims the screen, so nothing about it becomes ambiguous.
    sheetAnimationStyle: Hip.reducedMotion
        ? AnimationStyle(
            duration: Duration.zero, reverseDuration: Duration.zero)
        : null,
    builder: (_) => HipSheet(children: children),
  );
}
