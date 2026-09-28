import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_version.dart';
import 'async_gate.dart';
import 'review_prompt.dart';

/// Asks the store for its rating sheet when [ReviewPromptPolicy] allows it.
///
/// The app never draws a rating screen of its own: on iOS the request goes to
/// StoreKit (`AppStore.requestReview`), on Android to the Play In-App Review
/// API. Both decide for themselves whether anything appears.
///
/// Android ships one APK to every channel (Play, GitHub, IzzyOnDroid, the
/// hideip.net F-Droid repo), so the Play review library is inside all of
/// them, next to Play Billing. It is only ever called when Google Play
/// installed this copy: an APK from anywhere else never talks to Play for a
/// rating, and its user is never sent to a store they did not use.
class ReviewPrompter {
  ReviewPrompter({
    this.policy = const ReviewPromptPolicy(),
    DateTime Function()? now,
    bool Function()? inForeground,
    Future<bool> Function()? storeAllowed,
    Future<void> Function()? requestSheet,
  }) : _now = now ?? DateTime.now,
       _inForeground = inForeground ?? _appResumed,
       _storeAllowed = storeAllowed ?? _installedFromStore,
       _requestSheet = requestSheet ?? InAppReview.instance.requestReview;

  static const prefsKey = 'review_prompt_v1';
  static const _control = MethodChannel('net.hideip.vpn/control');

  /// The Play Store's package name, as Android reports the installer.
  static const playInstaller = 'com.android.vending';

  final ReviewPromptPolicy policy;
  final DateTime Function() _now;
  final bool Function() _inForeground;
  final Future<bool> Function() _storeAllowed;
  final Future<void> Function() _requestSheet;

  // Every change is a read, a change and a write; two of them at once (a
  // failure landing while a held connection is counted) must not lose one.
  final AsyncGate _gate = AsyncGate();

  Duration get holdFor => policy.holdFor;

  /// Once per app start.
  Future<void> onLaunch() => _update((s) => s.onLaunch());

  /// A connection attempt failed.
  Future<void> onFailure() => _update((s) => s.onFailure(_now()));

  /// A connection reached Connected and stayed up for [holdFor]. Counts it,
  /// then asks for the sheet if every rule holds.
  Future<void> onConnectionHeld() => _gate.run(() async {
    try {
      final p = await SharedPreferences.getInstance();
      var s = ReviewPromptState.decode(
        p.getString(prefsKey),
      ).onConnectionHeld();
      await p.setString(prefsKey, s.encode());
      final now = _now();
      if (!policy.shouldPrompt(
        s,
        now: now,
        version: appVersion,
        inForeground: _inForeground(),
      )) {
        return;
      }
      if (!await _storeAllowed()) return;
      // Recorded before asking: whatever the store does next, including
      // taking the app down, this version has had its one ask.
      s = s.onPrompted(now, appVersion);
      await p.setString(prefsKey, s.encode());
      await _requestSheet();
    } catch (_) {
      // A rating sheet is never worth an error the user can see.
    }
  });

  Future<void> _update(ReviewPromptState Function(ReviewPromptState) f) =>
      _gate.run(() async {
        try {
          final p = await SharedPreferences.getInstance();
          final s = f(ReviewPromptState.decode(p.getString(prefsKey)));
          await p.setString(prefsKey, s.encode());
        } catch (_) {
          // Losing a count only delays the ask.
        }
      });

  static bool _appResumed() =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// Whether this install may use the store's rating sheet at all.
  static Future<bool> _installedFromStore() async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        // Only the App Store (and TestFlight, where StoreKit shows nothing)
        // can put this app on an iPhone.
        return true;
      case TargetPlatform.android:
        try {
          final installer = await _control.invokeMethod<String>(
            'installerPackage',
          );
          return installer == playInstaller;
        } on MissingPluginException {
          return false;
        } on PlatformException {
          return false;
        }
      default:
        return false;
    }
  }
}
