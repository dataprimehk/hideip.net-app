import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/country_names.dart';
import '../../core/location.dart';
import '../../core/ping.dart';
import '../../core/sub_info.dart';
import '../../core/votes.dart';
import '../../state/app_state.dart';
import '../brand.dart';
import '../strings.dart';
import 'detail_screen.dart';
import 'hip.dart';
import 'hip_sheet.dart';
import 'locked_row.dart';
import 'shell.dart';
import 'srv_edit.dart';

/// What the managed (hideip.net) group has to show right now.
enum ManagedGroup {
  /// A live subscription: the real servers.
  servers,

  /// No subscription: the catalog locations, with their measured latency and
  /// a padlock.
  locked,

  /// Subscribed, but the profiles have not landed yet.
  settingUp,

  /// The backend is finished with this subscription.
  ended,
}

/// What Locations keeps on the nav stack, so coming back from a detail screen
/// or the paywall restores the list the way the user left it.
class LocationsCtx {
  final bool allLocked;
  const LocationsCtx({this.allLocked = false});
}

/// The server list: Auto on top, the hideip.net group under it, the user's
/// own imports under "Your servers".
///
/// Ported from `LocationsScreen` in `design/app-1_1_0/screens-home.jsx`. The
/// two groups are separated by what runs them, never by name: a user is free
/// to call their own server "hideip" and it stays theirs.
class LocationsScreen extends StatefulWidget {
  final AppState state;
  final HipNav nav;
  const LocationsScreen({super.key, required this.state, required this.nav});

