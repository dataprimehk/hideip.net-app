import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/haptics.dart';
import '../../core/location.dart';
import '../../core/ping.dart';
import '../../core/premium.dart';
import '../../core/share_link_parser.dart';
import '../../core/wg_speed_mode.dart';
import '../../state/app_state.dart';
import '../../vpn_controller.dart';
import '../strings.dart';
import 'ascii/hero_ascii.dart';
import 'ascii/hero_glow.dart';
import 'detail_screen.dart' show serverLabel;
import 'hero_search.dart';
import 'hip.dart';
import 'hip_sheet.dart';
import 'home_banners.dart';
import 'home_status_card.dart';
import 'locked_row.dart';
import 'mark.dart';
import 'shell.dart';
import 'worldmap.dart';

/// Home: the dark hero panel (an ASCII field behind the glass status card)
/// with a Servers/Map switch. Servers keeps a short list under the panel; Map
/// grows the panel over the whole screen and shows the world map.
class HomeHeroScreen extends StatefulWidget {
  final AppState state;
  final HipNav nav;
  const HomeHeroScreen({super.key, required this.state, required this.nav});

  @override
  State<HomeHeroScreen> createState() => _HomeHeroScreenState();
}

class _HomeHeroScreenState extends State<HomeHeroScreen>
    with WidgetsBindingObserver {
  // The native side disconnects near-instantly; hold the state long enough
  // for the hero's re-expose sweep to read.
  bool _disconnecting = false;

  final _heroKey = GlobalKey();
  final _ctaKey = GlobalKey();
  final _search = TextEditingController();
  String _query = '';

  /// A connection link sitting in the clipboard, and the last one that was
  /// waved away. Offering the same link twice is nagging.
  String? _clipLink;
  String? _clipDismissed;

  /// True while the failure sheet is up, so a rebuild cannot stack a second.
  bool _failSheetOpen = false;

  // Hero content + CTA bar, measured after layout. The measured value is kept
  // across remounts (the shell rebuilds this screen on every visit), so coming
  // back from another screen lays out exactly on the first frame instead of
  // overflowing the column across the CTA until the measurement lands.
  static double? _measuredChrome;
  double? _chromeH = _measuredChrome;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _readClipboard();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _readClipboard();
  }

  // --- clipboard suggestion (B9) ------------------------------------------

  /// Reads the clipboard on the two occasions a link can have arrived: the
  /// first build and every return to the foreground. Nothing is ever imported
  /// from here; the banner only offers.
  Future<void> _readClipboard() async {
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      // A platform that refuses the clipboard simply has nothing to suggest.
      return;
    }
    if (!mounted) return;
    final link = _connectionLink(text);
    if (link == _clipLink || (link != null && link == _clipDismissed)) return;
    setState(() => _clipLink = link);
  }

  /// Whether [text] is a share link the importer would accept. Plain web
  /// addresses are left out on purpose: `https://` is importable as a
  /// subscription, but suggesting every copied URL would be noise.
  static String? _connectionLink(String? text) {
    final t = text?.trim();
    if (t == null || t.isEmpty || t.length > 4096 || t.contains('\n')) {
      return null;
    }
    final at = t.indexOf('://');
    if (at <= 0) return null;
    final scheme = t.substring(0, at).toLowerCase();
    if (scheme == 'http' || scheme == 'https') return null;
    return ShareLinkParser.supportedSchemes.contains(scheme) ? t : null;
  }

  /// `vless://…@host`: enough to recognize the link, never the credential.
  static String _clipPreview(String link) {
    final at = link.indexOf('://');
    final scheme = link.substring(0, at);
    var rest = link.substring(at + 3);
    final mark = rest.lastIndexOf('@');
    final named = mark >= 0;
    if (named) rest = rest.substring(mark + 1);
    final host = rest.split(RegExp(r'[/?#]')).first;
    return named ? '$scheme://…@$host' : '$scheme://$host';
  }

  // --- connect flow -------------------------------------------------------

  /// The one system permission is explained once, above `connect()`: the
  /// state layer keeps its timeout guard and knows nothing about sheets.
  Future<void> _connect() async {
    final state = widget.state;
    if (state.needsVpnPrimer) {
      final go =
          await showHipSheet<bool>(context, children: const [VpnPrimerSheet()]);
      // The explanation is offered once per install, whatever the answer was.
      // "Not now" retires it too, so the next Connect goes straight to the
      // system dialog rather than reading the same page again.
      await state.markVpnPrimerSeen();
      if (go != true) return;
    }
    await state.connect();
  }

  Future<void> _disconnect() async {
    setState(() => _disconnecting = true);
    // Let the hero sweep before the state actually flips.
    await Future<void>.delayed(Hip.dur(const Duration(milliseconds: 850)));
    await widget.state.disconnect();
    if (mounted) setState(() => _disconnecting = false);
    _maybeWarnAlwaysOn();
  }

  /// Raises the failure sheet the state layer is owed. Offline never gets
  /// here: there is nothing to explain about a server that could not have
  /// been reached in the first place.
  void _maybeShowConnectFailed() {
    final state = widget.state;
    if (!state.showConnectFailed || _failSheetOpen || state.offline) return;
    _failSheetOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _failSheetOpen = false;
        return;
      }
      final choice = await showHipSheet<ConnectFailedChoice>(
        context,
        children: [ConnectFailedSheet(offerPlans: !state.premium.isOn)],
      );
      _failSheetOpen = false;
      state.dismissConnectFailed();
      if (!mounted) return;
      switch (choice) {
        case ConnectFailedChoice.retry:
          await _connect();
        case ConnectFailedChoice.another:
          widget.nav.go(HipScreen.locations);
        case ConnectFailedChoice.plans:
          widget.nav.openPaywall(from: HipScreen.home);
        case null:
          break;
      }
    });
  }

  /// With Android's system Always-on VPN enabled but our in-app Always-on
  /// opt-in off, the OS can keep holding traffic after a disconnect (the
  /// service refuses the system's restart). The user has to resolve that in
  /// system settings, so say it plainly and take them there.
  void _maybeWarnAlwaysOn() {
    final state = widget.state;
    if (!mounted || !state.systemAlwaysOn || state.prefs.alwaysOn) return;
    showHipSheet<void>(context, children: [
      AlwaysOnSheet(onOpenSettings: VpnController.openVpnSettings),
    ]);
  }

  Future<void> _selectFromMap(Location loc) async {
    final state = widget.state;
    await state.selectLocation(loc);
    if (state.isConnected) {
      await state.disconnect();
      await state.connect();
    }
  }

  void _setMapMode(bool map) {
    final prefs = widget.state.prefs;
    if (prefs.homeMap != map) {
      Haptics.selection();
      widget.state.updatePrefs(prefs.copyWith(homeMap: map));
    }
  }

  void _measureChrome() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final hero = _heroKey.currentContext?.size?.height;
      final cta = _ctaKey.currentContext?.size?.height;
      if (hero == null || cta == null || !mounted) return;
      final h = hero + cta;
      if ((h - (_chromeH ?? 0)).abs() > 1) {
        _measuredChrome = h;
        setState(() => _chromeH = h);
      }
    });
  }

  // --- what the status card says ------------------------------------------

  MarkState get _markState {
    if (_disconnecting) return MarkState.disconnecting;
    switch (widget.state.conn) {
      case ConnState.connecting:
        return MarkState.connecting;
      case ConnState.connected:
        return MarkState.connected;
      case ConnState.disconnected:
      case ConnState.error:
        return MarkState.disconnected;
    }
  }

  String _contextLine({required bool offline, required bool connected}) {
    if (offline) return S.b15Context;
    final state = widget.state;
    if (connected) {
      final loc = state.activeLocation;
      if (loc == null) return '';
      // A server nobody could place carries its host as "country"; the name
      // alone reads better than "name, 203.0.113.9".
      return loc.placed ? S.ctxPlace(loc.city, loc.country) : loc.city;
    }
    final geo = state.userGeo;
    final city = geo?.city;
    final region = geo?.cc ?? geo?.country;
    final place = city == null || city.isEmpty
        ? null
        : (region == null || region.isEmpty ? city : S.ctxPlace(city, region));
    final isp = geo?.isp;
    if (isp != null && isp.isNotEmpty && place != null) {
      return S.ctxExposed(isp, place);
    }
    return isp ?? place ?? '';
  }

  /// The trial reminder is owed exactly once: on the last day of the free
  /// week, while the subscription is still in its trial period.
  static bool _trialEndsTomorrow(AppState state) {
    final premium = state.premium;
    if (premium.status != PremiumStatus.trial) return false;
    final renews = premium.renews;
    if (renews == null) return false;
    final left = renews.difference(DateTime.now());
    return !left.isNegative && left <= const Duration(days: 1);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final nav = widget.nav;
    final on = state.isConnected && !_disconnecting;
    final busy = state.isBusy || _disconnecting;
    final loc = state.activeLocation;
    final hasServers = state.profiles.isNotEmpty;
    final mapMode = state.prefs.homeMap;
    // Offline only takes the card over when nothing else is happening: a live
    // tunnel and a handshake in flight both have more to say than "no network".
    final offMode = state.offline && !on && !busy;
    final denied = state.vpnPerm == VpnPerm.denied && !on && !busy;
    final searching = !mapMode && _query.trim().isNotEmpty;

    _measureChrome();
    _maybeShowConnectFailed();

    final activePing = loc == null ? null : state.pingFor(loc.profile);
    final clip = _clipLink;

    final tone = offMode
        ? StatusTone.off
        : busy
            ? StatusTone.busy
            : on
                ? StatusTone.safe
                : StatusTone.risk;
    final status = offMode
        ? S.b15Status
        : busy
            ? (_disconnecting ? S.tDisconnecting : S.tConnecting)
            : on
                ? S.tProtected
                : S.tExposed;

    return LayoutBuilder(builder: (context, cons) {
      // Before the first measurement the guess must only ever overshoot: a map
      // a touch too short settles smoothly, a map too tall overflows the
      // column. 470 covers the fixed hero + CTA content with slack to spare.
      final pad = MediaQuery.paddingOf(context);
      final chrome = _chromeH ?? (pad.top + pad.bottom + 470);
      // 14 = the map's top margin inside the hero panel.
      final mapH = (cons.maxHeight - chrome - 14).clamp(0.0, cons.maxHeight);
      // In map mode the strip under the panel (where the CTA sits) darkens
      // with the same timing as the map expand, so the screen reads as one
      // dark surface instead of a light band under a wall of map.
      return AnimatedContainer(
        duration: Hip.dur(const Duration(milliseconds: 650)),
        curve: const Cubic(.32, .72, 0, 1),
        color: mapMode ? Hip.hero : Hip.surface,
        child: Column(children: [
          // --- dark hero panel ---------------------------------------------
          ClipRRect(
            borderRadius:
                const BorderRadius.vertical(bottom: Radius.circular(32)),
            child: Container(
              width: double.infinity,
              color: Hip.hero,
              child: Column(children: [
                Column(key: _heroKey, children: [
                  SizedBox(height: pad.top + 6),
                  HipAppHead(
                    onDark: true,
                    onSettings: () => nav.go(HipScreen.settings),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(children: [
                      // The ASCII field lives behind the glass; a sparser,
                      // larger layer floats in front of it, and the glow sits
                      // between the two. Both hang a little outside the hero
                      // (`.hero-ascii` and `.hero-glow` in app.css), so the
                      // stack must not clip them.
                      Stack(
                          alignment: Alignment.bottomCenter,
                          clipBehavior: Clip.none,
                          children: [
                        const SizedBox(height: 132, width: double.infinity),
                        Positioned(
                          left: -10,
                          right: -10,
                          top: 0,
                          bottom: 0,
                          child: IgnorePointer(
                            child: HeroAscii(state: _markState),
                          ),
                        ),
                        Positioned(
                          left: -10,
                          right: -10,
                          bottom: -12,
                          height: 78,
                          child: IgnorePointer(
                            child: HeroGlow(
                                state: _markState, offline: state.offline),
                          ),
                        ),
                        HomeStatusCard(
                          tone: tone,
                          status: status,
                          ip: offMode
                              ? null
                              : (state.publicIp ??
                                  (state.ipLoading ? '…' : S.homeIpUnknown)),
                          context:
                              _contextLine(offline: offMode, connected: on),
                          slowLine:
                              state.connSlow && state.isBusy ? S.b16Slow : null,
                        ),
                        Positioned(
                          left: -10,
                          right: -10,
                          top: 0,
                          bottom: 0,
                          child: IgnorePointer(
                            child: HeroAscii(state: _markState, front: true),
                          ),
                        ),
                      ]),
                      if (clip != null)
                        HomeClipboardBanner(
                          preview: _clipPreview(clip),
                          onAdd: () {
                            setState(() => _clipLink = null);
                            nav.openImportWith(clip);
                          },
                          onDismiss: () => setState(() {
                            _clipDismissed = clip;
                            _clipLink = null;
                          }),
                        ),
                      if (denied)
                        HomeDeniedBanner(
                            onOpenSettings: VpnController.openVpnSettings),
                      if (_trialEndsTomorrow(state))
                        HomeTrialBanner(
                          price: state.planInfo(PremiumPlan.yearly).price,
                          onKeep: () => nav.openPaywall(from: HipScreen.home),
                        ),
                      const SizedBox(height: 16),
                      _HomeSeg(mapMode: mapMode, onChanged: _setMapMode),
                      if (!mapMode && hasServers)
                        _HomeSearch(
                          controller: _search,
                          onChanged: (q) => setState(() => _query = q),
                        ),
                    ]),
                  ),
                  // Animates in step with the map container below: jumping to
                  // 20 while the map is still tall overflows the hero by 20px.
                  AnimatedContainer(
                    duration: Hip.dur(const Duration(milliseconds: 650)),
                    curve: const Cubic(.32, .72, 0, 1),
                    height: mapMode ? 0 : 20,
                  ),
                ]),
                // The map keeps living (camera and all) while collapsed; only
                // its height animates, so the expand is one fluid move.
                AnimatedContainer(
                  duration: Hip.dur(const Duration(milliseconds: 650)),
                  curve: const Cubic(.32, .72, 0, 1),
                  height: mapMode ? mapH : 0,
                  margin: EdgeInsets.only(top: mapMode ? 14 : 0),
                  child: WorldMap(
                    locations: state.locations,
                    active: loc,
                    conn: _markState,
                    advanced: state.prefs.advanced,
                    open: mapMode,
                    userGeo: state.userGeo,
                    activePingMs: activePing is PingOk ? activePing.ms : null,
                    onPick: _selectFromMap,
                    onConnect: () {
                      if (busy || state.offline) return;
                      hasServers ? _connect() : nav.openImport();
                    },
                    onAllLocations: () => nav.go(HipScreen.locations),
                    notifPermission: state.notifPermission,
                    requestNotifPermission: state.requestNotifPermission,
                  ),
                ),
              ]),
            ),
          ),

          // --- server list (hidden in map mode) ------------------------------
          Expanded(
            child: IgnorePointer(
              ignoring: mapMode,
              child: AnimatedOpacity(
                duration: Hip.dur(const Duration(milliseconds: 300)),
                opacity: mapMode ? 0 : 1,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                  child: _HomeList(
                    state: state,
                    nav: nav,
                    on: on,
                    query: searching ? _query.trim() : null,
                  ),
                ),
              ),
            ),
          ),

          // --- CTA bar -------------------------------------------------------
          Padding(
            key: _ctaKey,
            padding: EdgeInsets.fromLTRB(22, 14, 22, pad.bottom + 14),
            child: HomeCtaBar(
              empty: !hasServers,
              connected: on || _disconnecting,
              disconnecting: _disconnecting,
              connecting: state.isBusy,
              offline: state.offline,
              denied: denied,
              darkSurface: mapMode,
              onConnect: _connect,
              onCancel: state.cancel,
              onDisconnect: _disconnect,
              onAdd: nav.openImport,
              onSeePremium: () => nav.go(HipScreen.locations),
            ),
          ),
        ]),
      );
    });
  }
}

