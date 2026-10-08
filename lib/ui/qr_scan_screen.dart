import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import '../core/haptics.dart';
import 'brand.dart';
import 'strings.dart';

/// Where the scanner's bottom furniture goes, shared by everything that draws
/// its own overlay over a [QrReader] so the caption and the reader's control
/// row can never land on top of each other.
///
/// [QrReader] mounts the camera with the safe-area padding stripped, so these
/// offsets are measured from the bottom edge of the preview itself on every
/// platform, and the inset is added back here, once and explicitly.
abstract final class QrOverlay {
  /// Design: `.cam-fabs { bottom: 18px }`.
  static const double controlsBottom = 18;

  /// Design: `.cam-fabs button { height: 48px }`.
  static const double controlsHeight = 48;

  /// Clear air between the control row and the caption above it. The design
  /// puts the caption at 86px, which is 18 + 48 + 20.
  static const double captionGap = 20;

  /// Padding for the reader's control row over a preview whose bottom edge
  /// carries [bottomInset] of unusable space (the iPhone home indicator).
  static EdgeInsets controlsPadding(double bottomInset) =>
      EdgeInsets.only(bottom: bottomInset + controlsBottom);

  /// How far the caption sits above the bottom edge of that same preview:
  /// clear of the controls, which are clear of the inset.
  static double captionBottom(double bottomInset) =>
      bottomInset + controlsBottom + controlsHeight + captionGap;
}

/// The live camera preview that decodes QR codes, with no chrome of its own
/// beyond the reader's torch and camera-flip buttons.
///
/// Backed by [flutter_zxing] (pure ZXing via FFI). Unlike ML Kit based
/// scanners it has no Google Play Services dependency, so it decodes on
/// GrapheneOS and other no-GMS devices exactly as on stock Android, which
/// matters for a privacy app whose users often run de-Googled ROMs.
///
/// It reports every decode it sees; whoever mounts it decides what a first
/// code means and when to stop listening.
class QrReader extends StatelessWidget {
  /// Called with the trimmed contents of each decoded code.
  final ValueChanged<String> onCode;

  /// Shows the reader's own torch and camera-flip buttons. They are the
  /// reader's because it owns the camera controller and knows whether the
  /// device has a torch at all.
  final bool showControls;

  final AlignmentGeometry controlsAlignment;

  /// Distance of the control row from the edge it is aligned to, measured on
  /// the preview itself. Whoever mounts the reader owns the safe-area inset:
  /// see [QrOverlay.controlsPadding].
  final EdgeInsetsGeometry controlsPadding;

  const QrReader({
    super.key,
    required this.onCode,
    this.showControls = true,
    this.controlsAlignment = Alignment.bottomLeft,
    this.controlsPadding = const EdgeInsets.all(10),
  });

  void _onScan(Code code) {
    final raw = code.text;
    if (!code.isValid || raw == null || raw.trim().isEmpty) return;
    onCode(raw.trim());
  }

  /// A camera switch throws the controller away and builds a new one. On iOS
  /// the zoom factor lives on the capture device rather than on the session,
  /// so it outlives that rebuild and the preview comes back still zoomed in;
  /// on Android the new session starts at 1x by itself. Push every fresh
  /// controller back to 1x, or to the nearest zoom the camera admits.
  Future<void> _resetZoom(
    CameraController? controller,
    Exception? error,
  ) async {
    if (controller == null || error != null) return;
    try {
      final minZoom = await controller.getMinZoomLevel();
      final maxZoom = await controller.getMaxZoomLevel();
      var target = 1.0;
      if (target < minZoom) target = minZoom;
      if (target > maxZoom) target = maxZoom;
      await controller.setZoomLevel(target);
    } catch (_) {
      // A camera that cannot zoom has no zoom to reset, and a controller torn
      // down mid-switch is about to be replaced anyway. Neither is worth
      // failing a scan over.
    }
  }

