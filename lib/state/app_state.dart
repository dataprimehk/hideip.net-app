import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;

import '../core/app_telemetry.dart';
import '../core/async_gate.dart';
import '../core/cc_iso.dart';
import '../core/connectivity.dart';
import '../core/device_link.dart';
import '../core/haptics.dart';
import '../core/ip_lookup.dart';
import '../core/location.dart';
import '../core/notifications.dart';
import '../core/ping.dart';
import '../core/premium.dart';
import '../core/premium_catalog.dart';
import '../core/profile_store.dart';
import '../core/provisioning.dart';
import '../core/proxy_profile.dart';
import '../core/purchase_service.dart';
import '../core/share_link_parser.dart';
import '../core/singbox_config.dart';
import '../core/srv_naming.dart';
import '../core/sub_info.dart';
import '../core/subscription.dart';
import '../core/ui_prefs.dart';
import '../core/user_subscription.dart';
import '../core/votes.dart';
import '../core/wg_keys.dart';
import '../core/wg_profile.dart';
import '../core/wg_register.dart';
import '../core/wg_singbox.dart';
import '../core/wg_speed_mode.dart';
import '../ui/strings.dart';
import '../vpn_controller.dart';

enum ConnState { disconnected, connecting, connected, error }

/// What the user's server list is made of. It decides what the app promotes:
/// a subscriber with imports of their own gets the hideip.net group marked out
/// (`mixed`), a subscriber with nothing else gets no marking at all (`hip`,
/// because everything is ours and saying so on every row is noise), and
/// someone with no subscription gets locked rows and the upsell (`byo`).
enum Mix { byo, mixed, hip }

/// What the OS says about the VPN configuration this app needs.
///
/// [unknown] is not [denied]. `prepare()` answering false can mean the user
/// said no, or that the answer never came back inside the guard window, or
/// that the channel broke; only a real refusal may put the app into the
/// declined state, because that state turns Connect off.
enum VpnPerm { unknown, granted, denied }

/// What a list of [profiles] plus an entitlement adds up to.
///
/// The rule, from `HideIP App 1.1.0.html`:
/// `mix = !subscribed ? 'byo' : ownLocs.length ? 'mixed' : 'hip'`. Note that
/// it keys off `premium` on the profile, never off a name: a user is free to
/// call their own server "hideip", and it stays theirs.
Mix mixOf(Iterable<ProxyProfile> profiles, {required bool premiumOn}) {
  if (!premiumOn) return Mix.byo;
  return profiles.any((p) => !p.premium) ? Mix.mixed : Mix.hip;
}

/// A session length in the design's shape: `4m 07s` below the hour,
/// `2h 05m` above it. Ported from `fmtDur` in
/// `design/app-1_1_0/screens-home.jsx`.
String fmtDur(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  return h > 0 ? S.durHours(h, m) : S.durMinutes(m, s);
}

/// Single source of truth for the UI: holds the profile list, the selected
/// profile, the connection state, the current public IP, and bridges the
/// parser/config to [VpnController]. Backed by [ProfileStore] for persistence.
class AppState extends ChangeNotifier {
  final List<ProxyProfile> _profiles = [];
  int _selected = -1;
  ConnState _conn = ConnState.disconnected;
  String? _error;
  String? _publicIp;
  IpGeo? _userGeo;
  bool _ipLoading = false;
  Timer? _statusPoll;
  VpnStats _stats = VpnStats.zero;
  // Latency probes, keyed by "host:port". Absent = never tested.
  final Map<String, PingResult> _pings = {};
  bool _pinging = false;
  UiPrefs _prefs = const UiPrefs();
  final PurchaseService _purchases = PurchaseService();
  final ProvisioningService _provisioning = ProvisioningService();
  final AsyncGate _premiumRefreshGate = AsyncGate();
  final UserSubscriptionService _userSubs = UserSubscriptionService();
  // Plan metadata (data used, expiry, provider name/links) keyed by
  // subscription URL, captured from the provider's response headers on refresh.
  final Map<String, SubInfo> _subInfos = {};
  Premium _premium = const Premium.none();
  String? _toast;
  Timer? _toastTimer;
  bool _ready = false;

  // --- Speed mode (WireGuard) ---------------------------------------------
  final WgRegisterService _wg = WgRegisterService();
  WgProfile? _wgProfile;
  // Networks WireGuard could not hand shake on; in-memory only, so every
  // launch re-tests and a network that stops blocking recovers by itself.
  final WgHandshakeMemory _wgBlocked = WgHandshakeMemory();
  TunnelPath _path = TunnelPath.stealth;
  SpeedFallbackReason _fallback = SpeedFallbackReason.off;
  bool _wgDeviceLimit = false;
  // Guards the probe so a disconnect (or a second connect) mid-window cannot
  // have a late probe tear down a tunnel it no longer owns. The connecting
  // timers below ride on the same counter rather than inventing a second one.
  int _connectGeneration = 0;

  // --- Connecting: permission, network, patience --------------------------
  VpnPerm _vpnPerm = VpnPerm.unknown;
  bool _vpnPrepared = false;
  DateTime? _connectedAt;
  bool _connSlow = false;
  bool _showConnectFailed = false;
  Timer? _slowTimer;
  Timer? _failTimer;
  late final ConnectivityWatch _connectivity =
      ConnectivityWatch(onChanged: _onConnectivity);
  bool _offline = false;

  // hideip.net locations shown without a subscription: real hosts from the
  // signed public catalog, real latency, no credential. Kept apart from
  // [_profiles] on purpose; nothing here can ever reach the tunnel.
  List<Location> _lockedLocations = const [];

  List<ProxyProfile> get profiles => List.unmodifiable(_profiles);
  int get selectedIndex => _selected;
  ProxyProfile? get selected => (_selected >= 0 && _selected < _profiles.length)
      ? _profiles[_selected]
      : null;
  ConnState get conn => _conn;
  String? get error => _error;
  String? get publicIp => _publicIp;

  /// Where the user's real IP geolocates (the map's "you" pin). Only
  /// refreshed while the tunnel is down; with it up the public IP would
  /// geolocate to the exit node instead.
  IpGeo? get userGeo => _userGeo;
  bool get ipLoading => _ipLoading;
  bool get isConnected => _conn == ConnState.connected;
  bool get isBusy => _conn == ConnState.connecting;
  VpnStats get stats => _stats;
  bool get pinging => _pinging;
  PingResult? pingFor(ProxyProfile p) => _pings['${p.server}:${p.port}'];

  /// Plan metadata the provider sent for the subscription at [subUrl] (data
  /// used, expiry, panel link), or null when none was captured.
  SubInfo? subInfoFor(String subUrl) => _subInfos[subUrl];
  UiPrefs get prefs => _prefs;