/// The bar under the list. Every Home state that changes what the primary
/// action is changes it here, and nowhere else.
class HomeCtaBar extends StatelessWidget {
  /// Nothing has been imported: Connect is not shown at all.
  final bool empty;
  final bool connected;
  final bool disconnecting;
  final bool connecting;
  final bool offline;
  final bool denied;
  final bool darkSurface;

  final VoidCallback onConnect;
  final VoidCallback onCancel;
  final VoidCallback onDisconnect;
  final VoidCallback onAdd;
  final VoidCallback onSeePremium;

  const HomeCtaBar({
    super.key,
    required this.empty,
    required this.connected,
    required this.disconnecting,
    required this.connecting,
    required this.offline,
    required this.denied,
    required this.onConnect,
    required this.onCancel,
    required this.onDisconnect,
    required this.onAdd,
    required this.onSeePremium,
    this.darkSurface = false,
  });

  @override
  Widget build(BuildContext context) {
    if (empty) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        HipCta(S.tAddConn, connect: true, onTap: onAdd),
        const SizedBox(height: 8),
        HipCta(S.b0SeePremium,
            quiet: true, darkGhost: darkSurface, onTap: onSeePremium),
      ]);
    }

    final Widget cta;
    if (connected) {
      cta = HipCta(
        disconnecting ? S.tDisconnecting : S.tDisconnect,
        key: const ValueKey('cta-off'),
        ghost: true,
        danger: true,
        darkGhost: darkSurface,
        onTap: disconnecting ? null : onDisconnect,
      );
    } else if (connecting) {
      // Connecting stays tappable: it is the only way to take the attempt back.
      cta = HipCta(
        S.tConnecting,
        key: const ValueKey('cta-cancel'),
        connect: true,
        onTap: onCancel,
      );
    } else {
      cta = HipCta(
        S.tConnect,
        key: const ValueKey('cta-on'),
        connect: true,
        onTap: offline || denied ? null : onConnect,
      );
    }

    return Column(mainAxisSize: MainAxisSize.min, children: [
      // The CTA variants swap with a short crossfade; a hard swap between
      // such different buttons reads as a glitch.
      AnimatedSwitcher(
        duration: Hip.dur(const Duration(milliseconds: 260)),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween(begin: .98, end: 1.0).animate(anim),
            child: child,
          ),
        ),
        child: cta,
      ),
      if (offline && !connected && !connecting)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            S.b15CtaNote,
            textAlign: TextAlign.center,
            style: Hip.sans(400, Hip.captionSize,
                color:
                    darkSurface ? Colors.white.withValues(alpha: .5) : Hip.muted,
                height: 1.4),
          ),
        ),
    ]);
  }
}

