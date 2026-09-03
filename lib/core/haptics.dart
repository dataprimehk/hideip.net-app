import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The four pulses the app uses, lightest first.
enum HapticKind { selection, tap, success, error }

/// Thin wrapper over [HapticFeedback] so the rest of the app expresses intent
/// ("a server was selected", "we connected") rather than raw vibration calls.
/// Each method is best-effort: on devices/platforms without a vibrator the
/// platform call is a no-op, so callers never need to guard.
///
/// The weights follow the platform guidance on both sides: the stronger
/// single pulse goes to the bigger state change, which is the tunnel coming
/// up; the tunnel going down gets one lighter pulse; anything doubled is
/// reserved for a failure, so nothing routine ever reads as a warning.
class Haptics {
  /// Test hook. While set, every pulse is handed here and nothing reaches
  /// the platform, so a test can count what fired instead of listening for
  /// a motor that the test runner does not have.
  @visibleForTesting
  static void Function(HapticKind kind)? sink;

  /// Light tick for routine selections (pick a server, toggle a control,
  /// copy the address).
  static void selection() =>
      _fire(HapticKind.selection, HapticFeedback.selectionClick);

  /// Confirming press for a primary action (tap Connect / Import), and the
  /// one pulse a finished disconnect gets.
  static void tap() => _fire(HapticKind.tap, HapticFeedback.lightImpact);

  /// Success landing: the tunnel came up. Once per connection.
  static void success() =>
      _fire(HapticKind.success, HapticFeedback.mediumImpact);

  /// Something failed (connect error, parse error).
  static void error() => _fire(HapticKind.error, HapticFeedback.heavyImpact);

  static void _fire(HapticKind kind, Future<void> Function() platform) {
    final s = sink;
    if (s != null) {
      s(kind);
      return;
    }
    platform();
  }
}
