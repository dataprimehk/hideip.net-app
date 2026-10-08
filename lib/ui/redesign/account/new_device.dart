/// This device asking another one for access (pairing v2, P2/P7): the QR
/// code and the short code of one request, shown together, while a device
/// that manages the account approves it. The phone shows its code; it never
/// scans or approves its own.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import '../../../core/pairing.dart';
import '../../../state/app_pairing.dart';
import '../../../state/app_state.dart';
import '../../strings.dart';
import '../hip.dart';
import '../shell.dart' show kPlansAvailable;
import 'account_widgets.dart';

/// What the new-device part of the Account screen reads and asks for.
abstract interface class NewDevicePort {
  Listenable get changes;

  /// Where this device's own request stands.
  LinkRequestPhase get phase;

  /// The request on show, or null when there is none open.
  LinkTicket? get ticket;

  /// Whether a request would move this device off what it runs on now, so
  /// the user is asked first (K10).
  bool get needsConfirm;

  /// Whether a store purchase can be restored here.
  bool get canRestore;

  Future<LinkRequestPhase> start({bool confirmSwitch = false});
  Future<void> cancel();

  /// Puts a finished request back to idle once its end has been shown.
  void clear();

  Future<void> restore();
}

/// [NewDevicePort] over the app state.
class AppStateNewDevicePort implements NewDevicePort {
  final AppState _state;
  AppStateNewDevicePort(this._state);

  @override
  Listenable get changes => _state;
  @override
  LinkRequestPhase get phase => _state.linkPhase;
  @override
  LinkTicket? get ticket => _state.linkTicket;
  @override
  bool get needsConfirm => _state.linkRequestNeedsConfirm;
  @override
  bool get canRestore => kPlansAvailable;
  @override
  Future<LinkRequestPhase> start({bool confirmSwitch = false}) =>
      _state.startLinkRequest(confirmSwitch: confirmSwitch);
  @override
  Future<void> cancel() => _state.cancelLinkRequest();
  @override
  void clear() => _state.clearLinkPhase();
  @override
  Future<void> restore() => _state.restoreStoreHere();
}

/// Called as the screen showing the code goes away: a request still open
/// does not stay up behind the user's back, neither one nobody approved
/// nor one whose approval is still being confirmed. An account already in
/// force here stays (the state decides that). Asked after the frame, since
/// the screen is being torn down while this runs.
void withdrawNewDeviceRequest(NewDevicePort port) {
  bool open() =>
      port.phase == LinkRequestPhase.waiting ||
      port.phase == LinkRequestPhase.storing;
  if (!open()) return;
  scheduleMicrotask(() {
    if (open()) unawaited(port.cancel());
  });
}

/// Whether the screen should show the code at all in [phase]. A server
/// without pairing v2 gets the 1.2.0 sign-in alone, never a code nobody can
/// approve (K1).
bool newDeviceOffered(LinkRequestPhase phase) =>
    phase != LinkRequestPhase.unsupported;

/// The card with the QR code and the short code of this device's request,
/// and what became of it. Opening it asks for a request unless one is up
/// already; the screen that holds it withdraws an unapproved request when
/// the user leaves ([withdrawNewDeviceRequest]), not the card, which a list
/// builds and drops as it scrolls.
class NewDeviceCard extends StatefulWidget {
  final NewDevicePort port;

  /// Asks the user before a request that would move this device to
  /// another account. True goes ahead.
  final Future<bool> Function() confirmSwitch;

  const NewDeviceCard({
    super.key,
    required this.port,
    required this.confirmSwitch,
  });

  @override
  State<NewDeviceCard> createState() => _NewDeviceCardState();
}

class _NewDeviceCardState extends State<NewDeviceCard> {
  Timer? _tick;
  bool _asking = false;

  NewDevicePort get _port => widget.port;

