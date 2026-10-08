/// Device pairing v2 (`/v1/link/*`, pairing v2 rev 1): a new device asks
/// for access with a QR code and a short code, a device that manages the
/// account looks at the request and approves it.
///
/// Both halves live here. The approving half ([PairingClient.preview],
/// [PairingClient.approve], the device list, removal and permissions) is
/// what the Account screens use. The asking half ([PairingClient.start],
/// [PairingClient.poll], [PairingClient.ack], [PairingClient.cancel]) is
/// what a new device runs while it shows its code.
///
/// Every call answers and none throws. A server from before pairing v2
/// answers `capabilities` with 404, and the app then keeps to the first
/// protocol and offers nothing that would lead nowhere.
///
/// Nothing secret is ever put in a URL or a log: the poll secret, the
/// device token and the code travel in POST bodies only. The device list is
/// the one GET, and it carries the device's own token, as it did before.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'account_number.dart';
import 'device_link.dart';
import 'provisioning.dart';

// --- Devices ------------------------------------------------------------------

/// What kind of device it is. Only ever for the icon and the label: the
/// server decides what a device may do, never the kind it says it is.
enum DeviceKind { phone, tablet, desktop, tv, extension, unknown }

/// Reads a wire `kind`. A kind this build does not know yet is shown as a
/// plain device instead of hiding the row.
DeviceKind deviceKindOf(Object? raw) =>
    switch (raw?.toString().trim().toLowerCase()) {
      'phone' => DeviceKind.phone,
      'tablet' => DeviceKind.tablet,
      'desktop' => DeviceKind.desktop,
      'tv' => DeviceKind.tv,
      'extension' => DeviceKind.extension,
      _ => DeviceKind.unknown,
    };

/// Whether a device of [kind] can be given the right to manage the account
/// (phones, tablets and computers only).
bool kindCanManage(DeviceKind kind) =>
    kind == DeviceKind.phone ||
    kind == DeviceKind.tablet ||
    kind == DeviceKind.desktop;

/// One device on the account: the device row of pairing v2, which knows
/// TVs, tablets and who may manage the account.
@immutable
class AccountDevice {
  final String id;
  final DeviceKind kind;

  /// What the device calls itself. Never empty: an unnamed device is still
  /// told apart in the list.
  final String name;
  final DateTime? createdAt;
  final DateTime? lastSeenAt;

  /// Whether it may manage the account, or null when the server did not say
  /// (a server from before pairing v2).
  final bool? manage;

  /// The device this list was read on.
  final bool current;

  const AccountDevice({
    required this.id,
    required this.kind,
    required this.name,
    this.createdAt,
    this.lastSeenAt,
    this.manage,
    this.current = false,
  });

  /// One device row. Null without an id: a device that cannot be addressed
  /// cannot be removed either.
  static AccountDevice? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id']?.toString().trim() ?? '';
    if (id.isEmpty) return null;
    final name = json['name']?.toString().trim() ?? '';
    final permissions = json['permissions'];
    final manage = permissions is Map ? permissions['manage'] : null;
    return AccountDevice(
      id: id,
      kind: deviceKindOf(json['kind']),
      name: name.isEmpty ? unnamedDevice : name,
      createdAt: _seconds(json['created_at']),
      lastSeenAt: _seconds(json['last_seen_at']),
      manage: manage is bool ? manage : null,
      current: json['current'] == true,
    );
  }

  /// A row of the device list as [LinkedDevice] reads it. A newer server
  /// fills in the kind it really is, the permissions and which row is the
  /// device asking; an older one leaves them out.
  factory AccountDevice.fromLinked(LinkedDevice d, {bool current = false}) =>
      AccountDevice(
        id: d.id,
        kind: deviceKindOf(d.kindName),
        name: d.name,
        createdAt: d.createdAt,
        lastSeenAt: d.lastSeenAt,
        manage: d.manage,
        current: current || d.current,
      );

  AccountDevice copyWith({bool? manage, bool? current}) => AccountDevice(
    id: id,
    kind: kind,
    name: name,
    createdAt: createdAt,
    lastSeenAt: lastSeenAt,
    manage: manage ?? this.manage,
    current: current ?? this.current,
  );

  /// The kind in words, for the row's subtitle.
  String get kindLabel => switch (kind) {
    DeviceKind.phone => 'Phone',
    DeviceKind.tablet => 'Tablet',
    DeviceKind.desktop => 'Desktop',
    DeviceKind.tv => 'TV',
    DeviceKind.extension => 'Browser',
    DeviceKind.unknown => 'Device',
  };

  /// What a device that gave no name is called in the list.
  static const unnamedDevice = 'Unnamed device';
}

