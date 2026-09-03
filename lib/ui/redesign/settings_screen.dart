import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/notifications.dart';
import '../../core/premium.dart';
import '../../core/ui_prefs.dart';
import '../../state/app_state.dart';
import '../../vpn_controller.dart';
import '../strings.dart';
import 'hip.dart';
import 'hip_sheet.dart';
import 'paywall_screen.dart';
import 'shell.dart';

bool get _isIos => defaultTargetPlatform == TargetPlatform.iOS;
bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

const _privacyUrl = 'https://hideip.net/privacy';
String get _termsUrl => _isIos
    ? 'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/'
    : 'https://hideip.net/terms';

void _openUrl(String url) =>
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

/// A flat gray tile. The blue one is reserved for flags and for Premium.
Widget _grayTile(IconData icon) => Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: Hip.line2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, size: 19, color: Hip.inkSoft),
    );

Widget _chevron() => Icon(Icons.chevron_right, size: 17, color: Hip.muted2);

/// A section header: a small outlined icon, muted, in front of the label.
///
/// [HipSectionLabel] alone is a text-only header; Settings has grown enough
/// sections that the eye needs a shape to catch mid-scroll, not just a word
/// in caps. Same padding and type as [HipSectionLabel] so the two would sit
/// flush if one ever appeared without the other.
class SettingsSectionHeader extends StatelessWidget {
  final IconData icon;
  final String text;
  const SettingsSectionHeader(this.icon, this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 7),
      child: Row(children: [
        Icon(icon, size: 15, color: Hip.muted2),
        const SizedBox(width: 6),
        Text(text.toUpperCase(),
            style: Hip.sans(650, Hip.captionSize,
                color: Hip.muted2, letterSpacing: .91)),
      ]),
    );
  }
}

/// A list-row subtitle where every fragment in [mono] is set in the mono
/// face and the sentence around it stays in the body face.
///
/// The billing lines are framed by `S` and filled in by the store, so the
/// two are put back together at render time instead of being concatenated
/// into a constant: a translation can move the date to the front of the line
/// and it still comes out mono. A fragment that is not in [line] is skipped,
/// which is what a reordered translation does to one that no longer fits.
InlineSpan monoWithin(String line, List<String> mono) {
  final words = Hip.sans(400, Hip.bodySize, color: Hip.muted);
  final numbers = Hip.mono(600, 12.5, color: Hip.muted);
  final pending = [
    for (final m in mono)
      if (m.isNotEmpty) m,
  ];
  final spans = <InlineSpan>[];
  var rest = line;
  while (pending.isNotEmpty) {
    var at = -1;
    var pick = -1;
    for (var i = 0; i < pending.length; i++) {
      final found = rest.indexOf(pending[i]);
      if (found < 0) continue;
      if (at < 0 || found < at) {
        at = found;
        pick = i;
      }
    }
    if (pick < 0) break;
    final fragment = pending.removeAt(pick);
    if (at > 0) {
      spans.add(TextSpan(text: rest.substring(0, at), style: words));
    }
    spans.add(TextSpan(text: fragment, style: numbers));
    rest = rest.substring(at + fragment.length);
  }
  if (rest.isNotEmpty) spans.add(TextSpan(text: rest, style: words));
  return TextSpan(children: spans);
}

/// Three-way palette switch: Light, Dark, or whatever the system says.
///
/// A two-state switch cannot express the default, and the default is what
/// most people never change. Plain parameters so the control can be driven
/// and read without any app state behind it.
class ThemeSegment extends StatelessWidget {
  final AppThemeMode mode;
  final ValueChanged<AppThemeMode> onChanged;
  const ThemeSegment({super.key, required this.mode, required this.onChanged});

