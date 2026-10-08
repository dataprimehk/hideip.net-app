import 'package:flutter/material.dart';

import '../../core/camera_permission.dart';
import '../../core/haptics.dart';
import '../qr_scan_screen.dart';
import '../strings.dart';
import 'hip.dart';
import 'system_bars.dart';

/// Builds the live camera preview the popup scans with. Swapped in tests for
/// something that fires a code on demand, so the flow can be driven without a
/// camera.
typedef QrReaderBuilder =
    Widget Function(
      BuildContext context, {
      required ValueChanged<String> onCode,
    });

/// The real preview: [QrReader] with its torch and camera-flip buttons sitting
/// on the bottom edge of the popup.
///
/// The panel's bottom edge is the screen's bottom edge, so the buttons carry
/// the safe-area inset themselves. [_scanner] lifts the caption by the same
/// inset, which is what keeps the two apart on a device with a home indicator.
Widget buildQrReader(
  BuildContext context, {
  required ValueChanged<String> onCode,
}) => QrReader(
  onCode: onCode,
  controlsAlignment: Alignment.bottomCenter,
  controlsPadding: QrOverlay.controlsPadding(
    MediaQuery.paddingOf(context).bottom,
  ),
);

/// The QR scanner as an inline popup over the import screen, in three states:
/// the pre-prompt that explains what the camera is for, the calm denied state
/// with a way into system settings, and the scanner itself.
///
/// A scan hands the raw string back through [onCode] and closes. It never
/// imports anything: the string lands in the same field a paste would fill,
/// and the person still taps Import.
class QrPopup extends StatefulWidget {
  /// Called once with the first decoded string.
  final ValueChanged<String> onCode;

  /// Dismiss without a code.
  final VoidCallback onClose;

  /// The way out of the denied state that does not involve system settings.
  final VoidCallback onPasteInstead;

  /// Platform seams, overridable for tests.
  final Future<CamPerm> Function() camStatus;
  final Future<CamPerm> Function() camRequest;
  final Future<void> Function() openCamSettings;
  final QrReaderBuilder readerBuilder;

  const QrPopup({
    super.key,
    required this.onCode,
    required this.onClose,
    required this.onPasteInstead,
    this.camStatus = CameraPermission.status,
    this.camRequest = CameraPermission.request,
    this.openCamSettings = CameraPermission.openSettings,
    this.readerBuilder = buildQrReader,
  });

  @override
  State<QrPopup> createState() => _QrPopupState();
}

