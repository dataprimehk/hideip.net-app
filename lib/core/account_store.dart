/// Where the account number and this device's standing on it are kept.
///
/// The number and the device token are secrets: whoever holds them holds
/// the subscription. They live in [SecretPrefs] (encrypted, key in the
/// Keychain / Keystore). The account's kind and expiry are not secret and
/// sit in plain preferences, where the Settings row can read them cheaply.
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'secret_prefs.dart';

/// Everything this device keeps about the account it is signed in to.
class AccountCredentials {
  /// The account number, canonical (sixteen digits, no spaces). Null on a
  /// device that came onto the account through a store purchase made
  /// elsewhere: the number is only ever told once, to the device that made
  /// it, and this one proves itself with [deviceToken] instead.
  final String? number;

  /// This device's secret on the account, or null while the account has no
  /// time left and no device was added for it.
  final String? deviceToken;

  /// This device's entry on the account, for the "This device" badge and
  /// for signing out.
  final String? deviceId;

  /// What the last payment was: `monthly`, `yearly` or `trial`.
  final String? kind;

  /// When the account's time runs out, as the server last said.
  final DateTime? expires;

  /// Whether the server last said the account has time. The device never
  /// works this out from [expires]: time can be added from anywhere.
  final bool active;

  const AccountCredentials({
    required this.number,
    this.deviceToken,
    this.deviceId,
    this.kind,
    this.expires,
    this.active = true,
  });

  /// Whether this device is on the account. False after an account with no
  /// time was entered, or after this device was taken off the account.
  bool get hasDevice => deviceToken != null;

  /// The same credentials with a newer standing from the server.
  AccountCredentials withStanding({
    String? kind,
    DateTime? expires,
    bool? active,
  }) => AccountCredentials(
    number: number,
    deviceToken: deviceToken,
    deviceId: deviceId,
    kind: kind ?? this.kind,
    expires: expires ?? this.expires,
    active: active ?? this.active,
  );

  /// The same number with this device no longer on the account.
  AccountCredentials withoutDevice() => AccountCredentials(
    number: number,
    kind: kind,
    expires: expires,
    active: active,
  );
}

/// How this device's store subscription stands toward the account number.
/// Not secret: it says nothing a store receipt would not.
class StoreLink {
  /// The subscription adds its time to the account this device is on, by
  /// the server's last word. While it does, the account is the entitlement
  /// in force and the subscription is only how it is paid for.
  final bool linked;

  /// This device left an account the subscription adds time to (signed out,
  /// taken off from elsewhere, or the number deleted). A renewal arriving
  /// on its own does not put it back; a purchase or a restore does.
  final bool paused;

  /// The subscription already adds time to a different account number than
  /// the one this device is on.
  final bool elsewhere;

  /// The one-off check for an install from before accounts took store
  /// purchases has had its answer.
  final bool checked;

  /// When the store charges next, by the server's reading of the store.
  final DateTime? renews;

  const StoreLink({
    this.linked = false,
    this.paused = false,
    this.elsewhere = false,
    this.checked = false,
    this.renews,
  });

  StoreLink copyWith({
    bool? linked,
    bool? paused,
    bool? elsewhere,
    bool? checked,
    DateTime? renews,
  }) => StoreLink(
    linked: linked ?? this.linked,
    paused: paused ?? this.paused,
    elsewhere: elsewhere ?? this.elsewhere,
    checked: checked ?? this.checked,
    renews: renews ?? this.renews,
  );
}

class AccountStore {
  const AccountStore();

  static const kNumber = 'premium_account_number';
  static const kDeviceToken = 'premium_account_device_token';
  static const kDeviceId = 'premium_account_device_id';
  static const kKind = 'premium_account_kind';
  static const kExpiresMs = 'premium_account_expires_ms';
  static const kActive = 'premium_account_active';
  static const kStatusAtMs = 'premium_account_status_at_ms';
  static const kFreshNumber = 'premium_account_fresh_number';
  static const kLastNumber = 'premium_account_last_number';
  static const kStoreLinked = 'premium_store_link_v2';
  static const kStoreLinkPaused = 'premium_store_link_paused_v2';
  static const kStoreLinkedElsewhere = 'premium_store_link_elsewhere_v2';
  static const kStoreLinkChecked = 'premium_store_link_checked_v2';
  static const kStoreRenewsMs = 'premium_store_link_renews_ms_v2';