  static const _labels = {
    AppThemeMode.light: S.setThemeLight,
    AppThemeMode.dark: S.setThemeDark,
    AppThemeMode.system: S.setThemeSystem,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 300),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Hip.line2,
        border: Border.all(color: Hip.line),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(children: [
        for (final entry in _labels.entries)
          Expanded(
            child: Semantics(
              button: true,
              selected: mode == entry.key,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(entry.key),
                child: AnimatedContainer(
                  duration: Hip.dur(const Duration(milliseconds: 180)),
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: mode == entry.key ? Hip.card : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: mode == entry.key
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: .14),
                              blurRadius: 3,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(entry.value,
                      style: Hip.sans(600, 13,
                          color: mode == entry.key ? Hip.ink : Hip.muted)),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// The Speed mode row for a subscriber.
///
/// The toggle never moves on its own. With all five device slots taken it
/// stays where it is and the sheet does the explaining; a switch that flips
/// and springs back reads as a bug, not as a limit.
class SpeedModeRow extends StatelessWidget {
  final bool speedMode;
  final bool deviceLimit;

  /// Called only when the change is allowed to happen.
  final ValueChanged<bool> onChanged;

  /// Called instead, when turning it on would need a sixth device slot.
  final VoidCallback onDeviceLimit;

  const SpeedModeRow({
    super.key,
    required this.speedMode,
    required this.deviceLimit,
    required this.onChanged,
    required this.onDeviceLimit,
  });

  @override
  Widget build(BuildContext context) {
    return HipListRow(
      title: S.tSpeed,
      titleBadge: HipBadge.blue(S.setBadgeNew),
      subtitle: S.setSpeedSub,
      trailing: HipToggle(
        on: speedMode && !deviceLimit,
        onChanged: (v) {
          if (v && deviceLimit) {
            onDeviceLimit();
            return;
          }
          onChanged(v);
        },
      ),
    );
  }
}

/// The two things this app may ever notify about.
///
/// Three permission states, three shapes: never asked gets a pre-prompt
/// before the system dialog, allowed gets the switches, refused gets one calm
/// line and a way into system settings.
class NotificationRows extends StatelessWidget {
  final NotifPerm perm;
  final bool connAlerts;
  final bool votingNotifs;
  final ValueChanged<bool> onConnAlerts;
  final ValueChanged<bool> onVoting;

  /// Turning voting updates on while nobody has ever been asked: the
  /// pre-prompt explains first, the system dialog follows only if they agree.
  final VoidCallback onPrePrompt;
  final VoidCallback onOpenSettings;

  const NotificationRows({
    super.key,
    required this.perm,
    required this.connAlerts,
    required this.votingNotifs,
    required this.onConnAlerts,
    required this.onVoting,
    required this.onPrePrompt,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final blocked = perm == NotifPerm.denied;
    Widget row(String title, String sub, bool on, ValueChanged<bool> onSet) =>
        HipListRow(
          title: title,
          subtitle: blocked ? S.setNotifBlocked : sub,
          trailing: blocked
              ? _MiniButton(S.aOpenSettings, onTap: onOpenSettings)
              : HipToggle(on: on, onChanged: onSet),
        );
    return HipListGroup(children: [
      row(S.notifConnTitle, S.notifConnBody, connAlerts, onConnAlerts),
      row(S.notifVoteTitle, S.notifVoteBody, votingNotifs, (v) {
        if (v && perm == NotifPerm.ask) {
          onPrePrompt();
          return;
        }
        onVoting(v);
      }),
    ]);
  }
}

/// A small bordered action inside a list row (app.css `.minibtn`).
class _MiniButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _MiniButton(this.label, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: Hip.line2,
            border: Border.all(color: Hip.line, width: 1.5),
            borderRadius: BorderRadius.circular(11),
          ),
          child:
              Text(label, style: Hip.sans(650, 12.5, color: Hip.ink)),
        ),
      ),
    );
  }
}

/// The card that sells, shown only while there is no subscription. Selling
/// stops the moment someone has paid: that is part of what they bought.
class PremiumSalesCard extends StatelessWidget {
  final String yearlyPrice;
  final VoidCallback onTap;
  const PremiumSalesCard(
      {super.key, required this.yearlyPrice, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final legal = S.setSellLegal(yearlyPrice).split('|');
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Hip.blueSoft,
        border: Border.all(color: Hip.blue.withValues(alpha: .2), width: 1.5),
        borderRadius: BorderRadius.circular(Hip.radius),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const PremiumBadge(),
        const SizedBox(height: 11),
        Text(S.setSellTitle,
            style: Hip.sans(700, 17.5, color: Hip.ink, letterSpacing: -.39)),
        const SizedBox(height: 5),
        Text(S.setSellBody,
            style: Hip.sans(400, 13, color: Hip.muted, height: 1.5)),
        const SizedBox(height: 15),
        HipCta(S.setSellCta, onTap: onTap),
        const SizedBox(height: 9),
        Center(
          child: Text.rich(
            TextSpan(children: [
              for (var i = 0; i < legal.length; i++)
                TextSpan(
                  text: legal[i],
                  style: i.isOdd
                      ? Hip.mono(600, 12, color: Hip.muted2)
                      : Hip.sans(400, 12, color: Hip.muted2),
                ),
            ]),
            textAlign: TextAlign.center,
          ),
        ),
      ]),
    );
  }
}