/// The Servers/Map segmented pill on the hero panel.
class _HomeSeg extends StatelessWidget {
  final bool mapMode;
  final ValueChanged<bool> onChanged;
  const _HomeSeg({required this.mapMode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget seg(String label, IconData icon, bool active, bool toMap) =>
        GestureDetector(
          onTap: () => onChanged(toMap),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 118,
            height: 44,
            alignment: Alignment.center,
            child: AnimatedDefaultTextStyle(
              duration: Hip.dur(const Duration(milliseconds: 300)),
              style: Hip.sans(600, 13,
                  color: Colors.white.withValues(alpha: active ? 1 : .55)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon,
                    size: 15,
                    color: Colors.white.withValues(alpha: active ? 1 : .55)),
                const SizedBox(width: 7),
                Text(label),
              ]),
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .06),
        border: Border.all(color: Colors.white.withValues(alpha: .1)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: SizedBox(
        width: 118 * 2 + 3,
        height: 44,
        child: Stack(children: [
          AnimatedAlign(
            duration: Hip.dur(const Duration(milliseconds: 500)),
            curve: const Cubic(.32, .72, 0, 1),
            alignment: mapMode ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 118,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .13),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          Row(mainAxisSize: MainAxisSize.min, children: [
            seg(S.homeSegServers, Icons.dns_outlined, !mapMode, false),
            const SizedBox(width: 3),
            seg(S.homeSegMap, Icons.public, mapMode, true),
          ]),
        ]),
      ),
    );
  }
}