DateTime? _seconds(Object? raw) {
  final n = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
  if (n == null || n <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(n * 1000);
}

// --- What the server speaks ----------------------------------------------------

/// The answer of `GET /v1/link/capabilities`. A server that does not answer,
/// answers 404, or says `pairing < 2` gets the first protocol and nothing
/// newer.
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

  /// A new device can ask for access itself and confirm it got it.
  bool get request => pairing >= 2 && features.contains('ack');
}

// --- Errors --------------------------------------------------------------------

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

// --- The approving device ------------------------------------------------------

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

/// An open request, as `POST /v1/link/preview` shows it. Nothing has been
/// approved by reading it.
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

/// What an approval came back with.
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

/// The characters a pairing code is made of: no 0, 1, I or O, so nothing
/// on a TV screen reads two ways.
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

/// What a managing call proves the account with: this device's token on the
/// account (or a store subscription's token), or the account number. The
/// token wins when there are both, so the server can mark this device as
/// the current one in its lists.
@immutable
class PairingAuth {
  final String? token;
  final String? accountNumber;
  const PairingAuth({this.token, this.accountNumber});

  bool get usable => token != null || accountNumber != null;

  Map<String, dynamic> get body {
    final t = token;
    if (t != null) return {'token': t};
    final digits = normalizeAccountNumber(accountNumber ?? '');
    return isValidAccountNumber(digits) ? {'account_number': digits} : {};
  }
}

// --- The asking device -----------------------------------------------------------

/// An open request this device made: what it shows (the QR payload and the
/// code) and the secret only it holds. The secret never leaves this device
/// except to collect the answer.
@immutable
class LinkTicket {
  final String linkId;
  final String pollSecret;
  final String qrPayload;

  /// `XXXX-XXXX`. Empty when the server answered the first protocol.
  final String code;

  /// When the request stops being approvable, by this device's clock.
  final DateTime expiresAt;

  const LinkTicket({
    required this.linkId,
    required this.pollSecret,
    required this.qrPayload,
    required this.code,
    required this.expiresAt,
  });

  static LinkTicket? fromStartJson(Object? json, DateTime now) {
    if (json is! Map) return null;
    final id = json['link_id']?.toString().trim() ?? '';
    final secret = json['poll_secret']?.toString() ?? '';
    if (id.isEmpty || secret.isEmpty) return null;
    final ttl = json['expires_in'];
    final qr = json['qr_payload']?.toString().trim() ?? '';
    return LinkTicket(
      linkId: id,
      pollSecret: secret,
      qrPayload: qr.isEmpty ? 'hideip://link?v=1&id=$id' : qr,
      code: json['code']?.toString().trim() ?? '',
      expiresAt: now.add(
        Duration(seconds: ttl is num && ttl > 0 ? ttl.toInt() : 600),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'link_id': linkId,
    'poll_secret': pollSecret,
    'qr_payload': qrPayload,
    'code': code,
    'expires_at_ms': expiresAt.millisecondsSinceEpoch,
  };

  static LinkTicket? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['link_id']?.toString() ?? '';
    final secret = json['poll_secret']?.toString() ?? '';
    final ms = json['expires_at_ms'];
    if (id.isEmpty || secret.isEmpty || ms is! num) return null;
    return LinkTicket(
      linkId: id,
      pollSecret: secret,
      qrPayload: json['qr_payload']?.toString() ?? '',
      code: json['code']?.toString() ?? '',
      expiresAt: DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
    );
  }
}

/// The approved answer, as the asking device collects it: its own token on
/// the account and what it connects with. Kept on the device until the
/// server has been told it arrived.
@immutable
class LinkHandoff {
  final String deviceToken;
  final String? deviceId;
  final String? deviceName;
  final String? kind;

  /// Whether this device may manage the account, or null when the server
  /// did not say.
  final bool? manage;