  /// A number a store purchase has just made, until the user has seen it.
  /// As secret as the number itself, so it is kept the same way.
  Future<String?> freshNumber() async =>
      _nonEmpty(await SecretPrefs.readString(kFreshNumber));

  Future<void> saveFreshNumber(String? number) => _secret(kFreshNumber, number);

  /// The number this device was last signed in with, kept past a sign-out
  /// so signing back in is one tap (the server cannot show it again). Only
  /// deleting the number forgets it.
  Future<String?> lastNumber() async =>
      _nonEmpty(await SecretPrefs.readString(kLastNumber));

  Future<void> saveLastNumber(String? number) => _secret(kLastNumber, number);

  Future<StoreLink> loadStoreLink() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(kStoreRenewsMs);
    return StoreLink(
      linked: prefs.getBool(kStoreLinked) ?? false,
      paused: prefs.getBool(kStoreLinkPaused) ?? false,
      elsewhere: prefs.getBool(kStoreLinkedElsewhere) ?? false,
      checked: prefs.getBool(kStoreLinkChecked) ?? false,
      renews: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
    );
  }

  Future<void> saveStoreLink(StoreLink link) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kStoreLinked, link.linked);
    await prefs.setBool(kStoreLinkPaused, link.paused);
    await prefs.setBool(kStoreLinkedElsewhere, link.elsewhere);
    await prefs.setBool(kStoreLinkChecked, link.checked);
    final renews = link.renews;
    if (renews == null) {
      await prefs.remove(kStoreRenewsMs);
    } else {
      await prefs.setInt(kStoreRenewsMs, renews.millisecondsSinceEpoch);
    }
  }

  /// What is stored, or null when this device is not signed in.
  Future<AccountCredentials?> load() async {
    final number = _nonEmpty(await SecretPrefs.readString(kNumber));
    final token = _nonEmpty(await SecretPrefs.readString(kDeviceToken));
    if (number == null && token == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(kExpiresMs);
    return AccountCredentials(
      number: number,
      deviceToken: token,
      deviceId: _nonEmpty(await SecretPrefs.readString(kDeviceId)),
      kind: prefs.getString(kKind),
      expires: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
      active: prefs.getBool(kActive) ?? true,
    );
  }

  /// Writes [credentials] over whatever was stored. A field that is null is
  /// removed rather than kept from before.
  Future<void> save(AccountCredentials credentials) async {
    await _secret(kNumber, credentials.number);
    await _secret(kDeviceToken, credentials.deviceToken);
    await _secret(kDeviceId, credentials.deviceId);
    await saveStanding(
      kind: credentials.kind,
      expires: credentials.expires,
      active: credentials.active,
    );
  }

  /// Updates the standing only; the secrets stay as they are.
  Future<void> saveStanding({
    String? kind,
    DateTime? expires,
    bool active = true,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kActive, active);
    if (kind == null) {
      await prefs.remove(kKind);
    } else {
      await prefs.setString(kKind, kind);
    }
    if (expires == null) {
      await prefs.remove(kExpiresMs);
    } else {
      await prefs.setInt(kExpiresMs, expires.millisecondsSinceEpoch);
    }
  }

  /// Forgets the account on this device.
  Future<void> clear() async {
    await SecretPrefs.deleteString(kNumber);
    await SecretPrefs.deleteString(kDeviceToken);
    await SecretPrefs.deleteString(kDeviceId);
    await SecretPrefs.deleteString(kFreshNumber);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kKind);
    await prefs.remove(kExpiresMs);
    await prefs.remove(kActive);
    await prefs.remove(kStatusAtMs);
  }

  /// When the server was last asked about the account, or null if never.
  Future<DateTime?> lastStatusAt() async {
    final ms = (await SharedPreferences.getInstance()).getInt(kStatusAtMs);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> markStatusAt(DateTime at) async =>
      (await SharedPreferences.getInstance()).setInt(
        kStatusAtMs,
        at.millisecondsSinceEpoch,
      );

  static Future<void> _secret(String key, String? value) => value == null
      ? SecretPrefs.deleteString(key)
      : SecretPrefs.writeString(key, value);

  static String? _nonEmpty(String? s) => s == null || s.isEmpty ? null : s;
}
