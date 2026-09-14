import 'package:flutter/material.dart';

import 'hip.dart';

/// A soft fade over the bottom edge of a scrolling list, shown only while
/// there is more list below the edge.
///
/// The Home list ends under the Connect bar, and without a hint the last
/// visible row reads as the last row there is. The fade is the hint both
/// platforms use now under a floating bar: the surface colour bleeding into
/// the content over the last few points, gone once the list is scrolled to
/// its end so nothing is covered that cannot be reached.
///
/// It wraps the scroll view rather than living inside it, so it never moves
/// with the content and never takes a touch: the list underneath stays fully
/// tappable and swipeable through it.
class HeroScrollEdge extends StatefulWidget {
  final ScrollController controller;
  final Widget child;

  /// The height of the fade.
  static const double height = 28;

  const HeroScrollEdge({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  State<HeroScrollEdge> createState() => _HeroScrollEdgeState();
}

class _HeroScrollEdgeState extends State<HeroScrollEdge> {
  bool _more = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_check);
    // The first layout decides whether the list even overflows.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void didUpdateWidget(HeroScrollEdge old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_check);
      widget.controller.addListener(_check);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_check);
    super.dispose();
  }

  void _check() {
    if (!mounted || !widget.controller.hasClients) return;
    final pos = widget.controller.position;
    // A point of slack: at the very end the extent after can be a fraction.
    final more = pos.hasContentDimensions && pos.extentAfter > 1;
    if (more != _more) setState(() => _more = more);
  }

  @override
  Widget build(BuildContext context) {
    // Content size can change without a scroll (a server added, a search
    // typed), so every build re-checks after layout.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    final surface = Hip.surface;
    return Stack(children: [
      widget.child,
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        height: HeroScrollEdge.height,
        child: IgnorePointer(
          child: AnimatedOpacity(
            duration: Hip.dur(const Duration(milliseconds: 180)),
            opacity: _more ? 1 : 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [surface.withValues(alpha: 0), surface],
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}
