import 'package:shared_preferences/shared_preferences.dart';

/// Which palette the app paints in. Three states, not a switch: "System"
/// follows the phone, and it is the setting most people never touch.
enum AppThemeMode { light, dark, system }

/// Small persisted UI preferences for the redesign (all default false except
/// nothing; the app starts in Simple view, on the onboarding flow).
class UiPrefs {
  static const _kAdvanced = 'ui_advanced_v1';
  static const _kOnboarded = 'ui_onboarded_v1';
  static const _kAutoConnect = 'ui_autoconnect_v1';
  static const _kAutoSelect = 'ui_autoselect_v1';
  // Superseded by _kThemeMode; still read once so an install that had dark
  // mode on keeps it after the update.
  static const _kDarkMode = 'ui_darkmode_v1';
  static const _kThemeMode = 'ui_thememode_v1';
  static const _kHomeMap = 'ui_homemap_v1';
  static const _kAlwaysOn = 'ui_alwayson_v1';
  static const _kKillSwitch = 'ui_killswitch_v1';
  static const _kSpeedMode = 'ui_speedmode_v1';
  static const _kUsageCounts = 'ui_usagecounts_v1';
  static const _kVpnPermAsked = 'ui_vpnpermasked_v1';
  static const _kNotifAsked = 'ui_notifasked_v1';
  static const _kConnAlerts = 'ui_connalerts_v1';
  static const _kVotingNotifs = 'ui_votingnotifs_v1';
  static const _kUpsellSnooze = 'ui_upsellsnooze_v1';
  static const _kRecents = 'ui_recents_v1';
  static const _kWonClaimed = 'ui_won_claimed_v1';
  static const _kVotePrimer = 'ui_vote_primer_v1';
  static const _kComingNext = 'ui_comingnext_v1';

  /// How many recently used locations are remembered. Home shows at most a
  /// handful of them; the rest is the tail that lets one dropped server fall
  /// off the list without emptying it.
  static const maxRecents = 8;

  final bool advanced;
  final bool onboarded;
  final bool autoConnect;
  final bool autoSelect;
  final AppThemeMode themeMode;
  final bool homeMap; // home shows the map view instead of the server list
  // Opt-in for Android's Always-on VPN: when true the native service may
  // reconnect the last server on a system-initiated start.
  final bool alwaysOn;
  // Kill switch: don't leak to the physical network if the tunnel drops.
  // Android: strict routing + the service reconnects (keeping the TUN up)
  // when the core dies; iOS: on-demand rules (the system redials itself).
  final bool killSwitch;

  // Speed mode: use WireGuard instead of the stealth protocol where the
  // network allows it. Off by default, because stealth is the promise the app
  // is built on and WireGuard is the optional upgrade on top of it.
  final bool speedMode;

  // Anonymous usage counts: three one-shot events with no identifier (see
  // docs/app-events-api.md). On by default because nothing about the user is
  // in them; the switch exists so that stays the user's call, not ours.
  final bool usageCounts;

  /// Whether the system VPN consent dialog has ever been put up on this
  /// install. What it gates is the pre-prompt before the first Connect: that
  /// explanation is shown once and then never again, whatever the answer was.
  final bool vpnPermAsked;

  /// Same idea for notifications: the system dialog is offered once.
  final bool notifAsked;

  /// Notify when the tunnel drops without being asked to.
  final bool connAlerts;

  /// Notify when a location this device voted for goes live.
  final bool votingNotifs;

  /// Epoch milliseconds until which the Speed mode upsell row on Home stays
  /// hidden. Dismissing it snoozes it for fourteen days; zero means it has
  /// never been dismissed.
  final int upsellSnoozeUntil;

  /// Locations the user picked, most recent first, capped at [maxRecents].
  /// Stored as `Location.id` (`host:port`), which survives a subscription
  /// refresh reordering the list.
  final List<String> recents;

  /// Locations whose winner trophy has already been collected: the user
  /// connected there once, which is what turns the reward back into an
  /// ordinary server. Stored as `Location.id`, same as [recents].
  final Set<String> wonClaimed;

  /// Whether the notification explanation after the first vote has been
  /// offered. Once per install, whatever the answer was.
  final bool votePrimerSeen;

  /// Whether the Coming next section on Locations is unfolded. Closed by
  /// default; it stays the way the user last left it.
  final bool comingNextOpen;

  const UiPrefs({
    this.advanced = false,
    this.onboarded = false,
    this.autoConnect = false,
    this.autoSelect = true,
    this.themeMode = AppThemeMode.system,
    this.homeMap = false,
    this.alwaysOn = false,
    this.killSwitch = false,
    this.speedMode = false,
    this.usageCounts = true,
    this.vpnPermAsked = false,
    this.notifAsked = false,
    this.connAlerts = true,
    this.votingNotifs = false,
    this.upsellSnoozeUntil = 0,
    this.recents = const [],
    this.wonClaimed = const {},
    this.votePrimerSeen = false,
    this.comingNextOpen = false,
  });

  /// [recents] with [id] moved to the front, deduplicated and capped. The
  /// same location picked twice is one entry, not two.
  static List<String> pushRecent(List<String> recents, String id) => [
        id,
        ...recents.where((e) => e != id),
      ].take(maxRecents).toList();

