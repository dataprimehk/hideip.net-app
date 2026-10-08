/// What the account and pairing screens need from device pairing v2
/// (`/v1/link/*`, pairing v2 rev 1): capabilities, preview, approve,
/// permissions and the device list with its removal. The screens talk to
/// [PairingPort] only; the HTTP client behind it belongs to the app core.
///
/// Until the core has a v2 client, [LegacyPairingPort] answers for it: it
/// says pairing v2 is not there, so no screen offers a code entry or a
/// preview that would lead nowhere, and it serves the 1.2.0 list and removal
/// through the existing [DeviceLinkService].
library;

import 'package:flutter/foundation.dart';

import '../../../core/premium.dart';
import '../../../state/app_state.dart';
import 'account_device.dart';

/// The answer of `GET /v1/link/capabilities`. A server that does not answer,
/// answers 404, or says `pairing < 2` gets the 1.2.0 flow and nothing newer.
@immutable
class PairingCapabilities {
  /// The pairing protocol version the server speaks. 0 when it could not be
  /// asked, 1 for a server from before pairing v2.
  final int pairing;
  final Set<String> kinds;

  /// How many characters the short code has, separator not counted.
  final int codeLength;
  final Duration linkTtl;
  final Set<String> features;

  const PairingCapabilities({
    required this.pairing,
    this.kinds = const {},
    this.codeLength = 8,
    this.linkTtl = const Duration(minutes: 10),
    this.features = const {},
  });

  /// The server could not be asked: treated exactly like an old server.
  static const unknown = PairingCapabilities(pairing: 0);

  /// A server from before pairing v2.
  static const legacy = PairingCapabilities(pairing: 1);

  /// Reads the capabilities body. Anything unreadable is [unknown].
  static PairingCapabilities fromJson(Object? json) {
    if (json is! Map) return unknown;
    final version = json['pairing'];
    final length = json['code_length'];
    final ttl = json['link_ttl_s'];
    return PairingCapabilities(
      pairing: version is num ? version.toInt() : 0,
      kinds: {
        if (json['kinds'] case final List list)
          for (final k in list) k.toString(),
      },
      codeLength: length is num && length > 0 ? length.toInt() : 8,
      linkTtl: Duration(seconds: ttl is num && ttl > 0 ? ttl.toInt() : 600),
      features: {
        if (json['features'] case final List list)
          for (final f in list) f.toString(),
      },
    );
  }

  /// The new flow: the new device shows a QR code and a short code, this
  /// one previews what it is about to add before it approves.
  bool get v2 => pairing >= 2 && features.contains('preview');

  /// Per-device "can manage" can be read and changed.
  bool get permissions => pairing >= 2 && features.contains('permissions');
}

/// Why a pairing call did not go through, one value per answer the contract
/// names, plus the two the client adds itself.
enum PairingError {
  /// 401 `unauthorized`: the token is not (or no longer) on the account.
  unauthorized,

  /// 403 `not_permitted`: the token may use Premium but not manage.
  notPermitted,

  /// 403 `account_revoked`.
  accountRevoked,

  /// 404 `unknown_link`: no such request, wrong code, expired, cancelled,
  /// or approved by another account. The server says the same for all.
  unknownLink,

  /// 400 `bad_code`: not a code at all.
  badCode,

  /// 429 `too_many_attempts`.
  tooManyAttempts,

  /// 409 `device_limit_reached`, with the devices to choose from.
  deviceLimitReached,

  /// 403 `subscription_inactive`: the account is known but out of time.
  subscriptionInactive,

  /// 410 `link_expired`.
  linkExpired,

  /// 410 `link_cancelled`.
  linkCancelled,

  /// 400 `not_allowed_for_kind`: manage asked for a TV or a browser.
  notAllowedForKind,

  /// 400 `self`: a device asked to change its own permissions.
  self,

  /// 409 `last_manager`: the change would leave no device that manages.
  lastManager,

  /// The client has no pairing v2 to offer (no core client, old server).
  unsupported,

  /// No answer, or one the contract does not describe.
  network,
}