  @override
  State<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends State<LocationsScreen> {
  bool _allLocked = false;
  bool _winnerDismissed = false;

  @override
  void initState() {
    super.initState();
    final ctx = widget.nav.ctx();
    if (ctx is LocationsCtx) _allLocked = ctx.allLocked;
  }

  void _showAll() {
    setState(() => _allLocked = true);
    // Remembered on the stack: walking into a location and back must not
    // collapse the group again.
    widget.nav.go(HipScreen.locations, const LocationsCtx(allLocked: true));
  }

  Future<void> _select(Location? loc) async {
    await widget.state.selectLocation(loc);
    widget.nav.go(HipScreen.home);
    if (widget.state.isConnected) {
      // Changing servers mid-tunnel means a quick reconnect.
      await widget.state.disconnect();
      await widget.state.connect();
    }
  }

  int? _ping(Location l) {
    final r = widget.state.pingFor(l.profile);
    return r is PingOk ? r.ms : null;
  }

  /// The position of [l] right now: the list may have been reordered by a
  /// refresh since the row was built, so it is resolved by identity.
  int _indexOf(Location l) {
    final match = widget.state.locations.where((e) => e.id == l.id);
    return match.isEmpty ? l.index : match.first.index;
  }

  /// Behind the swipe's Edit: the importer, opened on this server's config.
  void _edit(Location l) {
    widget.nav.go(
      HipScreen.import,
      SrvEditCtx(
        index: _indexOf(l),
        id: l.id,
        label: serverLabel(l),
        text: srvEditText(l.profile),
      ),
    );
  }

  /// Behind the swipe's Delete: the same confirmation the detail screen
  /// asks, and the same fallback to Auto when the chosen server goes.
  Future<void> _confirmDelete(Location l) async {
    final name = serverLabel(l);
    final go = await showHipSheet<bool>(
      context,
      children: removeSwipedSheet(
        name: name,
        onCancel: () => Navigator.of(context).pop(false),
        onRemove: () => Navigator.of(context).pop(true),
      ),
    );
    if (go != true || !mounted) return;
    final state = widget.state;
    final index = _indexOf(l);
    final toAuto = removalFallsBackToAuto(
      autoSelect: state.prefs.autoSelect,
      selectedIndex: state.selectedIndex,
      removedIndex: index,
    );
    await state.remove(index);
    if (toAuto) await state.selectLocation(null);
    state.showToast(S.gRemoved(name));
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final nav = widget.nav;
    final subscribed = state.premium.isOn;
    final all = state.locations;
    final userLocs = [for (final l in all) if (!l.premium) l];
    final managedLocs = [for (final l in all) if (l.premium) l];

    // Locked catalog rows carry a real measurement, so the comparison the
    // paywall rests on is an honest one. Cheapest latency first, unmeasured
    // last.
    final locked = [...state.lockedLocations]
      ..sort((a, b) {
        final pa = _ping(a), pb = _ping(b);
        if (pa == null && pb == null) return 0;
        if (pa == null) return 1;
        if (pb == null) return -1;
        return pa.compareTo(pb);
      });

    final ManagedGroup group;
    if (subscribed && managedLocs.isNotEmpty) {
      group = ManagedGroup.servers;
    } else if (subscribed && state.premiumEnded) {
      group = ManagedGroup.ended;
    } else if (subscribed) {
      group = ManagedGroup.settingUp;
    } else {
      group = ManagedGroup.locked;
    }

    // Auto names the server it would pick, and where it comes from when there
    // is a mix to tell apart.
    Location? fastest;
    for (final l in all) {
      final ms = _ping(l);
      if (ms == null) continue;
      if (fastest == null || ms < _ping(fastest)!) fastest = l;
    }

    // The card for a location this install voted for. It stands until the
    // user acts on it or connects there.
    Location? winner;
    for (final l in [...all, ...locked]) {
      if (l.won) {
        winner = l;
        break;
      }
    }
    if (_winnerDismissed ||
        (state.isConnected && state.activeLocation?.id == winner?.id)) {
      winner = null;
    }

    final selected = all.where((l) => l.index == state.selectedIndex).toList();

    return LocationsBody(
      mix: state.mix,
      advanced: state.prefs.advanced,
      subscribed: subscribed,
      // The whole managed section rides on the plans catalog being live for
      // this platform; an existing subscriber keeps their servers regardless.
      showManagedSection: (kPlansAvailable && state.plansOffered) || subscribed,
      managedGroup: group,
      managed: managedLocs,
      locked: locked,
      userLocations: userLocs,
      allLockedShown: _allLocked,
      winner: winner,
      selectedId: state.prefs.autoSelect || selected.isEmpty
          ? null
          : selected.first.id,
      autoCity: fastest == null ? null : serverLabel(fastest),
      autoMs: fastest == null ? null : _ping(fastest),
      autoManaged: fastest?.premium ?? false,
      pingOf: _ping,
      levelOf: (l) => state.levelFor(l.profile),
      nameOf: serverLabel,
      subInfoOf: state.subInfoFor,
      onBack: () => nav.go(HipScreen.home),
      onSelect: _select,
      onManage: nav.openDetail,
      onEdit: _edit,
      onDelete: _confirmDelete,
      onLockedTap: (from, locId) =>
          nav.openPaywall(from: HipScreen.locations, locId: locId),
      onShowAll: _showAll,
      onSeePlans: () => nav.openPaywall(from: HipScreen.locations),
      onAdd: nav.openImport,
      onDismissWinner: () => setState(() => _winnerDismissed = true),
      onWinner: (l) => l.locked
          ? nav.openPaywall(from: HipScreen.locations, locId: l.id)
          : _select(l),
      footer: _VoteSection(onOpenMap: () {
        final prefs = state.prefs;
        if (!prefs.homeMap) {
          state.updatePrefs(prefs.copyWith(homeMap: true));
        }
        nav.go(HipScreen.home);
      }),
    );
  }
}

/// Everything Locations draws, from plain values.
///
/// The screen above owns the app state; this owns the layout, which is what
/// the three entitlement mixes actually change.
class LocationsBody extends StatelessWidget {
  final Mix mix;
  final bool advanced;
  final bool subscribed;
  final bool showManagedSection;
  final ManagedGroup managedGroup;

  /// Managed servers on a live subscription.
  final List<Location> managed;

  /// Catalog locations without a subscription, already sorted by latency.
  final List<Location> locked;

  final List<Location> userLocations;

  /// Whether the locked group is expanded past its first three rows.
  final bool allLockedShown;

  final Location? winner;

  /// The chosen server, or null for Auto.
  final String? selectedId;

  /// What Auto would pick right now.
  final String? autoCity;
  final int? autoMs;
  final bool autoManaged;

