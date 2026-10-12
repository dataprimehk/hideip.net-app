import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/account_number.dart';
import '../../core/account_service.dart';
import '../../core/camera_permission.dart';
import '../../core/haptics.dart';
import '../../core/premium.dart';
import '../../core/sensitive_clipboard.dart';
import '../../state/app_pairing.dart';
import '../../state/app_state.dart';
import '../brand.dart';
import '../strings.dart';
import 'account/account_device.dart';
import 'account/account_port.dart';
import 'account/account_widgets.dart';
import 'account/new_device.dart';
import 'account/pairing_flow.dart';
import 'account/pairing_port.dart';
import 'hip.dart';
import 'hip_sheet.dart';
import 'linked_devices_screen.dart';
import 'paywall_screen.dart' show openStoreSubscriptions;
import 'shell.dart';

/// Copies [number] grouped, off the clipboard again after a minute. The
/// whole number, whether it is shown on screen or not.
Future<void> _copyNumber(AccountPort port, String number) async {
  Haptics.tap();
  await SensitiveClipboard.setText(
    displayAccountNumber(number),
    ttl: const Duration(seconds: 60),
  );
  port.toast(S.accountCopied);
}

bool _freshOpen = false;

/// The number a store purchase just made, once: whichever screen is up when
/// it arrives shows it, and closing the sheet is the acknowledgement. A
/// sheet that never got on screen acknowledges nothing, so the number waits
/// for the next chance.
Future<void> showFreshAccountNumber(
  AppState state,
  HipNav nav, {
  AccountPort? port,
}) async {
  final account = port ?? accountPortOf(state);
  final fresh = account.freshNumber;
  if (fresh == null || _freshOpen) return;
  _freshOpen = true;
  var shown = false;
  try {
    await nav.showSheet<void>([
      Builder(
        builder: (_) {
          shown = true;
          return const HipSheetTitle(S.accountFreshTitle);
        },
      ),
      Padding(
        padding: const EdgeInsets.only(top: 14),
        child: OneLine(
          Text(
            displayAccountNumber(fresh),
            style: Hip.mono(600, 22, color: Hip.ink, letterSpacing: 1.5),
          ),
        ),
      ),
      const HipSheetBody(S.accountFreshBody),
      HipSheetActions(
        children: [
          HipCta(S.accountCopy, onTap: () => _copyNumber(account, fresh)),
          Builder(
            builder: (c) => HipCta(
              S.aClose,
              quiet: true,
              onTap: () => Navigator.of(c).pop(),
            ),
          ),
        ],
      ),
    ]);
  } finally {
    _freshOpen = false;
    if (shown) account.ackFreshNumber();
  }
}

/// Settings → Account. Signed out it is the way in for a device whose
/// account is elsewhere: the QR code and the short code another device
/// approves (pairing v2), the account number, and a store restore. Signed
/// in it answers, top to bottom, the
/// questions people actually have: does Premium work and until when, how
/// it gets onto another device, what the number is for, how it is paid,
/// and, folded away, the rare ways to change or leave the account.
///
/// Nothing on this screen says where a number comes from. It is a sign-in.
class AccountScreen extends StatefulWidget {
  final AppState state;
  final HipNav nav;

  /// The account and pairing the screen talks to. Without them it reads
  /// [state] through the 1.2.0 adapters ([accountPortOf], [pairingPortOf]).
  final AccountPort? account;
  final PairingPort? pairing;

  /// This device asking another one for access. Without it the screen
  /// reads [state].
  final NewDevicePort? newDevice;

  /// Test seams for the camera: its permission and the scanner itself.
  final Future<CamPerm> Function()? camStatus;
  final ScanQr? scan;

  const AccountScreen({
    super.key,
    required this.state,
    required this.nav,
    this.account,
    this.pairing,
    this.newDevice,
    this.camStatus,
    this.scan,
  });

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final TextEditingController _field = TextEditingController();
  late final AccountPort _port = widget.account ?? accountPortOf(widget.state);
  late final PairingPort _pairing =
      widget.pairing ?? pairingPortOf(widget.state);
  late final NewDevicePort _newDevice =
      widget.newDevice ?? AppStateNewDevicePort(widget.state);
  late final Listenable _changes = Listenable.merge([
    _port.changes,
    _newDevice.changes,
  ]);

  bool _restoring = false;

  bool _busy = false;
  String? _error;
  bool _done = false;
  bool _savedOnly = false;
  bool _revealed = false;

  /// The rare actions, folded on every visit.
  bool _moreOpen = false;

  /// A device without its number asked to put it in.
  bool _enterNumber = false;

  AccountOverview? _overview;
  bool _loading = false;
  bool _statusFailed = false;
  String? _statusError;

