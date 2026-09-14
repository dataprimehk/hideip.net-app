import 'package:flutter/material.dart';

import 'hip.dart';

/// A soft fade over the bottom edge of a scrolling list, shown only while
/// there is more list below the edge.
///
/// A list that ends under a floating bar reads as complete at the last
/// visible row. The fade is the hint both platforms use now under such a
/// bar: the surface colour bleeding into the content over the last few
/// points, gone once the list is scrolled to its end so nothing is covered
/// that cannot be reached.
///
/// It listens to the scroll notifications of whatever scrolls inside it,
/// so any list can be wrapped without threading a controller through. It
/// wraps the scroll view rather than living inside it, so it never moves
/// with the content and never takes a touch: the list underneath stays
/// fully tappable and swipeable through it.
class HeroScrollEdge extends StatefulWidget {
  final Widget child;

  /// The height of the fade.
  static const double height = 28;

  const HeroScrollEdge({super.key, required this.child});

  @override
  State<HeroScrollEdge> createState() => _HeroScrollEdgeState();
}

class _HeroScrollEdgeState extends State<HeroScrollEdge> {
  bool _more = false;

  bool _onNotification(Notification n) {
    final ScrollMetrics m;
    if (n is ScrollNotification) {
      m = n.metrics;
    } else if (n is ScrollMetricsNotification) {
      m = n.metrics;
    } else {
      return false;
    }
    // A point of slack: at the very end the extent after can be a fraction.
    final more = m.hasContentDimensions && m.extentAfter > 1;
    if (more != _more) setState(() => _more = more);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final surface = Hip.surface;
    return NotificationListener<Notification>(
      onNotification: _onNotification,
      child: Stack(children: [
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
      ]),
    );
  }
}