  /// Where this device's servers are served from.
  final String? subUrl;
  final bool active;
  final DateTime? expires;
  final int? deviceLimit;

  const LinkHandoff({
    required this.deviceToken,
    this.deviceId,
    this.deviceName,
    this.kind,
    this.manage,
    this.subUrl,
    this.active = true,
    this.expires,
    this.deviceLimit,
  });

  /// Reads an approved poll answer; null when it carries no token.
  static LinkHandoff? fromPollJson(Object? json) {
    if (json is! Map) return null;
    final token = _text(json['device_token']);
    if (token == null) return null;
    final device = json['device'] is Map ? json['device'] as Map : const {};
    final permissions = json['permissions'] is Map
        ? json['permissions'] as Map
        : const {};
    final credentials = json['credentials'] is Map
        ? json['credentials'] as Map
        : const {};
    final account = json['account'] is Map ? json['account'] as Map : const {};
    final manage = permissions['manage'];
    final limit = account['device_limit'];
    return LinkHandoff(
      deviceToken: token,
      deviceId: _text(device['id']),
      deviceName: _text(device['name']),
      kind: _text(device['kind']),
      manage: manage is bool ? manage : null,
      subUrl: _text(credentials['sub_url']),
      active: account['active'] != false,
      expires: _ms(account['expires_ms']),
      deviceLimit: limit is num && limit > 0 ? limit.toInt() : null,
    );
  }

  LinkHandoff withSubUrl(String url) => LinkHandoff(
    deviceToken: deviceToken,
    deviceId: deviceId,
    deviceName: deviceName,
    kind: kind,
    manage: manage,
    subUrl: url,
    active: active,
    expires: expires,
    deviceLimit: deviceLimit,
  );

  Map<String, dynamic> toJson() => {
    'device_token': deviceToken,
    'device': {'id': ?deviceId, 'name': ?deviceName, 'kind': ?kind},
    'permissions': {'manage': ?manage},
    'credentials': {'sub_url': ?subUrl},
    'account': {
      'active': active,
      'expires_ms': ?expires?.millisecondsSinceEpoch,
      'device_limit': ?deviceLimit,
    },
  };
}

/// Where an asking device's request stands, by the last poll.
enum LinkPollStatus {
  /// Nobody has approved it yet.
  pending,

  /// Approved: the answer carries this device's credentials.
  approved,

  /// The server has the acknowledgement already; the credentials are no
  /// longer handed out. Whatever this device stored is what it has.
  delivered,

  /// The request lapsed, or its answer was not collected in time.
  expired,

  /// This device cancelled it.
  cancelled,

  /// The device it would have become was removed before it was collected.
  revoked,

  /// The account ran out of time before the answer was collected.
  inactive,

  /// No such request, or the secret does not match.
  unknown,

  /// Too many attempts from this network.
  tooManyAttempts,

  /// No answer, or one the contract does not describe. Nothing is decided.
  network,
}

/// One poll's answer.
@immutable
class LinkPollResult {
  final LinkPollStatus status;

  /// Set for [LinkPollStatus.approved].
  final LinkHandoff? handoff;

  /// How long the request stays open, for [LinkPollStatus.pending].
  final Duration? expiresIn;

  const LinkPollResult(this.status, {this.handoff, this.expiresIn});

  /// Whether nothing more will come of this request.
  bool get finished => switch (status) {
    LinkPollStatus.pending ||
    LinkPollStatus.approved ||
    LinkPollStatus.tooManyAttempts ||
    LinkPollStatus.network => false,
    _ => true,
  };
}

/// How a request for access started.
enum LinkStartError {
  /// The server does not speak pairing v2 (or could not be asked).
  unsupported,
  tooManyAttempts,
  network,
}

@immutable
class LinkStartResult {
  final LinkTicket? ticket;
  final LinkStartError? error;
  const LinkStartResult.ok(LinkTicket this.ticket) : error = null;
  const LinkStartResult.failed(LinkStartError this.error) : ticket = null;
}

/// How a call that ends a request (ack, cancel) went.
enum LinkCloseResult {
  ok,

  /// The server no longer knows it (gone, or the secret does not match).
  unknown,

  /// Cancel after the answer was collected: the device has to sign itself
  /// out instead.
  alreadyDelivered,