  @override
  Widget build(BuildContext context) {
    // The reader wraps its buttons in a SafeArea of its own. On iOS that lifts
    // them 34px off the bottom, over the home indicator and straight into the
    // caption above them; on Android it lifts them by nothing, which is why
    // only iOS shows the collision. Strip the padding so the control row lands
    // exactly where controlsPadding says on both platforms, and let the caller
    // add the inset back through QrOverlay.
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      removeBottom: true,
      removeLeft: true,
      removeRight: true,
      child: ReaderWidget(
        codeFormat: Format.qrCode,
        onScan: _onScan,
        onControllerCreated: _resetZoom,
        // Pinch zoom is not part of the scanner: the package keeps its zoom
        // factor in state it never resets across a camera switch, so one pinch
        // leaves the preview stuck zoomed in with no way back but a restart.
        // A code held at arm's length needs no zoom.
        allowPinchZoom: false,
        // Privacy: never reach into the photo library; links come from the
        // camera or paste, not the gallery.
        showGallery: false,
        showScannerOverlay: false,
        showFlashlight: showControls,
        showToggleCamera: showControls,
        actionButtonsAlignment: controlsAlignment,
        actionButtonsPadding: controlsPadding,
        flashOnIcon: const Icon(
          Icons.flashlight_on_outlined,
          color: Colors.white,
        ),
        flashOffIcon: const Icon(
          Icons.flashlight_off_outlined,
          color: Colors.white,
        ),
        toggleCameraIcon: const Icon(
          Icons.cameraswitch_outlined,
          color: Colors.white,
        ),
        scanDelaySuccess: const Duration(milliseconds: 600),
        actionButtonsBackgroundColor: Colors.black.withValues(alpha: 0.35),
        actionButtonsBackgroundBorderRadius: BorderRadius.circular(999),
        loading: const DecoratedBox(
          decoration: BoxDecoration(color: Colors.black),
          child: Center(child: CircularProgressIndicator(color: Colors.white)),
        ),
      ),
    );
  }
}

/// Full-screen QR scanner. Pops with the first decoded string, or null if the
/// user backs out.
///
/// The importer scans in an inline popup instead; this screen is what device
/// linking uses, where the scan is the whole task.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _handled = false;

  void _onCode(String raw) {
    if (_handled) return;
    _handled = true;
    Haptics.success();
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    // The preview runs edge to edge, so the reader's controls and the caption
    // both have to clear the home indicator themselves.
    final inset = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(S.e7Title),
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          QrReader(
            onCode: _onCode,
            controlsAlignment: Alignment.bottomCenter,
            controlsPadding: QrOverlay.controlsPadding(inset),
          ),
          // Brand reticle drawn on top of the live preview.
          IgnorePointer(
            child: CustomPaint(
              painter: _ReticlePainter(color: brand.primary),
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: QrOverlay.captionBottom(inset),
            child: Text(
              S.accountScanHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws a darkened frame with a transparent square reticle in the centre.
class _ReticlePainter extends CustomPainter {
  final Color color;
  _ReticlePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide * 0.66;
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: side,
      height: side,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(20));

    // Dim everything except the reticle.
    final overlay = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      overlay,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    // Corner brackets in brand blue.
    final bracket = Paint()
      ..color = color
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const len = 28.0;
    void corner(Offset o, Offset hDir, Offset vDir) {
      canvas.drawLine(o, o + hDir * len, bracket);
      canvas.drawLine(o, o + vDir * len, bracket);
    }

    corner(rect.topLeft, const Offset(1, 0), const Offset(0, 1));
    corner(rect.topRight, const Offset(-1, 0), const Offset(0, 1));
    corner(rect.bottomLeft, const Offset(1, 0), const Offset(0, -1));
    corner(rect.bottomRight, const Offset(-1, 0), const Offset(0, -1));
  }

  @override
  bool shouldRepaint(covariant _ReticlePainter old) => old.color != color;
}
