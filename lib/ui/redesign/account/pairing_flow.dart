/// Adding a device with pairing v2, from this side: the new device shows a
/// QR code and a short code for one request, this device scans the one or
/// types the other, sees which device it is about to add, and approves it
/// once. Reading a code alone changes nothing.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/camera_permission.dart';
import '../../../core/deep_link.dart';
import '../../../core/haptics.dart';
import '../../../core/premium.dart' show formatPremiumDate;
import '../../qr_scan_screen.dart';
import '../../strings.dart';
import '../hip.dart';
import '../hip_sheet.dart';
import 'account_device.dart';
import 'account_widgets.dart' show SheetScroll;
import 'account_strings.dart';
import 'pairing_port.dart';

/// Opens a sheet with these children and returns what it was closed with.
typedef ShowSheet = Future<T?> Function<T>(List<Widget> children);

/// Reads one QR code, or null when nothing was read.
typedef ScanQr = Future<String?> Function(BuildContext context);

/// The scanner the app uses everywhere.
Future<String?> scanWithCamera(BuildContext context) => Navigator.of(
  context,
).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));

/// What the user is told about [error]. [byCode] picks the words for a
/// typed code over those for a scanned one where the two differ.
String pairingErrorText(PairingError error, {bool byCode = false}) =>
    switch (error) {
      PairingError.unknownLink =>
        byCode ? SA.errUnknownCode : SA.errUnknownLink,
      PairingError.badCode => SA.errBadCode,
      PairingError.linkExpired => SA.errExpired,
      PairingError.linkCancelled => SA.errCancelled,
      PairingError.subscriptionInactive => SA.errInactive,
      PairingError.notPermitted => SA.errNotPermitted,
      PairingError.accountRevoked => S.accountErrRevoked,
      PairingError.unauthorized => SA.errUnauthorized,
      PairingError.tooManyAttempts => S.accountErrTooMany,
      PairingError.unsupported => SA.errUnsupported,
      PairingError.notAllowedForKind => SA.useOnly,
      PairingError.self => SA.errSelf,
      // Both have their own screens; reaching here means a retry failed.
      PairingError.deviceLimitReached ||
      PairingError.lastManager ||
      PairingError.network => S.accountErrNetwork,
    };

/// Asks before a change that would leave the account with no device that
/// manages it (K7 `last_manager`), then repeats it with the answer.
Future<DeviceChangeResult> withLastManagerCheck(
  ShowSheet showSheet,
  Future<DeviceChangeResult> Function(bool confirm) change,
) async {
  final first = await change(false);
  if (first.error != PairingError.lastManager) return first;
  final go = await showSheet<bool>([
    const HipSheetTitle(SA.lastManagerTitle),
    const HipSheetBody(SA.lastManagerBody),
    HipSheetActions(
      children: [
        Builder(
          builder: (c) =>
              HipCta(S.aContinue, onTap: () => Navigator.of(c).pop(true)),
        ),
        Builder(
          builder: (c) => HipCta(
            S.aCancel,
            quiet: true,
            onTap: () => Navigator.of(c).pop(false),
          ),
        ),
      ],
    ),
  ]);
  if (go != true) return first;
  return change(true);
}

/// Scans the new device's QR code and goes on to the same confirmation a
/// typed code reaches. With the camera turned off in system settings the
/// code entry opens instead, saying why. True when a device was added.
Future<bool> pairByScan(
  BuildContext context, {
  required PairingPort port,
  required ShowSheet showSheet,
  required PairingCapabilities caps,
  ScanQr scan = scanWithCamera,
  Future<CamPerm> Function() camStatus = CameraPermission.status,
}) async {
  Haptics.tap();
  if (await camStatus() == CamPerm.denied) {
    if (!context.mounted) return false;
    return pairByCode(
      port: port,
      showSheet: showSheet,
      caps: caps,
      note: SA.cameraOff,
    );
  }
  if (!context.mounted) return false;
  final raw = await scan(context);
  if (!context.mounted || raw == null || raw.isEmpty) return false;
  final pairing = parsePairingLink(raw);
  if (pairing == null) {
    return await showSheet<bool>([
          PairingFlow(
            port: port,
            showSheet: showSheet,
            caps: caps,
            notALink: true,
          ),
        ]) ==
        true;
  }
  return pairByLink(
    port: port,
    showSheet: showSheet,
    caps: caps,
    linkId: pairing.linkId,
  );
}

