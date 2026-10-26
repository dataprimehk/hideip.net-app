import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_version.dart';
import 'proxy_profile.dart';
import 'wg_import.dart';

/// Anonymous counters, so hideip.net can see its funnel (opened, added a
/// server, tunnel came up, saw the plans) and how many phones use the app,
/// with which kind of server and from which country, without ever seeing a
/// person. The contract is docs/app-events-api.md.
///
/// Four one-shot events are sent once per install; the "active" ping at most
/// once a day, after a tunnel comes up. What leaves the phone is the event,
/// the platform and labels from closed lists (see [UsageLabels]). No
/// identifier, no server address, no link, no cookie back. The server turns
/// each request into a few daily totals and drops it. The user can switch it
/// off in Settings; the switch is honoured before anything else here runs.
///
/// Sending is fire-and-forget: a failed send is simply retried on the next
/// trigger, and the app never waits on it or shows an error for it.
enum AppEvent { firstOpen, firstProfile, firstConnect, firstPaywall }

extension AppEventWire on AppEvent {
  String get wire => switch (this) {
        AppEvent.firstOpen => 'first_open',
        AppEvent.firstProfile => 'first_profile',
        AppEvent.firstConnect => 'first_connect',
        AppEvent.firstPaywall => 'first_paywall',
      };
}

/// The closed vocabulary the attributes are drawn from. Anything a profile
/// holds is reduced to one of these words before it can leave the phone.
class UsageLabels {
  UsageLabels._();

  /// own, premium or free.
  static String kind(ProxyProfile p) =>
      p.premium ? 'premium' : (p.free ? 'free' : 'own');

  /// How the server got into the app: a subscription URL, a single share
  /// link, a WireGuard file, a pasted body, or our own provisioning.
  static String source(ProxyProfile p) {
    if (p.premium) return 'premium';
    if (p.free) return 'free';
    if (p.subUrl != null) return 'sub';
    if (p.protocol == WgImport.protocol) return 'wg';
    if (p.source != null) return 'link';
    return 'paste';
  }

  static const _protocols = {
    'vless',
    'vmess',
    'trojan',
    'shadowsocks',
    'shadowtls',
    'hysteria2',
    'tuic',
    'wireguard',
    'socks',
    'http',
    'anytls',
  };

  static String proto(ProxyProfile p) =>
      _protocols.contains(p.protocol) ? p.protocol : 'other';

