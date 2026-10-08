/// Device linking: this phone holds the subscription, and other clients (a
/// browser extension, a desktop app, a sideloaded phone build) get access by
/// being approved from here. No account, no email, no password anywhere; the
/// phone approves a one-time link id it read off a QR code, exactly the way a
/// messenger pairs its web client.
///
/// The wire contract is `/v1/link/*` on the provisioning backend. Every method
/// takes the subscription token this phone already holds (see [subTokenOf]),
/// which is the only thing that proves the caller is entitled to hand out
/// access.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'provisioning.dart';

/// What kind of client is being linked. The phone only ever reads this off the
/// backend, it never sends it: the client that started the link declared it.
enum LinkedDeviceKind { extension, desktop, phone, unknown }

/// One entry in the "Linked devices" list.
class LinkedDevice {
  final String id;
  final LinkedDeviceKind kind;
  final String name;

  /// When the device was linked, or null when the backend omitted it.
  final DateTime? createdAt;

  /// Last time the device asked for credentials, or null when it never has.
  final DateTime? lastSeenAt;

  /// The kind exactly as the backend sent it, so a kind [kind] does not
  /// know yet (a TV, a tablet) can still be told apart. Empty when absent.
  final String kindName;

  /// Whether the device may manage the account, or null from a backend that
  /// does not say (pairing before v2).
  final bool? manage;

  /// The backend marked this row as the device that asked for the list.
  final bool current;

  const LinkedDevice({
    required this.id,
    required this.kind,
    required this.name,
    this.createdAt,
    this.lastSeenAt,
    this.kindName = '',
    this.manage,
    this.current = false,
  });

  /// Parses one `devices[]` entry. Returns null when the row carries no id,
  /// since a device that cannot be addressed also cannot be revoked.
  static LinkedDevice? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as Object?)?.toString().trim() ?? '';
    if (id.isEmpty) return null;
    final name = (json['name'] as Object?)?.toString().trim() ?? '';
    final permissions = json['permissions'];
    final manage = permissions is Map ? permissions['manage'] : null;
    return LinkedDevice(
      id: id,
      kind: kindOf(json['kind'] as Object?),
      // An unnamed device still has to be identifiable in the list.
      name: name.isEmpty ? 'Unnamed device' : name,
      createdAt: _epochSeconds(json['created_at']),
      lastSeenAt: _epochSeconds(json['last_seen_at']),
      kindName: (json['kind'] as Object?)?.toString().trim().toLowerCase() ?? '',
      manage: manage is bool ? manage : null,
      current: json['current'] == true,
    );
  }

  /// Maps a wire `kind` onto the enum, tolerating an unknown value so a newer
  /// backend adding a device type cannot make the whole list unreadable.
  static LinkedDeviceKind kindOf(Object? raw) =>
      switch (raw?.toString().trim().toLowerCase()) {
        'extension' => LinkedDeviceKind.extension,
        'desktop' => LinkedDeviceKind.desktop,
        'phone' => LinkedDeviceKind.phone,
        _ => LinkedDeviceKind.unknown,
      };

  /// Human label for the kind, used as the row subtitle prefix. A TV stays
  /// a TV and a tablet a tablet, although [kind] has no value for either.
  String get kindLabel => switch (kindName) {
        'tv' => 'TV',
        'tablet' => 'Tablet',
        _ => _enumLabel,
      };

  String get _enumLabel => switch (kind) {
        LinkedDeviceKind.extension => 'Browser',
        LinkedDeviceKind.desktop => 'Desktop',
        LinkedDeviceKind.phone => 'Phone',
        LinkedDeviceKind.unknown => 'Device',
      };
}