/// Settings: Premium status, interface switches, connection behaviour,
/// notifications, and shortcuts.
class SettingsScreen extends StatefulWidget {
  final AppState state;
  final HipNav nav;
  const SettingsScreen({super.key, required this.state, required this.nav});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  /// What the system says about notifications. Re-read on resume, because
  /// the answer can change while the user is away in system settings.
  NotifPerm _perm = NotifPerm.ask;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _readPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _readPermission();
  }

  Future<void> _readPermission() async {
    final perm = await widget.state.notifPermission();
    if (mounted) setState(() => _perm = perm);
  }

  InlineSpan _premiumSubtitle(Premium p) => switch (p.status) {
        PremiumStatus.trial => monoWithin(
            S.setPremiumTrial(formatPremiumDate(p.renews!)),
            [formatPremiumDate(p.renews!)]),
        PremiumStatus.active => monoWithin(
            S.setPremiumActive(
                PlanInfo.of(p.plan!).name, formatPremiumDate(p.renews!)),
            [formatPremiumDate(p.renews!)]),
        PremiumStatus.expired => monoWithin(S.setPremiumEnded, const []),
        PremiumStatus.none => monoWithin(S.setPremiumNone, const []),
      };

  /// The subscription already covers five devices. An explanation with an
  /// action, not a notice in passing, so it gets a sheet.
  Future<void> _deviceLimitSheet() => widget.nav.showSheet<void>([
        const HipSheetTitle(S.f5Title),
        const HipSheetBody(S.f5Body),
        HipSheetActions(children: [
          Builder(
            builder: (c) =>
                HipCta(S.aClose, onTap: () => Navigator.of(c).pop()),
          ),
        ]),
      ]);

  Future<void> _askNotifications() async {
    final go = await widget.nav.showSheet<bool>([
      const HipSheetTitle(S.c4Title),
      const HipSheetBody(S.c4Body),
      HipSheetActions(children: [
        Builder(
          builder: (c) => HipCta(S.setNotifAllow,
              connect: true, onTap: () => Navigator.of(c).pop(true)),
        ),
        Builder(
          builder: (c) => HipCta(S.aNotNow,
              quiet: true, onTap: () => Navigator.of(c).pop(false)),
        ),
      ]),
    ]);
    if (go != true) return;
    final result = await widget.state.requestNotifPermission();
    if (!mounted) return;
    setState(() => _perm = result);
    if (result == NotifPerm.granted) {
      await widget.state
          .updatePrefs(widget.state.prefs.copyWith(votingNotifs: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final nav = widget.nav;
    final prefs = state.prefs;
    final premium = state.premium;
    // The plans catalog has to be live for this platform before anything may
    // advertise a purchase; an existing subscriber keeps their Premium row
    // regardless (plansOffered stays true while premium is on).
    final sellable = kPlansAvailable && state.plansOffered;
    final active = state.activeLocation;
    return SafeArea(
      child: Column(children: [
        HipNavHead(title: S.tSettings, onBack: () => nav.go(HipScreen.home)),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              if (sellable && premium.status == PremiumStatus.none)
                PremiumSalesCard(
                  yearlyPrice: state.planInfo(PremiumPlan.yearly).price,
                  onTap: () => nav.openPaywall(from: HipScreen.settings),
                )
              else if (sellable) ...[
                const SettingsSectionHeader(Icons.person_outline, S.setAccount),
                HipListGroup(children: [
                  HipListRow(
                    leading: const HipFlag(cc: '', child: PremiumCubeIcon()),
                    title: S.tPremium,
                    titleBadge:
                        premium.isOn ? HipBadge.ok(S.setPremiumOn) : null,
                    subtitleSpan: _premiumSubtitle(premium),
                    trailing: _chevron(),
                    onTap: () => nav.go(HipScreen.premium),
                  ),
                  // Only a phone that actually holds a provisioned
                  // subscription can hand access to anything else, so the row
                  // appears with the token rather than with the entitlement.
                  if (state.canLinkDevices)
                    HipListRow(
                      leading: _grayTile(Icons.devices_outlined),
                      title: S.setLinkedDevices,
                      subtitle: S.setLinkedDevicesSub,
                      trailing: _chevron(),
                      onTap: () => nav.go(HipScreen.linkedDevices),
                    ),
                ]),
              ],
              const SettingsSectionHeader(Icons.tune_outlined, S.setInterface),
              HipListGroup(children: [
                _ThemeRow(
                  mode: prefs.themeMode,
                  onChanged: state.setThemeMode,
                ),
                HipListRow(
                  leading: _grayTile(Icons.visibility_outlined),
                  title: S.setAdvanced,
                  subtitle: S.setAdvancedSub,
                  trailing: HipToggle(
                    on: prefs.advanced,
                    onChanged: (v) =>
                        state.updatePrefs(prefs.copyWith(advanced: v)),
                  ),
                ),
              ]),
              const SettingsSectionHeader(Icons.bolt_outlined, S.setConnection),
              HipListGroup(children: [
                HipListRow(
                  title: S.setAutoConnect,
                  trailing: HipToggle(
                    on: prefs.autoConnect,
                    onChanged: (v) =>
                        state.updatePrefs(prefs.copyWith(autoConnect: v)),
                  ),
                ),
                HipListRow(
                  title: S.tKill,
                  // Android holds the TUN up through a drop (traffic is
                  // blocked, not leaked); iOS can only redial via on-demand.
                  subtitle: _isAndroid ? S.setKillSub : S.setKillSubIos,
                  trailing: HipToggle(
                    on: prefs.killSwitch,
                    onChanged: (v) async {
                      await state.updatePrefs(prefs.copyWith(killSwitch: v));
                      if (state.isConnected) state.showToast(S.setKillLater);
                    },
                  ),
                ),
                // Speed mode rides on the hideip.net fleet, which is what the
                // subscription pays for. The copy says "hideip.net locations"
                // on purpose: WireGuard itself is free, anyone can import
                // their own through Add connection.
                if (premium.isOn)
                  SpeedModeRow(
                    speedMode: prefs.speedMode,
                    deviceLimit: state.speedDeviceLimit,
                    onDeviceLimit: _deviceLimitSheet,
                    onChanged: (v) async {
                      await state.setSpeedMode(v);
                      if (!mounted) return;
                      // The first attempt is what discovers a full account.
                      if (v && state.speedDeviceLimit) {
                        await _deviceLimitSheet();
                      } else if (v && state.isConnected) {
                        state.showToast(S.setSpeedLater);
                      }
                    },
                  )
                else if (sellable)
                  HipListRow(
                    title: S.tSpeed,
                    titleBadge: HipBadge.blue(S.setBadgeNew),
                    // The second clause matters: a lock next to the word
                    // WireGuard would otherwise read as "WireGuard is paid".
                    subtitle: S.setSpeedLocked,
                    trailing:
                        Icon(Icons.lock_outline, size: 17, color: Hip.muted2),
                    onTap: () => nav.openPaywall(from: HipScreen.settings),
                  ),
                // Advanced view adds the one row that explains how a server
                // is picked and what it runs. The prototype prints a fixed
                // failover chain; this app has no failover order, so the row
                // names the protocol actually in use instead of inventing one.
                if (prefs.advanced && active != null)
                  HipListRow(
                    title: S.setRouting,
                    subtitle: S.setRoutingSub(
                        prefs.autoSelect ? S.tAuto : active.label,
                        active.protoLabel),
                    trailing: _chevron(),
                    onTap: () => nav.openDetail(active),
                  ),
                if (_isAndroid) _AndroidAlwaysOnRows(state: state),
              ]),
              const _LeftSubnote(S.setSpeedNote),
              const SettingsSectionHeader(
                  Icons.notifications_outlined, S.setNotifications),
              NotificationRows(
                perm: _perm,
                connAlerts: prefs.connAlerts,
                votingNotifs: prefs.votingNotifs,
                onConnAlerts: (v) =>
                    state.updatePrefs(prefs.copyWith(connAlerts: v)),
                onVoting: (v) =>
                    state.updatePrefs(prefs.copyWith(votingNotifs: v)),
                onPrePrompt: _askNotifications,
                onOpenSettings: Notifications.openSettings,
              ),
              const SettingsSectionHeader(
                  Icons.privacy_tip_outlined, S.setPrivacySection),
              HipListGroup(children: [
                HipListRow(
                  leading: _grayTile(Icons.bar_chart_outlined),
                  title: S.setUsage,
                  subtitle: S.setUsageSub,
                  trailing: HipToggle(
                    on: prefs.usageCounts,
                    onChanged: (v) =>
                        state.updatePrefs(prefs.copyWith(usageCounts: v)),
                  ),
                ),
              ]),
              const SettingsSectionHeader(Icons.dns_outlined, S.setConnections),
              HipListGroup(children: [
                HipListRow(
                  title: S.tAddConn,
                  subtitle: S.setAddConnSub,
                  trailing: _chevron(),
                  onTap: () => nav.openImport(),
                ),
                HipListRow(
                  title: S.setManageServers,
                  trailing: _chevron(),
                  onTap: () => nav.go(HipScreen.locations),
                ),
              ]),
              const SettingsSectionHeader(Icons.help_outline, S.setHelp),
              HipListGroup(children: [
                HipListRow(
                  title: S.setIntroAgain,
                  subtitle: S.setIntroAgainSub,
                  trailing: _chevron(),
                  onTap: () =>
                      nav.go(HipScreen.onboarding, const {'replay': true}),
                ),
                HipListRow(
                  title: S.setPrivacyPolicy,
                  trailing:
                      Icon(Icons.open_in_new, size: 16, color: Hip.muted2),
                  onTap: () => _openUrl(_privacyUrl),
                ),
                HipListRow(
                  title: S.setTerms,
                  trailing:
                      Icon(Icons.open_in_new, size: 16, color: Hip.muted2),
                  onTap: () => _openUrl(_termsUrl),
                ),
              ]),
              // Apple guideline 2.3.10: no other-platform mentions on iOS.
              HipSubnote(_isIos ? S.setFooter : S.setFooterBoth),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ]),
    );
  }
}

/// The Theme row: a title, the three-way segment, and one line saying what
/// the default does. Too tall for [HipListRow], same padding as one.
class _ThemeRow extends StatelessWidget {
  final AppThemeMode mode;
  final ValueChanged<AppThemeMode> onChanged;
  const _ThemeRow({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _grayTile(Icons.dark_mode_outlined),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(S.setTheme,
                style: Hip.sans(650, Hip.titleSize,
                    color: Hip.ink, letterSpacing: -.17)),
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 9, 0, 7),
              child: ThemeSegment(mode: mode, onChanged: onChanged),
            ),
            Text(S.setThemeNote,
                style: Hip.sans(400, Hip.bodySize, color: Hip.muted)),
          ]),
        ),
      ]),
    );
  }
}

