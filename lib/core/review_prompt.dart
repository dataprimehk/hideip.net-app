/// When the app may ask the store for a rating.
///
/// Pure Dart on purpose: the whole decision is a function of a few counters
/// and dates, so it is tested without a device, a store or a clock. The store
/// sheet itself (and whether this install may use it at all) lives in
/// `review_launcher.dart`.
///
/// The rules, all of which must hold:
///  * not on the first launch of the app;
///  * at least [minHeldConnects] connections that reached Connected and stayed
///    up for [holdFor], counted across launches;
///  * no connection failure in the last [failureQuiet];
///  * never twice for the same app version;
///  * never twice inside [cooldown];
///  * only while the app is in the foreground.
///
/// The stores throttle on top of this (iOS shows the sheet at most three
/// times a year, Play keeps its own quota), so a "yes" here is a request,
/// never a promise that anything appears.
library;

import 'dart:convert';

/// What the policy remembers between launches. Immutable; every event returns
/// a new value to persist.
class ReviewPromptState {
  const ReviewPromptState({
    this.launches = 0,
    this.heldConnects = 0,
    this.lastPromptAt,
    this.lastPromptVersion,
    this.lastFailureAt,
  });

  /// App launches seen, including the current one once [onLaunch] ran.
  final int launches;

  /// Connections that stayed up for [ReviewPromptPolicy.holdFor].
  final int heldConnects;

  /// When the store was last asked for the sheet, or null for never.
  final DateTime? lastPromptAt;

  /// The app version that last asked, or null for never.
  final String? lastPromptVersion;

  /// When a connection last failed, or null for never.
  final DateTime? lastFailureAt;

  ReviewPromptState onLaunch() => _copy(launches: launches + 1);

  ReviewPromptState onConnectionHeld() => _copy(heldConnects: heldConnects + 1);

  ReviewPromptState onFailure(DateTime now) => _copy(lastFailureAt: now);

  ReviewPromptState onPrompted(DateTime now, String version) =>
      _copy(lastPromptAt: now, lastPromptVersion: version);

  ReviewPromptState _copy({
    int? launches,
    int? heldConnects,
    DateTime? lastPromptAt,
    String? lastPromptVersion,
    DateTime? lastFailureAt,
  }) => ReviewPromptState(
    launches: launches ?? this.launches,
    heldConnects: heldConnects ?? this.heldConnects,
    lastPromptAt: lastPromptAt ?? this.lastPromptAt,
    lastPromptVersion: lastPromptVersion ?? this.lastPromptVersion,
    lastFailureAt: lastFailureAt ?? this.lastFailureAt,
  );

  String encode() => jsonEncode({
    'launches': launches,
    'held': heldConnects,
    if (lastPromptAt != null)
      'promptAt': lastPromptAt!.toUtc().millisecondsSinceEpoch,
    if (lastPromptVersion != null) 'promptVersion': lastPromptVersion,
    if (lastFailureAt != null)
      'failureAt': lastFailureAt!.toUtc().millisecondsSinceEpoch,
  });

  /// Reads what [encode] wrote. An unreadable record starts over from zero:
  /// the launches and held connections have to be earned again, so a corrupt
  /// record delays the next ask instead of opening the window early.
  static ReviewPromptState decode(String? raw) {
    if (raw == null || raw.isEmpty) return const ReviewPromptState();
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return const ReviewPromptState();
      DateTime? at(Object? v) =>
          v is int ? DateTime.fromMillisecondsSinceEpoch(v, isUtc: true) : null;
      final launches = m['launches'];
      final held = m['held'];
      final version = m['promptVersion'];
      return ReviewPromptState(
        launches: launches is int && launches > 0 ? launches : 0,
        heldConnects: held is int && held > 0 ? held : 0,
        lastPromptAt: at(m['promptAt']),
        lastPromptVersion: version is String ? version : null,
        lastFailureAt: at(m['failureAt']),
      );
    } on FormatException {
      return const ReviewPromptState();
    }
  }
}

class ReviewPromptPolicy {
  const ReviewPromptPolicy({
    this.minHeldConnects = 2,
    this.holdFor = const Duration(seconds: 10),
    this.cooldown = const Duration(days: 120),
    this.failureQuiet = const Duration(hours: 24),
  });

  /// Held connections needed before the first ask.
  final int minHeldConnects;

  /// How long a tunnel must stay Connected to count as a success.
  final Duration holdFor;

  /// Minimum time between two asks, across versions.
  final Duration cooldown;

  /// How long a connection failure keeps the prompt away.
  final Duration failureQuiet;

  bool shouldPrompt(
    ReviewPromptState s, {
    required DateTime now,
    required String version,
    required bool inForeground,
  }) {
    if (!inForeground) return false;
    // The launch that installed the app, or the first one after a wipe.
    if (s.launches < 2) return false;
    if (s.heldConnects < minHeldConnects) return false;
    if (s.lastPromptVersion == version) return false;
    final prompted = s.lastPromptAt;
    // A clock set backwards reads as "just asked", which is the safe side.
    if (prompted != null && now.difference(prompted) < cooldown) return false;
    final failed = s.lastFailureAt;
    if (failed != null && now.difference(failed) < failureQuiet) return false;
    return true;
  }
}
