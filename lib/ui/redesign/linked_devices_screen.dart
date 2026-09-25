import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../core/deep_link.dart';
import '../../core/device_link.dart';
import '../../core/haptics.dart';
import '../../core/premium.dart';
import '../../core/sensitive_clipboard.dart';
import '../../state/app_state.dart';
import '../qr_scan_screen.dart';
import '../strings.dart';
import 'hip.dart';
import 'hip_sheet.dart';
import 'shell.dart';

/// Settings → Linked devices: what else is using this subscription, and the
/// way to add one more. Linking is a scan away; nothing is typed and no
/// account exists to sign into on the other side.
class LinkedDevicesScreen extends StatefulWidget {
  final AppState state;
  final HipNav nav;
  const LinkedDevicesScreen({super.key, required this.state, required this.nav});

  @override
  State<LinkedDevicesScreen> createState() => _LinkedDevicesScreenState();
}

class _LinkedDevicesScreenState extends State<LinkedDevicesScreen> {
  List<LinkedDevice>? _devices;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = widget.state.subToken;
    if (token == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    final list = await widget.state.deviceLinks.devices(token);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failed = list == null;
      if (list != null) _devices = list;
    });
  }

  /// Opens the scanner, and hands anything that reads as a pairing link to the
  /// approval sheet. A server QR scanned here is a mistake worth naming, so it
  /// gets its own message rather than silently doing nothing.
  Future<void> _scanToLink() async {
    Haptics.tap();
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (!mounted || scanned == null || scanned.isEmpty) return;
    final pairing = parsePairingLink(scanned);
    if (pairing == null) {
      widget.state.showToast('That is not a hideip.net pairing code');
      return;
    }
    final approved =
        await showLinkApprovalSheet(context, state: widget.state, pairing: pairing);
    if (approved == true && mounted) await _load();
  }

  Future<void> _showCode() async {
    Haptics.tap();
    final token = widget.state.subToken;
    if (token == null) return;
    await showLinkCodeSheet(context, state: widget.state, subToken: token);
    if (mounted) await _load();
  }

  /// This phone's own entry when it is on the list through an account
  /// number. It leaves by signing out, never from here.
  String? get _ownId =>
      widget.state.premium.source == PremiumSource.account
          ? widget.state.accountDeviceId
          : null;

  Future<void> _confirmRevoke(LinkedDevice device) async {
    final token = widget.state.subToken;
    if (token == null || device.id == _ownId) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Hip.card,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Hip.radius)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Remove ${device.name}?',
                  style: Hip.sans(650, 17, color: Hip.ink)),
              const SizedBox(height: 10),
              Text(
                'It loses access to your premium servers right away. You can '
                'link it again any time by scanning a new code.',
                style: Hip.sans(550, 14, color: Hip.inkSoft, height: 1.45),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child:
                        Text('Cancel', style: Hip.sans(650, 14, color: Hip.muted)),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: Text('Remove',
                        style: Hip.sans(650, 14, color: Hip.danger)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (yes != true || !mounted) return;
    final ok = await widget.state.deviceLinks
        .revoke(subToken: token, deviceId: device.id);
    if (!mounted) return;
    if (ok) {
      Haptics.success();
      setState(() => _devices =
          _devices?.where((d) => d.id != device.id).toList(growable: false));
      widget.state.showToast('${device.name} removed');
    } else {
      Haptics.error();
      widget.state.showToast('Could not remove it; try again');
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices ?? const <LinkedDevice>[];
    return SafeArea(
      child: Column(children: [
        HipNavHead(
          title: 'Linked devices',
          onBack: () => widget.nav.go(HipScreen.settings),
          trailing: _loading
              ? const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : HipIconButton(Icons.refresh, onTap: _load),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              HipCard(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('One subscription, every device',
                          style: Hip.sans(650, 15.5,
                              color: Hip.ink, letterSpacing: -.15)),
                      const SizedBox(height: 6),
                      Text(
                        'Scan the code a browser or desktop app shows and it '
                        'gets access to your premium servers. No sign-in, '
                        'nothing to remember.',
                        style:
                            Hip.sans(550, 13, color: Hip.muted, height: 1.45),
                      ),
                    ]),
              ),
              const SizedBox(height: 14),
              HipCta('Link a device',
                  leading: const Icon(Icons.qr_code_scanner_outlined),
                  onTap: _scanToLink),
              const SizedBox(height: 10),
              HipCta('Show a code instead',
                  ghost: true, quiet: true, onTap: _showCode),
              if (_failed) ...[
                const HipSectionLabel('Devices'),
                HipListGroup(children: [
                  HipListRow(
                    title: 'Could not load your devices',
                    subtitle: 'Check your connection, then try again',
                    trailing:
                        Icon(Icons.refresh, size: 17, color: Hip.muted2),
                    onTap: _load,
                  ),
                ]),
              ] else if (devices.isNotEmpty) ...[
                HipSectionLabel('Devices (${devices.length})'),
                HipListGroup(children: [
                  for (final d in devices)
                    _DeviceRow(
                        device: d,
                        own: d.id == _ownId,
                        onRevoke: () => _confirmRevoke(d)),
                ]),
                const HipSubnote(
                    'Swipe a device left, or tap the unlink icon, to cut off '
                    'its access.'),
              ] else if (!_loading) ...[
                const HipSectionLabel('Devices'),
                HipListGroup(children: [
                  HipListRow(
                    title: 'No devices linked yet',
                    subtitle: 'This phone is the only one using Premium',
                  ),
                ]),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ]),
    );
  }
}

/// One linked device: kind icon, name, and the dates in mono. Swiping it left
/// asks the same question the trailing button does.
class _DeviceRow extends StatelessWidget {
  final LinkedDevice device;
  final VoidCallback onRevoke;

  /// This phone: marked, and without a way to remove it.
  final bool own;
  const _DeviceRow(
      {required this.device, required this.onRevoke, this.own = false});

  static IconData iconFor(LinkedDeviceKind kind) => switch (kind) {
        LinkedDeviceKind.extension => Icons.language_outlined,
        LinkedDeviceKind.desktop => Icons.desktop_windows_outlined,
        LinkedDeviceKind.phone => Icons.smartphone_outlined,
        LinkedDeviceKind.unknown => Icons.devices_other_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final row = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: Hip.line2,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(iconFor(device.kind), size: 19, color: Hip.inkSoft),
        ),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(device.name,
                overflow: TextOverflow.ellipsis,
                style:
                    Hip.sans(650, 15.5, color: Hip.ink, letterSpacing: -.15)),
            const SizedBox(height: 2),
            _subtitle,
          ]),
        ),
        const SizedBox(width: 12),
        if (own)
          HipBadge.blue(S.accountThisDevice)
        else
          Semantics(
            button: true,
            child: GestureDetector(
              onTap: onRevoke,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(Icons.link_off, size: 18, color: Hip.muted2),
              ),
            ),
          ),
      ]),
    );
    if (own) return row;
    return Dismissible(
      key: ValueKey('linked-device:${device.id}'),
      direction: DismissDirection.endToStart,
      // The dialog owns the decision; the row itself never disappears on the
      // swipe alone, so a mis-swipe cannot silently cut a device off.
      confirmDismiss: (_) async {
        onRevoke();
        return false;
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 18),
        child: Icon(Icons.link_off, size: 20, color: Hip.danger),
      ),
      child: row,
    );
  }

  /// "Browser · linked Aug 5, 2026 · seen Aug 5, 2026". Only the dates are
  /// mono (the brand rule reserves it for numbers); the words around them stay
  /// in the body face. A device that has never checked in says so.
  Widget get _subtitle {
    final words = Hip.sans(400, 12.5, color: Hip.muted);
    final dates = Hip.mono(600, 11.5, color: Hip.muted);
    final spans = <TextSpan>[TextSpan(text: device.kindLabel, style: words)];
    final created = device.createdAt;
    if (created != null) {
      spans.add(TextSpan(text: '  ·  linked ', style: words));
      spans.add(TextSpan(text: _shortDate(created), style: dates));
    }
    final seen = device.lastSeenAt;
    if (seen == null) {
      spans.add(TextSpan(text: '  ·  never used', style: words));
    } else {
      spans.add(TextSpan(text: '  ·  seen ', style: words));
      spans.add(TextSpan(text: _shortDate(seen), style: dates));
    }
    return Text.rich(TextSpan(children: spans),
        maxLines: 2, overflow: TextOverflow.ellipsis);
  }
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _shortDate(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';

/// The approval sheet: what is being linked, and the two ways out. Returns
/// true when the device was linked.
Future<bool?> showLinkApprovalSheet(
  BuildContext context, {
  required AppState state,
  required DeepLinkPairing pairing,
}) {
  return showHipSheet<bool>(context, children: [
    _LinkApprovalSheet(state: state, pairing: pairing),
  ]);
}

class _LinkApprovalSheet extends StatefulWidget {
  final AppState state;
  final DeepLinkPairing pairing;
  const _LinkApprovalSheet({required this.state, required this.pairing});

  @override
  State<_LinkApprovalSheet> createState() => _LinkApprovalSheetState();
}

enum _ApprovePhase { ask, working, done }

class _LinkApprovalSheetState extends State<_LinkApprovalSheet> {
  _ApprovePhase _phase = _ApprovePhase.ask;
  String? _error;

  Future<void> _approve() async {
    final token = widget.state.subToken;
    if (token == null) {
      setState(() => _error = 'Your subscription is not active on this phone.');
      return;
    }
    Haptics.tap();
    setState(() {
      _phase = _ApprovePhase.working;
      _error = null;
    });
    final result = await widget.state.deviceLinks.approve(
      linkId: widget.pairing.linkId,
      subToken: token,
      deviceName: thisDeviceName,
    );
    if (!mounted) return;
    if (result == LinkApproveResult.ok) {
      Haptics.success();
      setState(() => _phase = _ApprovePhase.done);
      return;
    }
    Haptics.error();
    setState(() {
      _phase = _ApprovePhase.ask;
      _error = switch (result) {
        LinkApproveResult.deviceLimit =>
          'You have linked as many devices as your plan allows. Remove one '
              'from Linked devices, then scan again.',
        LinkApproveResult.expired =>
          'That code has expired. Ask the other device for a fresh one.',
        LinkApproveResult.notEntitled =>
          'Your subscription is not active. Restore purchases and try again.',
        _ => 'Could not link the device. Check your connection and try again.',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final done = _phase == _ApprovePhase.done;
    final working = _phase == _ApprovePhase.working;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: done ? Hip.successSoft : Hip.blueSoft,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(done ? Icons.check_rounded : Icons.devices_outlined,
                size: 26, color: done ? Hip.success : Hip.blue),
          ),
        ),
        const SizedBox(height: 16),
        Text(done ? 'Device linked' : 'Link this device?',
            textAlign: TextAlign.center,
            style: Hip.sans(700, 20, color: Hip.ink, letterSpacing: -.4)),
        const SizedBox(height: 8),
        Text(
          done
              ? 'It has access to your premium servers now. You can remove it '
                  'any time from Linked devices.'
              : 'It gets access to your premium servers. Only approve a code '
                  'you are looking at on your own device.',
          textAlign: TextAlign.center,
          style: Hip.sans(550, 14, color: Hip.muted, height: 1.5),
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: Hip.danger.withValues(alpha: .1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(_error!,
                style: Hip.sans(550, 13, color: Hip.danger, height: 1.4)),
          ),
        ],
        const SizedBox(height: 20),
        if (done)
          HipCta('Done', onTap: () => Navigator.of(context).pop(true))
        else ...[
          HipCta(working ? 'Linking…' : 'Approve',
              onTap: working ? null : _approve),
          const SizedBox(height: 8),
          HipCta('Cancel',
              ghost: true,
              quiet: true,
              onTap: working ? null : () => Navigator.of(context).pop(false)),
        ],
      ],
    );
  }
}

