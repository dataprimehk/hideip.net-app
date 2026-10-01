import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/deep_link.dart';
import '../../core/import_payload.dart';
import '../../core/location.dart';
import '../../core/ui_prefs.dart';
import '../../state/app_state.dart';
import 'account_screen.dart';
import 'detail_screen.dart';
import 'hip.dart';
import 'hip_sheet.dart';
import 'home_hero.dart';
import 'import_screen.dart';
import 'linked_devices_screen.dart';
import 'locations_screen.dart';
import 'onboarding_screen.dart';
import 'paywall_screen.dart';
import 'settings_screen.dart';

/// Whether the "get access from hideip.net" plans flow can exist on this
/// platform at all. Both stores ship it (StoreKit on iOS, Play Billing on
/// Android). This is only the build-time floor; whether any paywall entry
/// point actually renders is a further runtime check on the live catalog
/// (see [AppState.plansOffered]), so the app never advertises a purchase it
/// cannot complete, e.g. before the store products exist.
final bool kPlansAvailable = defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.android;

/// Whether the ways into signing in with an account number are shown. On by
/// default; a build made with `--dart-define=HIP_ACCOUNT_SIGNIN=false` hides
/// every entry point (the Settings row, the links under the paywall) while
/// the screen and the code behind it stay in place.
const bool kAccountSignIn =
    bool.fromEnvironment('HIP_ACCOUNT_SIGNIN', defaultValue: true);

enum HipScreen {
  onboarding,
  home,
  locations,
  import,
  settings,
  detail,
  paywall,
  premium,
  trialExpired,
  linkedDevices,
  account,
}

/// One entry on the in-app back stack: the screen and the context bag it was
/// showing at the time.
typedef HipStackEntry = ({HipScreen screen, Object? ctx});

/// The in-app back stack.
///
/// Kept apart from the widget so the navigation rules can be read (and
/// tested) on their own. The rules, from the design prototype:
///
///  * [go] pushes the screen being left, with its context, and shows the new
///    one. Returning later restores that exact context.
///  * Home is the root. Arriving at Home empties the stack: a finished flow
///    (an import, a purchase) is not something to walk back out of.
///  * A screen already on the stack is dropped from it before being pushed
///    again, so the stack holds each screen at most once and back cannot loop.
///  * Re-entering the screen already showing changes only its context.
///  * [back] pops one entry. With an empty stack it lands on Home, and from a
///    root screen [backTarget] is null so the shell can hand the gesture to
///    the OS instead.
class HipNavStack {
  final List<HipStackEntry> _entries = [];

  /// The screen showing right now.
  HipScreen screen;

  /// The context bag the current screen was opened with.
  Object? ctx;

  HipNavStack({this.screen = HipScreen.home, this.ctx});

  List<HipStackEntry> get entries => List.unmodifiable(_entries);
  int get depth => _entries.length;

  void go(HipScreen next, [Object? nextCtx]) {
    if (next == HipScreen.account && !kAccountSignIn) return;
    if (next == HipScreen.home) {
      _entries.clear();
    } else if (next != screen) {
      _entries.removeWhere((e) => e.screen == next);
      _entries.add((screen: screen, ctx: ctx));
    }
    ctx = nextCtx;
    screen = next;
  }

  void back() {
    final prev = _entries.isNotEmpty
        ? _entries.removeLast()
        : (screen: HipScreen.home, ctx: null);
    ctx = prev.ctx;
    screen = prev.screen;
  }

  /// Where back leads, or null when back belongs to the OS.
  HipScreen? get backTarget {
    if (_entries.isNotEmpty) return _entries.last.screen;
    if (screen == HipScreen.home || screen == HipScreen.onboarding) return null;
    return HipScreen.home;
  }
}

/// In-app navigator used by every redesign screen. Not a Navigator: screens
/// are few, transitions are uniform, and the VPN state lives above them all.
/// It is a real stack though, the same one the design prototype keeps
/// (`HideIP App 1.1.0.html`), rather than a fixed parent-of table.
///
/// [go] pushes the current screen and moves to a new one; [back] returns to
/// exactly where the user came from, with the context that screen had. Home is
/// the root: going there clears the stack, because a finished flow (an import,
/// a purchase) is not something to walk back out of. A screen already on the
/// stack is never pushed twice, so back can never loop.
class HipNav {
  final void Function(HipScreen screen, [Object? ctx]) go;

