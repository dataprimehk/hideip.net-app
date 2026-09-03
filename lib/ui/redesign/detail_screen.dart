import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/config_redaction.dart';
import '../../core/location.dart';
import '../../core/ping.dart';
import '../../core/sensitive_clipboard.dart';
import '../../core/wg_speed_mode.dart';
import '../../state/app_state.dart';
import '../brand.dart';
import '../strings.dart';
import 'hip.dart';
import 'hip_sheet.dart';
import 'shell.dart';
import 'srv_edit.dart';
import 'srv_location_picker.dart';

/// The label to show for [l]: the name the user gave the server, or the one
/// it was imported under.
///
/// The provider's own name stays on the profile and is still shown under the
/// rename field, so renaming never loses it. Managed (hideip.net) servers are
/// named by the fleet and carry no name of the user's own, so they read the
/// parsed one like everything else.
String serverLabel(Location l) => l.label;

/// What a list row says under the label. Normally the country; when the
/// label already is the country (a server named from a lookup that knew no
/// city), the protocol, so the row does not say the same thing twice.
String rowPlace(Location l) =>
    serverLabel(l) == l.country ? l.protoLabel : l.country;

/// Where a subscription refresh stands right now.
enum RefreshState { idle, busy, done, error }

/// Manage one server: rename it, see where it came from, refresh the
/// subscription it belongs to, remove it. Advanced view adds the raw sing-box
/// outbound and the two ways to copy it.
///
/// Managed (hideip.net) servers show the header card only: there is nothing
/// on them for the user to rename, refresh or remove.
class DetailScreen extends StatefulWidget {
  final AppState state;
  final HipNav nav;
  final Location location;
  const DetailScreen({
    super.key,
    required this.state,
    required this.nav,
    required this.location,
  });

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  bool _testing = false;
  int? _ms;
  RefreshState _refresh = RefreshState.idle;
  int _refreshed = 0;

  @override
  void initState() {
    super.initState();
    final ping = widget.state.pingFor(widget.location.profile);
    if (ping is PingOk) _ms = ping.ms;
  }

  /// This screen was opened with a snapshot of the location. A rename or a
  /// subscription refresh rewrites the profile behind it, so the current one
  /// is looked up by id on every build. An edit can change the endpoint and
  /// with it the id, but it keeps the position, so that is the next answer;
  /// the snapshot is only the last fallback.
  Location get _loc {
    final locs = widget.state.locations;
    for (final l in locs) {
      if (l.id == widget.location.id) return l;
    }
    final at = widget.location.index;
    if (at >= 0 && at < locs.length && !locs[at].premium) return locs[at];
    return widget.location;
  }

  /// Where this server is, in words, for the Location row: the user's own
  /// choice says so, the lookup's answer stands on its own, and nothing
  /// placed reads as not known.
  String _placeLine(Location loc) {
    if (!loc.placed) return S.srvLocationUnknown;
    return loc.profile.ccOverride != null
        ? S.srvLocationSetByYou(loc.placeLabel)
        : loc.placeLabel;
  }

  /// Asks where the server is and stores the answer on the profile.
  Future<void> _pickLocation() async {
    final loc = _loc;
    final p = loc.profile;
    final place = await showSrvLocationPicker(
      context,
      cc: p.ccOverride ?? (loc.placed ? loc.cc : null),
      city: p.cityOverride ?? loc.placeCity,
      overridden: p.ccOverride != null,
    );
    if (place == null || !mounted) return;
    final state = widget.state;
    final match = state.locations.where((l) => l.id == loc.id);
    final index = match.isEmpty ? loc.index : match.first.index;
    await state.setServerLocation(index, cc: place.cc, city: place.city);
    state.showToast(S.srvLocationSaved);
  }

  /// Opens the importer on this server's config; saving there puts the
  /// result back in this position.
  void _edit() {
    final loc = _loc;
    widget.nav.go(
      HipScreen.import,
      SrvEditCtx(
        index: loc.index,
        id: loc.id,
        label: serverLabel(loc),
        text: srvEditText(loc.profile),
      ),
    );
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    final p = widget.location.profile;
    final r = await Ping.measure(p.server, p.port,
        timeout: const Duration(seconds: 4));
    if (!mounted) return;
    setState(() {
      _testing = false;
      _ms = r is PingOk ? r.ms : null;
    });
  }