/// The confirmation for a request whose id is already known (a scanned QR
/// code, or a pairing link opened from outside).
Future<bool> pairByLink({
  required PairingPort port,
  required ShowSheet showSheet,
  required PairingCapabilities caps,
  required String linkId,
}) async =>
    await showSheet<bool>([
      PairingFlow(port: port, showSheet: showSheet, caps: caps, linkId: linkId),
    ]) ==
    true;

/// Types the short code the new device shows, then the confirmation.
Future<bool> pairByCode({
  required PairingPort port,
  required ShowSheet showSheet,
  required PairingCapabilities caps,
  String? note,
}) async =>
    await showSheet<bool>([
      PairingFlow(port: port, showSheet: showSheet, caps: caps, note: note),
    ]) ==
    true;

enum _Phase { code, reading, confirm, approving, limit, done, failed }

/// The whole pairing conversation in one sheet: the code (unless a QR code
/// was read), the device it belongs to, the approval, and either a device
/// added or a choice of one to remove when every place is taken. Pops true
/// once a device was added.
class PairingFlow extends StatefulWidget {
  final PairingPort port;
  final ShowSheet showSheet;
  final PairingCapabilities caps;

  /// A scanned request. Without it the sheet starts at the code entry.
  final String? linkId;

  /// A line above the code field (the camera being off, for one).
  final String? note;

  /// The scanned QR code was not a pairing code at all.
  final bool notALink;

  const PairingFlow({
    super.key,
    required this.port,
    required this.showSheet,
    required this.caps,
    this.linkId,
    this.note,
    this.notALink = false,
  });

  @override
  State<PairingFlow> createState() => _PairingFlowState();
}

class _PairingFlowState extends State<PairingFlow> {
  final TextEditingController _code = TextEditingController();
  late _Phase _phase;
  String? _error;
  PairingRequest? _request;
  bool _grantManage = false;
  AccountDevice? _added;
  bool _addedManage = false;
  int _limit = 0;
  List<AccountDevice> _devices = const [];
  Duration _left = Duration.zero;
  Timer? _tick;

  bool get _byCode => widget.linkId == null;