  /// Return to the previous screen and its context. From the root this is a
  /// no-op; the shell hands the gesture to the OS instead.
  final VoidCallback back;

  /// The context bag the current screen was opened with, or null. Screens use
  /// it to restore what they had open (a group, a search box) when the user
  /// comes back to them.
  final Object? Function() ctx;

  /// Opens a sheet over whatever is on screen, without the caller needing a
  /// context that sits under a Navigator.
  final Future<T?> Function<T>(List<Widget> children) showSheet;

  final void Function(Location loc) openDetail;

  /// Opens the import screen remembering where it was launched from, so back
  /// returns there (import is reachable from home, locations, onboarding,
  /// settings and the paywall).
  final VoidCallback openImport;

  /// Opens the importer with its input prefilled (used by `hideip://` deep
  /// links). Back returns home. The screen still waits for the user to tap
  /// Import; nothing is auto-imported.
  final void Function(String text) openImportWith;

  /// Opens the paywall remembering where it was launched from, so both back
  /// gestures and a cancelled purchase return there. [locId] names the
  /// location a locked row was tapped on ([Location.id]), which is what lets
  /// the paywall say "London is part of the plan" instead of a generic title.
  final void Function({required HipScreen from, String? locId}) openPaywall;

  /// Screens with internal steps (onboarding beats, import phases) claim the
  /// system back gesture so it walks their steps before leaving the screen.
  /// Unclaimed, the shell walks up the screen hierarchy instead.
  final void Function(VoidCallback handler) claimBack;
  final void Function(VoidCallback handler) releaseBack;

  const HipNav({
    required this.go,
    required this.back,
    required this.ctx,
    required this.showSheet,
    required this.openDetail,
    required this.openImport,
    required this.openImportWith,
    required this.openPaywall,
    required this.claimBack,
    required this.releaseBack,
  });
}

/// Root of the redesigned UI: owns which screen is visible plus the toast.
class HipShell extends StatefulWidget {
  final AppState state;
  const HipShell({super.key, required this.state});

  @override
  State<HipShell> createState() => _HipShellState();
}