/// Maps an HTTP status and the body's `detail` onto [PairingError], by the
/// contract's own words. Null for a 200.
PairingError? pairingErrorOf(int status, Object? detail) {
  if (status == 200) return null;
  final d = detail?.toString();
  return switch ((status, d)) {
    (401, _) => PairingError.unauthorized,
    (403, 'account_revoked') => PairingError.accountRevoked,
    (403, 'subscription_inactive') => PairingError.subscriptionInactive,
    (403, _) => PairingError.notPermitted,
    (404, _) => PairingError.unknownLink,
    (400, 'bad_code') => PairingError.badCode,
    (400, 'not_allowed_for_kind') => PairingError.notAllowedForKind,
    (400, 'self') => PairingError.self,
    (409, 'device_limit_reached') => PairingError.deviceLimitReached,
    (409, 'last_manager') => PairingError.lastManager,
    (410, 'link_cancelled') => PairingError.linkCancelled,
    (410, _) => PairingError.linkExpired,
    (429, _) => PairingError.tooManyAttempts,
    _ => PairingError.network,
  };
}

/// The device that asked to be added, as the new device described itself.
/// Its name is what the new device said, not proof of what it is.
@immutable
class PairingTarget {
  final DeviceKind kind;
  final String name;
  final String? platform;
  const PairingTarget({required this.kind, required this.name, this.platform});

  static PairingTarget fromJson(Object? json) {
    final map = json is Map ? json : const {};
    final platform = map['platform']?.toString().trim();
    return PairingTarget(
      kind: deviceKindOf(map['kind']),
      name: map['name']?.toString().trim() ?? '',
      platform: platform == null || platform.isEmpty ? null : platform,
    );
  }
}

/// An open request, as `POST /v1/link/preview` shows it (K3). Nothing has
/// been approved by reading it.
@immutable
class PairingRequest {
  final String linkId;

  /// The short code, `XXXX-XXXX`, so both screens show the same mark.
  final String code;
  final PairingTarget device;
  final Duration expiresIn;
  final bool canGrantManage;
  final bool accountActive;
  final int devicesUsed;
  final int deviceLimit;

  const PairingRequest({
    required this.linkId,
    required this.code,
    required this.device,
    required this.expiresIn,
    required this.canGrantManage,
    required this.accountActive,
    required this.devicesUsed,
    required this.deviceLimit,
  });

  static PairingRequest? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['link_id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final account = json['account'] is Map ? json['account'] as Map : const {};
    int number(Object? v, int fallback) => v is num ? v.toInt() : fallback;
    return PairingRequest(
      linkId: id,
      code: json['code']?.toString() ?? '',
      device: PairingTarget.fromJson(json['device']),
      expiresIn: Duration(seconds: number(json['expires_in'], 0)),
      canGrantManage: json['can_grant_manage'] == true,
      accountActive: account['active'] != false,
      devicesUsed: number(account['devices_used'], 0),
      deviceLimit: number(account['device_limit'], 5),
    );
  }
}

/// What a preview came back with: the request, or why there is none.
@immutable
class PairingPreviewResult {
  final PairingRequest? request;
  final PairingError? error;
  const PairingPreviewResult.ok(PairingRequest this.request) : error = null;
  const PairingPreviewResult.failed(PairingError this.error) : request = null;
}

/// What an approval came back with (K4).
@immutable
class PairingApproveResult {
  final PairingError? error;

  /// The device that was added. Also set when the same account had already
  /// approved this request ([already]): no second device was made.
  final AccountDevice? device;
  final bool already;

  /// Whether the new device may manage the account.
  final bool manage;

  /// With [PairingError.deviceLimitReached]: the limit, and the devices to
  /// remove one from. The request stays open.
  final int? deviceLimit;
  final List<AccountDevice> devices;

  const PairingApproveResult.ok({
    required AccountDevice this.device,
    this.already = false,
    this.manage = false,
  }) : error = null,
       deviceLimit = null,
       devices = const [];

  const PairingApproveResult.limit({
    required int this.deviceLimit,
    required this.devices,
  }) : error = PairingError.deviceLimitReached,
       device = null,
       already = false,
       manage = false;

  const PairingApproveResult.failed(PairingError this.error)
    : device = null,
      already = false,
      manage = false,
      deviceLimit = null,
      devices = const [];

  bool get ok => error == null;
}

/// A change to one device (remove, or "can manage"): done, or why not.
@immutable
class DeviceChangeResult {
  final PairingError? error;

