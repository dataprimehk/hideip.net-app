/// Signing in with an account number: the `/v1/account/*` endpoints on the
/// provisioning backend.
///
/// The account number is the only credential, so it travels in a POST body
/// and never in a URL. A device that came onto the account through a store
/// purchase and was never told the number proves itself with its own device
/// token instead, in the same place. Every call is anonymous otherwise: no
/// email, no password, no device identifier beyond the name this phone gives
/// itself.
/// Nothing here throws; every failure is one of the [AccountResult] values
/// and the screen picks its words from those, never from the server's text.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:http/http.dart' as http;

import 'account_number.dart';
import 'device_link.dart';
import 'provisioning.dart';

/// How a call to the account API ended.
enum AccountResult {
  /// Done. For a sign-in: this device is on the account and has a
  /// subscription URL.
  ok,

  /// The number is valid but the account has run out of time. Nothing was
  /// spent: no device was added.
  inactive,

  /// Not an account number: wrong length or a failed check digit (400).
  invalid,

  /// No account has this number (404).
  unknown,

  /// The account was shut down, for good (403).
  revoked,

  /// The account already has as many devices as it may have (409).
  deviceLimit,

  /// Too many attempts from this network in a short while (429).
  tooManyAttempts,

  /// Could not reach the server, or any other answer.
  network,
}

/// What a sign-in returned.
class AccountSignIn {
  final AccountResult result;

  /// When the account's time runs out. Set for [AccountResult.ok] and
  /// [AccountResult.inactive].
  final DateTime? expires;

  /// Where this device's servers are served from. Only for
  /// [AccountResult.ok].
  final String? subscriptionUrl;

  /// This device's entry on the account.
  final String? deviceId;
  final String? deviceName;

  /// The secret this device proves itself with on later calls: signing in
  /// again without using a second slot, and the linked-devices API.
  final String? deviceToken;

  /// How many devices the account may have. Filled from the answer when it
  /// states it, otherwise the backend's documented default.
  final int deviceLimit;

  const AccountSignIn(
    this.result, {
    this.expires,
    this.subscriptionUrl,
    this.deviceId,
    this.deviceName,
    this.deviceToken,
    this.deviceLimit = AccountService.defaultDeviceLimit,
  });
}

/// What the account looks like right now.
class AccountStatus {
  final AccountResult result;
  final bool active;
  final DateTime? expires;

  /// What the last payment on the account was: `monthly`, `yearly` or
  /// `trial`.
  final String? kind;

  /// The devices signed in to the account, or null when the answer carried
  /// no readable list (which is not the same as an empty one).
  final List<LinkedDevice>? devices;
  final int deviceLimit;

  /// Whether a store subscription adds time to the account and is still
  /// running, or null when the answer did not say.
  final bool? storeLinked;

  /// Which store that subscription is in: `ios` or `android`.
  final String? storePlatform;

  const AccountStatus(
    this.result, {
    this.active = false,
    this.expires,
    this.kind,
    this.devices,
    this.deviceLimit = AccountService.defaultDeviceLimit,
    this.storeLinked,
    this.storePlatform,
  });
}

/// What a new account number came back as.
class AccountRotate {
  final AccountResult result;

  /// The new number, canonical (sixteen digits, no spaces). Only for
  /// [AccountResult.ok]; it is shown once and never stored anywhere else.
  final String? accountNumber;
  final DateTime? expires;
  final bool devicesRevoked;

  /// The answer was lost, but the old number no longer works: the new one
  /// was most likely issued and never arrived.
  final bool maybeIssued;

  const AccountRotate(
    this.result, {
    this.accountNumber,
    this.expires,
    this.devicesRevoked = false,
    this.maybeIssued = false,
  });
}

/// The name this device goes by on the account. The platform only, the
/// same as a device linked by QR code: a hardware model would be one more
/// identifier than the app needs.
String get accountDeviceName =>
    defaultTargetPlatform == TargetPlatform.iOS ? 'iPhone' : 'Android phone';