class _HipShellState extends State<HipShell>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // null until AppState.ready decides the entry screen; the stack takes over
  // from the first frame that has one.
  HipScreen? _screen;
  final HipNavStack _stack = HipNavStack();
  Location? _detailLoc;
  HipScreen _importFrom = HipScreen.home;
  HipScreen _paywallFrom = HipScreen.home;
  String? _paywallLocId;
  VoidCallback? _backOverride;
  // A context that sits under the shell's Navigator, so any screen can raise
  // a sheet through `nav.showSheet` without holding one of its own.
  BuildContext? _sheetContext;

  // Deep-link plumbing. A `hideip://` link parses into text the importer is
  // prefilled with; while onboarding is still up the link waits here and opens
  // the importer once the shell settles on a real screen.
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;
  String? _importInitialText; // consumed by the next import build
  String? _pendingLinkText; // held until the shell is past onboarding
  DeepLinkPairing? _pendingPairing; // same, for a device-link approval
  final DeepLinkOnce _once = DeepLinkOnce(); // same link delivered twice

  // iOS edge-swipe back: with no Navigator stack there is no system gesture,
  // so a drag that starts at the left edge maps onto the same hierarchy the
  // back arrows use. The screen it would return to renders underneath and the
  // current one follows the finger (the Cupertino pop feel); a claimed back
  // handler has internal steps the shell cannot preview, so it just fires on
  // a completed swipe.
  late final AnimationController _swipeCtrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 240));
  HipScreen? _swipeTarget; // non-null while a peek drag/settle is showing
  bool _swipeSettling = false; // release animation running, ignore updates
  bool _swipeClaimed = false; // drag belongs to a claimed handler
  double _dragExtent = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initDeepLinks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _linkSub?.cancel();
    _swipeCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Someone who went to system settings to allow the VPN configuration
    // comes back to a live Connect button, with no extra tap to clear the
    // declined state.
    if (state == AppLifecycleState.resumed) {
      widget.state.refreshVpnPermission();
    }
  }

  /// Wires the `hideip://` deep-link sources: the cold-start link (app opened
  /// by a link) and the warm stream (a link arriving while running). The
  /// stream also emits the initial link, so we only read the initial link
  /// explicitly for the cold-start case and let the stream cover the rest.
  Future<void> _initDeepLinks() async {
    _linkSub = _appLinks.uriLinkStream.listen(_onDeepLink, onError: (_) {});
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _onDeepLink(initial);
    } catch (_) {
      // No initial link (or no platform side, e.g. tests): nothing to do.
    }
  }

  /// Turns a deep link into importer text and routes to the import screen.
  /// While onboarding is still showing, the text is parked and opened once the
  /// user reaches a real screen (see [build]). Never auto-imports.
  void _onDeepLink(Uri uri) {
    if (!mounted) return;
    final raw = uri.toString();
    // A cold start reads the launch link and the stream replays it; the same
    // tap must not open two importers.
    if (!_once.accept(raw)) return;
    // Onboarding is a modal flow; anything that arrives during it waits.
    final duringOnboarding = _screen == HipScreen.onboarding ||
        (_screen == null && !widget.state.prefs.onboarded);

    // A pairing link asks this phone to grant another device access; it never
    // touches the importer.
    final pairing = parsePairingLink(raw);
    if (pairing != null) {
      if (duringOnboarding) {
        _pendingPairing = pairing;
      } else {
        _askApproval(pairing);
      }
      return;
    }

    final parsed = parseDeepLink(raw);
    if (parsed == null) return; // not a hideip import link
    // The payload is whatever whoever built the link decided to put there, so
    // it passes the importer's own whitelist before it reaches the screen. A
    // refusal says only that, never what the link held: the payload is a
    // credential and it stays out of the toast as much as out of any log.
    if (classifyImportPayload(parsed.text) == null) {
      widget.state.showToast('That link carries nothing we can import');
      return;
    }
    if (duringOnboarding) {
      _pendingLinkText = parsed.text;
      return;
    }
    _openImportWith(parsed.text);
  }

  /// Shows the approval sheet for [pairing]. A phone with no live subscription
  /// has nothing to hand out, so it is told that instead of being walked into
  /// a call that can only fail.
  Future<void> _askApproval(DeepLinkPairing pairing) async {
    final state = widget.state;
    if (!state.canLinkDevices) {
      state.showToast('Premium is needed to link another device');
      return;
    }
    await showLinkApprovalSheet(context, state: state, pairing: pairing);
  }

  void _openImportWith(String text) {
    _importInitialText = text;
    _importFrom = HipScreen.home;
    _go(HipScreen.import);
  }

  /// Push [screen] onto the stack and show it.
  ///
  /// Home is the root: arriving there empties the stack. Re-entering the
  /// screen already showing changes only its context. Any other target first
  /// drops an older copy of itself from the stack, so a back walk is always
  /// finite and never revisits a screen twice.
  void _go(HipScreen screen, [Object? ctx]) {
    setState(() {
      _stack.go(screen, ctx);
      _screen = _stack.screen;
    });
  }

  /// Pop back to where the user came from, restoring that screen's context.
  void _back() {
    setState(() {
      _stack.back();
      _screen = _stack.screen;
    });
  }

  Future<T?> _showSheet<T>(List<Widget> children) {
    final context = _sheetContext;
    if (context == null) return Future<T?>.value(null);
    return showHipSheet<T>(context, children: children);
  }

  late final HipNav _nav = HipNav(
    go: _go,
    back: _back,
    ctx: () => _stack.ctx,
    showSheet: _showSheet,
    openDetail: (loc) {
      _detailLoc = loc;
      _go(HipScreen.detail);
    },
    openImport: () {
      _importInitialText = null;
      _importFrom = _screen ?? HipScreen.home;
      _go(HipScreen.import);
    },
    openImportWith: _openImportWith,
    openPaywall: ({required HipScreen from, String? locId}) {
      _paywallFrom = from;
      _paywallLocId = locId;
      _go(HipScreen.paywall, locId);
    },
    claimBack: (h) => _backOverride = h,
    // Only the claimant may release; a new screen may already hold the claim
    // by the time the old one is disposed.
    releaseBack: (h) {
      if (_backOverride == h) _backOverride = null;
    },
  );

  /// The system back gesture, on the same stack the in-app back arrows walk.
  /// Only the root screens hand back to the OS.
  void _systemBack() {
    final claimed = _backOverride;
    if (claimed != null) {
      claimed();
      return;
    }
    if (_stack.backTarget != null) {
      _back();
    } else {
      SystemNavigator.pop();
    }
  }

  void _swipeStart(DragStartDetails d) {
    _dragExtent = 0;
    _swipeClaimed = false;
    if (_swipeSettling) return;
    if (_backOverride != null) {
      // Internal steps (import phases, onboarding beats): no preview, the
      // completed swipe fires the claimed handler like the arrow would.
      _swipeClaimed = true;
      return;
    }
    final target = _stack.backTarget;
    if (target == null) return; // root screen: never background the app
    setState(() => _swipeTarget = target);
  }

  void _swipeUpdate(DragUpdateDetails d) {
    _dragExtent += d.delta.dx;
    if (_swipeTarget != null && !_swipeSettling) {
      final width = context.size?.width ?? 1;
      _swipeCtrl.value = (_dragExtent / width).clamp(0.0, 1.0);
    }
  }

  Future<void> _swipeEnd(DragEndDetails d) async {
    final velocity = d.primaryVelocity ?? 0;
    if (_swipeClaimed) {
      _swipeClaimed = false;
      if (_dragExtent > 72 || velocity > 500) _systemBack();
      return;
    }
    final target = _swipeTarget;
    if (target == null || _swipeSettling) return;
    final commit =
        velocity > 300 || (_swipeCtrl.value > 0.35 && velocity > -300);
    _swipeSettling = true;
    final remaining = commit ? 1 - _swipeCtrl.value : _swipeCtrl.value;
    final duration = _swipeCtrl.duration! * remaining;
    if (commit) {
      await _swipeCtrl.animateTo(1, duration: duration, curve: Curves.easeOut);
    } else {
      await _swipeCtrl.animateBack(0, duration: duration, curve: Curves.easeOut);
    }
    if (!mounted) return;
    setState(() {
      _swipeTarget = null;
      _swipeCtrl.value = 0;
      _swipeSettling = false;
    });
    // The peek previewed the back target; committing takes the same route the
    // arrow does, so the stack and the context come back with it.
    if (commit) _back();
  }

  Widget _buildScreen(HipScreen s, AppState state) => switch (s) {
        HipScreen.onboarding => OnboardingScreen(state: state, nav: _nav),
        HipScreen.home => HomeHeroScreen(state: state, nav: _nav),
        HipScreen.locations => LocationsScreen(state: state, nav: _nav),
        HipScreen.import => ImportScreen(
            // A new deep link while the importer is already open must rebuild
            // its state so the fresh text prefills; key on the text to force it.
            key: ValueKey('import:${_importInitialText ?? ''}'),
            state: state,
            nav: _nav,
            exitTo: _importFrom,
            initialText: _importInitialText,
          ),
        HipScreen.settings => SettingsScreen(state: state, nav: _nav),
        HipScreen.detail =>
          DetailScreen(state: state, nav: _nav, location: _detailLoc!),
        HipScreen.paywall => PaywallScreen(
            state: state,
            nav: _nav,
            from: _paywallFrom,
            locId: _paywallLocId,
          ),
        HipScreen.premium => PremiumManageScreen(state: state, nav: _nav),
        HipScreen.trialExpired => TrialExpiredScreen(state: state, nav: _nav),
        HipScreen.linkedDevices =>
          LinkedDevicesScreen(state: state, nav: _nav),
        HipScreen.account => AccountScreen(state: state, nav: _nav),
      };

  Color _bgFor(HipScreen s) =>
      s == HipScreen.onboarding || s == HipScreen.paywall
          ? Hip.dark
          : Hip.surface;

  /// The mid-swipe frame: the back target sits underneath with the Cupertino
  /// parallax while the current screen follows the finger, carrying an edge
  /// shadow. Both get opaque backgrounds so nothing shows through the seam.
  Widget _buildPeek(AppState state, {required Widget current}) {
    final target = _swipeTarget!;
    final under = KeyedSubtree(
        key: ValueKey(target), child: _buildScreen(target, state));
    return AnimatedBuilder(
      animation: _swipeCtrl,
      builder: (context, _) {
        final p = _swipeCtrl.value;
        final width = MediaQuery.sizeOf(context).width;
        return Stack(children: [
          Positioned.fill(
            child: Transform.translate(
              offset: Offset(-width * 0.3 * (1 - p), 0),
              child: ColoredBox(color: _bgFor(target), child: under),
            ),
          ),
          Positioned.fill(
            child: Transform.translate(
              offset: Offset(width * p, 0),
              child: DecoratedBox(
                decoration: const BoxDecoration(boxShadow: [
                  BoxShadow(color: Colors.black26, blurRadius: 16),
                ]),
                child: ColoredBox(color: _bgFor(_screen!), child: current),
              ),
            ),
          ),
        ]);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final state = widget.state;
        if (!state.ready) {
          return const Scaffold(backgroundColor: Hip.dark, body: SizedBox());
        }
        // Resolve the token palette for this frame; the prefs change that
        // flips it already rebuilds the whole tree below.
        Hip.dm = _darkFor(context, state.prefs.themeMode);
        Hip.reducedMotion = MediaQuery.disableAnimationsOf(context);
        if (_screen == null) {
          _screen = state.prefs.onboarded
              ? HipScreen.home
              : HipScreen.onboarding;
          _stack.screen = _screen!;
        }

        // A deep link that arrived during onboarding lands on import once the
        // user finishes and the shell leaves the onboarding screen.
        if (_pendingLinkText != null && _screen != HipScreen.onboarding) {
          final text = _pendingLinkText!;
          _pendingLinkText = null;
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _openImportWith(text));
        }
        // Same for a pairing link: the approval sheet needs a settled screen
        // underneath it, so it waits out onboarding too.
        if (_pendingPairing != null && _screen != HipScreen.onboarding) {
          final pairing = _pendingPairing!;
          _pendingPairing = null;
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _askApproval(pairing));
        }
        // A number a purchase just made is shown once, over whatever screen
        // the purchase lands on; the paywall finishes its own moment first.
        if (state.freshAccountNumber != null &&
            _screen != HipScreen.onboarding &&
            _screen != HipScreen.paywall) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) showFreshAccountNumber(state, _nav);
          });
        }

        final iosSwipe = Theme.of(context).platform == TargetPlatform.iOS;
        final onDark = _screen == HipScreen.onboarding ||
            _screen == HipScreen.paywall;
        Widget content = KeyedSubtree(
            key: ValueKey(_screen), child: _buildScreen(_screen!, state));
        if (_swipeTarget != null) {
          content = _buildPeek(state, current: content);
        }

        return AnnotatedRegion<SystemUiOverlayStyle>(
          // Home also starts under the dark hero panel; in dark mode every
          // surface is dark.
          value: onDark || _screen == HipScreen.home || Hip.dm
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          child: PopScope(
            // The shell handles every back gesture itself; screens are a
            // state machine, not a Navigator stack, so a real pop would
            // background the whole app.
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _systemBack();
            },
            child: RawGestureDetector(
              // iOS has no system back gesture without a Navigator stack;
              // Android's arrives through PopScope already. The recognizer
              // only competes for pointers that land on the left screen edge
              // (like the native gesture), so pans and horizontal scrolls
              // anywhere else never lose the arena to it.
              gestures: {
                if (iosSwipe)
                  _EdgeBackDragRecognizer: GestureRecognizerFactoryWithHandlers<
                      _EdgeBackDragRecognizer>(
                    () => _EdgeBackDragRecognizer(debugOwner: this),
                    (r) => r
                      ..onStart = _swipeStart
                      ..onUpdate = _swipeUpdate
                      ..onEnd = _swipeEnd,
                  ),
              },
              child: Scaffold(
                backgroundColor: onDark ? Hip.dark : Hip.surface,
                body: Builder(builder: (context) {
                  // Captured once per frame: `nav.showSheet` needs a context
                  // under this Navigator, and no screen should have to own one.
                  _sheetContext = context;
                  return Stack(children: [
                  content,
                  if (state.toast != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 132,
                      child: Center(child: HipToast(state.toast!)),
                    ),
                ]);
                }),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Whether the app paints dark right now. Three states, and only the third
/// one asks the platform anything.
bool _darkFor(BuildContext context, AppThemeMode mode) => switch (mode) {
      AppThemeMode.light => false,
      AppThemeMode.dark => true,
      AppThemeMode.system =>
        MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    };

/// A horizontal drag that only enters the gesture arena for pointers that
/// land within the left screen edge, mirroring the native iOS back gesture.
/// Anywhere else the shell never competes, so the map pan and horizontal
/// scrolls keep their gestures.
class _EdgeBackDragRecognizer extends HorizontalDragGestureRecognizer {
  _EdgeBackDragRecognizer({super.debugOwner});

  static const double edgeWidth = 32;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (event.position.dx > edgeWidth) return;
    super.addAllowedPointer(event);
  }
}
