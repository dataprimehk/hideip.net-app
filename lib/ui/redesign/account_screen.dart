import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/account_number.dart';
import '../../core/account_service.dart';
import '../../core/device_link.dart';
import '../../core/haptics.dart';
import '../../core/premium.dart';
import '../../core/sensitive_clipboard.dart';
import '../../state/app_state.dart';
import '../brand.dart';
import '../strings.dart';
import 'hip.dart';
import 'hip_sheet.dart';
import 'shell.dart';

/// A sentence with [mono] set in the mono face and the rest in [words]. The
/// date inside a status line is a number, so it gets the number face even
/// when a translation moves it around.
InlineSpan _monoIn(String line, String mono, TextStyle words, TextStyle nums) {
  final at = mono.isEmpty ? -1 : line.indexOf(mono);
  if (at < 0) return TextSpan(text: line, style: words);
  return TextSpan(
    children: [
      if (at > 0) TextSpan(text: line.substring(0, at), style: words),
      TextSpan(text: mono, style: nums),
      if (at + mono.length < line.length)
        TextSpan(text: line.substring(at + mono.length), style: words),
    ],
  );
}

/// Settings → Account number: one screen, two states. Signed out it is a
/// sign-in form (the number is the only credential there is); signed in it
/// shows the number, how long the account runs, the devices on it, and the
/// ways to change or leave it.
///
/// Nothing on this screen says where a number comes from. It is a sign-in.
class AccountScreen extends StatefulWidget {
  final AppState state;
  final HipNav nav;
  const AccountScreen({super.key, required this.state, required this.nav});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final TextEditingController _field = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _done = false;
  bool _savedOnly = false;
  bool _revealed = false;