  /// Days since install in four wide ranges, so retention shows without a
  /// date that could single a phone out.
  static String age(DateTime installed, DateTime now) {
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(installed.year, installed.month, installed.day))
        .inDays;
    if (days <= 0) return 'd0';
    if (days < 7) return 'd1_6';
    if (days < 30) return 'd7_29';
    return 'd30';
  }

  /// ISO 8601 week, e.g. 2026-W44: the phone's own week, used only to know
  /// whether this is its first ping of the week.
  static String week(DateTime d) {
    final day = DateTime.utc(d.year, d.month, d.day);
    final thursday = day.add(Duration(days: 4 - day.weekday));
    final week =
        thursday.difference(DateTime.utc(thursday.year)).inDays ~/ 7 + 1;
    return '${thursday.year}-W${week.toString().padLeft(2, '0')}';
  }

  static String dayOf(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String monthOf(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';
}

class AppTelemetry {
  AppTelemetry._();

  static const endpoint = String.fromEnvironment(
    'HIDEIP_EVENTS_ENDPOINT',
    defaultValue: 'https://hideip.net/api/app/events',
  );
  static const _timeout = Duration(seconds: 6);
  static const _prefix = 'tel_sent_v1_';
  static const _kActiveDay = 'tel_active_day';
  static const _kActiveWeek = 'tel_active_week';
  static const _kActiveMonth = 'tel_active_month';
  static const _control = MethodChannel('net.hideip.vpn/control');

  /// Test seam: replaced in unit tests so nothing touches the network.
  @visibleForTesting
  static Future<bool> Function(Map<String, Object> body) send = _post;

  /// Test seam for what the platform reports (country, install channel and
  /// install time). The real one asks the native side once per app run.
  @visibleForTesting
  static Future<DeviceFacts> Function() facts = _nativeFacts;

  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  static String get platform => Platform.isIOS ? 'ios' : 'android';

  static bool _activeBusy = false;

  /// Records [event] if allowed and not yet sent. Returns true when a request
  /// went out and was accepted; false for "already sent", "switched off" and
  /// any failure alike, because none of those are the caller's concern.
  /// [attrs] are labels from [UsageLabels] (kind, source, from).
  static Future<bool> mark(
    AppEvent event, {
    required bool enabled,
    Map<String, String> attrs = const {},
  }) async {
    if (!enabled) return false;
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return false;
    }
    final key = '$_prefix${event.wire}';
    if (prefs.getBool(key) ?? false) return false;
    final f = await _factsOnce();
    final body = <String, Object>{
      'event': event.wire,
      'platform': platform,
      ...attrs,
      if (event == AppEvent.firstOpen) ...{
        if (f.country != null) 'country': f.country!,
        'channel': f.channel,
      },
      if (event == AppEvent.firstConnect && f.country != null)
        'country': f.country!,
    };
    final ok = await send(body);
    if (ok) await prefs.setBool(key, true);
    return ok;
  }

  /// The daily "in use" ping for the tunnel that just came up on [profile].
  /// At most one accepted ping per local day; the first of the phone's week
  /// and month carry a flag, which lets the server count unique phones per
  /// week and month without an identifier.
  static Future<bool> active(
    ProxyProfile profile, {
    required bool enabled,
  }) async {
    if (!enabled || _activeBusy) return false;
    _activeBusy = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final today = now();
      final day = UsageLabels.dayOf(today);
      if (prefs.getString(_kActiveDay) == day) return false;
      final week = UsageLabels.week(today);
      final month = UsageLabels.monthOf(today);
      final f = await _factsOnce();
      final body = <String, Object>{
        'event': 'active',
        'platform': platform,
        'kind': UsageLabels.kind(profile),
        'source': UsageLabels.source(profile),
        'proto': UsageLabels.proto(profile),
        'channel': f.channel,
        'version': appVersion,
        if (f.country != null) 'country': f.country!,
        if (f.installedAt != null)
          'age': UsageLabels.age(f.installedAt!, today),
        'new_week': prefs.getString(_kActiveWeek) != week,
        'new_month': prefs.getString(_kActiveMonth) != month,
      };
      if (!await send(body)) return false;
      await prefs.setString(_kActiveDay, day);
      await prefs.setString(_kActiveWeek, week);
      await prefs.setString(_kActiveMonth, month);
      return true;
    } catch (_) {
      return false;
    } finally {
      _activeBusy = false;
    }
  }

  static Future<DeviceFacts>? _facts;
  static Future<DeviceFacts> _factsOnce() => _facts ??= facts();

  @visibleForTesting
  static void resetFacts() => _facts = null;

  static Future<DeviceFacts> _nativeFacts() async {
    try {
      final m = await _control
          .invokeMapMethod<String, Object?>('usageFacts')
          .timeout(const Duration(seconds: 3));
      return DeviceFacts.fromNative(m ?? const {}, ios: Platform.isIOS);
    } catch (_) {
      return DeviceFacts(channel: Platform.isIOS ? 'appstore' : 'apk');
    }
  }

  static Future<bool> _post(Map<String, Object> body) async {
    try {
      final res = await http
          .post(
            Uri.parse(endpoint),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

/// What the platform knows about this install, reduced to wire labels.
class DeviceFacts {
  /// Two-letter country code: the mobile network's, else the SIM's, else the
  /// region setting. Never from an IP address: through a tunnel that would
  /// be the server's country, not the user's.
  final String? country;

  /// play, appstore, apk or fdroid.
  final String channel;
  final DateTime? installedAt;

  const DeviceFacts({this.country, required this.channel, this.installedAt});

  static const _fdroid = {
    'org.fdroid.fdroid',
    'org.fdroid.basic',
    'com.looker.droidify',
  };

  factory DeviceFacts.fromNative(Map<String, Object?> m, {required bool ios}) {
    final raw = m['country'];
    final country = raw is String && RegExp(r'^[A-Za-z]{2}$').hasMatch(raw)
        ? raw.toUpperCase()
        : null;
    // Anything but a store is the APK from GitHub or the site, whichever
    // browser, file manager or updater put it on the phone.
    final installer = m['installer'];
    final channel = ios
        ? 'appstore'
        : installer == 'com.android.vending'
            ? 'play'
            : _fdroid.contains(installer)
                ? 'fdroid'
                : 'apk';
    final ms = m['installedAt'];
    return DeviceFacts(
      country: country,
      channel: channel,
      installedAt: ms is int && ms > 0
          ? DateTime.fromMillisecondsSinceEpoch(ms)
          : null,
    );
  }
}