class _QrPopupState extends State<QrPopup>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// Null while the first permission read is in flight.
  CamPerm? _perm;
  bool _found = false;
  // Built eagerly rather than lazily: with reduced motion nothing ever reads
  // it, and a lazy field would first be created inside dispose(), where the
  // element is already deactivated and a ticker can no longer be made.
  late final AnimationController _scan;

  @override
  void initState() {
    super.initState();
    _scan = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    if (!Hip.reducedMotion) _scan.repeat(reverse: true);
    WidgetsBinding.instance.addObserver(this);
    _read();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scan.dispose();
    super.dispose();
  }

  /// Someone who came back from system settings with the camera switched on
  /// gets the scanner, not the line that sent them there.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _perm != CamPerm.granted) _read();
  }

  Future<void> _read() async {
    final perm = await widget.camStatus();
    if (mounted) setState(() => _perm = perm);
  }

  Future<void> _allow() async {
    final perm = await widget.camRequest();
    if (mounted) setState(() => _perm = perm);
  }

  Future<void> _settings() async {
    await widget.openCamSettings();
  }

  /// The first valid code wins. A short beat on the green pill lets the person
  /// see that the scan landed before the popup goes away.
  void _onCode(String raw) {
    if (_found) return;
    setState(() => _found = true);
    Haptics.success();
    Future.delayed(Hip.dur(const Duration(milliseconds: 420)), () {
      if (mounted) widget.onCode(raw);
    });
  }

  @override
  Widget build(BuildContext context) {
    final perm = _perm;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onClose,
        child: ColoredBox(
          color: Hip.dark.withValues(alpha: .16),
          child: Stack(
            children: [
              if (perm == CamPerm.ask || perm == CamPerm.denied)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _Sheet(child: _ask(perm == CamPerm.denied)),
                ),
              if (perm == CamPerm.granted)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: MediaQuery.sizeOf(context).height * .62,
                  // The dark panel meets the navigation bar, so it sets the
                  // colour of that bar's icons while it is up.
                  child: HipNavBarRegion(bottom: Hip.dark, child: _scanner()),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // --- the pre-prompt and the denied state ------------------------------------

  Widget _ask(bool denied) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                S.e7Title,
                style: Hip.sans(700, 16.5, color: Hip.ink, letterSpacing: -.3),
              ),
            ),
            HipIconButton(Icons.close, onTap: widget.onClose),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: Hip.blueSoft,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(Icons.photo_camera_outlined, size: 24, color: Hip.blue),
        ),
        const SizedBox(height: 14),
        Text(
          denied ? S.e8Head : S.e7Head,
          textAlign: TextAlign.center,
          style: Hip.sans(
            700,
            Hip.titleSize,
            color: Hip.ink,
            letterSpacing: -.3,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          denied ? S.e8Body : S.e7Body,
          textAlign: TextAlign.center,
          style: Hip.sans(400, 13.5, color: Hip.muted, height: 1.55),
        ),
        const SizedBox(height: 20),
        HipCta(
          denied ? S.aOpenSettings : S.e7Allow,
          onTap: denied ? _settings : _allow,
        ),
        const SizedBox(height: 8),
        HipCta(
          denied ? S.e8PasteInstead : S.aNotNow,
          quiet: true,
          onTap: denied ? widget.onPasteInstead : widget.onClose,
        ),
      ],
    );
  }

  // --- the scanner -------------------------------------------------------------

  Widget _scanner() {
    // What the reader's controls stand on, so the caption can stand above
    // them. On iOS this is the home indicator's 34px; on Android 15 and
    // later, which always draw edge to edge, it is the navigation bar.
    final inset = MediaQuery.paddingOf(context).bottom;
    // Absorbs its own taps: only the scrim above the panel closes the popup.
    return GestureDetector(
      onTap: () {},
      behavior: HitTestBehavior.opaque,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        child: ColoredBox(
          color: Hip.dark,
          child: LayoutBuilder(
            builder: (context, c) {
              final side = c.maxWidth * .58;
              final rect = Rect.fromCenter(
                center: Offset(c.maxWidth / 2, c.maxHeight * .42),
                width: side,
                height: side,
              );
              return Stack(
                children: [
                  Positioned.fill(
                    child: widget.readerBuilder(context, onCode: _onCode),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _DimPainter(rect: rect, bracket: Hip.blue),
                      ),
                    ),
                  ),
                  if (!_found)
                    AnimatedBuilder(
                      animation: _scan,
                      builder: (context, _) => Positioned(
                        left: rect.left + 12,
                        width: rect.width - 24,
                        top: rect.top + 6 + (rect.height - 12) * _scanValue,
                        height: 2.5,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Hip.blue,
                            borderRadius: BorderRadius.circular(2),
                            boxShadow: [
                              BoxShadow(
                                color: Hip.blue.withValues(alpha: .8),
                                blurRadius: 14,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_found)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: rect.center.dy - 17,
                      child: Center(child: _FoundPill()),
                    )
                  else
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: QrOverlay.captionBottom(inset),
                      child: Text(
                        S.e9Hint,
                        textAlign: TextAlign.center,
                        style: Hip.sans(
                          500,
                          12.5,
                          color: Colors.white.withValues(alpha: .7),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 10,
                    right: 10,
                    child: _Fab(
                      icon: Icons.close,
                      label: S.aClose,
                      onTap: widget.onClose,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Frozen mid travel when the device asks for less motion, so the marker is
  /// still there and still says "looking" without a moving part.
  double get _scanValue => Hip.reducedMotion ? .5 : _scan.value;
}

/// The bottom sheet the pre-prompt and the denied state share.
class _Sheet extends StatelessWidget {
  final Widget child;
  const _Sheet({required this.child});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {},
      child: Container(
        decoration: BoxDecoration(
          color: Hip.card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        ),
        padding: EdgeInsets.fromLTRB(
          18,
          14,
          18,
          MediaQuery.paddingOf(context).bottom + 18,
        ),
        child: SafeArea(top: false, bottom: false, child: child),
      ),
    );
  }
}

class _FoundPill extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
      decoration: BoxDecoration(
        color: Hip.success,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check, size: 15, color: Colors.white),
          const SizedBox(width: 7),
          Text(S.e9Found, style: Hip.sans(650, 13, color: Colors.white)),
        ],
      ),
    );
  }
}

class _Fab extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Fab({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: .5),
          ),
          child: Icon(icon, size: 20, color: Colors.white),
        ),
      ),
    );
  }
}

/// Dims everything outside the reticle and draws the four brand brackets on
/// its corners.
class _DimPainter extends CustomPainter {
  final Rect rect;
  final Color bracket;
  _DimPainter({required this.rect, required this.bracket});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(20)))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = Hip.dark.withValues(alpha: .55));

    final stroke = Paint()
      ..color = bracket
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const len = 28.0;
    void corner(Offset o, Offset h, Offset v) {
      canvas.drawLine(o, o + h * len, stroke);
      canvas.drawLine(o, o + v * len, stroke);
    }

    corner(rect.topLeft, const Offset(1, 0), const Offset(0, 1));
    corner(rect.topRight, const Offset(-1, 0), const Offset(0, 1));
    corner(rect.bottomLeft, const Offset(1, 0), const Offset(0, -1));
    corner(rect.bottomRight, const Offset(-1, 0), const Offset(0, -1));
  }

  @override
  bool shouldRepaint(covariant _DimPainter old) =>
      old.rect != rect || old.bracket != bracket;
}