  final int? Function(Location) pingOf;
  final int Function(Location) levelOf;
  final String Function(Location) nameOf;
  final SubInfo? Function(String subUrl) subInfoOf;

  final VoidCallback onBack;
  final void Function(Location?) onSelect;
  final void Function(Location) onManage;

  /// The swipe actions on the user's own rows. Both or neither: with either
  /// missing the rows stay still, which is what a list with nothing to edit
  /// (a test fixture, a read-only mix) wants.
  final void Function(Location)? onEdit;
  final void Function(Location)? onDelete;
  final void Function(LockedFrom from, String locId) onLockedTap;
  final VoidCallback onShowAll;
  final VoidCallback onSeePlans;
  final VoidCallback onAdd;
  final VoidCallback onDismissWinner;
  final void Function(Location) onWinner;

  /// Anything that follows the two groups (the voting pointer).
  final Widget? footer;

  const LocationsBody({
    super.key,
    required this.mix,
    required this.advanced,
    required this.subscribed,
    required this.showManagedSection,
    required this.managedGroup,
    this.managed = const [],
    this.locked = const [],
    this.userLocations = const [],
    this.allLockedShown = false,
    this.winner,
    this.selectedId,
    this.autoCity,
    this.autoMs,
    this.autoManaged = false,
    required this.pingOf,
    required this.levelOf,
    required this.nameOf,
    required this.subInfoOf,
    required this.onBack,
    required this.onSelect,
    required this.onManage,
    this.onEdit,
    this.onDelete,
    required this.onLockedTap,
    required this.onShowAll,
    required this.onSeePlans,
    required this.onAdd,
    required this.onDismissWinner,
    required this.onWinner,
    this.footer,
  });

  /// The locked rows on show: the three fastest, until the group is expanded.
  /// A short catalog is never truncated, because there is nothing to reveal.
  List<Location> get _shownLocked =>
      allLockedShown || locked.length < 6 ? locked : locked.take(3).toList();

  int get _hiddenLocked => locked.length - _shownLocked.length;