  /// The list may have been reordered by a refresh since this screen opened,
  /// so the position is resolved by identity rather than trusted.
  Future<void> _rename(String name) async {
    final state = widget.state;
    final match = state.locations.where((l) => l.id == widget.location.id);
    final index = match.isEmpty ? widget.location.index : match.first.index;
    await state.renameServer(
      index,
      name.trim() == _loc.city ? null : name,
    );
  }

  /// Pulls the subscription this server came from. A failure keeps every
  /// server already on the device: nothing is dropped because a provider was
  /// briefly unreachable.
  Future<void> _refreshSubscription(String url) async {
    if (_refresh == RefreshState.busy) return;
    setState(() => _refresh = RefreshState.busy);
    final count = await widget.state.refreshSubscription(url);
    if (!mounted) return;
    if (count == null) {
      setState(() => _refresh = RefreshState.error);
      return;
    }
    // The provider may have retired this exact server. Its manage screen has
    // nothing left to manage, so the list is where the user belongs.
    final gone =
        widget.state.locations.every((l) => l.id != widget.location.id);
    if (gone) {
      widget.nav.go(HipScreen.locations);
      return;
    }
    setState(() {
      _refresh = RefreshState.done;
      _refreshed = count;
    });
  }

  Future<void> _copyConfig() async {
    const encoder = JsonEncoder.withIndent('  ');
    await Clipboard.setData(ClipboardData(
        text: encoder.convert(redactConfig(widget.location.profile.outbound))));
    widget.state.showToast(S.gToastRedacted);
  }

  Future<void> _copyFullConfig() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text(S.gCopyFullTitle),
            content: const Text(S.gCopyFullBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text(S.aCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text(S.gCopyFullAction),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    const encoder = JsonEncoder.withIndent('  ');
    try {
      await SensitiveClipboard.setText(
          encoder.convert(widget.location.profile.outbound));
      widget.state.showToast(S.gToastFull);
    } on PlatformException {
      widget.state.showToast(S.gToastFullFailed);
    }
  }

  Future<void> _confirmRemove(String name) async {
    final go = await showHipSheet<bool>(
      context,
      children: removeServerSheet(
        name: name,
        onCancel: () => Navigator.of(context).pop(false),
        onRemove: () => Navigator.of(context).pop(true),
      ),
    );
    if (go != true || !mounted) return;
    await _remove(name);
  }

  Future<void> _remove(String name) async {
    final state = widget.state;
    // Resolve the position by identity: a refresh may have reordered the list
    // since this screen was opened.
    final match =
        state.locations.where((l) => l.id == widget.location.id).toList();
    final index = match.isEmpty ? widget.location.index : match.first.index;
    final toAuto = removalFallsBackToAuto(
      autoSelect: state.prefs.autoSelect,
      selectedIndex: state.selectedIndex,
      removedIndex: index,
    );
    await state.remove(index);
    // The server that was selected is gone; Auto is the honest answer, not
    // whichever server happens to sit first in the list now.
    if (toAuto) await state.selectLocation(null);
    state.showToast(S.gRemoved(name));
    widget.nav.go(HipScreen.locations);
  }

  @override
  Widget build(BuildContext context) {
    final loc = _loc;
    final advanced = widget.state.prefs.advanced;
    final managed = loc.premium;
    final name = serverLabel(loc);
    final subUrl = loc.profile.subUrl;
    const encoder = JsonEncoder.withIndent('  ');

    return SafeArea(
      child: Column(children: [
        HipNavHead(title: name, onBack: widget.nav.back),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              _HeaderCard(
                location: loc,
                name: name,
                advanced: advanced,
                testing: _testing,
                ms: _ms,
                onTest: _testing ? null : _test,
              ),
              if (!managed)
                ManageServerSection(
                  name: name,
                  rawName: loc.rawName,
                  fromSubscription: subUrl != null,
                  refresh: _refresh,
                  refreshedServers: _refreshed,
                  lastUpdated: subUrl == null
                      ? null
                      : widget.state.subInfoFor(subUrl)?.fetchedAt,
                  onRename: _rename,
                  onRefresh:
                      subUrl == null ? null : () => _refreshSubscription(subUrl),
                  onEdit: _edit,
                  place: _placeLine(loc),
                  onLocation: _pickLocation,
                ),
              if (advanced) ...[
                const HipSectionLabel(S.gRawConfig),
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
                  decoration: BoxDecoration(
                    color: Brand.hsl(220, 15, 10),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Text(encoder.convert(loc.profile.outbound),
                      style: Hip.mono(500, 10.5,
                          color: Brand.hsl(220, 10, 78), height: 1.7)),
                ),
                const SizedBox(height: 10),
                HipCta(S.gCopyConfig,
                    ghost: true,
                    leading: const Icon(Icons.copy_outlined),
                    onTap: _copyConfig),
                const SizedBox(height: 8),
                HipCta(S.gCopyFull,
                    ghost: true,
                    leading: const Icon(Icons.warning_amber_rounded),
                    onTap: _copyFullConfig),
              ],
              if (!managed)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: GestureDetector(
                    onTap: () => _confirmRemove(name),
                    behavior: HitTestBehavior.opaque,
                    child: const Padding(
                      padding: EdgeInsets.all(14),
                      child: Center(child: _DangerLabel(S.gRemove)),
                    ),
                  ),
                ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ]),
    );
  }
}

/// Whether removing the server at [removedIndex] should leave the app on
/// Auto: it should exactly when that server was the one explicitly selected.
/// Falling to whatever sits first in the list instead would silently move the
/// user to a server they never picked.
bool removalFallsBackToAuto({
  required bool autoSelect,
  required int selectedIndex,
  required int removedIndex,
}) =>
    !autoSelect && selectedIndex == removedIndex;

/// The confirmation for removing a server: it names what keeps working, so
/// the decision does not read as more final than it is.
List<Widget> removeServerSheet({
  required String name,
  required VoidCallback onCancel,
  required VoidCallback onRemove,
}) =>
    [
      HipSheetTitle(S.g5Title(name)),
      const HipSheetBody(S.g5Body),
      HipSheetActions(children: [
        HipCta(S.aRemove, danger: true, ghost: true, onTap: onRemove),
        HipCta(S.aCancel, quiet: true, onTap: onCancel),
      ]),
    ];

/// The `This server` section: rename, where the server came from, and (for a
/// subscription) a manual refresh with its four answers.
///
/// Takes plain values rather than the app state, so it renders the same in
/// every entitlement and can be exercised on its own.
class ManageServerSection extends StatefulWidget {
  /// The name shown for this server: the user's, or the parsed one.
  final String name;