  AccountStatus? _status;
  bool _loading = false;
  bool _statusFailed = false;
  String? _statusError;

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _field.addListener(_onEdit);
    if (_state.accountSignedIn) _loadStatus();
  }

  @override
  void dispose() {
    _field.removeListener(_onEdit);
    _field.dispose();
    super.dispose();
  }

  void _onEdit() {
    // A new digit makes the last server answer stale.
    if (_error != null) _error = null;
    setState(() {});
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
    AccountStatus? status;
    try {
      // Opening this screen always asks, however recently the background
      // check did.
      status = await _state.refreshAccount(force: true);
    } catch (_) {
      status = null;
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          if (status != null && status.result == AccountResult.ok) {
            _status = status;
          } else if (status == null) {
            _statusFailed = true;
            _statusError = S.accountErrNetwork;
          } else if (status.result == AccountResult.tooManyAttempts) {
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
    var digits = normalizeAccountNumber(data?.text ?? '');
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
      result = await _state.signInWithAccountNumber(digits);
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
              _savedOnly = _state.premium.source != PremiumSource.account;
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
        if (r?.result == AccountResult.inactive) _loadStatus();
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

  Future<bool> _confirm({
    required String title,
    String? body,
    required String action,
    bool danger = false,
  }) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Hip.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Hip.radius),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Hip.sans(650, 17, color: Hip.ink)),
              if (body != null) ...[
                const SizedBox(height: 10),
                Text(
                  body,
                  style: Hip.sans(550, 14, color: Hip.inkSoft, height: 1.45),
                ),
              ],
              const SizedBox(height: 18),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: Text(
                      S.aCancel,
                      style: Hip.sans(650, 14, color: Hip.muted),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: Text(
                      action,
                      style: Hip.sans(
                        650,
                        14,
                        color: danger ? Hip.danger : Hip.blue,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return yes == true;
  }

  Future<void> _toggleReveal() async {
    if (_revealed) {
      setState(() => _revealed = false);
      return;
    }
    final ok = await _confirm(
      title: S.accountReveal,
      body: S.accountKeepSafe,
      action: S.accountReveal,
    );
    if (ok && mounted) setState(() => _revealed = true);
  }

  Future<void> _copy(String number) async {
    Haptics.tap();
    await SensitiveClipboard.setText(
      displayAccountNumber(number),
      ttl: const Duration(seconds: 60),
    );
    _state.showToast(S.accountCopied);
  }

  Future<void> _removeDevice(LinkedDevice device) async {
    final ok = await _confirm(
      title: S.accountRemoveDevice(device.name),
      action: S.aRemove,
      danger: true,
    );
    if (!ok || !mounted) return;
    AccountResult result;
    try {
      result = await _state.removeAccountDevice(device.id);
    } catch (_) {
      result = AccountResult.network;
    }
    if (!mounted) return;
    if (result == AccountResult.ok) {
      Haptics.success();
      final status = _status;
      if (status != null) {
        setState(
          () => _status = AccountStatus(
            status.result,
            active: status.active,
            expires: status.expires,
            kind: status.kind,
            devices: status.devices
                ?.where((d) => d.id != device.id)
                .toList(growable: false),
            deviceLimit: status.deviceLimit,
          ),
        );
      }
    } else {
      Haptics.error();
      _state.showToast(_errorFor(result, AccountService.defaultDeviceLimit));
    }
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
      result = await _state.rotateAccountNumber(revokeDevices: also);
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
      _state.showToast(
        _errorFor(result.result, AccountService.defaultDeviceLimit),
      );
      return;
    }
    Haptics.success();
    // The new number, once, with the one thing worth doing with it.
    await widget.nav.showSheet<void>([
      const HipSheetTitle(S.accountRotateDone),
      Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Text(
          displayAccountNumber(fresh),
          style: Hip.mono(600, 22, color: Hip.ink, letterSpacing: 1.5),
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

  Future<void> _signOut() async {
    final ok = await _confirm(
      title: S.accountSignOut,
      body: S.accountSignOutBody,
      action: S.accountSignOut,
      danger: true,
    );
    if (!ok || !mounted) return;
    try {
      await _state.signOutAccount();
    } catch (_) {
      if (mounted) _state.showToast(S.accountErrNetwork);
    }
    if (!mounted) return;
    setState(() {
      _revealed = false;
      _status = null;
      _statusFailed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return _success();
    final signedIn = _state.accountSignedIn;
    return SafeArea(
      child: Column(
        children: [
          HipNavHead(
            title: S.accountNumberTitle,
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
              children: signedIn ? _signedIn() : _signInForm(),
            ),
          ),
        ],
      ),
    );
  }

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
              child: TextField(
                controller: _field,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                inputFormatters: const [AccountNumberFormatter()],
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _signIn(),
                style: Hip.mono(600, 24, color: Hip.ink, letterSpacing: 2),
                cursorColor: Hip.blue,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: S.accountFieldHint,
                  hintStyle: Hip.mono(
                    600,
                    24,
                    color: Hip.muted2.withValues(alpha: .5),
                    letterSpacing: 2,
                  ),
                ),
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

  /// Where the account stands, in one line. A server verdict about the
  /// number itself outranks anything about its time.
  Widget _standing() {
    final words = Hip.sans(500, 13.5, color: Hip.muted, height: 1.45);
    final nums = Hip.mono(600, 12.5, color: Hip.muted, height: 1.45);
    final issue = _state.accountIssue;
    if (issue == AccountIssue.revoked) {
      return Text(
        S.accountErrRevoked,
        style: words.copyWith(color: Hip.danger),
      );
    }
    if (issue == AccountIssue.numberReplaced) {
      return Text(S.accountNumberReplaced, style: words);
    }
    if (_state.accountDeviceSignedOut) {
      return Text(S.accountDeviceSignedOut, style: words);
    }
    // The server's word, not the date: time can be added from anywhere.
    final expires = _state.accountExpires;
    if (_state.accountActive) {
      if (expires == null) return const SizedBox.shrink();
      final date = formatPremiumDate(expires);
      return Text.rich(_monoIn(S.accountActiveUntil(date), date, words, nums));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(S.accountOutOfTime, style: words.copyWith(color: Hip.ink)),
        if (expires != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text.rich(
              _monoIn(
                S.accountEndedOn(formatPremiumDate(expires)),
                formatPremiumDate(expires),
                words,
                nums,
              ),
            ),
          ),
      ],
    );
  }

  /// The number is fine but has no time left: the one state where the
  /// screen offers a way forward instead of only saying where things stand.
  bool get _outOfTime =>
      !_state.accountActive &&
      _state.accountIssue == null &&
      !_state.accountDeviceSignedOut;

  List<Widget> _signedIn() {
    final number = _state.accountNumber ?? '';
    final ownId = _state.accountDeviceId;
    final devices = _status?.devices;
    return [
      HipCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _revealed
                  ? displayAccountNumber(number)
                  : maskAccountNumber(number),
              style: Hip.mono(600, 20, color: Hip.ink, letterSpacing: 1.2),
            ),
            const SizedBox(height: 8),
            _standing(),
            if (_outOfTime) ...[
              const SizedBox(height: 6),
              Text(
                S.accountOutOfTimeNote,
                style: Hip.sans(400, 13.5, color: Hip.muted, height: 1.45),
              ),
              const SizedBox(height: 12),
              HipCta(
                S.accountCheckAgain,
                onTap: _loading ? null : _loadStatus,
              ),
              if (kPlansAvailable && _state.plansOffered) ...[
                const SizedBox(height: 8),
                HipCta(
                  S.aSeePlans,
                  quiet: true,
                  onTap: () =>
                      widget.nav.openPaywall(from: HipScreen.account),
                ),
              ],
            ],
            if (_state.accountDeviceSignedOut) ...[
              const SizedBox(height: 12),
              HipCta(
                S.accountCtaSignIn,
                connect: true,
                onTap: _busy
                    ? null
                    : () => _signInWith(_state.accountNumber ?? ''),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MiniAction(
                  icon: _revealed
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  label: _revealed ? S.accountHide : S.accountReveal,
                  onTap: _toggleReveal,
                ),
                _MiniAction(
                  icon: Icons.copy_outlined,
                  label: S.accountCopy,
                  onTap: () => _copy(number),
                ),
              ],
            ),
          ],
        ),
      ),
      if (_error != null && _state.accountDeviceSignedOut)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            _error!,
            style: Hip.sans(500, 13.5, color: Hip.danger, height: 1.45),
          ),
        ),
      const HipSubnote(S.accountKeepSafe),
      HipSectionLabel(S.accountDevices),
      if (_statusFailed)
        HipListGroup(
          children: [
            HipListRow(
              title: _statusError ?? S.accountErrNetwork,
              trailing: Icon(Icons.refresh, size: 17, color: Hip.muted2),
              onTap: _loadStatus,
            ),
          ],
        )
      else if (devices != null && devices.isNotEmpty)
        HipListGroup(
          children: [
            for (final d in devices)
              _AccountDeviceRow(
                device: d,
                own: d.id == ownId,
                onRemove: d.id == ownId ? null : () => _removeDevice(d),
              ),
          ],
        )
      else if (_loading)
        const SizedBox(height: 8),
      const SizedBox(height: 18),
      HipListGroup(
        children: [
          HipListRow(
            leading: const _Tile(Icons.autorenew),
            title: S.accountRotate,
            trailing: Icon(Icons.chevron_right, size: 17, color: Hip.muted2),
            onTap: _busy ? null : _rotate,
          ),
          HipListRow(
            leading: const _Tile(Icons.logout),
            title: S.accountSignOut,
            trailing: Icon(Icons.chevron_right, size: 17, color: Hip.muted2),
            onTap: _busy ? null : _signOut,
          ),
        ],
      ),
      const SizedBox(height: 24),
    ];
  }

  /// Signed in and live: the same moment as a purchase going through, on
  /// the app's own surface.
  Widget _success() {
    final expires = _state.accountExpires;
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
                      _monoIn(
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

/// A flat gray tile in front of a row, as in Settings.
class _Tile extends StatelessWidget {
  final IconData icon;
  const _Tile(this.icon);

  @override
  Widget build(BuildContext context) => Container(
    width: 38,
    height: 38,
    decoration: BoxDecoration(
      color: Hip.line2,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Icon(icon, size: 19, color: Hip.inkSoft),
  );
}

/// A small bordered action under the number.
class _MiniAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _MiniAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Hip.line2,
            border: Border.all(color: Hip.line, width: 1.5),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: Hip.inkSoft),
              const SizedBox(width: 6),
              Text(label, style: Hip.sans(650, 12.5, color: Hip.ink)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One device on the account, in the Linked devices row style: kind icon,
/// name, the date it signed in (mono), and a way to take it off. This
/// device carries a badge instead; leaving is what signing out is for.
class _AccountDeviceRow extends StatelessWidget {
  final LinkedDevice device;
  final bool own;
  final VoidCallback? onRemove;
  const _AccountDeviceRow({
    required this.device,
    required this.own,
    required this.onRemove,
  });

  static IconData _iconFor(LinkedDeviceKind kind) => switch (kind) {
    LinkedDeviceKind.extension => Icons.language_outlined,
    LinkedDeviceKind.desktop => Icons.desktop_windows_outlined,
    LinkedDeviceKind.phone => Icons.smartphone_outlined,
    LinkedDeviceKind.unknown => Icons.devices_other_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final created = device.createdAt;
    final words = Hip.sans(400, 12.5, color: Hip.muted);
    final dates = Hip.mono(600, 11.5, color: Hip.muted);
    final row = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          _Tile(_iconFor(device.kind)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        device.name,
                        overflow: TextOverflow.ellipsis,
                        style: Hip.sans(
                          650,
                          15.5,
                          color: Hip.ink,
                          letterSpacing: -.15,
                        ),
                      ),
                    ),
                    if (own) ...[
                      const SizedBox(width: 7),
                      HipBadge.blue(S.accountThisDevice),
                    ],
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (onRemove != null) ...[
            const SizedBox(width: 12),
            Semantics(
              button: true,
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
