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
  /// The account number, canonical (sixteen digits, no spaces).
  final String number;

  /// This device's secret on the account, or null while the account has no
  /// time left and no device was added for it.
  final String? deviceToken;

  /// This device's entry on the account, for the "This device" badge and
  /// for signing out.
  final String? deviceId;

  /// What the last payment was: `monthly`, `yearly` or `trial`.
  final String? kind;

  /// When the account's time runs out.
  final DateTime? expires;

  const AccountCredentials({
    required this.number,
    this.deviceToken,
    this.deviceId,
    this.kind,
    this.expires,
  });

  /// The same credentials with a newer standing from the server.
  AccountCredentials withStanding({String? kind, DateTime? expires}) =>
      AccountCredentials(
        number: number,
        deviceToken: deviceToken,
        deviceId: deviceId,
        kind: kind ?? this.kind,
        expires: expires ?? this.expires,
      );
}

class AccountStore {
  const AccountStore();

  static const kNumber = 'premium_account_number';
  static const kDeviceToken = 'premium_account_device_token';
  static const kDeviceId = 'premium_account_device_id';
  static const kKind = 'premium_account_kind';
  static const kExpiresMs = 'premium_account_expires_ms';

  /// What is stored, or null when this device is not signed in.
  Future<AccountCredentials?> load() async {
    final number = await SecretPrefs.readString(kNumber);
    if (number == null || number.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(kExpiresMs);
    return AccountCredentials(
      number: number,
      deviceToken: _nonEmpty(await SecretPrefs.readString(kDeviceToken)),
      deviceId: _nonEmpty(await SecretPrefs.readString(kDeviceId)),
      kind: prefs.getString(kKind),
      expires: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
    );
  }

  /// Writes [credentials] over whatever was stored. A field that is null is
  /// removed rather than kept from before.
  Future<void> save(AccountCredentials credentials) async {
    await SecretPrefs.writeString(kNumber, credentials.number);
    await _secret(kDeviceToken, credentials.deviceToken);
    await _secret(kDeviceId, credentials.deviceId);
    await saveStanding(kind: credentials.kind, expires: credentials.expires);
  }

  /// Updates the kind and the expiry only; the secrets stay as they are.
  Future<void> saveStanding({String? kind, DateTime? expires}) async {
    final prefs = await SharedPreferences.getInstance();
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kKind);
    await prefs.remove(kExpiresMs);
  }

  static Future<void> _secret(String key, String? value) => value == null
      ? SecretPrefs.deleteString(key)
      : SecretPrefs.writeString(key, value);

  static String? _nonEmpty(String? s) => s == null || s.isEmpty ? null : s;
}