  /// What the provider actually called it. Stays visible under the field.
  final String rawName;

  final bool fromSubscription;
  final RefreshState refresh;

  /// How many servers the last successful refresh returned.
  final int refreshedServers;

  /// When the subscription was last read, for the idle line.
  final DateTime? lastUpdated;

  final void Function(String name) onRename;
  final VoidCallback? onRefresh;

  /// Opens the config for editing. Null hides the row.
  final VoidCallback? onEdit;

  /// Where the server is, in words, and the picker behind the row. The row
  /// is shown only with [onLocation].
  final String? place;
  final VoidCallback? onLocation;

  const ManageServerSection({
    super.key,
    required this.name,
    required this.rawName,
    required this.fromSubscription,
    this.refresh = RefreshState.idle,
    this.refreshedServers = 0,
    this.lastUpdated,
    required this.onRename,
    this.onRefresh,
    this.onEdit,
    this.place,
    this.onLocation,
  });

  @override
  State<ManageServerSection> createState() => _ManageServerSectionState();
}

class _ManageServerSectionState extends State<ManageServerSection> {
  final TextEditingController _field = TextEditingController();
  bool _renaming = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _start() {
    _field.text = widget.name;
    _field.selection =
        TextSelection(baseOffset: 0, extentOffset: _field.text.length);
    setState(() => _renaming = true);
  }

  void _save() {
    setState(() => _renaming = false);
    widget.onRename(_field.text.trim().isEmpty ? widget.name : _field.text);
  }

  String get _subscriptionLine => switch (widget.refresh) {
        RefreshState.busy => S.gRefreshBusy,
        RefreshState.done => S.gRefreshDone(widget.refreshedServers),
        RefreshState.error => S.gRefreshError,
        RefreshState.idle => S.gRefreshIdle(_ago(widget.lastUpdated)),
      };