  /// Whether the Speed mode upsell may show right now.
  bool upsellAllowed(DateTime now) =>
      now.millisecondsSinceEpoch >= upsellSnoozeUntil;

  UiPrefs copyWith({
    bool? advanced,
    bool? onboarded,
    bool? autoConnect,
    bool? autoSelect,
    AppThemeMode? themeMode,
    bool? homeMap,
    bool? alwaysOn,
    bool? killSwitch,
    bool? speedMode,
    bool? usageCounts,
    bool? vpnPermAsked,
    bool? notifAsked,
    bool? connAlerts,
    bool? votingNotifs,
    int? upsellSnoozeUntil,
    List<String>? recents,
    Set<String>? wonClaimed,
    bool? votePrimerSeen,
    bool? comingNextOpen,
  }) =>
      UiPrefs(
        advanced: advanced ?? this.advanced,
        onboarded: onboarded ?? this.onboarded,
        autoConnect: autoConnect ?? this.autoConnect,
        autoSelect: autoSelect ?? this.autoSelect,
        themeMode: themeMode ?? this.themeMode,
        homeMap: homeMap ?? this.homeMap,
        alwaysOn: alwaysOn ?? this.alwaysOn,
        killSwitch: killSwitch ?? this.killSwitch,
        speedMode: speedMode ?? this.speedMode,
        usageCounts: usageCounts ?? this.usageCounts,
        vpnPermAsked: vpnPermAsked ?? this.vpnPermAsked,
        notifAsked: notifAsked ?? this.notifAsked,
        connAlerts: connAlerts ?? this.connAlerts,
        votingNotifs: votingNotifs ?? this.votingNotifs,
        upsellSnoozeUntil: upsellSnoozeUntil ?? this.upsellSnoozeUntil,
        recents: recents ?? this.recents,
        wonClaimed: wonClaimed ?? this.wonClaimed,
        votePrimerSeen: votePrimerSeen ?? this.votePrimerSeen,
        comingNextOpen: comingNextOpen ?? this.comingNextOpen,
      );

  static Future<UiPrefs> load() async {
    final p = await SharedPreferences.getInstance();
    return UiPrefs(
      advanced: p.getBool(_kAdvanced) ?? false,
      onboarded: p.getBool(_kOnboarded) ?? false,
      autoConnect: p.getBool(_kAutoConnect) ?? false,
      autoSelect: p.getBool(_kAutoSelect) ?? true,
      themeMode: _readThemeMode(p),
      homeMap: p.getBool(_kHomeMap) ?? false,
      alwaysOn: p.getBool(_kAlwaysOn) ?? false,
      killSwitch: p.getBool(_kKillSwitch) ?? false,
      speedMode: p.getBool(_kSpeedMode) ?? false,
      usageCounts: p.getBool(_kUsageCounts) ?? true,
      vpnPermAsked: p.getBool(_kVpnPermAsked) ?? false,
      notifAsked: p.getBool(_kNotifAsked) ?? false,
      connAlerts: p.getBool(_kConnAlerts) ?? true,
      votingNotifs: p.getBool(_kVotingNotifs) ?? false,
      upsellSnoozeUntil: p.getInt(_kUpsellSnooze) ?? 0,
      recents: p.getStringList(_kRecents) ?? const [],
      wonClaimed: (p.getStringList(_kWonClaimed) ?? const []).toSet(),
      votePrimerSeen: p.getBool(_kVotePrimer) ?? false,
      comingNextOpen: p.getBool(_kComingNext) ?? false,
    );
  }

  /// The three-state theme, falling back to the old boolean once. An install
  /// that had dark mode on lands on [AppThemeMode.dark]; everyone else lands
  /// on System, which is what the design asks for as the default.
  static AppThemeMode _readThemeMode(SharedPreferences p) {
    final stored = p.getString(_kThemeMode);
    for (final mode in AppThemeMode.values) {
      if (mode.name == stored) return mode;
    }
    return (p.getBool(_kDarkMode) ?? false)
        ? AppThemeMode.dark
        : AppThemeMode.system;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kAdvanced, advanced);
    await p.setBool(_kOnboarded, onboarded);
    await p.setBool(_kAutoConnect, autoConnect);
    await p.setBool(_kAutoSelect, autoSelect);
    await p.setString(_kThemeMode, themeMode.name);
    await p.setBool(_kHomeMap, homeMap);
    await p.setBool(_kAlwaysOn, alwaysOn);
    await p.setBool(_kKillSwitch, killSwitch);
    await p.setBool(_kSpeedMode, speedMode);
    await p.setBool(_kUsageCounts, usageCounts);
    await p.setBool(_kVpnPermAsked, vpnPermAsked);
    await p.setBool(_kNotifAsked, notifAsked);
    await p.setBool(_kConnAlerts, connAlerts);
    await p.setBool(_kVotingNotifs, votingNotifs);
    await p.setInt(_kUpsellSnooze, upsellSnoozeUntil);
    await p.setStringList(_kRecents, recents);
    await p.setStringList(_kWonClaimed, wonClaimed.toList());
    await p.setBool(_kVotePrimer, votePrimerSeen);
    await p.setBool(_kComingNext, comingNextOpen);
  }
}