  /// One of the user's own servers, or a managed one on a live subscription.
  Widget _serverRow(Location l) {
    final ms = pingOf(l);
    // The chevron into manage: always for the user's own servers, only in
    // Advanced view for the ones hideip.net runs (there is nothing on those
    // to rename, refresh or remove).
    final manageable = !l.premium || advanced;
    final row = HipListRow(
      leading: HipFlag(cc: l.cc),
      title: nameOf(l),
      titleBadge: l.won
          ? const _WonBadge()
          : l.premium
              ? (mix == Mix.hip ? null : HipBadge.blue('hideip.net'))
              : (l.provider != null ? HipBadge.blue(l.provider!) : null),
      subtitle: advanced
          ? S.tunnelChain(l.protoLabel, l.host)
          : ms == null
              ? l.country
              : S.lockedSub(l.country, ms),
      subtitleMono: advanced,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        // Speed mode only ever applies to the hideip.net fleet, and only a
        // mixed list has anything to tell apart.
        if (l.premium && mix == Mix.mixed) ...[
          Icon(Icons.bolt, size: 14, color: Hip.blueDeep),
          const SizedBox(width: 6),
        ],
        HipBars(level: levelOf(l)),
        SizedBox(
          width: 30,
          child: selectedId == l.id
              ? Icon(Icons.check, size: 18, color: Hip.blue)
              : null,
        ),
        if (manageable)
          _TapTarget(
            semanticLabel: S.dManage,
            onTap: () => onManage(l),
            child: Icon(Icons.chevron_right, size: 18, color: Hip.muted2),
          ),
      ]),
      onTap: () => onSelect(l),
    );
    // Only the user's own servers slide: a managed row has nothing on it to
    // edit or delete, so it does not move.
    final edit = onEdit, delete = onDelete;
    if (l.premium || edit == null || delete == null) return row;
    return HipSwipeRow(
      onEdit: () => edit(l),
      onDelete: () => delete(l),
      child: row,
    );
  }

  Widget _lockedRow(Location l) => LockedRow(
        location: l,
        from: LockedFrom.locationsLock,
        pingMs: pingOf(l),
        level: levelOf(l),
        advanced: advanced,
        onTap: onLockedTap,
      );

  /// The "Your servers" list, grouped: profiles that came from the same
  /// subscription URL sit under a compact header row (provider title, data
  /// used, expiry); everything else (single-link imports) stays flat above.
  /// Order follows first appearance so the list stays stable across refreshes.
  List<Widget> _userServers() {
    final loose = <Location>[]; // no subUrl: plain imports
    final grouped = <String, List<Location>>{}; // subUrl -> its locations
    final order = <String>[]; // subUrls in first-seen order
    for (final l in userLocations) {
      final u = l.profile.subUrl;
      if (u == null) {
        loose.add(l);
      } else {
        final group = grouped[u];
        if (group == null) {
          order.add(u);
          grouped[u] = [l];
        } else {
          group.add(l);
        }
      }
    }

    return [
      if (loose.isNotEmpty)
        HipListGroup(children: [for (final l in loose) _serverRow(l)]),
      for (final u in order) ...[
        _SubHeader(
          info: subInfoOf(u),
          fallbackHost: Uri.tryParse(u)?.host ?? u,
        ),
        HipListGroup(children: [for (final l in grouped[u]!) _serverRow(l)]),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final w = winner;
    final managedRows = switch (managedGroup) {
      ManagedGroup.servers => [for (final l in managed) _serverRow(l)],
      ManagedGroup.locked => [
          for (final l in _shownLocked) _lockedRow(l),
          if (_hiddenLocked > 0)
            _ShowAllRow(total: locked.length, onTap: onShowAll),
        ],
      ManagedGroup.settingUp => [
          HipListRow(
            leading: HipFlag(
              cc: '',
              child: SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Hip.blueDeep),
              ),
            ),
            title: S.dSettingUp,
            subtitle: S.dSettingUpSub,
          ),
        ],
      ManagedGroup.ended => [
          HipListRow(
            leading: HipFlag(
              cc: '',
              child: Icon(Icons.error_outline, size: 19, color: Hip.muted2),
            ),
            title: S.dExpired,
            subtitle: S.dExpiredSub,
          ),
        ],
    };

    return SafeArea(
      bottom: false,
      child: Column(children: [
        HipNavHead(
          title: S.tLocations,
          onBack: onBack,
          trailing: HipIconButton(Icons.add, onTap: onAdd),
        ),
        Expanded(
          child: HipSwipeArea(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                if (w != null)
                  _WinnerCard(
                    city: nameOf(w),
                    locked: w.locked,
                    onDismiss: onDismissWinner,
                    onAct: () => onWinner(w),
                  ),
                HipListGroup(children: [
                  HipListRow(
                    leading: HipFlag(
                        cc: '',
                        child: Icon(Icons.bolt_outlined,
                            size: 19, color: Hip.blueDeep)),
                    title: S.tAuto,
                    subtitle: autoCity == null || autoMs == null
                        ? S.d3AutoIdle
                        : S.autoSub(autoCity!, autoMs!,
                            managed: mix == Mix.mixed && autoManaged),
                    trailing: selectedId == null
                        ? Icon(Icons.check, size: 18, color: Hip.blue)
                        : const SizedBox(width: 18),
                    onTap: () => onSelect(null),
                  ),
                ]),
                if (showManagedSection) ...[
                  // The brand header and the tint are relational: they exist
                  // only while there is something to tell apart.
                  if (mix != Mix.hip) const _PremiumSectionHead(),
                  // Locked rows come from the public catalog; while there are
                  // none (no mirror reachable, or a build without the release
                  // key) the strip alone carries the offer. An empty box would
                  // only look broken.
                  if (managedRows.isNotEmpty)
                    _Group(tinted: mix == Mix.mixed, children: managedRows),
                  if (!subscribed) _PremiumStrip(onTap: onSeePlans),
                ],
                if (mix != Mix.hip) ...[
                  const HipSectionLabel(S.dYourServers),
                  if (userLocations.isEmpty)
                    HipCard(
                      child: Text(S.dNoServers,
                          style:
                              Hip.sans(400, 13.5, color: Hip.muted, height: 1.5)),
                    )
                  else
                    ..._userServers(),
                  if (userLocations.isNotEmpty) const HipSubnote(S.dNamesCleaned),
                ],
                ?footer,
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
              22, 14, 22, MediaQuery.paddingOf(context).bottom + 14),
          child: HipCta(
            S.tAddConn,
            ghost: true,
            leading: const Icon(Icons.add),
            onTap: onAdd,
          ),
        ),
      ]),
    );
  }
}