  /// The current entitlement with expiry applied at read time. The persisted
  /// copy is only re-evaluated on launch, but a session can outlive the
  /// period (long-running app, or a clock that was behind at load); the real
  /// gate stays server-side receipt validation.
  Premium get premium {
    final r = _premium.renews;
    if (_premium.isOn && r != null && r.isBefore(DateTime.now())) {
      return Premium(
        status: PremiumStatus.expired,
        plan: _premium.plan,
        renews: r,
      );
    }
    return _premium;
  }

  /// Whether the provisioning backend has finished with this subscription:
  /// the subscription URL is retired and a re-provision with the stored
  /// purchase proof was refused too. The store can keep reporting the
  /// entitlement for a while after that, so this is the only thing that tells
  /// an empty premium list apart from a first provision still in flight.
  bool get premiumEnded => _premiumEnded && premium.isOn;
  bool _premiumEnded = false;

  String? get toast => _toast;

  /// Whether Android's system Always-on VPN is enabled for this app (as last
  /// reported by the native service). With it on and [UiPrefs.alwaysOn] off,
  /// a disconnect can leave the OS holding traffic; the UI warns about that.
  bool get systemAlwaysOn => _systemAlwaysOn;
  bool _systemAlwaysOn = false;

  /// True once [init] has loaded persisted state (gates the first frame).
  bool get ready => _ready;

  /// Which path the live tunnel is taking.
  TunnelPath get tunnelPath => _path;

  /// Why Speed mode is not carrying the traffic right now.
  SpeedFallbackReason get speedFallback => _fallback;

  /// The tunnel chip on the session card: what is carrying this session,
  /// always in words. Advanced view carries the full `proto · host` chain.
  String get tunnelChip => tunnelChipLabel(
        _path,
        _fallback,
        activeLocation,
        advanced: _prefs.advanced,
      );

  /// When the live session started, or null while nothing is up. Drives the
  /// duration on the session card.
  DateTime? get connectedAt => _connectedAt;

  /// How long the live session has been up, or null while nothing is up.
  Duration? get sessionLength {
    final start = _connectedAt;
    return start == null ? null : DateTime.now().difference(start);
  }

  /// What the user's list is made of. Derived on every read; nothing about
  /// this is ever stored, so it cannot fall out of step with the entitlement.
  Mix get mix => mixOf(_profiles, premiumOn: premium.isOn);

  /// hideip.net locations the user cannot use yet, cheapest latency first.
  /// Empty while a subscription is live: they are then real servers in
  /// [profiles] instead.
  List<Location> get lockedLocations =>
      List.unmodifiable([for (final l in _lockedLocations) _stampWon(l)]);

  /// What the OS says about the VPN configuration.
  VpnPerm get vpnPerm => _vpnPerm;

  /// Whether the one-off explanation should be shown before the first
  /// Connect. It lives above [connect]: the sheet is a tap-driven courtesy,
  /// and a connect that was not a tap (Always-on, auto-connect, a deep link)
  /// goes straight to the system dialog as it always did.
  bool get needsVpnPrimer => !_prefs.vpnPermAsked && !_vpnPrepared;

  /// True when the device has no network at all. Connect is off, its reason
  /// is stated under it, and the failure sheet stays shut.
  bool get offline => _offline;

  /// True ten seconds into a connect that has not landed yet.
  bool get connSlow => _connSlow;

  /// True when a connect attempt gave up and the failure sheet is owed. The
  /// screen that shows it calls [dismissConnectFailed] afterwards.
  bool get showConnectFailed => _showConnectFailed;

  /// Whether the subscription has already used its five WireGuard slots.
  bool get speedDeviceLimit => _wgDeviceLimit;

  /// Display-friendly view over [profiles], in the same order.
  List<Location> get locations =>
      [for (final l in Location.deriveAll(_profiles)) _stampWon(l)];

  /// Marks a location whose country won a voting round and went live.
  ///
  /// The vote service answers in ISO 3166 numeric codes while a location
  /// carries the alpha-2 one, so the two are matched through [ccNumeric]. The
  /// trophy is a one-off reward: once the user has connected there its id is
  /// in [UiPrefs.wonClaimed] and the location goes back to being an ordinary
  /// server, on every screen at once.
  Location _stampWon(Location l) {
    final won = !_prefs.wonClaimed.contains(l.id) &&
        VoteService.instance.won.contains(ccNumeric(l.cc) ?? '');
    return won == l.won ? l : l.copyWith(won: won);
  }

  /// The location the tunnel would use right now. In auto mode this is the
  /// lowest-latency probed server (falling back to the persisted selection).
  Location? get activeLocation {
    final all = locations;
    if (all.isEmpty) return null;
    if (_prefs.autoSelect) {
      Location? best;
      int? bestMs;
      for (final l in all) {
        final ping = pingFor(l.profile);
        if (ping is PingOk && (bestMs == null || ping.ms < bestMs)) {
          bestMs = ping.ms;
          best = l;
        }
      }
      if (best != null) return best;
    }
    if (_selected >= 0 && _selected < all.length) return all[_selected];
    return all.first;
  }

  /// Signal level 0-4 for the ping bars.
  int levelFor(ProxyProfile p) {
    final ping = pingFor(p);
    if (ping is! PingOk) return 0;
    if (ping.ms < 60) return 4;
    if (ping.ms < 120) return 3;
    if (ping.ms < 250) return 2;
    return 1;
  }