  /// How long ago the subscription was read, in words. Never read on this
  /// device reads as just now rather than as a number nobody measured.
  static String _ago(DateTime? at) {
    if (at == null) return S.gAgoJustNow;
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return S.gAgoJustNow;
    if (d.inMinutes < 60) return S.gAgoMinutes(d.inMinutes);
    if (d.inHours < 24) return S.gAgoHours(d.inHours);
    return S.gAgoDays(d.inDays);
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const HipSectionLabel(S.gThisServer),
      HipListGroup(children: [
        if (_renaming)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _field,
                  autofocus: true,
                  autocorrect: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _save(),
                  style: Hip.sans(650, 15.5, color: Hip.ink),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.only(top: 2, bottom: 5),
                    border: UnderlineInputBorder(
                        borderSide: BorderSide(color: Hip.blue, width: 1.5)),
                    enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Hip.blue, width: 1.5)),
                    focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Hip.blue, width: 1.5)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _MiniButton(S.gSave, onTap: _save),
            ]),
          )
        else
          HipListRow(
            title: S.gName,
            subtitle: S.gNameSub(widget.name, widget.rawName),
            trailing: Icon(Icons.edit_outlined, size: 16, color: Hip.muted2),
            onTap: _start,
          ),
        if (widget.onLocation != null)
          HipListRow(
            title: S.srvLocation,
            subtitle: widget.place ?? S.srvLocationUnknown,
            trailing: Icon(Icons.edit_outlined, size: 16, color: Hip.muted2),
            onTap: widget.onLocation,
          ),
        if (widget.onEdit != null)
          HipListRow(
            title: S.srvEditConfig,
            subtitle: S.srvEditConfigSub,
            trailing: Icon(Icons.chevron_right, size: 18, color: Hip.muted2),
            onTap: widget.onEdit,
          ),
        if (widget.fromSubscription)
          HipListRow(
            title: S.gSubscription,
            subtitle: _subscriptionLine,
            trailing: widget.refresh == RefreshState.busy
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Hip.muted2),
                  )
                : Icon(Icons.refresh, size: 16, color: Hip.muted2),
            onTap: widget.refresh == RefreshState.busy ? null : widget.onRefresh,
          )
        else
          const HipListRow(title: S.gSource, subtitle: S.gSourceSub),
      ]),
    ]);
  }
}

/// The server card at the top: flag, place, what runs it, and a ping badge
/// that measures again on tap.
class _HeaderCard extends StatelessWidget {
  final Location location;
  final String name;
  final bool advanced;
  final bool testing;
  final int? ms;
  final VoidCallback? onTest;
  const _HeaderCard({
    required this.location,
    required this.name,
    required this.advanced,
    required this.testing,
    required this.ms,
    required this.onTest,
  });

  @override
  Widget build(BuildContext context) {
    final proto = protoShort(location) ?? location.profile.protocol;
    // A name suggested from the place already ends in the country; saying
    // it twice would read as a stutter.
    final title = name.endsWith(', ${location.country}')
        ? name
        : '$name, ${location.country}';
    final line = advanced
        ? S.tunnelChain(location.protoLabel, location.host)
        : location.premium
            ? S.gManagedBy(proto)
            : S.gFromProvider(proto, location.provider ?? S.gYourProvider);

    return HipCard(
      child: Row(children: [
        HipFlag(cc: location.cc),
        const SizedBox(width: 14),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(title,
                    overflow: TextOverflow.ellipsis,
                    style: Hip.sans(650, 15.5,
                        color: Hip.ink, letterSpacing: -.15)),
              ),
              if (location.premium) ...[
                const SizedBox(width: 7),
                const HipBrandTag(),
              ],
            ]),
            const SizedBox(height: 2),
            Text(line,
                overflow: TextOverflow.ellipsis,
                style: advanced
                    ? Hip.mono(600, 12, color: Hip.muted)
                    : Hip.sans(400, Hip.calloutSize, color: Hip.muted)),
          ]),
        ),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: onTest,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: 44,
            child: Center(
              child: HipBadge.blue(testing
                  ? S.gTesting
                  : ms != null
                      ? S.gMs(ms!)
                      : S.gTest),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Small inline button beside a field (app.css `.minibtn`).
class _MiniButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _MiniButton(this.label, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: Hip.line2,
          border: Border.all(color: Hip.line, width: 1.5),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Text(label, style: Hip.sans(650, 12.5, color: Hip.ink)),
      ),
    );
  }
}

class _DangerLabel extends StatelessWidget {
  final String text;
  const _DangerLabel(this.text);

  @override
  Widget build(BuildContext context) =>
      Text(text, style: Hip.sans(600, 14.5, color: Hip.danger));
}