/// Unix seconds (the contract's time unit) to a local [DateTime]. Tolerates a
/// numeric string and maps anything unusable to null.
DateTime? _epochSeconds(Object? raw) {
  final n = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
  if (n == null || n <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(n * 1000);
}

/// How an approval ended. The UI only distinguishes the cases it has different
/// words for; everything else lands in [LinkApproveResult.failed].
enum LinkApproveResult {
  ok,

  /// The link id is unknown or its short window already closed (404).
  expired,

  /// The subscription already has as many devices as it may have (409).
  deviceLimit,

  /// The subscription token was rejected (401): expired or revoked.
  notEntitled,

  /// Network trouble or any other server answer.
  failed,
}

/// A short code the user types into a client that has no camera.
class LinkCode {
  final String code;
  final Duration expiresIn;
  const LinkCode(this.code, this.expiresIn);
}

/// Talks to `/v1/link/*`. Stateless: every call carries the subscription token,
/// so the service holds nothing that could go stale.
class DeviceLinkService {
  /// Same host the provisioning API lives on; a linked device is just another
  /// consumer of the subscription this phone bought.
  static String get endpoint => ProvisioningService.endpoint;

  final http.Client _client;
  DeviceLinkService({http.Client? client}) : _client = client ?? http.Client();

  static const _timeout = Duration(seconds: 20);
  static const _jsonHeaders = {'content-type': 'application/json'};

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$endpoint$path').replace(queryParameters: query);

  /// Approve the link request identified by [linkId], granting the client that
  /// created it access to this subscription's servers. [deviceName] is this
  /// phone's name, which the backend records next to the linked device.
  Future<LinkApproveResult> approve({
    required String linkId,
    required String subToken,
    required String deviceName,
  }) async {
    try {
      final resp = await _client
          .post(
            _uri('/v1/link/approve'),
            headers: _jsonHeaders,
            body: jsonEncode({
              'link_id': linkId,
              'token': subToken,
              'device_name': deviceName,
            }),
          )
          .timeout(_timeout);
      return switch (resp.statusCode) {
        200 => LinkApproveResult.ok,
        401 => LinkApproveResult.notEntitled,
        404 => LinkApproveResult.expired,
        409 => LinkApproveResult.deviceLimit,
        _ => LinkApproveResult.failed,
      };
    } catch (_) {
      return LinkApproveResult.failed;
    }
  }

  /// Mint a one-time code for a client that cannot scan a QR code. Null when
  /// the backend refused or was unreachable.
  Future<LinkCode?> mintCode(String subToken) async {
    try {
      final resp = await _client
          .post(
            _uri('/v1/link/code/mint'),
            headers: _jsonHeaders,
            body: jsonEncode({'token': subToken}),
          )
          .timeout(_timeout);
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final code = (body['code'] as Object?)?.toString().trim() ?? '';
      if (code.isEmpty) return null;
      final secs = body['expires_in'] is num
          ? (body['expires_in'] as num).toInt()
          : 600;
      return LinkCode(code, Duration(seconds: secs > 0 ? secs : 600));
    } catch (_) {
      return null;
    }
  }

  /// The devices currently linked to this subscription. Null on any failure so
  /// the list can say "could not load" instead of claiming there are none.
  Future<List<LinkedDevice>?> devices(String subToken) async {
    try {
      final resp = await _client
          .get(_uri('/v1/link/devices', {'token': subToken}))
          .timeout(_timeout);
      if (resp.statusCode != 200) return null;
      return parseDevices(resp.body);
    } catch (_) {
      return null;
    }
  }

  /// Cut a device off: its credentials stop working immediately. True when the
  /// backend confirmed.
  Future<bool> revoke({
    required String subToken,
    required String deviceId,
  }) async {
    try {
      final resp = await _client
          .post(
            _uri('/v1/link/revoke'),
            headers: _jsonHeaders,
            body: jsonEncode({'token': subToken, 'device_id': deviceId}),
          )
          .timeout(_timeout);
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

/// Parses a `/v1/link/devices` body into the list, skipping rows that carry no
/// usable id. Returns null when the body is not the shape the contract
/// describes (so the caller reports a failure rather than an empty list).
List<LinkedDevice>? parseDevices(String body) {
  try {
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) return null;
    final raw = json['devices'];
    if (raw is! List) return null;
    final out = <LinkedDevice>[];
    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      final device = LinkedDevice.fromJson(item);
      if (device != null) out.add(device);
    }
    return out;
  } catch (_) {
    return null;
  }
}

/// Pulls the subscription token out of the subscription URL the provisioning
/// backend issued (`.../v1/sub/<token>`). That URL is what the app persists;
/// the `/v1/link/*` calls want the bare token. Null when the URL carries none.
String? subTokenOf(String? subscriptionUrl) {
  if (subscriptionUrl == null) return null;
  final uri = Uri.tryParse(subscriptionUrl.trim());
  if (uri == null) return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length < 2) return null;
  // Only accept the shape the backend actually issues, so a stray URL cannot
  // send some unrelated path segment to the link API as if it were a token.
  if (segments[segments.length - 2].toLowerCase() != 'sub') return null;
  final token = segments.last.trim();
  return token.isEmpty ? null : token;
}