  @override
  void initState() {
    super.initState();
    _code.addListener(_onEdit);
    if (widget.notALink) {
      _phase = _Phase.failed;
      _error = SA.errBadCode;
    } else if (widget.linkId != null) {
      _phase = _Phase.reading;
      _read(linkId: widget.linkId);
    } else {
      _phase = _Phase.code;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _code.removeListener(_onEdit);
    _code.dispose();
    super.dispose();
  }

  void _onEdit() {
    if (_error != null && _phase == _Phase.code) _error = null;
    setState(() {});
  }

  String get _normalized => normalizePairingCode(_code.text);
  bool get _complete => _normalized.length == widget.caps.codeLength;
  bool get _charsOk => pairingCodeCharsValid(_normalized);

  Future<void> _read({String? linkId, String? code}) async {
    setState(() {
      _phase = _Phase.reading;
      _error = null;
    });
    PairingPreviewResult result;
    try {
      result = await widget.port.preview(linkId: linkId, code: code);
    } catch (_) {
      result = const PairingPreviewResult.failed(PairingError.network);
    }
    if (!mounted) return;
    final request = result.request;
    if (request == null) {
      Haptics.error();
      setState(() {
        // A typed code goes back to its field, to be fixed; a scanned one
        // has nothing to fix here.
        _phase = _byCode ? _Phase.code : _Phase.failed;
        _error = pairingErrorText(
          result.error ?? PairingError.network,
          byCode: _byCode,
        );
      });
      return;
    }
    _request = request;
    _startCountdown(request.expiresIn);
    setState(() {
      _phase = _Phase.confirm;
      _error = request.accountActive ? null : SA.errInactive;
    });
  }

  void _startCountdown(Duration left) {
    _tick?.cancel();
    _left = left.isNegative ? Duration.zero : left;
    if (_left == Duration.zero) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      final next = _left - const Duration(seconds: 1);
      setState(() => _left = next.isNegative ? Duration.zero : next);
      if (_left == Duration.zero) t.cancel();
    });
  }

  bool get _expired => _request != null && _left == Duration.zero;

  Future<void> _approve() async {
    final request = _request;
    if (request == null || _phase == _Phase.approving) return;
    Haptics.tap();
    setState(() {
      _phase = _Phase.approving;
      _error = null;
    });
    PairingApproveResult result;
    try {
      result = await widget.port.approve(
        linkId: request.linkId,
        grantManage: request.canGrantManage && _grantManage,
      );
    } catch (_) {
      result = const PairingApproveResult.failed(PairingError.network);
    }
    if (!mounted) return;
    if (result.ok) {
      Haptics.success();
      _tick?.cancel();
      setState(() {
        _phase = _Phase.done;
        _added = result.device;
        _addedManage = result.manage;
      });
      return;
    }
    Haptics.error();
    if (result.error == PairingError.deviceLimitReached) {
      setState(() {
        _phase = _Phase.limit;
        _limit = result.deviceLimit ?? request.deviceLimit;
        _devices = result.devices;
      });
      return;
    }
    final error = result.error ?? PairingError.network;
    setState(() {
      // A request that is gone stays gone; anything else can be retried
      // from the same confirmation.
      final over =
          error == PairingError.linkExpired ||
          error == PairingError.linkCancelled ||
          error == PairingError.unknownLink;
      _phase = over ? _Phase.failed : _Phase.confirm;
      if (over) _tick?.cancel();
      _error = pairingErrorText(error, byCode: _byCode);
    });
  }

  /// Takes [device] off the account to make room, then goes on with the
  /// same request while it is still open.
  Future<void> _removeForRoom(AccountDevice device) async {
    final yes = await widget.showSheet<bool>([
      HipSheetTitle(S.accountRemoveDevice(device.name)),
      HipSheetActions(
        children: [
          Builder(
            builder: (c) => HipCta(
              S.aRemove,
              ghost: true,
              danger: true,
              onTap: () => Navigator.of(c).pop(true),
            ),
          ),
          Builder(
            builder: (c) => HipCta(
              S.aCancel,
              quiet: true,
              onTap: () => Navigator.of(c).pop(false),
            ),
          ),
        ],
      ),
    ]);
    if (yes != true || !mounted) return;
    setState(() => _error = null);
    DeviceChangeResult result;
    try {
      result = await withLastManagerCheck(
        widget.showSheet,
        (confirm) => widget.port.revoke(device.id, confirmLastManager: confirm),
      );
    } catch (_) {
      result = const DeviceChangeResult.failed(PairingError.network);
    }
    if (!mounted) return;
    if (!result.ok) {
      Haptics.error();
      if (result.error == PairingError.lastManager) return;
      setState(
        () => _error = pairingErrorText(result.error ?? PairingError.network),
      );
      return;
    }
    setState(
      () => _devices = _devices
          .where((d) => d.id != device.id)
          .toList(growable: false),
    );
    await _approve();
  }

  @override
  Widget build(BuildContext context) {
    // The sheet rides up with the keyboard instead of sitting under it.
    return Flexible(
      child: AnimatedPadding(
        duration: Hip.dur(const Duration(milliseconds: 150)),
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: switch (_phase) {
              _Phase.code => _codeView(),
              _Phase.reading => _readingView(),
              _Phase.confirm || _Phase.approving => _confirmView(),
              _Phase.limit => _limitView(),
              _Phase.done => _doneView(),
              _Phase.failed => _failedView(),
            },
          ),
        ),
      ),
    );
  }

  Widget _errorBox(String text) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: Hip.danger.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: Hip.sans(550, 13, color: Hip.danger, height: 1.4),
      ),
    ),
  );

  Widget _cancel({bool result = false}) => Builder(
    builder: (c) => HipCta(
      S.aCancel,
      quiet: true,
      onTap: () => Navigator.of(c).pop(result),
    ),
  );

  List<Widget> _codeView() {
    final local = _complete && !_charsOk ? SA.codeBadChars : null;
    final error = local ?? _error;
    final ready = _complete && _charsOk;
    return [
      const HipSheetTitle(SA.enterCode),
      if (widget.note != null) HipSheetBody(widget.note!),
      const HipSheetBody(SA.codeBody),
      const SizedBox(height: 16),
      HipCard(
        padding: const EdgeInsets.fromLTRB(18, 12, 10, 12),
        child: TextField(
          key: const ValueKey('pairing-code'),
          controller: _code,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          keyboardType: TextInputType.visiblePassword,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.done,
          inputFormatters: [PairingCodeFormatter(widget.caps.codeLength)],
          onSubmitted: (_) {
            if (ready) _read(code: _normalized);
          },
          style: Hip.mono(600, 24, color: Hip.ink, letterSpacing: 2),
          cursorColor: Hip.blue,
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: SA.codeHint,
            hintStyle: Hip.mono(
              600,
              24,
              color: Hip.muted2.withValues(alpha: .5),
              letterSpacing: 2,
            ),
          ),
        ),
      ),
      if (error != null) _errorBox(error),
      HipSheetActions(
        children: [
          HipCta(
            S.aContinue,
            onTap: ready ? () => _read(code: _normalized) : null,
          ),
          _cancel(),
        ],
      ),
    ];
  }

  List<Widget> _readingView() => [
    HipSheetTitle(_byCode ? SA.enterCode : SA.scanQr),
    const Padding(
      padding: EdgeInsets.symmetric(vertical: 30),
      child: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      ),
    ),
    HipSheetActions(children: [_cancel()]),
  ];

  String get _countdown {
    final m = _left.inMinutes.toString().padLeft(2, '0');
    final s = (_left.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  List<Widget> _confirmView() {
    final request = _request!;
    final device = request.device;
    final working = _phase == _Phase.approving;
    final name = device.name.isEmpty ? SA.deviceUnnamed : device.name;
    final blocked = !request.accountActive || _expired;
    return [
      const HipSheetTitle(SA.confirmTitle),
      const SizedBox(height: 16),
      _TargetCard(device: device, name: name),
      const SizedBox(height: 12),
      _CodeCompare(code: request.code),
      if (request.canGrantManage)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _ManageSwitch(
            value: _grantManage,
            onChanged: working ? null : (v) => setState(() => _grantManage = v),
          ),
        )
      else
        const HipSheetBody(SA.useOnly),
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            Text(
              SA.addInUse(request.devicesUsed, request.deviceLimit),
              style: Hip.sans(500, 13, color: Hip.muted, height: 1.45),
            ),
            Text(
              _expired ? SA.errExpired : SA.expiresIn(_countdown),
              style: _expired
                  ? Hip.sans(500, 13, color: Hip.muted, height: 1.45)
                  : Hip.mono(600, 12.5, color: Hip.muted, height: 1.45),
            ),
          ],
        ),
      ),
      if (_error != null) _errorBox(_error!),
      HipSheetActions(
        children: [
          HipCta(
            working ? SA.approving : SA.approve,
            onTap: working || blocked ? null : _approve,
          ),
          Builder(
            builder: (c) => HipCta(
              S.aCancel,
              quiet: true,
              onTap: working ? null : () => Navigator.of(c).pop(false),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _limitView() => [
    HipSheetTitle(SA.limitTitle(_limit)),
    const HipSheetBody(SA.limitBody),
    const SizedBox(height: 14),
    HipListGroup(
      children: [
        for (final d in _devices)
          HipListRow(
            leading: _KindTile(d.kind),
            title: d.name,
            titleBadge: d.current ? HipBadge.blue(S.accountThisDevice) : null,
            subtitle: d.kindLabel,
            trailing: d.current
                ? null
                : Semantics(
                    button: true,
                    label: S.aRemove,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _removeForRoom(d),
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(
                          Icons.link_off,
                          size: 18,
                          color: Hip.muted2,
                        ),
                      ),
                    ),
                  ),
          ),
      ],
    ),
    if (_error != null) _errorBox(_error!),
    HipSheetActions(children: [_cancel()]),
  ];

  List<Widget> _doneView() {
    final name = _added?.name ?? _request?.device.name ?? SA.deviceUnnamed;
    return [
      Center(
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: Hip.successSoft,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(Icons.check_rounded, size: 26, color: Hip.success),
        ),
      ),
      const SizedBox(height: 16),
      Text(
        SA.doneTitle,
        textAlign: TextAlign.center,
        style: Hip.sans(700, 20, color: Hip.ink, letterSpacing: -.4),
      ),
      const SizedBox(height: 8),
      Text(
        _addedManage ? SA.doneManage(name) : SA.doneBody(name),
        textAlign: TextAlign.center,
        style: Hip.sans(400, 14, color: Hip.muted, height: 1.5),
      ),
      HipSheetActions(
        children: [
          Builder(
            builder: (c) =>
                HipCta(SA.done, onTap: () => Navigator.of(c).pop(true)),
          ),
        ],
      ),
    ];
  }

  List<Widget> _failedView() => [
    HipSheetTitle(_byCode ? SA.enterCode : SA.scanQr),
    if (_error != null) _errorBox(_error!),
    HipSheetActions(
      children: [
        Builder(
          builder: (c) =>
              HipCta(S.aClose, onTap: () => Navigator.of(c).pop(false)),
        ),
      ],
    ),
  ];
}