/// A footnote that belongs to the list above it, so it reads from the left
/// rather than being centered under the screen.
class _LeftSubnote extends StatelessWidget {
  final String text;
  const _LeftSubnote(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 9, 14, 0),
        child: Text(text,
            style: Hip.sans(400, Hip.captionSize,
                color: Hip.muted2, height: 1.5)),
      );
}

/// The Always-on pair of rows (Android only): the in-app opt-in toggle and a
/// shortcut into the system VPN screen. Android gives no API to flip the
/// system's Always-on switch from an app, so the closest honest UX is showing
/// the live system state (the secure setting is readable) and walking the
/// user to the exact screen. Re-reads the state whenever the app resumes,
/// i.e. right after the user comes back from Android settings.
class _AndroidAlwaysOnRows extends StatefulWidget {
  final AppState state;
  const _AndroidAlwaysOnRows({required this.state});

  @override
  State<_AndroidAlwaysOnRows> createState() => _AndroidAlwaysOnRowsState();
}

class _AndroidAlwaysOnRowsState extends State<_AndroidAlwaysOnRows>
    with WidgetsBindingObserver {
  VpnStatus? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final st = await VpnController.status();
    if (mounted) setState(() => _status = st);
  }

  String get _systemSubtitle {
    final st = _status;
    if (st == null) return S.setVpnChecking;
    if (!st.alwaysOn) return S.setVpnOff;
    return st.lockdown ? S.setVpnOnLockdown : S.setVpnOn;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final prefs = state.prefs;
    return Column(children: [
      HipListRow(
        title: S.setAlwaysOn,
        subtitle: S.setAlwaysOnSub,
        trailing: HipToggle(
          on: prefs.alwaysOn,
          onChanged: (v) async {
            await state.updatePrefs(prefs.copyWith(alwaysOn: v));
            // The system half can only be flipped by the user in Android
            // settings; take them straight there when it is still off.
            if (v && _status?.alwaysOn != true) {
              state.showToast(S.setAlwaysOnHint);
              await VpnController.openVpnSettings();
            }
          },
        ),
      ),
      Container(height: 1, color: Hip.line2),
      HipListRow(
        title: S.setVpnSettings,
        subtitle: _systemSubtitle,
        trailing: _chevron(),
        onTap: VpnController.openVpnSettings,
      ),
    ]);
  }
}