  /// The device as it is now, when the server sent it back.
  final AccountDevice? device;
  const DeviceChangeResult.ok([this.device]) : error = null;
  const DeviceChangeResult.failed(PairingError this.error) : device = null;
  bool get ok => error == null;
}

/// Pairing v2 as the screens see it. Every method answers; none throws.
/// The token, the account number and the request bodies (`v: 2`) are the
/// implementation's business.
abstract interface class PairingPort {
  /// K1. Cached by the implementation; never blocks long.
  Future<PairingCapabilities> capabilities();

  /// K3, by the id in a scanned QR code or by a typed code: exactly one of
  /// the two. The code goes as typed; the server normalizes it too.
  Future<PairingPreviewResult> preview({String? linkId, String? code});

  /// K4. [linkId] comes from the preview, so a typed code is spent on the
  /// preview only.
  Future<PairingApproveResult> approve({
    required String linkId,
    required bool grantManage,
  });

  /// K8: the devices on the account, or null when they could not be read.
  Future<List<AccountDevice>?> devices();

  /// K8 removal. With pairing v2, [confirmLastManager] answers the
  /// `last_manager` question (K7).
  Future<DeviceChangeResult> revoke(
    String deviceId, {
    bool confirmLastManager = false,
  });

  /// K7 `POST /v1/link/permissions`.
  Future<DeviceChangeResult> setManage(
    String deviceId, {
    required bool manage,
    bool confirmLastManager = false,
  });
}

/// The pairing a 1.2.0 core can do: the device list and its removal through
/// the subscription token, nothing of v2. Approving a scanned QR code and
/// showing a code stay in the 1.2.0 sheets of `linked_devices_screen.dart`.
class LegacyPairingPort implements PairingPort {
  final AppState state;
  LegacyPairingPort(this.state);

  @override
  Future<PairingCapabilities> capabilities() async =>
      PairingCapabilities.legacy;

  @override
  Future<PairingPreviewResult> preview({String? linkId, String? code}) async =>
      const PairingPreviewResult.failed(PairingError.unsupported);

  @override
  Future<PairingApproveResult> approve({
    required String linkId,
    required bool grantManage,
  }) async => const PairingApproveResult.failed(PairingError.unsupported);

  @override
  Future<List<AccountDevice>?> devices() async {
    final token = state.subToken;
    if (token == null) return null;
    final list = await state.deviceLinks.devices(token);
    // This phone's own entry, when it is on the list through an account
    // number; a store subscription's token is not a device of its own.
    final own = state.premium.source == PremiumSource.account
        ? state.accountDeviceId
        : null;
    return list
        ?.map((d) => AccountDevice.fromLinked(d, current: d.id == own))
        .toList(growable: false);
  }

  @override
  Future<DeviceChangeResult> revoke(
    String deviceId, {
    bool confirmLastManager = false,
  }) async {
    final token = state.subToken;
    if (token == null) {
      return const DeviceChangeResult.failed(PairingError.unauthorized);
    }
    final ok = await state.deviceLinks.revoke(
      subToken: token,
      deviceId: deviceId,
    );
    return ok
        ? const DeviceChangeResult.ok()
        : const DeviceChangeResult.failed(PairingError.network);
  }

  @override
  Future<DeviceChangeResult> setManage(
    String deviceId, {
    required bool manage,
    bool confirmLastManager = false,
  }) async => const DeviceChangeResult.failed(PairingError.unsupported);
}

/// The characters a pairing code is made of (K2): no 0, 1, I or O, so
/// nothing on a TV screen reads two ways.
const pairingCodeAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

/// A typed code without spaces or dashes, upper case. Characters outside
/// the alphabet are kept, so they can be pointed out rather than dropped.
String normalizePairingCode(String raw) =>
    raw.replaceAll(RegExp(r'[\s\-]'), '').toUpperCase();

/// Whether every character of a normalized code is one a code can have.
bool pairingCodeCharsValid(String normalized) =>
    normalized.split('').every(pairingCodeAlphabet.contains);

/// `7KQM3XHP` as `7KQM-3XHP`, the way the new device shows it.
String displayPairingCode(String normalized) {
  if (normalized.length <= 4) return normalized;
  return '${normalized.substring(0, 4)}-${normalized.substring(4)}';
}