/// Talks to `/v1/account/*`. Stateless: every call carries the number, or
/// this device's token on the account when the number is not known here.
class AccountService {
  /// The provisioning host, the same one the store purchase goes through.
  static String get endpoint => ProvisioningService.endpoint;

  /// The backend's device limit, used when an answer does not state one.
  static const defaultDeviceLimit = 5;

  final http.Client _client;

  /// How long one call may take before it counts as a network failure.
  final Duration timeout;
  AccountService({
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  static const _jsonHeaders = {'content-type': 'application/json'};

  Future<http.Response> _post(String path, Map<String, dynamic> body) => _client
      .post(
        Uri.parse('$endpoint$path'),
        headers: _jsonHeaders,
        body: jsonEncode(body),
      )
      .timeout(timeout);

  /// The answer to a failed call. A server that is down or answers
  /// something unexpected reads the same as one that cannot be reached: the
  /// user can only try again either way.
  static AccountResult _failure(int status) => switch (status) {
    400 => AccountResult.invalid,
    403 => AccountResult.revoked,
    404 => AccountResult.unknown,
    409 => AccountResult.deviceLimit,
    429 => AccountResult.tooManyAttempts,
    _ => AccountResult.network,
  };

  static Map<String, dynamic>? _json(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static DateTime? _ms(Object? raw) {
    final n = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
    if (n == null || n <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(n);
  }

  static int _limit(Map<String, dynamic>? body) {
    final raw = body?['device_limit'];
    return raw is num && raw > 0 ? raw.toInt() : defaultDeviceLimit;
  }

  static String? _text(Object? raw) {
    final s = raw?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }

  /// What a call proves the account with: the number when there is one,
  /// otherwise this device's token. Null when neither can be sent, which
  /// includes a number that fails its check digit.
  static Map<String, dynamic>? _auth(String? number, String? deviceToken) {
    if (number != null) {
      final digits = normalizeAccountNumber(number);
      return isValidAccountNumber(digits) ? {'account_number': digits} : null;
    }
    final token = _text(deviceToken);
    return token == null ? null : {'device_token': token};
  }

  /// Put this device on the account behind [number]. Passing the
  /// [deviceToken] from an earlier sign-in returns that same device instead
  /// of taking a new slot.
  Future<AccountSignIn> signIn(
    String number, {
    String kind = 'phone',
    String? name,
    String? deviceToken,
  }) async {
    final digits = normalizeAccountNumber(number);
    // Checked here as well as on the screen: a mistyped number must never
    // leave the device.
    if (!isValidAccountNumber(digits)) {
      return const AccountSignIn(AccountResult.invalid);
    }
    try {
      final resp = await _post('/v1/account/signin', {
        'account_number': digits,
        'kind': kind,
        'name': name ?? accountDeviceName,
        'device_token': deviceToken,
      });
      final body = _json(resp.body);
      if (resp.statusCode != 200) {
        return AccountSignIn(
          _failure(resp.statusCode),
          deviceLimit: _limit(body),
        );
      }
      if (body == null) return const AccountSignIn(AccountResult.network);
      final expires = _ms(body['expires_ms']);
      if (body['active'] != true) {
        return AccountSignIn(
          AccountResult.inactive,
          expires: expires,
          deviceLimit: _limit(body),
        );
      }
      final url = _text(body['subscription_url']);
      final token = _text(body['device_token']);
      final device = body['device'];
      final deviceMap = device is Map<String, dynamic> ? device : null;
      // An active answer without a URL or a token is not one this app can
      // do anything with; it waits for the next try like any other failure.
      if (url == null || token == null) {
        return const AccountSignIn(AccountResult.network);
      }
      return AccountSignIn(
        AccountResult.ok,
        expires: expires,
        subscriptionUrl: url,
        deviceId: _text(deviceMap?['id']),
        deviceName: _text(deviceMap?['name']),
        deviceToken: token,
        deviceLimit: _limit(body),
      );
    } catch (_) {
      return const AccountSignIn(AccountResult.network);
    }
  }

  /// The account behind [number], or behind [deviceToken] when the number
  /// is not known: its time and its devices. Null when the server could not
  /// be asked, so the caller keeps what it knew.
  Future<AccountStatus?> status(String? number, {String? deviceToken}) async {
    final auth = _auth(number, deviceToken);
    if (auth == null) return const AccountStatus(AccountResult.invalid);
    try {
      final resp = await _post('/v1/account/status', auth);
      if (resp.statusCode != 200) {
        final result = _failure(resp.statusCode);
        return result == AccountResult.network ? null : AccountStatus(result);
      }
      final body = _json(resp.body);
      if (body == null) return null;
      return AccountStatus(
        AccountResult.ok,
        active: body['active'] == true,
        expires: _ms(body['expires_ms']),
        kind: _text(body['kind']),
        devices: parseDevices(resp.body),
        deviceLimit: _limit(body),
        storeLinked: body['store_linked'] is bool
            ? body['store_linked'] as bool
            : null,
        storePlatform: _text(body['store_platform']),
      );
    } catch (_) {
      return null;
    }
  }

  /// Swap [number] for a new one. The old number stops working at once;
  /// the time and the devices stay, unless [revokeDevices] signs every
  /// device out as well (this one included). Without a number, [deviceToken]
  /// asks for one: the way a device that was never told the number gets one.
  Future<AccountRotate> rotate(
    String? number, {
    String? deviceToken,
    bool revokeDevices = false,
  }) async {
    final auth = _auth(number, deviceToken);
    if (auth == null) return const AccountRotate(AccountResult.invalid);
    try {
      final resp = await _post('/v1/account/rotate', {
        ...auth,
        'revoke_devices': revokeDevices,
      });
      if (resp.statusCode != 200) {
        return AccountRotate(_failure(resp.statusCode));
      }
      final body = _json(resp.body);
      final fresh = normalizeAccountNumber(
        body?['account_number']?.toString() ?? '',
      );
      if (!isValidAccountNumber(fresh)) {
        return const AccountRotate(AccountResult.network);
      }
      return AccountRotate(
        AccountResult.ok,
        accountNumber: fresh,
        expires: _ms(body?['expires_ms']),
        devicesRevoked: body?['devices_revoked'] == true,
      );
    } catch (_) {
      return const AccountRotate(AccountResult.network);
    }
  }

  /// Take one device off the account. A device the account no longer has
  /// is already gone, so that answer counts as done.
  Future<AccountResult> revokeDevice(
    String? number,
    String deviceId, {
    String? deviceToken,
  }) => _revoke(number, deviceToken, {'device_id': deviceId});

  /// Take every device off the account.
  Future<AccountResult> revokeAll(String? number, {String? deviceToken}) =>
      _revoke(number, deviceToken, {'all': true});

  Future<AccountResult> _revoke(
    String? number,
    String? deviceToken,
    Map<String, dynamic> which,
  ) async {
    final auth = _auth(number, deviceToken);
    if (auth == null) return AccountResult.invalid;
    try {
      final resp = await _post('/v1/account/revoke', {...auth, ...which});
      if (resp.statusCode == 200) return AccountResult.ok;
      if (resp.statusCode == 404 &&
          _json(resp.body)?['detail'] == 'unknown_device') {
        return AccountResult.ok;
      }
      return _failure(resp.statusCode);
    } catch (_) {
      return AccountResult.network;
    }
  }

  /// Delete the account for good: the number stops working and every device
  /// is signed out. A store subscription that adds time to it is not touched;
  /// only the store can stop that.
  Future<AccountResult> delete(String? number, {String? deviceToken}) async {
    final auth = _auth(number, deviceToken);
    if (auth == null) return AccountResult.invalid;
    try {
      final resp = await _post('/v1/account/delete', auth);
      if (resp.statusCode != 200) return _failure(resp.statusCode);
      return _json(resp.body)?['deleted'] == true
          ? AccountResult.ok
          : AccountResult.network;
    } catch (_) {
      return AccountResult.network;
    }
  }
}