/// The new device as it described itself: kind, name and platform.
class _TargetCard extends StatelessWidget {
  final PairingTarget device;
  final String name;
  const _TargetCard({required this.device, required this.name});

  @override
  Widget build(BuildContext context) {
    final platform = SA.platform(device.platform);
    return HipCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          _KindTile(device.kind, blue: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Hip.sans(650, 16.5, color: Hip.ink, height: 1.3),
                ),
                const SizedBox(height: 2),
                Text(
                  platform == null
                      ? deviceKindLabel(device.kind)
                      : '${deviceKindLabel(device.kind)}  ·  $platform',
                  style: Hip.sans(400, 13, color: Hip.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The request's short code, shown so it can be held against the one on
/// the new device's screen.
class _CodeCompare extends StatelessWidget {
  final String code;
  const _CodeCompare({required this.code});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Hip.blueSoft,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            SA.confirmCodeLabel.toUpperCase(),
            style: Hip.sans(650, 11.5, color: Hip.muted2, letterSpacing: .8),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              code,
              style: Hip.mono(700, 24, color: Hip.blueDeep, letterSpacing: 3),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            SA.confirmCodeNote,
            style: Hip.sans(400, 12.5, color: Hip.muted, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _ManageSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  const _ManageSwitch({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  SA.grantManage,
                  style: Hip.sans(650, 15, color: Hip.ink, height: 1.3),
                ),
                const SizedBox(height: 2),
                Text(
                  SA.grantManageSub,
                  style: Hip.sans(400, 12.5, color: Hip.muted, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch.adaptive(
            value: value,
            activeTrackColor: Hip.blue,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _KindTile extends StatelessWidget {
  final DeviceKind kind;
  final bool blue;
  const _KindTile(this.kind, {this.blue = false});

  @override
  Widget build(BuildContext context) => Container(
    width: 38,
    height: 38,
    decoration: BoxDecoration(
      color: blue ? Hip.blueSoft : Hip.line2,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Icon(
      deviceKindIcon(kind),
      size: 19,
      color: blue ? Hip.blue : Hip.inkSoft,
    ),
  );
}

/// Keeps a typed code to the code's own shape: upper case, no spaces, the
/// dash after the fourth character, no more than [length] characters.
/// Characters outside the alphabet stay, so the field can say which code
/// is wrong instead of silently eating what was typed.
class PairingCodeFormatter extends TextInputFormatter {
  final int length;
  const PairingCodeFormatter(this.length);

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var raw = normalizePairingCode(
      newValue.text,
    ).replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (raw.length > length) raw = raw.substring(0, length);
    final text = displayPairingCode(raw);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// One device on the account, opened from its row: what it is, when it was
/// added and last used, whether it manages the account, and the way to take
/// it off. Pops `true` when the device should be removed; a change to "can
/// manage" is made here and reported through [onChanged].
class DeviceSheet extends StatefulWidget {
  final AccountDevice device;
  final PairingPort port;
  final ShowSheet showSheet;
  final bool permissions;
  final ValueChanged<AccountDevice> onChanged;
  const DeviceSheet({
    super.key,
    required this.device,
    required this.port,
    required this.showSheet,
    required this.permissions,
    required this.onChanged,
  });

  @override
  State<DeviceSheet> createState() => _DeviceSheetState();
}

class _DeviceSheetState extends State<DeviceSheet> {
  late AccountDevice _device = widget.device;
  bool _working = false;
  String? _error;

  Future<void> _setManage(bool manage) async {
    setState(() {
      _working = true;
      _error = null;
    });
    DeviceChangeResult result;
    try {
      result = await withLastManagerCheck(
        widget.showSheet,
        (confirm) => widget.port.setManage(
          _device.id,
          manage: manage,
          confirmLastManager: confirm,
        ),
      );
    } catch (_) {
      result = const DeviceChangeResult.failed(PairingError.network);
    }
    if (!mounted) return;
    setState(() {
      _working = false;
      if (result.ok) {
        _device = result.device ?? _device.copyWith(manage: manage);
        widget.onChanged(_device);
        Haptics.success();
      } else if (result.error != PairingError.lastManager) {
        Haptics.error();
        _error = pairingErrorText(result.error ?? PairingError.network);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = _device;
    final words = Hip.sans(400, 13.5, color: Hip.muted, height: 1.5);
    final nums = Hip.mono(600, 12.5, color: Hip.muted, height: 1.5);
    final created = d.createdAt;
    final seen = d.lastSeenAt;
    final canChange = widget.permissions && kindCanManage(d.kind) && !d.current;
    return SheetScroll(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _KindTile(d.kind),
              const SizedBox(width: 12),
              Expanded(child: HipSheetTitle(d.name)),
              if (d.current) HipBadge.blue(S.accountThisDevice),
            ],
          ),
          const SizedBox(height: 12),
          Text(d.kindLabel, style: words),
          if (created != null)
            _dated(SA.deviceAdded, formatPremiumDate(created), words, nums),
          if (seen != null)
            _dated(SA.deviceSeen, formatPremiumDate(seen), words, nums)
          else
            Text(SA.deviceNeverUsed, style: words),
          const SizedBox(height: 14),
          if (canChange)
            _ManageSwitch(
              value: d.manage ?? false,
              onChanged: _working ? null : _setManage,
            )
          else if (!kindCanManage(d.kind))
            Text(SA.useOnly, style: words)
          else if (d.manage == true)
            Text(SA.deviceManages, style: words),
          if (_error != null) _errorBoxOf(_error!),
          HipSheetActions(
            children: [
              if (!d.current)
                Builder(
                  builder: (c) => HipCta(
                    S.aRemove,
                    ghost: true,
                    danger: true,
                    onTap: _working ? null : () => Navigator.of(c).pop(true),
                  ),
                ),
              Builder(
                builder: (c) => HipCta(
                  S.aClose,
                  quiet: true,
                  onTap: () => Navigator.of(c).pop(false),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// "Added Oct 6, 2026", the date in mono wherever a translation puts it.
  Widget _dated(
    String Function(String) line,
    String date,
    TextStyle words,
    TextStyle nums,
  ) {
    final text = line(date);
    final at = text.indexOf(date);
    if (at < 0) return Text(text, style: words);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: text.substring(0, at), style: words),
          TextSpan(text: date, style: nums),
          TextSpan(text: text.substring(at + date.length), style: words),
        ],
      ),
    );
  }

  Widget _errorBoxOf(String text) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(text, style: Hip.sans(550, 13, color: Hip.danger, height: 1.4)),
  );
}