/// The search field on the hero panel. It filters every list on Home, locked
/// rows included.
class _HomeSearch extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _HomeSearch({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final white = Colors.white;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.only(left: 16),
      height: 46,
      decoration: BoxDecoration(
        color: white.withValues(alpha: .06),
        border: Border.all(color: white.withValues(alpha: .1), width: 1.5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(children: [
        Icon(Icons.search, size: 16, color: white.withValues(alpha: .45)),
        const SizedBox(width: 9),
        Expanded(
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            autocorrect: false,
            style: Hip.sans(500, 14, color: white),
            cursorColor: Hip.blue,
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              hintText: S.homeSearchHint,
              hintStyle: Hip.sans(400, 14, color: white.withValues(alpha: .4)),
            ),
          ),
        ),
        if (controller.text.isNotEmpty)
          Semantics(
            button: true,
            label: S.homeSearchClear,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                controller.clear();
                onChanged('');
              },
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(Icons.close,
                    size: 14, color: white.withValues(alpha: .5)),
              ),
            ),
          )
        else
          const SizedBox(width: 16),
      ]),
    );
  }
}

/// Servers view: the session card while connected, Auto with the pick it
/// would make, the fastest rows with exactly one locked comparison, and the
/// door to the full list. Search replaces all of it with one result group.
class _HomeList extends StatelessWidget {
  final AppState state;
  final HipNav nav;
  final bool on;