/// The confirmation behind a swiped row's Delete: the row's label on top,
/// one question, and what keeps working. Same shape as the detail screen's
/// sheet, so removing a server reads the same from either place.
List<Widget> removeSwipedSheet({
  required String name,
  required VoidCallback onCancel,
  required VoidCallback onRemove,
}) =>
    [
      HipSheetTitle(name),
      const HipSheetBody(S.srvRemoveAsk),
      const HipSheetBody(S.srvRemoveBody),
      HipSheetActions(children: [
        HipCta(S.aRemove, danger: true, ghost: true, onTap: onRemove),
        HipCta(S.aCancel, quiet: true, onTap: onCancel),
      ]),
    ];

/// A list group that can carry the brand tint (app.css `.lgroup.brandg`).
///
/// [HipListGroup] paints an opaque card, so the tinted variant cannot be a
/// wrapper around it; it repeats the group's own geometry instead, including
/// the slot each row needs to round the right corners.
class _Group extends StatelessWidget {
  final bool tinted;
  final List<Widget> children;
  const _Group({required this.tinted, required this.children});

  @override
  Widget build(BuildContext context) {
    if (!tinted) return HipListGroup(children: children);
    final tint =
        Hip.dm ? Brand.hsl(220, 95, 60, .07) : Brand.hsl(220, 95, 55, .045);
    final edge =
        Hip.dm ? Brand.hsl(220, 95, 60, .30) : Brand.hsl(220, 95, 55, .22);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: tint,
        border: Border.all(color: edge, width: 1.5),
        borderRadius: BorderRadius.circular(Hip.radius),
      ),
      child: Column(children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) Container(height: 1, color: Brand.hsl(220, 95, 55, .10)),
          HipRowSlot(
            first: i == 0,
            last: i == children.length - 1,
            child: children[i],
          ),
        ],
      ]),
    );
  }
}

/// "Show all N locations": expands the locked group in place, keeping the
/// order by latency (app.css `.lrow.showall`).
class _ShowAllRow extends StatelessWidget {
  final int total;
  final VoidCallback onTap;
  const _ShowAllRow({required this.total, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: HipRowSlot.cornersOf(context),
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(children: [
          Expanded(
            child: Text(S.d2ShowAll(total),
                style: Hip.sans(600, 13.5, color: Hip.blueDeep)),
          ),
          Icon(Icons.keyboard_arrow_down, size: 18, color: Hip.blueDeep),
        ]),
      ),
    );
  }
}

/// The one line of selling under the locked group: what a plan opens, and
/// what it costs to try (app.css `.prem-strip`, a dashed brand outline).
class _PremiumStrip extends StatelessWidget {
  final VoidCallback onTap;
  const _PremiumStrip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Brand.hsl(220, 95, 55, .04),
            border: Border.all(color: Brand.hsl(220, 95, 55, .30), width: 1.5),
            borderRadius: BorderRadius.circular(15),
          ),
          child: Row(children: [
            Expanded(
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(S.d1StripTitle,
                    style: Hip.sans(650, 13.5, color: Hip.ink)),
                const SizedBox(height: 2),
                Text(S.d1StripSub,
                    style: Hip.sans(400, 11.5, color: Hip.muted)),
              ]),
            ),
            const SizedBox(width: 12),
            Icon(Icons.chevron_right, size: 17, color: Hip.blueDeep),
          ]),
        ),
      ),
    );
  }
}

/// The location this install voted for went live. The map gives the feeling,
/// this gives the action (app.css `.winner-card`).
class _WinnerCard extends StatelessWidget {
  final String city;
  final bool locked;
  final VoidCallback onDismiss;
  final VoidCallback onAct;
  const _WinnerCard({
    required this.city,
    required this.locked,
    required this.onDismiss,
    required this.onAct,
  });