  /// Ack before anyone approved the request (409 `not_approved`).
  notApproved,
  network,
}

/// What `/v1/link/refresh` says about this device.
@immutable
class LinkRefreshResult {
  /// Null when there was no answer; then nothing is decided.
  final bool? active;

  /// `subscription_inactive` or `revoked` with `active: false`.
  final String? reason;
  final String? subUrl;
  final bool? manage;

  const LinkRefreshResult({this.active, this.reason, this.subUrl, this.manage});
  static const noAnswer = LinkRefreshResult();
}

String? _text(Object? raw) {
  final s = raw?.toString().trim() ?? '';
  return s.isEmpty ? null : s;
}

DateTime? _ms(Object? raw) {
  final n = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
  if (n == null || n <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(n);
}

// --- HTTP ------------------------------------------------------------------------

/// Talks to `/v1/link/*` in pairing v2. Stateless apart from the cached
/// capabilities answer.
class PairingClient {
  static String get endpoint => ProvisioningService.endpoint;

  /// How long a capabilities answer is reused; the server says the same.
  static const capabilitiesTtl = Duration(minutes: 5);

  /// How long a failed capabilities question is not asked again, so a screen
  /// that opens twice does not wait twice for a server that is not there.
  static const capabilitiesRetry = Duration(seconds: 30);

  final http.Client _client;
  final Duration timeout;
  final DateTime Function() _now;

  PairingClient({
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       _now = now ?? DateTime.now;

  static const _jsonHeaders = {'content-type': 'application/json'};

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$endpoint$path').replace(queryParameters: query);

  Future<http.Response> _post(String path, Map<String, dynamic> body) => _client
      .post(_uri(path), headers: _jsonHeaders, body: jsonEncode(body))
      .timeout(timeout);

  static Map<String, dynamic>? _json(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static PairingError _error(http.Response resp) =>
      pairingErrorOf(resp.statusCode, _json(resp.body)?['detail']) ??
      PairingError.network;

  PairingCapabilities? _caps;
  DateTime? _capsAt;
  Future<PairingCapabilities>? _capsInFlight;

  /// What the server speaks. Cached; 404, no answer or an unreadable body
  /// all read as [PairingCapabilities.unknown].
  Future<PairingCapabilities> capabilities({bool fresh = false}) {
    final held = _caps;
    final at = _capsAt;
    if (!fresh && held != null && at != null) {
      final age = _now().difference(at);
      final ttl = held.pairing == 0 ? capabilitiesRetry : capabilitiesTtl;
      if (!age.isNegative && age < ttl) return Future.value(held);
    }
    return _capsInFlight ??= _askCapabilities().whenComplete(
      () => _capsInFlight = null,
    );
  }

  Future<PairingCapabilities> _askCapabilities() async {
    PairingCapabilities caps;
    try {
      final resp = await _client
          .get(_uri('/v1/link/capabilities'))
          .timeout(timeout);
      caps = resp.statusCode == 200
          ? PairingCapabilities.fromJson(_json(resp.body))
          : PairingCapabilities.unknown;
    } catch (_) {
      caps = PairingCapabilities.unknown;
    }
    _caps = caps;
    _capsAt = _now();
    return caps;
  }

  /// Forget the cached capabilities, for a test or a changed server.
  void forgetCapabilities() {
    _caps = null;
    _capsAt = null;
  }

  // --- Approving ---------------------------------------------------------------

  Future<PairingPreviewResult> preview(
    PairingAuth auth, {
    String? linkId,
    String? code,
  }) async {
    final which = _which(linkId, code);
    if (which == null || !auth.usable) {
      return const PairingPreviewResult.failed(PairingError.unauthorized);
    }
    try {
      final resp = await _post('/v1/link/preview', {
        'v': 2,
        ...auth.body,
        ...which,
      });
      if (resp.statusCode != 200) {
        return PairingPreviewResult.failed(_error(resp));
      }
      final request = PairingRequest.fromJson(_json(resp.body));
      return request == null
          ? const PairingPreviewResult.failed(PairingError.network)
          : PairingPreviewResult.ok(request);
    } catch (_) {
      return const PairingPreviewResult.failed(PairingError.network);
    }
  }

  Future<PairingApproveResult> approve(
    PairingAuth auth, {
    required String linkId,
    required bool grantManage,
  }) async {
    if (!auth.usable || linkId.isEmpty) {
      return const PairingApproveResult.failed(PairingError.unauthorized);
    }
    try {
      final resp = await _post('/v1/link/approve', {
        'v': 2,
        ...auth.body,
        'link_id': linkId,
        'grant_manage': grantManage,
      });
      final body = _json(resp.body);
      if (resp.statusCode == 409 && body?['detail'] == 'device_limit_reached') {
        final limit = body?['device_limit'];
        return PairingApproveResult.limit(
          deviceLimit: limit is num && limit > 0 ? limit.toInt() : 5,
          devices: _rows(body?['devices']) ?? const [],
        );
      }
      if (resp.statusCode != 200) {
        return PairingApproveResult.failed(_error(resp));
      }
      final device = AccountDevice.fromJson(body?['device']);
      if (device == null) {
        return const PairingApproveResult.failed(PairingError.network);
      }
      final permissions = body?['permissions'];
      final manage = permissions is Map && permissions['manage'] == true;
      return PairingApproveResult.ok(
        device: device.copyWith(manage: manage),
        already: body?['already'] == true,
        manage: manage,
      );
    } catch (_) {
      return const PairingApproveResult.failed(PairingError.network);
    }
  }

  /// The devices on the account, or null when they could not be read. Only
  /// a token goes in the query; a number never goes in a URL.
  Future<List<AccountDevice>?> devices(String token) async {
    try {
      final resp = await _client
          .get(_uri('/v1/link/devices', {'token': token, 'v': '2'}))
          .timeout(timeout);
      if (resp.statusCode != 200) return null;
      return _rows(_json(resp.body)?['devices']);
    } catch (_) {
      return null;
    }
  }

  Future<DeviceChangeResult> revoke(
    PairingAuth auth,
    String deviceId, {
    bool confirmLastManager = false,
  }) => _change('/v1/link/revoke', auth, {
    'device_id': deviceId,
    if (confirmLastManager) 'confirm_last_manager': true,
  });

  Future<DeviceChangeResult> setManage(
    PairingAuth auth,
    String deviceId, {
    required bool manage,
    bool confirmLastManager = false,
  }) => _change('/v1/link/permissions', auth, {
    'device_id': deviceId,
    'manage': manage,
    if (confirmLastManager) 'confirm_last_manager': true,
  });

  Future<DeviceChangeResult> _change(
    String path,
    PairingAuth auth,
    Map<String, dynamic> fields,
  ) async {
    if (!auth.usable) {
      return const DeviceChangeResult.failed(PairingError.unauthorized);
    }
    try {
      final resp = await _post(path, {'v': 2, ...auth.body, ...fields});
      if (resp.statusCode != 200) {
        return DeviceChangeResult.failed(_error(resp));
      }
      return DeviceChangeResult.ok(
        AccountDevice.fromJson(_json(resp.body)?['device']),
      );
    } catch (_) {
      return const DeviceChangeResult.failed(PairingError.network);
    }
  }

  // --- Asking --------------------------------------------------------------------

  /// Opens a request for this device. [kind] is what it shows on the
  /// approving screen, never what it may do.
  Future<LinkStartResult> start({
    required String kind,
    required String name,
    String? platform,
  }) async {
    try {
      final resp = await _post('/v1/link/start', {
        'v': 2,
        'kind': kind,
        'name': name,
        'platform': ?platform,
      });
      if (resp.statusCode == 429) {
        return const LinkStartResult.failed(LinkStartError.tooManyAttempts);
      }
      if (resp.statusCode == 404 || resp.statusCode == 400) {
        return const LinkStartResult.failed(LinkStartError.unsupported);
      }
      if (resp.statusCode != 200) {
        return const LinkStartResult.failed(LinkStartError.network);
      }
      final body = _json(resp.body);
      final ticket = LinkTicket.fromStartJson(body, _now());
      // An answer without a code is the first protocol: this device would
      // have nothing to show for the code entry on the other side.
      if (ticket == null) {
        return const LinkStartResult.failed(LinkStartError.network);
      }
      if (ticket.code.isEmpty) {
        return const LinkStartResult.failed(LinkStartError.unsupported);
      }
      return LinkStartResult.ok(ticket);
    } catch (_) {
      return const LinkStartResult.failed(LinkStartError.network);
    }
  }

  /// Asks whether the request was approved. Collecting the answer does not
  /// use it up: the same answer comes back until [ack].
  Future<LinkPollResult> poll(LinkTicket ticket) async {
    try {
      final resp = await _post('/v1/link/poll', {
        'v': 2,
        'link_id': ticket.linkId,
        'poll_secret': ticket.pollSecret,
      });
      final body = _json(resp.body);
      final detail = body?['detail']?.toString();
      switch (resp.statusCode) {
        case 200:
          break;
        case 404:
          return const LinkPollResult(LinkPollStatus.unknown);
        case 410:
          return LinkPollResult(switch (detail) {
            'link_cancelled' => LinkPollStatus.cancelled,
            'device_revoked' => LinkPollStatus.revoked,
            'subscription_inactive' => LinkPollStatus.inactive,
            _ => LinkPollStatus.expired,
          });
        case 429:
          return const LinkPollResult(LinkPollStatus.tooManyAttempts);
        default:
          return const LinkPollResult(LinkPollStatus.network);
      }
      switch (body?['status']) {
        case 'pending':
          final left = body?['expires_in'];
          return LinkPollResult(
            LinkPollStatus.pending,
            expiresIn: left is num ? Duration(seconds: left.toInt()) : null,
          );
        case 'delivered':
          return const LinkPollResult(LinkPollStatus.delivered);
        case 'approved':
          final handoff = LinkHandoff.fromPollJson(body);
          return handoff == null
              ? const LinkPollResult(LinkPollStatus.network)
              : LinkPollResult(LinkPollStatus.approved, handoff: handoff);
      }
      return const LinkPollResult(LinkPollStatus.network);
    } catch (_) {
      return const LinkPollResult(LinkPollStatus.network);
    }
  }

  /// Tells the server the answer is stored here. Idempotent.
  Future<LinkCloseResult> ack(LinkTicket ticket) =>
      _close('/v1/link/ack', ticket);

  /// Withdraws the request. An approval not yet collected goes with it.
  Future<LinkCloseResult> cancel(LinkTicket ticket) =>
      _close('/v1/link/cancel', ticket);

  Future<LinkCloseResult> _close(String path, LinkTicket ticket) async {
    try {
      final resp = await _post(path, {
        'link_id': ticket.linkId,
        'poll_secret': ticket.pollSecret,
      });
      return switch ((resp.statusCode, _json(resp.body)?['detail'])) {
        (200, _) => LinkCloseResult.ok,
        (404, _) => LinkCloseResult.unknown,
        (409, 'not_approved') => LinkCloseResult.notApproved,
        (409, _) => LinkCloseResult.alreadyDelivered,
        _ => LinkCloseResult.network,
      };
    } catch (_) {
      return LinkCloseResult.network;
    }
  }

  /// This device's own standing and credentials, by its token.
  Future<LinkRefreshResult> refresh(String deviceToken) async {
    try {
      final resp = await _post('/v1/link/refresh', {
        'device_token': deviceToken,
      });
      if (resp.statusCode != 200) return LinkRefreshResult.noAnswer;
      final body = _json(resp.body);
      if (body == null) return LinkRefreshResult.noAnswer;
      final credentials = body['credentials'] is Map
          ? body['credentials'] as Map
          : const {};
      final permissions = body['permissions'] is Map
          ? body['permissions'] as Map
          : const {};
      final manage = permissions['manage'];
      return LinkRefreshResult(
        active: body['active'] == true,
        reason: _text(body['reason']),
        subUrl: _text(credentials['sub_url']),
        manage: manage is bool ? manage : null,
      );
    } catch (_) {
      return LinkRefreshResult.noAnswer;
    }
  }

  static Map<String, dynamic>? _which(String? linkId, String? code) {
    final id = linkId?.trim() ?? '';
    final typed = code == null ? '' : normalizePairingCode(code);
    if (id.isNotEmpty == typed.isNotEmpty) return null;
    return id.isNotEmpty ? {'link_id': id} : {'code': typed};
  }

  static List<AccountDevice>? _rows(Object? raw) {
    if (raw is! List) return null;
    return [
      for (final row in raw)
        if (AccountDevice.fromJson(row) case final AccountDevice d) d,
    ];
  }
}