  /// Load persisted state + initial IP. Call once at startup.
  Future<void> init() async {
    _prefs = await UiPrefs.load();
    _count(AppEvent.firstOpen);
    // Keep the native side's copy of the Always-on opt-in current (the service
    // reads it on system-initiated starts, when no Dart is running).
    VpnController.setAlwaysOn(_prefs.alwaysOn);
    // Same for the kill switch: the native layer acts on it (on-drop
    // reconnect / on-demand rules) with no Dart in the loop.
    VpnController.setKillSwitch(_prefs.killSwitch);
    _premium = await Premium.load();
    iapLog(
      '[iap] loaded: ${_premium.status.name} plan=${_premium.plan?.name}'
      ' renews=${_premium.renews} now=${DateTime.now()}',
    );
    // The store is the source of truth: every entitlement it reports (a
    // purchase, a restore, a renewal from a previous session) lands here.
    _purchases.init(
      onPremium: (p, proof) {
        // The store replays past transactions in arbitrary order (a stale
        // renewal can land right after the newest one); an entitlement only
        // ever moves forward. Plan changes are safe under this rule: in a
        // subscription group the replacing transaction always starts at or
        // after the old one's period end.
        final held = _premium.renews;
        if (held != null && p.renews != null && p.renews!.isBefore(held)) {
          return;
        }
        _premium = p;
        notifyListeners();
        p.save();
        // Every live entitlement re-provisions: a first purchase creates the
        // server profile, a renewal extends its lifetime server-side.
        if (p.isOn && proof != null) _provisionPremium(proof);
      },
      // The catalog loads asynchronously; the paywall entry points are gated
      // on availability, so a rebuild has to follow when it flips.
      onAvailability: notifyListeners,
    );
    // Whether the OS already holds a VPN configuration for this app. Read
    // once here so the pre-prompt is skipped for anyone who has been through
    // the system dialog before, including on a reinstall over a live profile.
    _vpnPrepared = await VpnController.isPrepared();
    if (_vpnPrepared) _vpnPerm = VpnPerm.granted;
    unawaited(_connectivity.start());
    unawaited(Notifications.init());
    _profiles.addAll(await ProfileStore.load());
    _subInfos.addAll(await SubInfoStore.load());
    await _loadSubToken();
    final savedIdx = await ProfileStore.loadSelectedIndex();
    if (savedIdx >= 0 && savedIdx < _profiles.length) _selected = savedIdx;
    // Keep the premium server profiles current (or drop them once the
    // subscription lapsed); fire-and-forget, list updates when it lands.
    _refreshPremiumProfiles();
    // Same for the user's own subscription imports: providers rotate servers
    // behind their URL, so re-pull each one.
    _refreshUserSubscriptions();
    _ready = true;
    notifyListeners();
    refreshIp();
    // Latency probes power the Auto choice and the signal bars.
    pingAll();
    _backfillGeo();
    // Reconcile with whatever the native service reports (e.g. after restart).
    // On a cold start we ignore a stale native error when nothing is running:
    // a leftover error from a previous session must not greet the user.
    _syncStatus(initial: true);
    // The hideip.net fleet as it is shown to someone who has not bought it.
    unawaited(refreshLockedLocations());
    if (_prefs.autoConnect && _profiles.isNotEmpty && !isConnected) {
      connect();
    }
  }

  // --- Locked hideip.net locations ----------------------------------------

  /// Reads the signed public catalog and keeps the locked rows current.
  ///
  /// Runs without a subscription and without an identity, which is the whole
  /// point: the locations that come with a plan are visible, with their real
  /// latency, before anyone pays for them. With a live subscription there is
  /// nothing to show, because those same servers are real profiles by then.
  Future<void> refreshLockedLocations() async {
    if (premium.isOn) {
      if (_lockedLocations.isEmpty) return;
      _lockedLocations = const [];
      notifyListeners();
      return;
    }
    final fresh = await PremiumCatalog.fetchLocked();
    if (fresh.isEmpty || premium.isOn) return;
    _lockedLocations = fresh;
    notifyListeners();
    // Real bars need a real measurement; the row would rather say nothing
    // than show an invented number.
    await forEachBounded(
      fresh,
      limit: 8,
      action: (l) async {
        final p = l.profile;
        _pings['${p.server}:${p.port}'] = await Ping.measure(p.server, p.port);
        notifyListeners();
      },
    );
  }

  // --- Premium -----------------------------------------------------------

  /// The store bridge, exposed for the paywall (live prices, availability,
  /// the store's message for a failed purchase).
  PurchaseService get purchases => _purchases;

  /// Whether to show any in-app plans entry point right now. True once the
  /// store catalog is confirmed purchasable, or whenever the user already has
  /// a subscription (their Premium status stays reachable even if the catalog
  /// is momentarily unavailable). False keeps every paywall entry point hidden
  /// so the app never advertises a purchase it cannot complete, e.g. before
  /// the Play products exist. Gated further by [kPlansAvailable] at each site.
  bool get plansOffered => _purchases.available || premium.isOn;

  /// [PlanInfo] for [plan] with the store's localized price once the catalog
  /// has loaded; before that the USD fallback.
  PlanInfo planInfo(PremiumPlan plan) {
    final price = _purchases.priceOf(plan);
    final base = PlanInfo.of(plan);
    return price == null ? base : base.withPrice(price);
  }

  /// Buy the Premium subscription. The entitlement itself lands through the
  /// purchase stream (see [init]); this reports how the attempt ended.
  Future<PurchaseOutcome> purchasePremium(PremiumPlan plan) =>
      _purchases.buy(plan);

  /// Re-check the store for an existing subscription.
  Future<void> restorePurchases() async {
    final restored = await _purchases.restore();
    if (restored) {
      showToast(S.toastRestored);
      return;
    }
    // On a subscription that has run out, "nothing to restore" reads as a
    // failure of the restore. The truthful line is that there is no live
    // subscription to find, which is a different sentence.
    showToast(premium.status == PremiumStatus.expired
        ? S.toastNoSubscription
        : S.toastNothingToRestore);
  }

  /// Exchange the signed purchase proof for tunnel credentials and pull the
  /// premium profiles in. Every step is retried on the next launch (or the
  /// next store event) if it fails here, so errors stay silent.
  Future<void> _provisionPremium(PurchasePayload proof) =>
      _premiumRefreshGate.run(() => _provisionPremiumLocked(proof));

  Future<void> _provisionPremiumLocked(PurchasePayload proof) async {
    await PremiumSub.saveProof(proof);
    final result = await _provisioning.provision(proof);
    if (result.status == ProvisionStatus.gone) {
      // The store still hands out the entitlement, but the backend will not
      // honour this proof: the same verdict as a subscription that ran out.
      await _premiumSubscriptionEnded();
      return;
    }
    final url = result.url;
    if (url == null) return;
    _premiumEnded = false;
    await PremiumSub.saveUrl(url);
    // The linked-devices section keys off this token being present.
    await _loadSubToken();
    final refresh = await _provisioning.refreshProfiles(
      url,
      cachedProfiles: _profiles,
      // The URL is seconds old; asking the same proof again decides nothing.
      healLapsed: false,
    );
    final fresh = refresh?.profiles;
    if (fresh != null && fresh.isNotEmpty) {
      final epoch = refresh?.catalogEpoch;
      final floor = await PremiumSub.catalogEpoch();
      if (epoch == null || floor == null || epoch >= floor) {
        _applyPremiumProfiles(fresh);
        await _persist();
        if (epoch != null) await PremiumSub.saveCatalogEpoch(epoch);
        iapLog('[iap] provisioned: ${fresh.length} profile(s)');
      }
    }
    await _refreshWireGuard(url);
  }

  // --- Speed mode (WireGuard) ---------------------------------------------