  @override
  Widget build(BuildContext context) {
    final ink = Hip.dm ? Brand.hsl(42, 92, 66) : Brand.hsl(38, 85, 40);
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 4, 0, 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Brand.hsl(42, 92, 52, .09),
        border: Border.all(color: Brand.hsl(42, 92, 52, .30), width: 1.5),
        borderRadius: BorderRadius.circular(Hip.radius),
      ),
      child: Row(children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: Brand.hsl(42, 92, 52, .18),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(Icons.emoji_events_outlined, size: 20, color: ink),
        ),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(S.d6Title(city),
                style:
                    Hip.sans(700, 14.5, color: Hip.ink, letterSpacing: -.22)),
            const SizedBox(height: 2),
            Text(S.d6Sub,
                style: Hip.sans(400, 12, color: Hip.muted, height: 1.4)),
          ]),
        ),
        _TapTarget(
          semanticLabel: S.d6Dismiss,
          onTap: onDismiss,
          child: Icon(Icons.close, size: 15, color: Hip.muted2),
        ),
        GestureDetector(
          onTap: onAct,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 44,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 15),
            decoration: BoxDecoration(
              color: Hip.dm ? Brand.hsl(42, 92, 58) : Brand.hsl(38, 85, 40),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Text(locked ? S.aSeePlans : S.tConnect,
                style: Hip.sans(650, 13,
                    color: Hip.dm ? Brand.hsl(35, 40, 12) : Colors.white)),
          ),
        ),
      ]),
    );
  }
}

/// The trophy badge on a row the user voted for (app.css `.badge.won`).
class _WonBadge extends StatelessWidget {
  const _WonBadge();

  @override
  Widget build(BuildContext context) => HipBadge(
        S.badgeVoted,
        bg: Brand.hsl(42, 92, 52, .16),
        fg: Hip.dm ? Brand.hsl(42, 92, 66) : Brand.hsl(38, 85, 38),
        icon: Icons.emoji_events_outlined,
      );
}

/// A small icon inside a row that carries its own tap target: the visual is
/// as big as the design draws it, the target is the platform minimum.
class _TapTarget extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  final String semanticLabel;
  const _TapTarget({
    required this.child,
    required this.onTap,
    required this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(width: 44, height: 44, child: Center(child: child)),
      ),
    );
  }
}

/// Compact header above a subscription's servers: the provider title (or the
/// URL host when it sent none), and, when the provider reported them, the data
/// used against the quota and the expiry date. Numbers and the date render in
/// mono per the brand rules. A trailing icon opens the seller's panel when a
/// web-page URL is known. Deliberately one quiet row, no card-within-card.
class _SubHeader extends StatelessWidget {
  final SubInfo? info;
  final String fallbackHost;
  const _SubHeader({required this.info, required this.fallbackHost});

  @override
  Widget build(BuildContext context) {
    final i = info;
    final title =
        (i?.title != null && i!.title!.isNotEmpty) ? i.title! : fallbackHost;

    // Data used against the quota, e.g. "1.5 / 50.0 GB". Only when a quota is
    // known; a bare used figure without a total reads as noise here.
    String? usage;
    if (i != null && i.hasQuota) {
      usage = '${SubInfo.formatBytes(i.usedBytes).replaceAll(' GB', '')}'
          ' / ${SubInfo.formatBytes(i.totalBytes!)}';
    }

    // Expiry: past -> danger; within 7 days -> muted date; otherwise silent
    // (unless usage carries the row) to keep the header short.
    String? expiryText;
    Color? expiryColor;
    final e = i?.expire;
    if (e != null) {
      final now = DateTime.now();
      if (e.isBefore(now)) {
        expiryText = 'Expired ${_date(e)}';
        expiryColor = Hip.danger;
      } else if (e.difference(now).inDays <= 7) {
        expiryText = 'Expires ${_date(e)}';
        expiryColor = Hip.muted;
      }
    }

    final webUrl = i?.webPageUrl;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 6, 6),
      child: Row(children: [
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title.toUpperCase(),
                overflow: TextOverflow.ellipsis,
                style:
                    Hip.sans(650, 12, color: Hip.muted2, letterSpacing: .84)),
            if (usage != null || expiryText != null)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(children: [
                  if (usage != null)
                    Text(usage, style: Hip.mono(600, 11, color: Hip.muted)),
                  if (usage != null && expiryText != null)
                    Text('  ·  ', style: Hip.sans(400, 11, color: Hip.muted2)),
                  if (expiryText != null)
                    Text(expiryText,
                        style: Hip.mono(600, 11, color: expiryColor)),
                ]),
              ),
          ]),
        ),
        // url_launcher is already a dependency (used by the paywall), so the
        // panel button ships; no deferral needed.
        if (webUrl != null)
          HipIconButton(
            Icons.open_in_new,
            color: Hip.muted2,
            onTap: () => launchUrl(Uri.parse(webUrl),
                mode: LaunchMode.externalApplication),
          ),
      ]),
    );
  }

  /// Short date like "24 Jul 2026" (mono digits carry it).
  static String _date(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }
}

