import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// How the system bars look over a surface, for a window drawn edge to edge.
///
/// From Android 15 an app that targets SDK 35+ always runs edge to edge: the
/// status bar and the navigation bar are transparent and sit over the app,
/// so only the icon colours are ours to choose. Both are picked from what is
/// actually under them, [darkTop] for the status bar and [bottom] for the
/// navigation bar. With three-button navigation the system lays a scrim
/// under the buttons that follows the same choice, light over a light
/// surface and dark over a dark one.
///
/// Older Android versions still give the navigation bar a solid colour, so
/// [bottom] is handed over as that colour too, and the bar continues the
/// screen instead of cutting a black band under it. Android 15 and later
/// ignore it (the Flutter engine skips the call there). The status bar is
/// made transparent for the same reason: the app already draws under it.
SystemUiOverlayStyle hipBars({required bool darkTop, required Color bottom}) {
  final darkBottom =
      ThemeData.estimateBrightnessForColor(bottom) == Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: darkTop ? Brightness.light : Brightness.dark,
    // iOS names the bar by its background, not by its icons.
    statusBarBrightness: darkTop ? Brightness.dark : Brightness.light,
    systemNavigationBarColor: bottom.withValues(alpha: 1),
    systemNavigationBarIconBrightness: darkBottom
        ? Brightness.light
        : Brightness.dark,
  );
}

/// Claims the navigation bar for a surface that reaches the bottom edge on
/// top of a screen, such as a sheet or a camera panel. Flutter reads the
/// navigation bar style from whatever is painted under the bar and the
/// status bar style from whatever is under that one, so a region that never
/// reaches the top leaves the status bar to the screen behind it.
class HipNavBarRegion extends StatelessWidget {
  /// The colour of the surface that meets the navigation bar.
  final Color bottom;
  final Widget child;
  const HipNavBarRegion({super.key, required this.bottom, required this.child});

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: hipBars(
      darkTop: ThemeData.estimateBrightnessForColor(bottom) == Brightness.dark,
      bottom: bottom,
    ),
    child: child,
  );
}