  /// What the server can pair, asked once per visit. Until it answers the
  /// screen offers only what any server can finish.
  Future<PairingCapabilities>? _capsFuture;
  PairingCapabilities _caps = PairingCapabilities.unknown;

  /// Opens the number field on a device that holds the account without its
  /// number, filled with the one it last used when there is one.
  void _openNumberEntry() {
    final last = _port.lastNumber;
    if (last != null && _field.text.isEmpty) {
      _field.text = displayAccountNumber(last);
    }
    setState(() => _enterNumber = true);
  }

  /// The store this device bills through, for copy that names it.
  String get _store =>
      _port.storeName ??
      (defaultTargetPlatform == TargetPlatform.iOS
          ? 'App Store'
          : 'Google Play');

  @override
  void initState() {
    super.initState();
    _field.addListener(_onEdit);
    // Signed out, the number used last is filled in: signing back in is a
    // tap, the way the number cannot be shown again by the server.
    final last = _port.lastNumber;
    if (!_port.signedIn && last != null) {
      _field.text = displayAccountNumber(last);
    }
    if (_port.signedIn) {
      _loadStatus();
      _askCapabilities();
    }
    _newDevice.changes.addListener(_onNewDevice);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A request that finished while the screen was away has been shown
      // by the account it brought; its end is settled here.
      if (_newDevice.phase == LinkRequestPhase.done) _newDevice.clear();
      showFreshAccountNumber(widget.state, widget.nav, port: _port);
    });
  }

  /// Another device approved this one, and the account is stored here:
  /// the same moment as a sign-in going through.
  void _onNewDevice() {
    if (!mounted || _done) return;
    if (_newDevice.phase != LinkRequestPhase.done) return;
    Haptics.success();
    setState(() {
      _savedOnly = !_port.premiumFromAccount;
      _done = true;
    });
    _newDevice.clear();
  }

  /// Asks before this device's request would move it to another account
  /// (K10). Nothing changes until the new account is stored here.
  Future<bool> _confirmSwitch() => _confirm(
    title: S.accountSwitchTitle,
    body: _port.storeLinked || _port.hasStoreEntitlement
        ? S.accountSwitchBodyStore(_store)
        : S.accountSwitchBody,
    action: S.aContinue,
  );

  Future<void> _restore() async {
    if (_restoring || _busy) return;
    setState(() => _restoring = true);
    try {
      await _newDevice.restore();
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  void dispose() {
    _newDevice.changes.removeListener(_onNewDevice);
    withdrawNewDeviceRequest(_newDevice);
    _field.removeListener(_onEdit);
    _field.dispose();
    super.dispose();
  }

  void _onEdit() {
    // A new digit makes the last server answer stale.
    if (_error != null) _error = null;
    setState(() {});
  }

  Future<PairingCapabilities> _askCapabilities() {
    return _capsFuture ??= () async {
      PairingCapabilities caps;
      try {
        caps = await _pairing.capabilities();
      } catch (_) {
        caps = PairingCapabilities.unknown;
      }
      if (mounted) setState(() => _caps = caps);
      return caps;
    }();
  }

  String get _digits => normalizeAccountNumber(_field.text);

  bool get _complete => _digits.length == accountNumberLength;

  bool get _valid => _complete && luhnValid(_digits);

  Future<void> _loadStatus() async {
    setState(() {
      _loading = true;
      _statusFailed = false;
      _statusError = null;
    });
    AccountOverview? overview;
    try {
      // Opening this screen always asks, however recently the background
      // check did.
      overview = await _port.refresh(force: true);
    } catch (_) {
      overview = null;
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          if (overview != null && overview.result == AccountResult.ok) {
            _overview = overview;
          } else if (overview == null) {
            _statusFailed = true;
            _statusError = S.accountErrNetwork;
          } else if (overview.result == AccountResult.tooManyAttempts) {
            _statusFailed = true;
            _statusError = S.accountErrTooMany;
          }
        });
      }
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    var digits = extractAccountNumber(data?.text ?? '');
    if (digits.isEmpty) return;
    if (digits.length > accountNumberLength) {
      digits = digits.substring(0, accountNumberLength);
    }
    final text = displayAccountNumber(digits);
    _field.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _signIn() => _signInWith(_digits);

  /// Signs in with [digits]: the number typed into the field, or the one
  /// already kept when this device was signed out from elsewhere.
  Future<void> _signInWith(String digits) async {
    if (!isValidAccountNumber(digits) || _busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    AccountSignIn? result;
    try {
      result = await _port.signIn(digits);
    } catch (_) {
      result = null;
    } finally {
      if (mounted) {
        final r = result;
        if (r?.result == AccountResult.inactive) {
          // Signed in to an account with no time on it: the signed-in view
          // says so, and keeps the number for when time is added.
          _field.clear();
        }
        setState(() {
          _busy = false;
          switch (r?.result) {
            case AccountResult.ok:
              Haptics.success();
              // A store subscription that runs longer stays in force; the
              // number is kept, and the screen says only that.
              _savedOnly = !_port.premiumFromAccount;
              _done = true;
            case AccountResult.inactive:
              _error = null;
            default:
              Haptics.error();
              _error = _errorFor(
                r?.result ?? AccountResult.network,
                r?.deviceLimit ?? AccountService.defaultDeviceLimit,
              );
          }
        });
        if (r?.result == AccountResult.inactive) {
          _loadStatus();
          _askCapabilities();
        }
      }
    }
  }

  static String _errorFor(AccountResult r, int limit) => switch (r) {
    AccountResult.invalid => S.accountErrInvalid,
    AccountResult.unknown => S.accountErrUnknown,
    AccountResult.revoked => S.accountErrRevoked,
    AccountResult.deviceLimit => S.accountErrDeviceLimit(limit),
    AccountResult.tooManyAttempts => S.accountErrTooMany,
    _ => S.accountErrNetwork,
  };

  // --- Signed in -----------------------------------------------------------

  /// Asks in the same bottom sheet as the rotation: full-width buttons, the
  /// action on top and Cancel under it, so nothing wraps into a ragged column
  /// on a zoomed screen or with large text.
  ///
  /// [also] is a second way out that leaves the sheet up, such as the
  /// store's own page next to a delete.
  Future<bool> _confirm({
    required String title,
    String? body,
    required String action,
    bool danger = false,
    String? also,
    VoidCallback? onAlso,
  }) async {
    final yes = await widget.nav.showSheet<bool>([
      HipSheetTitle(title),
      if (body != null) HipSheetBody(body),
      HipSheetActions(
        children: [
          Builder(
            builder: (c) => AccountCta(
              action,
              danger: danger,
              onTap: () => Navigator.of(c).pop(true),
            ),
          ),
          if (also != null) AccountCta(also, ghost: true, onTap: onAlso),
          Builder(
            builder: (c) => AccountCta(
              S.aCancel,
              quiet: true,
              onTap: () => Navigator.of(c).pop(false),
            ),
          ),
        ],
      ),
    ]);
    return yes == true;
  }

  /// Showing the number asks first, wherever it is shown.
  Future<bool> _confirmReveal() => _confirm(
    title: S.accountReveal,
    body: S.accountKeepSafe,
    action: S.accountReveal,
  );

  Future<void> _toggleReveal() async {
    if (_revealed) {
      setState(() => _revealed = false);
      return;
    }
    final ok = await _confirmReveal();
    if (ok && mounted) setState(() => _revealed = true);
  }

  Future<void> _copy(String number) => _copyNumber(_port, number);

  /// Takes [device] off the account, after asking. With pairing v2 the
  /// server also guards the last device that manages the account, and the
  /// screen asks once more before that one goes.
  Future<void> _removeDevice(AccountDevice device) async {
    final ok = await _confirm(
      title: S.accountRemoveDevice(device.name),
      action: S.aRemove,
      danger: true,
    );
    if (!ok || !mounted) return;
    String? failure;
    if (_caps.permissions) {
      DeviceChangeResult result;
      try {
        result = await withLastManagerCheck(
          widget.nav.showSheet,
          (confirm) => _pairing.revoke(device.id, confirmLastManager: confirm),
        );
      } catch (_) {
        result = const DeviceChangeResult.failed(PairingError.network);
      }
      if (result.error == PairingError.lastManager) return;
      if (!result.ok) {
        failure = pairingErrorText(result.error ?? PairingError.network);
      }
    } else {
      AccountResult result;
      try {
        result = await _port.removeDevice(device.id);
      } catch (_) {
        result = AccountResult.network;
      }
      if (result != AccountResult.ok) {
        failure = _errorFor(result, AccountService.defaultDeviceLimit);
      }
    }
    if (!mounted) return;
    if (failure != null) {
      Haptics.error();
      _port.toast(failure);
      return;
    }
    Haptics.success();
    final overview = _overview;
    if (overview != null) {
      setState(
        () => _overview = overview.withDevices(
          overview.devices
              ?.where((d) => d.id != device.id)
              .toList(growable: false),
        ),
      );
    }
  }

  /// One device, opened from its row: its dates, who may manage the
  /// account, and the way to take it off.
  Future<void> _openDevice(AccountDevice device) async {
    final remove = await widget.nav.showSheet<bool>([
      DeviceSheet(
        device: device,
        port: _pairing,
        showSheet: widget.nav.showSheet,
        permissions: _caps.permissions,
        onChanged: (changed) {
          final overview = _overview;
          if (overview == null || !mounted) return;
          setState(
            () => _overview = overview.withDevices(
              overview.devices
                  ?.map((d) => d.id == changed.id ? changed : d)
                  .toList(growable: false),
            ),
          );
        },
      ),
    ]);
    if (remove == true && mounted) await _removeDevice(device);
  }

  /// Add a device: one sheet with every way there is. What it offers
  /// depends on what the server can pair, asked before it opens, so no row
  /// leads to a flow the server cannot finish.
  Future<void> _addDevice() async {
    if (_busy) return;
    Haptics.tap();
    final caps = await _askCapabilities();
    if (!mounted) return;
    final overview = _overview;
    final choice = await widget.nav.showSheet<AddDeviceChoice>([
      AddDeviceSheet(
        v2: caps.v2,
        canPair: _port.canLinkDevices,
        used: overview?.devices?.length,
        limit: overview?.deviceLimit ?? AccountService.defaultDeviceLimit,
        number: _port.numberKnown ? _port.number : null,
        confirmReveal: _confirmReveal,
        onCopy: _copy,
      ),
    ]);
    if (!mounted || choice == null) return;
    var added = false;
    switch (choice) {
      case AddDeviceChoice.scan:
        added = caps.v2
            ? await pairByScan(
                context,
                port: _pairing,
                showSheet: widget.nav.showSheet,
                caps: caps,
                scan: widget.scan ?? scanWithCamera,
                camStatus: widget.camStatus ?? CameraPermission.status,
              )
            : await scanToLinkDevice(context, state: widget.state);
      case AddDeviceChoice.code:
        added = await pairByCode(
          port: _pairing,
          showSheet: widget.nav.showSheet,
          caps: caps,
        );
      case AddDeviceChoice.legacyCode:
        final token = widget.state.subToken;
        if (token == null) return;
        await showLinkCodeSheet(context, state: widget.state, subToken: token);
        added = true;
    }
    if (added && mounted) await _loadStatus();
  }

  Future<void> _rotate() async {
    var also = false;
    final go = await widget.nav.showSheet<bool>([
      const HipSheetTitle(S.accountRotate),
      const HipSheetBody(S.accountRotateBody),
      StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setSheet(() => also = !also),
            child: Row(
              children: [
                Checkbox(
                  value: also,
                  activeColor: Hip.blue,
                  onChanged: (v) => setSheet(() => also = v ?? false),
                ),
                Expanded(
                  child: Text(
                    S.accountRotateAlso,
                    style: Hip.sans(550, 14, color: Hip.ink),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      HipSheetActions(
        children: [
          Builder(
            builder: (c) =>
                HipCta(S.accountRotate, onTap: () => Navigator.of(c).pop(true)),
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
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    AccountRotate result;
    try {
      result = await _port.rotate(revokeDevices: also);
    } catch (_) {
      result = const AccountRotate(AccountResult.network);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final fresh = result.accountNumber;
    if (result.maybeIssued) {
      // The old number is gone and the new one never arrived. Only support
      // can hand it over now, and the user should hear that plainly rather
      // than be told to try again.
      Haptics.error();
      await widget.nav.showSheet<void>([
        const HipSheetTitle(S.accountRotate),
        const HipSheetBody(S.accountRotateLost),
        HipSheetActions(
          children: [
            Builder(
              builder: (c) =>
                  HipCta(S.aClose, onTap: () => Navigator.of(c).pop()),
            ),
          ],
        ),
      ]);
      return;
    }
    if (result.result != AccountResult.ok || fresh == null) {
      Haptics.error();
      _port.toast(_errorFor(result.result, AccountService.defaultDeviceLimit));
      return;
    }
    Haptics.success();
    // The new number, once, with the one thing worth doing with it.
    await widget.nav.showSheet<void>([
      const HipSheetTitle(S.accountRotateDone),
      Padding(
        padding: const EdgeInsets.only(top: 14),
        child: OneLine(
          Text(
            displayAccountNumber(fresh),
            style: Hip.mono(600, 22, color: Hip.ink, letterSpacing: 1.5),
          ),
        ),
      ),
      const HipSheetBody(S.accountKeepSafe),
      HipSheetActions(
        children: [
          HipCta(S.accountCopy, onTap: () => _copy(fresh)),
          Builder(
            builder: (c) => HipCta(
              S.aClose,
              quiet: true,
              onTap: () => Navigator.of(c).pop(),
            ),
          ),
        ],
      ),
    ]);
    if (mounted) await _loadStatus();
  }

  /// Signs this device out, after asking. Also the first half of "Sign in
  /// with the new number" and "Sign in with another number": once signed
  /// out the screen is the sign-in form.
  Future<void> _signOut() async {
    final ok = await _confirm(
      title: S.accountSignOut,
      body: _port.storeLinked
          ? S.accountSignOutBodyLinked(_store)
          : _port.storeEntitlementLive
          ? S.accountSignOutBodyStore(_store)
          : S.accountSignOutBody,
      action: S.accountSignOut,
      danger: true,
    );
    if (!ok || !mounted) return;
    try {
      await _port.signOut();
    } catch (_) {
      if (mounted) _port.toast(S.accountErrNetwork);
    }
    if (!mounted) return;
    setState(() {
      _revealed = false;
      _overview = null;
      _statusFailed = false;
      _moreOpen = false;
      _field.clear();
    });
  }

  /// Deletes the number for good. A store subscription goes on billing
  /// until it is cancelled in the store, so the sheet says so and offers
  /// the store's page right there.
  Future<void> _delete() async {
    final store = _port.storeLinked || _port.hasStoreEntitlement;
    final ok = await _confirm(
      title: S.accountDelete,
      body: store ? S.accountDeleteBodyStore(_store) : S.accountDeleteBody,
      action: S.accountDelete,
      danger: true,
      also: store ? S.accountManageStore(_store) : null,
      onAlso: store ? openStoreSubscriptions : null,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    AccountResult result;
    try {
      result = await _port.deleteNumber();
    } catch (_) {
      result = AccountResult.network;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (result != AccountResult.ok) {
      Haptics.error();
      _port.toast(_errorFor(result, AccountService.defaultDeviceLimit));
      return;
    }
    Haptics.success();
    _port.toast(S.accountDeleted);
    setState(() {
      _revealed = false;
      _overview = null;
      _statusFailed = false;
      _moreOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _changes,
      builder: (context, _) {
        if (_done) return _success();
        final signedIn = _port.signedIn;
        return SafeArea(
          child: Column(
            children: [
              HipNavHead(
                title: S.accountTitle,
                onBack: widget.nav.back,
                trailing: signedIn && _loading
                    ? const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : null,
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: signedIn ? _signedIn() : _notSignedIn(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Not signed in: the code another device approves, then the account
  /// number, then the store's restore. A server without pairing v2 leaves
  /// the number and the restore, as in 1.2.0.
  List<Widget> _notSignedIn() => [
    if (newDeviceOffered(_newDevice.phase)) ...[
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 14),
        child: Text(
          S.accountNewDeviceIntro,
          style: Hip.sans(400, 14, color: Hip.muted, height: 1.5),
        ),
      ),
      NewDeviceCard(port: _newDevice, confirmSwitch: _confirmSwitch),
      const HipSectionLabel(S.accountNewDeviceOrNumber),
    ],
    ..._signInForm(),
    if (_newDevice.canRestore) ...[
      AccountCta(
        S.pwRestore,
        quiet: true,
        onTap: _restoring || _busy ? null : _restore,
      ),
      const SizedBox(height: 24),
    ],
  ];

  List<Widget> _signInForm() {
    final localError = _complete && !_valid ? S.accountErrInvalid : null;
    final error = localError ?? _error;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
        child: Text(
          S.accountHelp,
          style: Hip.sans(400, 14, color: Hip.muted, height: 1.5),
        ),
      ),
      HipCard(
        padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
        child: Row(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final size = accountFieldFontSize(
                    box.maxWidth,
                    MediaQuery.textScalerOf(context),
                  );
                  final spacing = size < 24 ? 1.0 : 2.0;
                  return TextField(
                    controller: _field,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    inputFormatters: const [AccountNumberFormatter()],
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _signIn(),
                    style: Hip.mono(
                      600,
                      size,
                      color: Hip.ink,
                      letterSpacing: spacing,
                    ),
                    cursorColor: Hip.blue,
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: S.accountFieldHint,
                      hintStyle: Hip.mono(
                        600,
                        size,
                        color: Hip.muted2.withValues(alpha: .5),
                        letterSpacing: spacing,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: _busy ? null : _paste,
          icon: Icon(Icons.content_paste_outlined, size: 16, color: Hip.blue),
          label: Text(
            S.accountPaste,
            style: Hip.sans(600, 13.5, color: Hip.blue),
          ),
        ),
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
          child: Text(
            error,
            style: Hip.sans(500, 13.5, color: Hip.danger, height: 1.45),
          ),
        ),
      const SizedBox(height: 10),
      HipCta(
        S.accountCtaSignIn,
        connect: true,
        onTap: _valid && !_busy ? _signIn : null,
      ),
      if (_busy)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Hip.muted2,
              ),
            ),
          ),
        ),
      const SizedBox(height: 24),
    ];
  }

  /// The status card: where the account stands, in one color and one
  /// title, with the one action the state asks for. A server verdict about
  /// the number itself outranks anything about its time.
  Widget _status() {
    final issue = _port.issue;
    if (issue == AccountIssue.revoked) {
      return AccountStatusCard(
        tone: StatusTone.bad,
        title: S.accountStatusRevoked,
        line: S.accountErrRevoked,
        actions: [
          AccountCta(
            S.accountCtaSignInAnotherNumber,
            connect: true,
            onTap: _busy ? null : _signOut,
          ),
        ],
      );
    }
    if (issue == AccountIssue.numberReplaced) {
      return AccountStatusCard(
        tone: StatusTone.off,
        title: S.accountStatusReplaced,
        line: S.accountStatusReplacedLine,
        // Only said while it is true here and now.
        fine: _port.premiumOn ? S.accountStatusReplacedStillOn : null,
        actions: [
          AccountCta(
            S.accountCtaSignInNewNumber,
            connect: true,
            onTap: _busy ? null : _signOut,
          ),
        ],
      );
    }
    final known = _port.numberKnown;
    if (_port.deviceSignedOut) {
      final number = _port.number;
      return AccountStatusCard(
        tone: StatusTone.off,
        title: S.accountStatusSignedOut,
        line: S.accountStatusSignedOutLine,
        fine: known ? S.accountStatusSignedOutKept : null,
        actions: [
          if (known && number != null)
            AccountCta(
              S.accountCtaSignIn,
              connect: true,
              onTap: _busy ? null : () => _signInWith(number),
            ),
        ],
      );
    }
    // The server's word, not the date: time can be added from anywhere.
    final expires = _port.expires;
    final date = expires == null ? '' : formatPremiumDate(expires);
    if (_port.active) {
      final linked = _port.storeLinked && _port.storeName != null;
      return AccountStatusCard(
        tone: StatusTone.on,
        title: S.accountStatusOn,
        line: expires == null ? null : S.accountActiveUntil(date),
        lineMono: date,
        fine: linked
            ? S.accountStatusRenewsThrough(_store)
            : expires == null
            ? null
            : S.accountStatusEndsUnlessAdded,
      );
    }
    final plans = _port.plansOffered;
    return AccountStatusCard(
      tone: StatusTone.off,
      title: S.accountStatusOff,
      line: expires == null ? null : S.accountEndedOn(date),
      lineMono: date,
      fine: S.accountOutOfTimeNote,
      actions: [
        if (plans)
          AccountCta(
            S.aSeePlans,
            onTap: () => widget.nav.openPaywall(from: HipScreen.account),
          ),
        // With plans on offer this is the quiet second way; without, the
        // only one.
        AccountCta(
          S.accountCheckAgain,
          quiet: plans,
          onTap: _loading ? null : _loadStatus,
        ),
      ],
    );
  }

  /// Signed in, the screen is where Premium lives. The devices and every
  /// way to change the account show only while this device may manage it;
  /// a device taken off, or a number that stopped working, gets the
  /// reason, the way back in and the way out, nothing more.
  List<Widget> _signedIn() {
    final known = _port.numberKnown;
    final number = _port.number ?? '';
    final manage = _port.canManage;
    final live = _port.issue == null && !_port.deviceSignedOut;
    final linked = _port.storeLinked && _port.storeName != null;
    return [
      const SizedBox(height: 4),
      _status(),
      if (_error != null && _port.deviceSignedOut)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            _error!,
            style: Hip.sans(500, 13.5, color: Hip.danger, height: 1.45),
          ),
        ),
      if (manage) ..._devicesSection(),
      CountedSectionLabel(S.accountNumberTitle),
      if (known) ...[
        HipCard(
          child: AccountNumberBlock(
            number: number,
            revealed: _revealed,
            onToggle: _toggleReveal,
            onCopy: () => _copy(number),
          ),
        ),
        const AccountNote(S.accountNumberNote),
      ] else
        HipCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                S.accountNumberNotHere,
                style: Hip.sans(650, 15.5, color: Hip.ink, height: 1.35),
              ),
              const SizedBox(height: 6),
              Text(
                S.accountNumberNotHereNote,
                style: Hip.sans(400, 13.5, color: Hip.muted, height: 1.45),
              ),
              // The two ways out, each with what it takes: the number from
              // wherever it is kept, or a new one when it is kept nowhere.
              if (!_enterNumber) ...[
                const SizedBox(height: 12),
                Text(
                  S.accountNumberFromOther,
                  style: Hip.sans(400, 13.5, color: Hip.muted, height: 1.45),
                ),
                const SizedBox(height: 10),
                AccountCta(
                  S.accountEnterNumber,
                  ghost: true,
                  onTap: _openNumberEntry,
                ),
                if (manage) ...[
                  const SizedBox(height: 16),
                  Text(
                    S.accountNumberNoOther,
                    style:
                        Hip.sans(400, 13.5, color: Hip.muted, height: 1.45),
                  ),
                  const SizedBox(height: 10),
                  AccountCta(
                    S.accountRotate,
                    ghost: true,
                    onTap: _busy ? null : _rotate,
                  ),
                ],
              ],
            ],
          ),
        ),
      if (!known && _enterNumber) ...[
        const SizedBox(height: 16),
        ..._signInForm(),
      ],
      if (_port.storeLinkedElsewhere)
        AccountNote(S.accountLinkedElsewhere(_store)),
      if (live && linked) ...[
        const CountedSectionLabel(S.accountPaymentTitle),
        HipListGroup(
          children: [
            _BillingRow(
              store: _store,
              renews: _port.storeRenews,
              onManage: openStoreSubscriptions,
            ),
          ],
        ),
      ]
      // A number in force with nothing paying for it from this device: the
      // store subscription is offered here, and its time goes onto it. Not
      // once the time has run out: See plans in the card already leads to
      // the same place.
      else if (live &&
          _port.active &&
          manage &&
          !_port.hasStoreEntitlement &&
          _port.plansOffered) ...[
        const CountedSectionLabel(S.accountPaymentTitle),
        HipListGroup(
          children: [
            AccountRow(
              leading: const AccountTile(Icons.add),
              title: S.accountSubscribeStore(_store),
              subtitle: S.accountSubscribeSub,
              onTap: () => widget.nav.openPaywall(from: HipScreen.account),
            ),
          ],
        ),
      ],
      if (manage)
        ..._moreOptions()
      else ...[
        const SizedBox(height: 18),
        HipListGroup(children: [_signOutRow()]),
      ],
      const SizedBox(height: 24),
    ];
  }

  /// Devices: how many of the places are taken, which devices they are,
  /// and the one way to add another. The list stays when the time runs
  /// out; only adding waits for Premium.
  List<Widget> _devicesSection() {
    final overview = _overview;
    final devices = overview?.devices;
    final limit = overview?.deviceLimit ?? AccountService.defaultDeviceLimit;
    final active = _port.active;
    final canAdd = _port.canLinkDevices || _port.numberKnown;
    final permissions = _caps.permissions;
    return [
      CountedSectionLabel(
        S.accountDevicesTitle,
        count: devices == null
            ? null
            : S.accountDevicesCount(devices.length, limit),
      ),
      if (devices != null) ...[
        DeviceMeter(used: devices.length, limit: limit),
        const SizedBox(height: 10),
      ],
      HipListGroup(
        children: [
          if (_statusFailed)
            HipListRow(
              title: _statusError ?? S.accountDevicesFailed,
              titleMaxLines: 3,
              trailing: Icon(Icons.refresh, size: 17, color: Hip.muted2),
              onTap: _loadStatus,
            )
          else if (devices != null && devices.isEmpty)
            HipListRow(title: S.accountDevicesEmpty, titleMaxLines: 2)
          else if (devices == null && _loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          for (final d in devices ?? const <AccountDevice>[])
            _AccountDeviceRow(
              device: d,
              own: d.current || d.id == _port.deviceId,
              onTap: permissions ? () => _openDevice(d) : null,
              onRemove: d.current || d.id == _port.deviceId
                  ? null
                  : () => _removeDevice(d),
            ),
          if (!active)
            Opacity(
              opacity: .5,
              child: AccountRow(
                leading: const AccountTile(Icons.add),
                title: S.accountAddDevice,
                subtitle: S.accountAddDeviceOff,
                chevron: false,
              ),
            )
          else if (canAdd)
            AccountRow(
              leading: const AccountTile(Icons.add, blue: true),
              title: S.accountAddDevice,
              titleColor: Hip.blue,
              subtitle: S.accountAddDeviceSub,
              onTap: _busy ? null : _addDevice,
            ),
        ],
      ),
    ];
  }

  Widget _signOutRow() => AccountRow(
    leading: const AccountTile(Icons.logout),
    title: S.accountSignOut,
    onTap: _busy ? null : _signOut,
  );

  /// The rare actions, folded until asked for.
  List<Widget> _moreOptions() => [
    const SizedBox(height: 8),
    MoreOptionsHeader(
      open: _moreOpen,
      onTap: () => setState(() => _moreOpen = !_moreOpen),
    ),
    if (_moreOpen) ...[
      const SizedBox(height: 4),
      HipListGroup(
        children: [
          AccountRow(
            leading: const AccountTile(Icons.autorenew),
            title: S.accountRotate,
            subtitle: S.accountRotateSub,
            onTap: _busy ? null : _rotate,
          ),
          _signOutRow(),
          AccountRow(
            leading: AccountTile(Icons.delete_outline, color: Hip.danger),
            title: S.accountDelete,
            titleColor: Hip.danger,
            onTap: _busy ? null : _delete,
          ),
        ],
      ),
    ],
  ];

  /// Signed in and live: the same moment as a purchase going through, on
  /// the app's own surface.
  Widget _success() {
    final expires = _port.expires;
    final date = expires == null ? null : formatPremiumDate(expires);
    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 46),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Brand.hsl(152, 60, 46, .16),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.check, size: 30, color: Hip.success),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    S.pwDoneTitle,
                    style: Hip.sans(
                      750,
                      23,
                      color: Hip.ink,
                      letterSpacing: -.64,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _savedOnly ? S.accountSaved : S.pwDonePaid,
                    textAlign: TextAlign.center,
                    style: Hip.sans(400, 13.5, color: Hip.muted, height: 1.5),
                  ),
                  if (date != null && !_savedOnly) ...[
                    const SizedBox(height: 4),
                    Text.rich(
                      monoIn(
                        S.accountActiveUntil(date),
                        date,
                        Hip.sans(400, 13.5, color: Hip.muted, height: 1.5),
                        Hip.mono(600, 12.5, color: Hip.muted, height: 1.5),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
            child: HipCta(
              S.pwDoneCta,
              onTap: () => widget.nav.go(HipScreen.home),
            ),
          ),
        ],
      ),
    );
  }
}

/// The largest monospace size, up to 24, at which a whole grouped account
/// number fits in [width] once the system text size is applied. With Display
/// Zoom or a larger text setting the fixed 24 ran past the field and iOS
/// showed "0000 0000 0000 ...", so the field shrinks instead, but never below
/// 14 (past that the number scrolls inside the field as before).
@visibleForTesting
double accountFieldFontSize(double width, TextScaler scaler) {
  const chars = 19; // "0000 0000 0000 0000"
  const advance = .6; // JetBrains Mono glyph width per em
  const caret = 4.0;
  for (var size = 24.0; size > 14; size -= .5) {
    final spacing = size < 24 ? 1.0 : 2.0;
    if (chars * (advance * scaler.scale(size) + spacing) + caret <= width) {
      return size;
    }
  }
  return 14;
}

/// What pays for the account from this device: the store, its next charge
/// (mono), and the store's own page. The line wraps rather than cut the
/// date off on a zoomed screen.
class _BillingRow extends StatelessWidget {
  final String store;
  final DateTime? renews;
  final VoidCallback onManage;
  const _BillingRow({
    required this.store,
    required this.renews,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final words = Hip.sans(550, 14, color: Hip.ink, height: 1.4);
    final nums = Hip.mono(600, 13, color: Hip.ink, height: 1.4);
    final r = renews;
    final date = r == null ? '' : formatPremiumDate(r);
    final line = r == null
        ? S.accountBillingUndated(store)
        : S.accountBilling(store, date);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      child: Row(
        children: [
          Expanded(child: Text.rich(monoIn(line, date, words, nums))),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onManage,
            child: Text(
              S.accountManage,
              style: Hip.sans(650, 14, color: Hip.blue),
            ),
          ),
        ],
      ),
    );
  }
}

/// One device on the account: kind icon, name, the date it was added
/// (mono), and a way to take it off. This device carries a badge instead;
/// leaving is what signing out is for. With pairing v2 a tap opens the
/// device, where its right to manage the account can be changed.
class _AccountDeviceRow extends StatelessWidget {
  final AccountDevice device;
  final bool own;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  const _AccountDeviceRow({
    required this.device,
    required this.own,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final created = device.createdAt;
    final words = Hip.sans(400, 12.5, color: Hip.muted);
    final dates = Hip.mono(600, 11.5, color: Hip.muted);
    Widget row = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          AccountTile(deviceKindIcon(device.kind)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The badge moves under a long name rather than push it
                // off the row with large text.
                Wrap(
                  spacing: 7,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      device.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Hip.sans(
                        650,
                        15.5,
                        color: Hip.ink,
                        letterSpacing: -.15,
                      ),
                    ),
                    if (own) HipBadge.blue(S.accountThisDevice),
                  ],
                ),
                const SizedBox(height: 2),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: device.kindLabel, style: words),
                      if (created != null) ...[
                        TextSpan(text: '  ·  ', style: words),
                        TextSpan(
                          text: formatPremiumDate(created),
                          style: dates,
                        ),
                      ],
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (onRemove != null) ...[
            const SizedBox(width: 12),
            Semantics(
              button: true,
              label: S.aRemove,
              child: GestureDetector(
                onTap: onRemove,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(Icons.link_off, size: 18, color: Hip.muted2),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    final tap = onTap;
    if (tap != null) {
      row = InkWell(
        onTap: tap,
        borderRadius: HipRowSlot.cornersOf(context),
        child: row,
      );
    }
    final remove = onRemove;
    if (remove == null) return row;
    return Dismissible(
      key: ValueKey('account-device:${device.id}'),
      direction: DismissDirection.endToStart,
      // The dialog decides; a swipe alone never takes a device off.
      confirmDismiss: (_) async {
        remove();
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
}