/// Section header for the managed servers: the brand wordmark where the
/// other sections carry an uppercase label, same metrics so the rhythm of
/// the list holds on any screen width.
class _PremiumSectionHead extends StatelessWidget {
  const _PremiumSectionHead();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(14, 18, 14, 7),
      child: Align(
        alignment: Alignment.centerLeft,
        child: HipWordmark(size: 13.5),
      ),
    );
  }
}

/// "Coming next": the pointer to voting on the map plus the live leaderboard.
/// Counts render only once the server has ever answered (see VoteService);
/// until then the section still shows the user's own votes, just without
/// numbers, so a cast vote never looks lost.
class _VoteSection extends StatefulWidget {
  final VoidCallback onOpenMap;
  const _VoteSection({required this.onOpenMap});

  @override
  State<_VoteSection> createState() => _VoteSectionState();
}

class _VoteSectionState extends State<_VoteSection> {
  final VoteService _votes = VoteService.instance;
  Map<String, String> _names = const {};

  @override
  void initState() {
    super.initState();
    _votes.addListener(_changed);
    _votes.init();
    CountryNames.load().then((m) {
      if (mounted) setState(() => _names = m);
    });
  }

  @override
  void dispose() {
    _votes.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final board = _votes.leaderboard(5);
    final onBoard = {for (final (cc, _) in board) cc};
    // The user's own votes always show, even below the top 5 or before the
    // server has ever answered.
    final mine = _votes.mine.where((cc) => !onBoard.contains(cc)).toList()
      ..sort((a, b) => (_names[a] ?? a).compareTo(_names[b] ?? b));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const HipSectionLabel(S.dComingNext),
      HipListGroup(children: [
        HipListRow(
          leading: HipFlag(
              cc: '',
              child: Icon(Icons.how_to_vote, size: 19, color: Hip.blueDeep)),
          title: S.dVoteTitle,
          subtitle: S.dVoteSub,
          trailing: Icon(Icons.chevron_right, size: 18, color: Hip.muted2),
          onTap: widget.onOpenMap,
        ),
        for (final (i, (cc, count)) in board.indexed)
          HipListRow(
            leading: HipFlag(cc: '${i + 1}'),
            title: _names[cc] ?? cc,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (_votes.hasVoted(cc)) ...[
                Icon(Icons.check, size: 15, color: Hip.blue),
                const SizedBox(width: 7),
              ],
              Text('$count', style: Hip.mono(700, 13, color: Hip.ink)),
              const SizedBox(width: 4),
              Text(S.dVotes, style: Hip.sans(500, 12, color: Hip.muted)),
            ]),
            onTap: widget.onOpenMap,
          ),
        for (final cc in mine)
          HipListRow(
            leading: HipFlag(
                cc: '',
                child: Icon(Icons.check, size: 17, color: Hip.blueDeep)),
            title: _names[cc] ?? cc,
            subtitle: S.dYourVote,
            trailing: switch (_votes.displayCount(cc)) {
              null => null,
              final count => Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('$count', style: Hip.mono(700, 13, color: Hip.ink)),
                  const SizedBox(width: 4),
                  Text(S.dVotes, style: Hip.sans(500, 12, color: Hip.muted)),
                ]),
            },
            onTap: widget.onOpenMap,
          ),
      ]),
      if (board.isNotEmpty || mine.isNotEmpty) const HipSubnote(S.dVoteNote),
    ]);
  }
}