  /// Register this device's WireGuard public key and cache the profile.
  ///
  /// Idempotent by contract, so it runs on every subscription refresh: that is
  /// what keeps the peer present on servers added to the fleet since last time.
  /// Only runs while Speed mode is on, so a user who never turns it on never
  /// generates a key and never has a peer registered anywhere.
  Future<void> _refreshWireGuard(String? subscriptionUrl) async {
    if (!_prefs.speedMode) return;
    if (!premium.isOn) return;
    final token = subTokenFromUrl(subscriptionUrl ?? await PremiumSub.url());
    if (token == null) return;
    // First use generates the keypair; later calls reuse it.
    final keys = await WgIdentity.ensure();
    final result = await _wg.register(
      subToken: token,
      publicKey: keys.publicKey,
    );
    switch (result.status) {
      case WgRegisterStatus.ok:
        _wgProfile = result.profile;
        _wgDeviceLimit = false;
        await WgProfileStore.save(result.profile!);
        notifyListeners();
      case WgRegisterStatus.deviceLimit:
        _wgDeviceLimit = true;
        _wgProfile = null;
        await WgProfileStore.clear();
        notifyListeners();
      case WgRegisterStatus.gone:
        // The subscription is finished; the premium refresh path clears the
        // rest of its state, so just let go of the WireGuard half here.
        await _forgetWireGuard();
      case WgRegisterStatus.badKey:
        // Should not happen: the key was generated and validated locally.
        // Start over with a fresh identity so the next refresh can recover.
        await WgIdentity.clear();
        await _forgetWireGuard();
      case WgRegisterStatus.transient:
        // Keep whatever is cached; retry on the next refresh.
        break;
    }
  }

  /// Drop every trace of the WireGuard profile (not the keypair).
  Future<void> _forgetWireGuard() async {
    _wgProfile = null;
    _wgDeviceLimit = false;
    await WgProfileStore.clear();
    notifyListeners();
  }

  /// Turn Speed mode on or off. Turning it on registers immediately so the
  /// profile is ready by the time the user next connects; turning it off
  /// releases the device's peer slot on the backend, which is what lets a
  /// subscriber move Speed mode to a different device.
  Future<void> setSpeedMode(bool on) async {
    await updatePrefs(_prefs.copyWith(speedMode: on));
    if (on) {
      _wgDeviceLimit = false;
      await _refreshWireGuard(null);
      if (_wgDeviceLimit) {
        // The subscription has no slot left, so Speed mode is not running and
        // the stored preference must not claim otherwise: an app restart
        // would otherwise come up believing it is on. The flag stays, because
        // Settings reads it to raise the explanation with its action.
        await updatePrefs(_prefs.copyWith(speedMode: false));
      }
    } else {
      // Best effort: a failed revoke only costs a slot until the
      // subscription lapses, and must not block the toggle.
      final token = subTokenFromUrl(await PremiumSub.url());
      final keys = await WgIdentity.load();
      if (token != null && keys != null) {
        final revoked = await _wg.revoke(
          subToken: token,
          publicKey: keys.publicKey,
        );
        // With the slot freed, retire the keypair too, so re-enabling mints a
        // fresh identity: that is the recovery path for an identity cloned by
        // a device restore. After a failed revoke the key is kept instead;
        // reusing it on re-enable is what stops an offline off/on cycle from
        // burning through the subscription's five slots.
        if (revoked) await WgIdentity.clear();
      }
      await _forgetWireGuard();
      _path = TunnelPath.stealth;
      _fallback = SpeedFallbackReason.off;
      notifyListeners();
    }
  }

  /// On launch: re-fetch premium profiles while the subscription lives (the
  /// server may rotate keys or add locations), retry a provision that never
  /// completed, and clear the managed profiles once the subscription lapsed.
  Future<void> _refreshPremiumProfiles() =>
      _premiumRefreshGate.run(_refreshPremiumProfilesLocked);

  Future<void> _refreshPremiumProfilesLocked() async {
    if (!premium.isOn) {
      if (premium.status == PremiumStatus.expired &&
          _profiles.any(isPremiumProfile)) {
        _applyPremiumProfiles(const []);
        await PremiumSub.clear();
        // The WireGuard peer goes with it; the backend drops the peers on its
        // side when the store notification lands, and holding a stale profile
        // here would only produce a tunnel that cannot hand shake.
        await _forgetWireGuard();
        await WgIdentity.clear();
        await _loadSubToken();
        iapLog('[iap] premium lapsed: managed profiles removed');
      }
      return;
    }
    final url = await PremiumSub.url();
    if (url == null) {
      final proof = await PremiumSub.proof();
      if (proof != null) await _provisionPremiumLocked(proof);
      return;
    }
    // Speed mode rides along on the same refresh: the register call is
    // idempotent, so this is how the peer reaches servers added since the
    // last launch.
    _wgProfile = await WgProfileStore.load();
    await _refreshWireGuard(url);
    final refresh = await _provisioning.refreshProfiles(
      url,
      cachedProfiles: _profiles,
    );
    final renewed = refresh?.renewedUrl;
    if (renewed != null) {
      // A renewal moved the subscription to a new URL; everything keyed off
      // the old token has to follow it.
      await _loadSubToken();
      await _refreshWireGuard(renewed);
    }
    if (refresh?.expired ?? false) {
      await _premiumSubscriptionEnded();
      return;
    }
    final fresh = refresh?.profiles;
    if (fresh == null) return; // unchanged or transient failure: keep cache
    if (fresh.isEmpty && !_profiles.any(isPremiumProfile)) return;
    final epoch = refresh?.catalogEpoch;
    final floor = await PremiumSub.catalogEpoch();
    if (epoch != null && floor != null && epoch < floor) return;
    if (fresh.isNotEmpty) _premiumEnded = false;
    _applyPremiumProfiles(fresh);
    await _persist();
    if (epoch != null) await PremiumSub.saveCatalogEpoch(epoch);
  }

  /// The backend refused the stored purchase proof, so the subscription is
  /// over even where the store has not caught up yet (a cancelled renewal is
  /// only reported to the app on the store's own schedule). Drop the managed
  /// profiles and the dead URL but keep the proof: a renewal provisions from
  /// it, and the empty list then means "expired" instead of "still setting up".
  Future<void> _premiumSubscriptionEnded() async {
    _premiumEnded = true;
    await PremiumSub.forgetSubscription();
    await _forgetWireGuard();
    await _loadSubToken();
    if (_profiles.any(isPremiumProfile)) {
      _applyPremiumProfiles(const []);
      await _persist();
    } else {
      notifyListeners();
    }
    iapLog('[iap] subscription gone server-side: managed profiles removed');
  }

  /// Swap the managed premium profiles for [fresh], preserving the user's
  /// own profiles and, when possible, the current selection.
  void _applyPremiumProfiles(List<ProxyProfile> fresh) {
    _applyMerged(mergePremiumProfiles(_profiles, fresh));
  }