/// The fallback sheet: a short code the user types into a client with no
/// camera, counting down to its expiry.
Future<void> showLinkCodeSheet(
  BuildContext context, {
  required AppState state,
  required String subToken,
}) {
  return showHipSheet<void>(context, children: [
    _LinkCodeSheet(state: state, subToken: subToken),
  ]);
}

class _LinkCodeSheet extends StatefulWidget {
  final AppState state;
  final String subToken;
  const _LinkCodeSheet({required this.state, required this.subToken});

  @override
  State<_LinkCodeSheet> createState() => _LinkCodeSheetState();
}

class _LinkCodeSheetState extends State<_LinkCodeSheet> {
  LinkCode? _code;
  bool _loading = true;
  bool _failed = false;
  Duration _left = Duration.zero;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _mint();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _mint() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final code = await widget.state.deviceLinks.mintCode(widget.subToken);
    if (!mounted) return;
    _tick?.cancel();
    setState(() {
      _loading = false;
      _failed = code == null;
      _code = code;
      _left = code?.expiresIn ?? Duration.zero;
    });
    if (code == null) return;
    Haptics.success();
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      final next = _left - const Duration(seconds: 1);
      setState(() => _left = next.isNegative ? Duration.zero : next);
      if (_left == Duration.zero) t.cancel();
    });
  }

  /// "09:58": the countdown, mono like every other number in the app.
  String get _countdown {
    final m = _left.inMinutes.toString().padLeft(2, '0');
    final s = (_left.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    final expired = code != null && _left == Duration.zero;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Enter this code',
            textAlign: TextAlign.center,
            style: Hip.sans(700, 20, color: Hip.ink, letterSpacing: -.4)),
        const SizedBox(height: 8),
        Text(
          'Type it into the browser or app you want to link. It works once, '
          'and only for a few minutes.',
          textAlign: TextAlign.center,
          style: Hip.sans(550, 14, color: Hip.muted, height: 1.5),
        ),
        const SizedBox(height: 20),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 26),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
          )
        else if (_failed)
          Text('Could not get a code. Check your connection and try again.',
              textAlign: TextAlign.center,
              style: Hip.sans(550, 13.5, color: Hip.danger, height: 1.45))
        else if (code != null) ...[
          GestureDetector(
            onTap: expired
                ? null
                : () async {
                    await SensitiveClipboard.setText(
                      code.code,
                      ttl: _left,
                    );
                    Haptics.selection();
                    widget.state.showToast('Code copied');
                  },
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 20),
              decoration: BoxDecoration(
                color: Hip.blueSoft,
                borderRadius: BorderRadius.circular(Hip.radius),
              ),
              child: Text(
                code.code,
                textAlign: TextAlign.center,
                style: Hip.mono(700, 34,
                    color: expired ? Hip.muted2 : Hip.blueDeep,
                    letterSpacing: 5),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(expired ? 'Code expired' : 'Expires in $_countdown',
              textAlign: TextAlign.center,
              style: expired
                  ? Hip.sans(600, 13, color: Hip.muted)
                  : Hip.mono(600, 13, color: Hip.muted)),
        ],
        const SizedBox(height: 20),
        if (_failed || expired)
          HipCta('Get a new code', onTap: _mint)
        else
          HipCta('Done', onTap: () => Navigator.of(context).pop()),
      ],
    );
  }
}

/// The name this phone is recorded under next to a device it approved. No
/// device-info plugin is pulled in for this: the platform name is honest, and
/// a real hardware model would be one more identifier than the app needs.
String get thisDeviceName =>
    defaultTargetPlatform == TargetPlatform.iOS ? 'iPhone' : 'Android phone';