  @override
  void initState() {
    super.initState();
    _port.changes.addListener(_changed);
    _syncTick();
    // A request still open from before (the app was closed while it waited)
    // is shown as it is. Otherwise a new one is asked for, unless it would
    // move this device off its account: that waits for the user's yes.
    final phase = _port.phase;
    if (phase != LinkRequestPhase.waiting &&
        phase != LinkRequestPhase.storing &&
        phase != LinkRequestPhase.done &&
        !_port.needsConfirm) {
      _asking = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ask(() => _port.start());
      });
    }
  }

  @override
  void dispose() {
    _port.changes.removeListener(_changed);
    _tick?.cancel();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    _syncTick();
    setState(() {});
  }

  /// The countdown runs only while a code is up.
  void _syncTick() {
    final up = _port.phase == LinkRequestPhase.waiting;
    if (up && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        if (_left == Duration.zero) {
          _tick?.cancel();
          _tick = null;
        }
      });
    } else if (!up) {
      _tick?.cancel();
      _tick = null;
    }
  }

  Duration get _left {
    final ticket = _port.ticket;
    if (ticket == null) return Duration.zero;
    final left = ticket.expiresAt.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Runs [step] with the card in its asking state.
  Future<void> _ask(Future<void> Function() step) async {
    setState(() => _asking = true);
    try {
      await step();
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  /// A new code. The one on show is withdrawn first, so only one request is
  /// ever open from this device; a move to another account is asked about
  /// first, every time.
  Future<void> _renew() async {
    if (_asking) return;
    if (_port.needsConfirm && !await widget.confirmSwitch()) return;
    if (!mounted) return;
    final confirmed = _port.needsConfirm;
    await _ask(() async {
      if (_port.phase == LinkRequestPhase.waiting) await _port.cancel();
      await _port.start(confirmSwitch: confirmed);
    });
  }

  Future<void> _withdraw() async {
    if (_asking) return;
    await _ask(_port.cancel);
  }

  static String _clock(Duration left) {
    final m = left.inMinutes.toString().padLeft(2, '0');
    final s = (left.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final phase = _port.phase;
    final ticket = _port.ticket;
    if (!newDeviceOffered(phase)) return const SizedBox.shrink();
    final Widget body;
    if ((phase == LinkRequestPhase.waiting ||
            phase == LinkRequestPhase.storing) &&
        ticket != null) {
      body = _code(ticket, storing: phase == LinkRequestPhase.storing);
    } else if (_asking || phase == LinkRequestPhase.done) {
      body = _waitingForCode();
    } else if (phase == LinkRequestPhase.idle ||
        phase == LinkRequestPhase.needsConfirm) {
      body = AccountCta(S.accountNewDeviceShow, ghost: true, onTap: _renew);
    } else {
      body = _ended(phase);
    }
    return HipCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: body,
    );
  }

  Widget _waitingForCode() => SizedBox(
    height: 120,
    child: Center(
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2, color: Hip.muted2),
      ),
    ),
  );

  Widget _code(LinkTicket ticket, {required bool storing}) {
    final left = _left;
    final lapsed = !storing && left == Duration.zero;
    final code = ticket.code.isEmpty
        ? null
        : displayPairingCode(normalizePairingCode(ticket.code));
    return Column(
      children: [
        Opacity(
          opacity: lapsed || storing ? .25 : 1,
          child: PairingQr(
            data: ticket.qrPayload,
            semanticLabel: S.accountNewDeviceQrLabel,
          ),
        ),
        if (code != null) ...[
          const SizedBox(height: 14),
          OneLine(
            SelectableText(
              code,
              key: const ValueKey('new-device-code'),
              style: Hip.mono(700, 26, color: Hip.ink, letterSpacing: 2),
            ),
          ),
        ],
        const SizedBox(height: 8),
        if (storing) ...[
          _statusLine(S.accountNewDeviceStoring, spinner: true),
          const SizedBox(height: 8),
          // A confirmation the server keeps refusing must not hold the
          // screen: this is the way out.
          AccountCta(S.aCancel, quiet: true, onTap: _withdraw),
        ] else if (lapsed) ...[
          _statusLine(S.accountNewDeviceExpired),
          const SizedBox(height: 12),
          AccountCta(S.accountNewDeviceNewCode, ghost: true, onTap: _renew),
        ] else ...[
          Text(
            S.accountExpiresIn(_clock(left)),
            style: Hip.mono(600, 12.5, color: Hip.muted, height: 1.45),
          ),
          const SizedBox(height: 4),
          _statusLine(S.accountNewDeviceWaiting, spinner: true),
        ],
      ],
    );
  }

  Widget _ended(LinkRequestPhase phase) {
    final text = switch (phase) {
      LinkRequestPhase.cancelled => S.accountNewDeviceCancelled,
      LinkRequestPhase.revoked => S.accountNewDeviceRevoked,
      LinkRequestPhase.inactive => S.accountNewDeviceInactive,
      LinkRequestPhase.tooManyAttempts => S.accountErrTooMany,
      LinkRequestPhase.failed => S.accountErrNetwork,
      _ => S.accountNewDeviceExpired,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: Hip.sans(500, 13.5, color: Hip.muted, height: 1.45),
        ),
        const SizedBox(height: 12),
        AccountCta(
          // No answer from the server is tried again; anything it decided
          // gets a new code.
          phase == LinkRequestPhase.failed
              ? S.aTryAgain
              : S.accountNewDeviceNewCode,
          ghost: true,
          onTap: _renew,
        ),
      ],
    );
  }

  Widget _statusLine(String text, {bool spinner = false}) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      if (spinner) ...[
        SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.6, color: Hip.muted2),
        ),
        const SizedBox(width: 8),
      ],
      Flexible(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Hip.sans(500, 13, color: Hip.muted, height: 1.45),
        ),
      ),
    ],
  );
}

/// A QR code for [data], dark modules on white in either theme (a scanner
/// reads it that way round), with the four-module quiet zone the standard
/// asks for.
class PairingQr extends StatelessWidget {
  final String data;
  final double size;
  final String semanticLabel;
  const PairingQr({
    super.key,
    required this.data,
    required this.semanticLabel,
    this.size = 196,
  });

  /// The last code drawn: the countdown rebuilds the card every second,
  /// and the same request draws the same modules.
  static String? _lastData;
  static QrImage? _lastImage;

  static QrImage _imageFor(String data) {
    final held = _lastImage;
    if (held != null && _lastData == data) return held;
    final image = QrImage(
      QrCode(
        payload: QrPayload.fromString(data),
        errorCorrectLevel: QrErrorCorrectLevel.medium,
      ),
    );
    _lastData = data;
    _lastImage = image;
    return image;
  }

  @override
  Widget build(BuildContext context) {
    final image = _imageFor(data);
    return Semantics(
      label: semanticLabel,
      image: true,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: CustomPaint(painter: _QrPainter(image)),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  final QrImage image;
  _QrPainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    const quiet = 4;
    final count = image.moduleCount;
    final cell = size.shortestSide / (count + quiet * 2);
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    final path = Path();
    for (var r = 0; r < count; r++) {
      for (var c = 0; c < count; c++) {
        if (!image.isDark(r, c)) continue;
        path.addRect(
          Rect.fromLTWH(
            (c + quiet) * cell,
            (r + quiet) * cell,
            cell + .5,
            cell + .5,
          ),
        );
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}