  /// The live search text, or null when nothing is being searched for.
  final String? query;

  const _HomeList({
    required this.state,
    required this.nav,
    required this.on,
    this.query,
  });

  int? _ms(Location l) {
    final p = state.pingFor(l.profile);
    return p is PingOk ? p.ms : null;
  }

  Widget _openRow(Location l, {required bool auto, required Location? active}) {
    final advanced = state.prefs.advanced;
    final ms = _ms(l);
    final chosen = !auto && active?.id == l.id;
    return HipListRow(
      leading: HipFlag(cc: l.cc),
      title: serverLabel(l),
      titleBadge: l.premium && state.mix == Mix.mixed
          ? HipBadge.blue('hideip.net')
          : (l.provider != null ? HipBadge.blue(l.provider!) : null),
      subtitle: advanced
          ? S.tunnelChain(l.protoLabel, l.host)
          : (ms == null ? l.country : S.homeRowSub(l.country, ms)),
      subtitleMono: advanced,
      selected: chosen,
      live: chosen && on,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        HipBars(level: state.levelFor(l.profile)),
        SizedBox(
          width: 30,
          child: chosen ? Icon(Icons.check, size: 18, color: Hip.blue) : null,
        ),
      ]),
      onTap: () => state.selectLocation(l),
    );
  }

  Widget _lockedRow(Location l, LockedFrom from) => LockedRow(
        location: l,
        from: from,
        pingMs: _ms(l),
        level: state.levelFor(l.profile),
        advanced: state.prefs.advanced,
        onTap: (_, locId) =>
            nav.openPaywall(from: HipScreen.home, locId: locId),
      );

  Widget _allLocationsGroup(int total) => HipListGroup(children: [
        HipListRow(
          leading: HipFlag(
              cc: '', child: Icon(Icons.public, size: 19, color: Hip.blueDeep)),
          title: S.homeAllLocations,
          subtitle: S.homeAllLocationsSub(total),
          trailing: Icon(Icons.chevron_right, size: 17, color: Hip.muted2),
          onTap: () => nav.go(HipScreen.locations),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final open = state.locations;
    final locked = [...state.lockedLocations]..sort((a, b) {
        final ma = _ms(a) ?? 1 << 30;
        final mb = _ms(b) ?? 1 << 30;
        return ma.compareTo(mb);
      });
    final total = open.length + locked.length;
    final auto = state.prefs.autoSelect;
    final active = state.activeLocation;

    // --- B10, search ------------------------------------------------------
    final q = query;
    if (q != null) {
      final hits = HeroSearch.filter(open, locked, q);
      final allLocked = hits.isNotEmpty && hits.every((l) => l.locked);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const HipSectionLabel(S.homeResults),
        HipListGroup(children: [
          for (final l in hits)
            l.locked
                ? _lockedRow(l, LockedFrom.homeSearch)
                : _openRow(l, auto: auto, active: active),
          if (hits.isEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(S.homeNoMatch,
                  style: Hip.sans(400, 13.5, color: Hip.muted2)),
            ),
        ]),
        // The country exists only on our fleet: the rows are already there,
        // this names the condition once.
        if (state.mix == Mix.byo && allLocked)
          const HipSubnote(S.homePremiumOnly),
        const SizedBox(height: 14),
        _allLocationsGroup(total),
      ]);
    }

    // --- B0, nothing imported and nothing subscribed ----------------------
    if (open.isEmpty) return const HomeEmptyBlock();

    // Fastest first; unprobed servers keep their list order at the back.
    final sorted = [...open]..sort((a, b) {
        final ma = _ms(a) ?? 1 << 30;
        final mb = _ms(b) ?? 1 << 30;
        return ma.compareTo(mb);
      });
    final fastest = sorted.first;
    // Recently used servers lead the list, newest first; the fastest fill the
    // rest of the five. A remembered id whose server is gone is skipped, so a
    // removed import cannot leave a hole in the list.
    final byId = {for (final l in open) l.id: l};
    final recent = <Location>[
      for (final id in state.prefs.recents) ?byId[id],
    ].take(4).toList();
    final rows = <Location>[
      ...recent,
      ...sorted.where((l) => recent.every((r) => r.id != l.id)),
    ].take(5).toList();

    final fastestMs = _ms(fastest);
    final autoSub = fastestMs == null
        ? S.autoSubUnknown
        : S.autoSub(serverLabel(fastest), fastestMs,
            managed: state.mix == Mix.mixed && fastest.premium);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (on) ...[
        HomeSessionCard(
          stats: state.stats,
          duration: state.sessionLength,
          chip: state.tunnelChip,
          fast: state.tunnelPath == TunnelPath.speed,
          advanced: state.prefs.advanced,
        ),
        // B7: connected without a subscription, one dismissible row.
        if (!state.premium.isOn && state.upsellAllowed)
          HomeUpsellRow(
            onTap: () => nav.openPaywall(from: HipScreen.home),
            onDismiss: state.snoozeUpsell,
          ),
        const SizedBox(height: 16),
      ],
      const HipSectionLabel(S.homeRecommended),
      HipListGroup(children: [
        HipListRow(
          leading: HipFlag(
              cc: '', child: Icon(Icons.bolt, size: 19, color: Hip.blueDeep)),
          title: S.tAuto,
          subtitle: autoSub,
          selected: auto,
          live: auto && on,
          trailing: auto ? Icon(Icons.check, size: 18, color: Hip.blue) : null,
          onTap: () => state.selectLocation(null),
        ),
      ]),
      const SizedBox(height: 16),
      HipSectionLabel(recent.isEmpty ? S.homeFastest : S.homeRecentFastest),
      HipListGroup(children: [
        for (final l in rows) _openRow(l, auto: auto, active: active),
        // Exactly one locked row, in the same list: the comparison is the
        // whole argument, so it lives in context and nowhere else.
        if (locked.isNotEmpty) _lockedRow(locked.first, LockedFrom.homeRow),
      ]),
      const SizedBox(height: 14),
      _allLocationsGroup(total),
    ]);
  }
}