  // --- Device linking ------------------------------------------------------

  final DeviceLinkService _deviceLinks = DeviceLinkService();

  /// The `/v1/link/*` client, used by the linked-devices screens.
  DeviceLinkService get deviceLinks => _deviceLinks;

  /// Whether this phone can hand out access to other devices: it needs a live
  /// subscription whose provisioned token is on disk. Read once at load and
  /// again whenever premium changes, so the Settings section can be gated
  /// without every build hitting storage.
  bool get canLinkDevices => premium.isOn && _subToken != null;
  String? _subToken;

  /// The subscription token the link API authenticates with, or null when this
  /// phone holds no provisioned subscription.
  String? get subToken => premium.isOn ? _subToken : null;

  /// Re-reads the provisioned subscription token from storage. Cheap and
  /// idempotent; called on launch and after a provision lands.
  Future<void> _loadSubToken() async {
    final next = subTokenOf(await PremiumSub.url());
    if (next == _subToken) return;
    _subToken = next;
    notifyListeners();
  }

  // --- User subscriptions --------------------------------------------------

  /// On launch: re-pull every subscription URL the user has imported and swap
  /// in the fresh server lists (providers rotate servers behind their URL).
  /// A transient failure keeps the current servers; only a definitive 404/410
  /// clears a group, since the provider retired that link.
  Future<void> _refreshUserSubscriptions() async {
    for (final url in userSubUrls(_profiles)) {
      final result = await _userSubs.fetch(url);
      if (result == null) continue; // transient failure: keep what we have
      if (result.info != null) {
        _subInfos[url] = result.info!;
        await SubInfoStore.put(url, result.info!);
        notifyListeners();
      }
      _applyMerged(mergeUserSubProfiles(_profiles, url, result.profiles));
    }
  }

  /// Replace the profile list with [merged], preserving the current selection
  /// when its profile survived the merge.
  void _applyMerged(List<ProxyProfile> merged) {
    final sel = selected;
    _profiles
      ..clear()
      ..addAll(merged);
    _selected = sel == null ? -1 : _profiles.indexOf(sel);
    if (_selected < 0 && _profiles.isNotEmpty) _selected = 0;
    _persist();
    notifyListeners();
    pingAll();
    _backfillGeo();
  }

  // --- UI preferences / toast --------------------------------------------

  /// Switch the palette. Three states: the system one is the default and the
  /// one most people never change.
  Future<void> setThemeMode(AppThemeMode mode) =>
      updatePrefs(_prefs.copyWith(themeMode: mode));

  /// Hide the Speed mode upsell row for fourteen days.
  Future<void> snoozeUpsell() => updatePrefs(_prefs.copyWith(
        upsellSnoozeUntil: DateTime.now()
            .add(const Duration(days: 14))
            .millisecondsSinceEpoch,
      ));

  /// Whether the Speed mode upsell may show right now.
  bool get upsellAllowed => _prefs.upsellAllowed(DateTime.now());

  /// The system notification permission, with "never asked" told apart from
  /// "asked and refused" by our own record of having put the dialog up.
  Future<NotifPerm> notifPermission() =>
      Notifications.permission(asked: _prefs.notifAsked);

  /// Puts the system notification dialog up, once. The record is written
  /// whatever the answer is, so nobody is asked a second time.
  Future<NotifPerm> requestNotifPermission() async {
    final result = await Notifications.request();
    await updatePrefs(_prefs.copyWith(notifAsked: true));
    return result;
  }

  Future<void> updatePrefs(UiPrefs next) async {
    final alwaysOnChanged = next.alwaysOn != _prefs.alwaysOn;
    final killSwitchChanged = next.killSwitch != _prefs.killSwitch;
    _prefs = next;
    notifyListeners();
    await next.save();
    if (alwaysOnChanged) await VpnController.setAlwaysOn(next.alwaysOn);
    if (killSwitchChanged) await VpnController.setKillSwitch(next.killSwitch);
  }