/// The session card: throughput, how long the session has been up, and the
/// chip that names what is carrying it. On a fallback the chip says so
/// plainly; there is no toast and nothing to dismiss.
class HomeSessionCard extends StatefulWidget {
  final VpnStats stats;
  final Duration? duration;
  final String chip;
  final bool fast;
  final bool advanced;

  const HomeSessionCard({
    super.key,
    required this.stats,
    required this.duration,
    required this.chip,
    required this.fast,
    required this.advanced,
  });

  @override
  State<HomeSessionCard> createState() => _HomeSessionCardState();
}

class _HomeSessionCardState extends State<HomeSessionCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // One second is the resolution the duration is written in; nothing else
    // on this card needs a ticker.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static String _rate(int bytesPerSec) {
    if (bytesPerSec >= 1024 * 1024) {
      return S.speedMbs((bytesPerSec / (1024 * 1024)).toStringAsFixed(1));
    }
    return S.speedKbs((bytesPerSec / 1024).round().toString());
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.duration;
    return HipCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Semantics(
            label: S.speedDown,
            child: Text('↓ ${_rate(widget.stats.downlink)}',
                style: Hip.mono(700, 14, color: Hip.blue)),
          ),
          const SizedBox(width: 14),
          Semantics(
            label: S.speedUp,
            child: Text('↑ ${_rate(widget.stats.uplink)}',
                style: Hip.mono(700, 14, color: Hip.ink)),
          ),
          const Spacer(),
          if (d != null)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.schedule, size: 13, color: Hip.muted),
              const SizedBox(width: 5),
              Text(fmtDur(d), style: Hip.mono(600, 12.5, color: Hip.muted)),
            ]),
        ]),
        Container(
          margin: const EdgeInsets.only(top: 11),
          padding: const EdgeInsets.only(top: 10),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Hip.line2)),
          ),
          child: Row(children: [
            Icon(widget.fast ? Icons.bolt : Icons.shield_outlined,
                size: 14, color: widget.fast ? Hip.blueDeep : Hip.muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                widget.chip,
                style: widget.advanced
                    ? Hip.mono(600, 11.5,
                        color: widget.fast ? Hip.blueDeep : Hip.inkSoft)
                    : Hip.sans(600, 13,
                        color: widget.fast ? Hip.blueDeep : Hip.inkSoft),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}