  void showToast(String message) {
    _toast = message;
    notifyListeners();
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(milliseconds: 2400), () {
      _toast = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _statusPoll?.cancel();
    _toastTimer?.cancel();
    _slowTimer?.cancel();
    _failTimer?.cancel();
    unawaited(_connectivity.dispose());
    _purchases.dispose();
    super.dispose();
  }

  // --- Profile management ----------------------------------------------------

  /// Add a single share link. Throws [ProfileParseException] on bad input.
  Future<void> addLink(String link) async {
    final p = ShareLinkParser.parse(link);
    if (p == null) throw const ProfileParseException('Empty or comment line');
    _profiles.add(p);
    if (_selected < 0) _selected = 0;
    await _persist();
    notifyListeners();
    _backfillGeo();
  }

  /// Import a subscription body (base64 blob or newline links). Returns the
  /// result so the UI can report how many were added and what failed.
  Future<SubscriptionResult> addSubscription(String body) async {
    final res = await Subscription.parseAsync(body);
    if (res.profiles.isNotEmpty) {
      _profiles.addAll(res.profiles);
      if (_selected < 0) _selected = 0;
      await _persist();
      notifyListeners();
      _backfillGeo();
    }
    return res;
  }

  /// Add pre-parsed profiles (the redesign import screen parses before
  /// committing, so the user can review what was detected first).
  Future<void> addProfiles(
    List<ProxyProfile> newProfiles, {
    bool select = false,
    bool countFirstProfile = true,
  }) async {
    if (newProfiles.isEmpty) return;
    if (countFirstProfile) _count(AppEvent.firstProfile);
    final sel = selected;
    // Re-importing a subscription the list already holds must replace its
    // group, not stack a second copy of every server next to the first.
    final subUrls = {
      for (final p in newProfiles)
        if (p.subUrl != null) p.subUrl!,
    };
    if (subUrls.isNotEmpty) {
      _profiles.removeWhere((p) => !p.premium && subUrls.contains(p.subUrl));
    }
    _profiles.addAll(newProfiles);
    // A subscription import may have just written fresh SubInfo to the store
    // (import screen does this directly); pull it in so its plan row shows now.
    if (subUrls.isNotEmpty) {
      _subInfos.addAll(await SubInfoStore.load());
    }
    if (select || _selected < 0) {
      _selected = _profiles.length - newProfiles.length;
      await updatePrefs(_prefs.copyWith(autoSelect: false));
    } else {
      // The removal above may have shifted (or removed) the selected profile.
      _selected = sel == null ? -1 : _profiles.indexOf(sel);
      if (_selected < 0 && _profiles.isNotEmpty) _selected = 0;
    }
    await _persist();
    notifyListeners();
    pingAll();
    _backfillGeo();
  }

  /// Re-reads one subscription URL and replaces the servers that came from
  /// it. Returns how many the provider sent back, or null when it could not
  /// be reached: a failure keeps every server already on the device, because
  /// nothing should be dropped over a provider being briefly unreachable.
  Future<int?> refreshSubscription(String subUrl) async {
    final result = await _userSubs.fetch(subUrl);
    if (result == null) return null;
    final info = result.info;
    if (info != null) await SubInfoStore.put(subUrl, info);
    // A manual refresh is not a first import, so the one-shot counter that
    // marks "this install has servers now" stays where it is.
    await addProfiles(result.profiles, countFirstProfile: false);
    return result.profiles.length;
  }

  /// Fill in country codes for profiles whose name reveals no location by
  /// geolocating the server address. Fire-and-forget: rows silently gain
  /// their flag (and map pin) when an answer arrives, and profiles that
  /// cannot be resolved right now are retried on the next app start.
  Future<void> _backfillGeo() async {
    for (final p in [..._profiles]) {
      if (p.cc != null) continue;
      final idx = _profiles.indexOf(p);
      if (idx < 0) continue;
      if (Location.derive(p, idx).placed) continue;
      final geo = await IpLookup.geoFor(p.server);
      final cc = geo?.cc;
      if (cc == null) continue;
      // The list may have shifted while the lookup was in flight.
      final at = _profiles.indexOf(p);
      if (at < 0) continue;
      _profiles[at] = p.copyWith(cc: cc, city: geo!.city);
      await _persist();
      notifyListeners();
    }
  }

  /// Explicitly pick a server (turns Auto off), or pass null for Auto.
  Future<void> selectLocation(Location? loc) async {
    if (loc == null) {
      await updatePrefs(_prefs.copyWith(autoSelect: true));
      Haptics.selection();
      return;
    }
    await updatePrefs(_prefs.copyWith(
      autoSelect: false,
      recents: UiPrefs.pushRecent(_prefs.recents, loc.id),
    ));
    await select(loc.index);
  }

  Future<void> select(int index) async {
    if (index < 0 || index >= _profiles.length) return;
    if (index != _selected) Haptics.selection();
    _selected = index;
    // Picking a server clears any prior error (e.g. "select a server first").
    if (_error != null && _conn != ConnState.connecting) {
      _error = null;
      if (_conn == ConnState.error) _conn = ConnState.disconnected;
    }
    await ProfileStore.saveSelectedIndex(_selected);
    notifyListeners();
  }

  /// Give the server at [index] a name of the user's own. An empty name (or
  /// null) drops back to the one the provider sent, which stays on the
  /// profile throughout, so renaming never loses it.
  Future<void> renameServer(int index, String? name) async {
    if (index < 0 || index >= _profiles.length) return;
    final trimmed = name?.trim();
    final next = trimmed == null || trimmed.isEmpty ? null : trimmed;
    if (next == _profiles[index].customName) return;
    _profiles[index] = _profiles[index].copyWith(customName: next);
    await _persist();
    notifyListeners();
  }

  Future<void> remove(int index) async {
    if (index < 0 || index >= _profiles.length) return;
    _profiles.removeAt(index);
    if (_selected == index) {
      _selected = _profiles.isEmpty ? -1 : 0;
    } else if (_selected > index) {
      _selected -= 1;
    }
    await _persist();
    notifyListeners();
  }

  // --- Latency ---------------------------------------------------------------

  /// Probes every server's TCP latency concurrently and updates the UI as each
  /// result lands. No-op while a probe run is already in flight.
  Future<void> pingAll() async {
    if (_pinging || _profiles.isEmpty) return;
    _pinging = true;
    notifyListeners();
    await forEachBounded(
      _profiles,
      limit: 8,
      action: (p) async {
        final key = '${p.server}:${p.port}';
        final result = await Ping.measure(p.server, p.port);
        _pings[key] = result;
        notifyListeners();
      },
    );
    _pinging = false;
    notifyListeners();
  }

  /// One-shot anonymous counter (docs/app-events-api.md). Never awaited: the
  /// app must behave identically whether the request succeeds, fails or is
  /// switched off.
  void _count(AppEvent event) {
    unawaited(AppTelemetry.mark(event, enabled: _prefs.usageCounts));
  }

  // --- Connection ------------------------------------------------------------

  Future<void> connect() async {
    // No network, nothing to blame the tunnel for. This is not an error and
    // it does not raise the failure sheet; the reason sits under the button.
    if (_offline) return;
    // Auto mode resolves to the best probed server; otherwise the selection.
    final target = activeLocation;
    final profile = target?.profile ?? selected;
    if (profile == null) {
      _setError(S.errNoServer);
      return;
    }
    _conn = ConnState.connecting;
    _error = null;
    _connSlow = false;
    _showConnectFailed = false;
    final generation = ++_connectGeneration;
    notifyListeners();

    try {
      // The OS consent dialog returns via the platform channel. Guard against a
      // dropped/never-delivered result so the UI can't get stuck "Connecting…".
      var timedOut = false;
      final ok = await VpnController.prepare().timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          timedOut = true;
          return false;
        },
      );
      if (!ok) {
        // User cancelled consent (or it timed out): return to a clean state.
        _clearConnectTimers();
        _conn = ConnState.disconnected;
        _error = null;
        // A guard that fired is not an answer from the user: the permission
        // stays unknown and the next Connect asks again. A refusal is an
        // answer, and it is what turns Connect off until settings change.
        if (!timedOut) _vpnPerm = VpnPerm.denied;
        notifyListeners();
        return;
      }
      _vpnPerm = VpnPerm.granted;
      _vpnPrepared = true;
      // A cancel while the consent sheet was up already ended this attempt;
      // the answer is still recorded above, only the tunnel is not started.
      if (generation != _connectGeneration) return;
      // The clock starts once consent is out of the way. The time someone
      // spends reading a system dialog is not the tunnel's to answer for.
      _startConnectTimers(generation);
      // Speed mode gets first refusal; anything unclear falls through to the
      // stealth profile below, which is the path that always works.
      final decision = SpeedModeDecision.decide(
        enabled: _prefs.speedMode,
        premium: premium.isOn,
        profile: _wgProfile,
        blockedHere: _wgBlocked.isBlocked(_networkId),
        preferredCountry: activeLocation?.cc,
        deviceLimited: _wgDeviceLimit,
      );
      _fallback = decision.reason;
      var startedSpeed = false;
      if (decision.useWireGuard && decision.server != null) {
        startedSpeed = await _startWireGuard(decision.server!);
      }
      if (!startedSpeed) {
        _path = TunnelPath.stealth;
        final config = SingboxConfig.buildJson(
          profile,
          killSwitch: _prefs.killSwitch,
        );
        await VpnController.start(config, label: profile.name);
      }
      _startStatusPoll();
      _clearConnectTimers();
      // Optimistic; the poll will confirm/flip to error.
      _conn = ConnState.connected;
      _connectedAt ??= DateTime.now();
      Haptics.success();
      notifyListeners();
      if (target != null) await _claimWin(target);
      _count(AppEvent.firstConnect);
      _refreshIpAfterToggle();
      // With WireGuard up, watch for the handshake actually completing and
      // fall back to stealth without user involvement if it never does.
      if (startedSpeed) {
        unawaited(_probeWireGuard(generation, profile));
      }
    } on MissingPluginException {
      // No native VPN side on this platform yet (iOS before the PacketTunnel
      // port). Keep the rest of the app usable; only connecting is off-limits.
      _clearConnectTimers();
      _setError(S.errNoPlatform);
    } catch (e) {
      _clearConnectTimers();
      _setError(S.errConnect(e));
      _showConnectFailed = !_offline;
      notifyListeners();
    }
  }

  /// Connecting to a location that won a voting round is what collects the
  /// reward: the trophy comes off it and does not come back.
  Future<void> _claimWin(Location loc) async {
    if (!loc.won || _prefs.wonClaimed.contains(loc.id)) return;
    await updatePrefs(
      _prefs.copyWith(wonClaimed: {..._prefs.wonClaimed, loc.id}),
    );
  }

  /// Cancel a connect in progress. The CTA stays live while Connecting for
  /// exactly this: a handshake that is going nowhere must have a way out that
  /// is not force-quitting the app.
  Future<void> cancel() async {
    if (_conn != ConnState.connecting) return;
    _connectGeneration++;
    _clearConnectTimers();
    try {
      await VpnController.stop();
    } catch (_) {
      // Nothing may have started yet; the state below is the answer either way.
    }
    _statusPoll?.cancel();
    _conn = ConnState.disconnected;
    _error = null;
    _connectedAt = null;
    _path = TunnelPath.stealth;
    notifyListeners();
  }

  /// The two things a slow connect is owed: a line after ten seconds, and an
  /// explanation after twenty five. Both check the generation before acting,
  /// the same guard the WireGuard probe uses, so a cancelled or superseded
  /// attempt cannot speak for the current one.
  void _startConnectTimers(int generation) {
    _clearConnectTimers();
    _slowTimer = Timer(const Duration(seconds: 10), () {
      if (generation != _connectGeneration) return;
      if (_conn != ConnState.connecting) return;
      _connSlow = true;
      notifyListeners();
    });
    _failTimer = Timer(const Duration(seconds: 25), () {
      if (generation != _connectGeneration) return;
      if (_conn != ConnState.connecting) return;
      _connectGeneration++;
      _clearConnectTimers();
      unawaited(VpnController.stop().catchError((_) {}));
      _statusPoll?.cancel();
      _conn = ConnState.disconnected;
      _error = null;
      _connectedAt = null;
      // Offline suppresses the sheet entirely: see [connect].
      _showConnectFailed = !_offline;
      notifyListeners();
    });
  }

  void _clearConnectTimers() {
    _slowTimer?.cancel();
    _slowTimer = null;
    _failTimer?.cancel();
    _failTimer = null;
    if (_connSlow) _connSlow = false;
  }

  /// The screen has shown the failure sheet; do not show it again.
  void dismissConnectFailed() {
    if (!_showConnectFailed) return;
    _showConnectFailed = false;
    notifyListeners();
  }

  /// Records that the one-off VPN explanation has been shown. Called whether
  /// the user continued or not: the explanation is offered once.
  Future<void> markVpnPrimerSeen() =>
      updatePrefs(_prefs.copyWith(vpnPermAsked: true));

  /// Re-reads the OS answer. Called when the app comes back to the
  /// foreground, so someone who went to system settings and allowed the
  /// configuration returns to a live Connect button with no extra tap.
  Future<void> refreshVpnPermission() async {
    final prepared = await VpnController.isPrepared();
    final perm = prepared ? VpnPerm.granted : _vpnPerm;
    if (prepared == _vpnPrepared && perm == _vpnPerm) return;
    _vpnPrepared = prepared;
    _vpnPerm = perm;
    notifyListeners();
  }

  /// The network came or went. Losing it while connecting ends the attempt
  /// quietly and takes the failure sheet with it; there is nothing to explain
  /// about a server that was never reachable.
  void _onConnectivity(bool offline) {
    _offline = offline;
    if (offline) {
      _showConnectFailed = false;
      if (_conn == ConnState.connecting) {
        unawaited(cancel());
        return;
      }
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    // Invalidate any in-flight WireGuard probe: it must not tear down or
    // reconnect a tunnel the user has already dismissed.
    _connectGeneration++;
    _clearConnectTimers();
    try {
      await VpnController.stop();
    } catch (_) {
      // best-effort; report state from poll
    }
    _statusPoll?.cancel();
    _conn = ConnState.disconnected;
    _error = null;
    _connectedAt = null;
    _path = TunnelPath.stealth;
    notifyListeners();
    _refreshIpAfterToggle();
  }

  /// Start the tunnel on WireGuard. Returns false when it could not even be
  /// started, in which case the caller proceeds with the stealth profile.
  Future<bool> _startWireGuard(WgServer server) async {
    final wg = _wgProfile;
    if (wg == null) return false;
    final keys = await WgIdentity.load();
    if (keys == null || !WgSingboxConfig.usableKey(keys.privateKey)) {
      return false;
    }
    try {
      final config = WgSingboxConfig.buildJson(
        profile: wg,
        server: server,
        privateKey: keys.privateKey,
        killSwitch: _prefs.killSwitch,
      );
      final label = server.label.isEmpty ? server.host : server.label;
      final ok = await VpnController.start(config, label: label);
      if (!ok) return false;
      _path = TunnelPath.speed;
      _fallback = SpeedFallbackReason.none;
      return true;
    } catch (_) {
      // A core that refuses the WireGuard config must not cost the user their
      // connection; the stealth path is tried right after.
      return false;
    }
  }

  /// Watch a freshly started WireGuard tunnel for proof that the handshake
  /// completed, and switch to stealth if it did not.
  ///
  /// The signal is the downlink byte counter: a blocked tunnel still sends
  /// (handshake initiations go out into the void) but never receives, while a
  /// working one has inbound bytes within a second or two, because the IP
  /// refresh this connect already kicked off generates traffic. See
  /// [WgHandshakeMemory] for the full reasoning.
  Future<void> _probeWireGuard(int generation, ProxyProfile stealth) async {
    await Future<void>.delayed(WgHandshakeMemory.probeWindow);
    // A disconnect or another connect happened meanwhile: this probe is stale.
    if (generation != _connectGeneration) return;
    if (_path != TunnelPath.speed || _conn != ConnState.connected) return;
    final stats = await VpnController.stats();
    if (!WgHandshakeMemory.looksBlocked(downlinkTotal: stats.downlinkTotal)) {
      _wgBlocked.markWorking(_networkId);
      return;
    }
    if (generation != _connectGeneration) return;
    // WireGuard is blocked on this network. Remember it so the next connect
    // here skips the probe entirely, then move to stealth without asking.
    _wgBlocked.markBlocked(_networkId);
    _fallback = SpeedFallbackReason.blocked;
    _path = TunnelPath.stealth;
    notifyListeners();
    try {
      await VpnController.stop();
      final config = SingboxConfig.buildJson(
        stealth,
        killSwitch: _prefs.killSwitch,
      );
      await VpnController.start(config, label: stealth.name);
      _startStatusPoll();
      _conn = ConnState.connected;
      notifyListeners();
      _refreshIpAfterToggle();
    } catch (e) {
      _setError('Failed to connect: $e');
    }
  }

  /// A key for "the network the device is on right now".
  ///
  /// The app has no connectivity plugin, and adding one for this alone is not
  /// worth a native dependency. What it does have is the user's real public IP,
  /// which [refreshIp] keeps current while disconnected: two different networks
  /// almost never share one, and a device that moves between networks gets a
  /// new value. Null (never looked up, or offline) simply means no memory is
  /// kept, so WireGuard is retried, which is the safe direction.
  String? get _networkId => _publicIp;

  /// Connect/disconnect flips the route table a moment AFTER the platform
  /// call returns (on iOS the extension boots asynchronously), so a single
  /// immediate lookup usually still travels the old path and shows the old
  /// address. Poll until the address actually changes, then stop; give up
  /// quietly after a few attempts so a flaky lookup can't spin forever.
  Future<void> _refreshIpAfterToggle() async {
    final before = _publicIp;
    for (var attempt = 0; attempt < 6; attempt++) {
      await refreshIp();
      if (_publicIp != null && _publicIp != before) return;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
  }

  Future<void> refreshIp() async {
    _ipLoading = true;
    notifyListeners();
    final ip = await IpLookup.current();
    _publicIp = ip;
    _ipLoading = false;
    notifyListeners();
    if (!isConnected) {
      final geo = await IpLookup.locate();
      if (geo != null && !isConnected) {
        _userGeo = geo;
        notifyListeners();
      }
    }
  }

  // --- internals -------------------------------------------------------------

  void _startStatusPoll() {
    _statusPoll?.cancel();
    _statusPoll = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _syncStatus(),
    );
  }

  Future<void> _syncStatus({bool initial = false}) async {
    final s = await VpnController.status();
    if (s.alwaysOn != _systemAlwaysOn) {
      _systemAlwaysOn = s.alwaysOn;
      notifyListeners();
    }
    if (s.error != null && s.error!.isNotEmpty) {
      // On the initial cold-start reconcile, a native error while nothing is
      // running is stale (left over from a previous session); discard it.
      if (initial && !s.running) return;
      _setError(s.error!);
      _statusPoll?.cancel();
      return;
    }
    final newState = s.running ? ConnState.connected : ConnState.disconnected;
    if (newState != _conn && _conn != ConnState.connecting) {
      _conn = newState;
      if (newState == ConnState.connected) {
        Haptics.success();
        _connectedAt ??= DateTime.now();
        _startStatusPoll();
      }
      if (newState == ConnState.disconnected) {
        _statusPoll?.cancel();
        _stats = VpnStats.zero;
        _connectedAt = null;
      }
      notifyListeners();
      refreshIp();
    }

    // While connected, refresh live traffic counters each tick.
    if (_conn == ConnState.connected) {
      _stats = await VpnController.stats();
      notifyListeners();
    }
  }

  void _setError(String msg) {
    _conn = ConnState.error;
    _error = msg;
    Haptics.error();
    notifyListeners();
  }

  Future<void> _persist() async {
    await ProfileStore.save(_profiles);
    await ProfileStore.saveSelectedIndex(_selected);
  }

  // --- 1.1.1, servers: editing in place ---------------------------------------

  /// Puts [next] where the profile at [index] sits, keeping what the user
  /// added to the old one: its position, its custom name (unless [next]
  /// carries one), the subscription it belongs to, and the selection. The
  /// geolocated place is carried over while the address is the same and
  /// looked up again when it changed. Managed hideip.net profiles are never
  /// edited, so a request against one is ignored.
  Future<void> replaceProfile(int index, ProxyProfile next) async {
    if (index < 0 || index >= _profiles.length) return;
    final old = _profiles[index];
    if (old.premium) return;
    final sameAddress = old.server == next.server;
    // A name that places itself (a city or country token) makes the old
    // lookup moot; otherwise it still describes the same address.
    final keepGeo = sameAddress && !Location.derive(next, index).placed;
    var merged = next.copyWith(
      subUrl: next.subUrl ?? old.subUrl,
      customName: next.customName ?? old.customName,
      ccOverride: old.ccOverride,
      cityOverride: old.cityOverride,
    );
    if (keepGeo) merged = merged.copyWith(cc: old.cc, city: old.city);
    _profiles[index] = merged;
    await _persist();
    notifyListeners();
    pingAll();
    _backfillGeo();
  }

  /// Sets where the server at [index] is, by the user's word: the country
  /// and, when given, the city. A null [cc] returns to the detected place.
  /// A name the importer suggested from the old place is suggested again
  /// from the new one, numbered against the rest of the list; a name the
  /// user typed or the provider sent is left alone.
  Future<void> setServerLocation(int index, {String? cc, String? city}) async {
    if (index < 0 || index >= _profiles.length) return;
    final old = _profiles[index];
    if (old.premium) return;
    final code = Location.validCc(cc) ? cc!.toUpperCase() : null;
    final town = code == null ? null : city?.trim();
    var next = old.copyWith(
      ccOverride: code,
      cityOverride: town == null || town.isEmpty ? null : town,
    );
    final before = Location.placeSuggestion(old);
    final unnamed =
        SrvNaming.isFallback(old.name, host: old.server, port: old.port);
    if (unnamed || (before != null && SrvNaming.isSuggested(old.name, before))) {
      final base = Location.placeSuggestion(next) ??
          '${next.server}:${next.port}';
      next = next.copyWith(name: SrvNaming.numbered(base, _labelsExcept(index)));
    }
    _profiles[index] = next;
    await _persist();
    notifyListeners();
  }

  /// The labels of every server but the one at [index], which is what a
  /// suggested name must stay clear of.
  Iterable<String> _labelsExcept(int index) => [
        for (final l in locations)
          if (l.index != index) l.label,
      ];
}
