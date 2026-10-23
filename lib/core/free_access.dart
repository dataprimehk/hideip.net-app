/// The hideip.net free location: an anonymous key per install, asked for
/// only when someone taps the free location or Connect on it.
///
/// The wire format is `/v1/free/*` on the provisioning backend. Nothing
/// that identifies the device goes with it: no hardware id, no model, no
/// HWID header (those only ever go to third-party panels, see
/// [isHideipHost]). Android proves it is the app with a proof of work. iOS
/// proves it with App Attest: a pseudonymous key Apple makes for this
/// installation, kept only so the free key can be renewed with an assertion.
/// It is not an account or a device identifier and carries no hardware
/// data. The key that comes back is kept in [SecretPrefs] and is only ever
/// used for the free servers: it is never a subscription, never an account,
/// and never approves or manages anything.
///
/// Every failure is quiet. A server that is off, unreachable or refusing
/// hides the free row; it never puts an error where Connect is.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'device_link.dart' show subTokenOf;
import 'provisioning.dart';
import 'proxy_profile.dart';
import 'safe_http.dart';
import 'secret_prefs.dart';
import 'subscription.dart';

/// What `GET /v1/free/info` says. Off unless the server says on.
@immutable
class FreeInfo {
  final bool enabled;

  /// Speed per user in Mbit/s; 0 means no limit.
  final int speedMbps;

  /// Monthly data in GB; 0 means no limit.
  final int dataGb;

  /// Whether the free location is offered over WireGuard as well.
  final bool speedMode;

  const FreeInfo({
    required this.enabled,
    this.speedMbps = 0,
    this.dataGb = 0,
    this.speedMode = false,
  });

  static const off = FreeInfo(enabled: false);

  static FreeInfo fromJson(Object? json) {
    if (json is! Map) return off;
    int count(Object? v) => v is num && v > 0 ? v.toInt() : 0;
    return FreeInfo(
      enabled: json['enabled'] == true,
      speedMbps: count(json['speed_mbps']),
      dataGb: count(json['data_gb']),
      speedMode: json['speed_mode'] == true,
    );
  }
}

/// A challenge to answer, from `POST /v1/free/challenge`.
@immutable
class FreeChallenge {
  /// As the server sent it (base64url); sent back unchanged.
  final String challenge;
  final int powBits;
  final DateTime? expires;

  const FreeChallenge({
    required this.challenge,
    required this.powBits,
    this.expires,
  });

  static FreeChallenge? fromJson(Object? json) {
    if (json is! Map) return null;
    final challenge = json['challenge']?.toString() ?? '';
    final bits = json['pow_bits'];
    if (challenge.isEmpty || bits is! num) return null;
    final ms = json['expires_ms'];
    return FreeChallenge(
      challenge: challenge,
      powBits: bits.toInt(),
      expires: ms is num
          ? DateTime.fromMillisecondsSinceEpoch(ms.toInt())
          : null,
    );
  }

  /// The bytes the proof is computed over: the challenge decoded from
  /// base64url. Null when it does not decode.
  Uint8List? get bytes => freeChallengeBytes(challenge);
}

/// [challenge] decoded from base64url, padding optional.
Uint8List? freeChallengeBytes(String challenge) {
  final trimmed = challenge.trim();
  if (trimmed.isEmpty) return null;
  try {
    return base64Url.decode(base64Url.normalize(trimmed));
  } on FormatException {
    return null;
  }
}

/// How a register attempt ended.
enum FreeRegisterStatus {
  ok,

  /// The free location is switched off (503 `free_disabled`).
  disabled,

  /// Too many keys from this network today (429).
  rateLimited,

  /// The challenge expired, failed its signature or was used (400).
  badChallenge,

  /// The proof did not check out (400 `bad_proof`).
  badProof,

  /// This device cannot prove itself at all (no App Attest here).
  unsupported,

  /// Anything else, or no answer.
  network,
}

/// How asking for the free servers ended, as the state layer reports it.
enum FreeAccessResult {
  /// The free servers are on the device.
  ok,

  /// Premium is on (or arrived meanwhile): there is no free key to have.
  premium,

  /// The free location is switched off.
  disabled,

  /// Too many free keys from this network today.
  rateLimited,

  /// The proof was refused, or the challenge had lapsed.
  rejected,

  /// This device has no way to prove itself (no App Attest).
  unsupported,

  /// No answer, or one that decides nothing. Try again later.
  network,
}

/// What `/v1/free/register` gave this install.
@immutable
class FreeRegistration {
  final FreeRegisterStatus status;
  final String? subUrl;
  final int? speedMbps;

  const FreeRegistration(this.status, {this.subUrl, this.speedMbps});

  bool get ok => status == FreeRegisterStatus.ok && subUrl != null;
}

/// The free servers, as the free key's subscription serves them.
@immutable
class FreeProfiles {
  /// Null when nothing was decided (no answer); empty when the key is gone.
  final List<ProxyProfile>? profiles;

  /// The key is no longer valid (410, or 404): it has to be asked for again.
  final bool gone;

  /// The server does not know this key at all (404). Its App Attest key is
  /// then let go too, and the next registration attests a new one.
  final bool unknown;

  const FreeProfiles({this.profiles, this.gone = false, this.unknown = false});
}

/// Proves this install is the app, by whatever the platform has. [prove]
/// returns the fields the register body carries for it, or null when no
/// proof can be made here. [accepted] and [refused] report how the server
/// took a proof this prover made, so it keeps or forgets what that proof
/// relied on.
abstract interface class FreeProver {
  Future<Map<String, dynamic>?> prove(FreeChallenge challenge);
  Future<void> accepted(Map<String, dynamic> proof);
  Future<void> refused(Map<String, dynamic> proof);
}

/// One registration as far as it went: its answer, and the proof it was
/// made with (null when no proof was made at all).
class _Attempt {
  final FreeRegistration reg;
  final Map<String, dynamic>? proof;

  const _Attempt(this.reg, [this.proof]);
}

/// Talks to `/v1/free/*`. Keeps the cached info answer, and the registration
/// it may have to send again ([FreePending]).
class FreeService {
  static String get endpoint => ProvisioningService.endpoint;

  static const infoTtl = Duration(minutes: 5);
  static const infoRetry = Duration(seconds: 30);

  final http.Client _client;
  final SafeHttpFetcher _fetcher;
  final Duration timeout;
  final DateTime Function() _now;
  final FreeStore _store;

  FreeService({
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    DateTime Function()? now,
    FreeStore? store,
  }) : _client = client ?? http.Client(),
       _fetcher = client == null
           ? SafeHttpFetcher()
           : SafeHttpFetcher.forTesting(client),
       _now = now ?? DateTime.now,
       _store = store ?? const FreeStore();

  // Plain JSON only. No User-Agent of our own, no device header, and never
  // an HWID: these are hideip.net's own routes.
  static const _jsonHeaders = {'content-type': 'application/json'};

  Uri _uri(String path) => Uri.parse('$endpoint$path');

  static Map<String, dynamic>? _json(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  FreeInfo? _info;
  DateTime? _infoAt;
  bool _infoAnswered = false;
  Future<FreeInfo>? _infoInFlight;

  /// Whether the free location is on, cached. No answer reads as off.
  Future<FreeInfo> info({bool fresh = false}) {
    final held = _info;
    final at = _infoAt;
    if (!fresh && held != null && at != null) {
      final age = _now().difference(at);
      final ttl = _infoAnswered ? infoTtl : infoRetry;
      if (!age.isNegative && age < ttl) return Future.value(held);
    }
    return _infoInFlight ??= _askInfo().whenComplete(
      () => _infoInFlight = null,
    );
  }

  Future<FreeInfo> _askInfo() async {
    var info = FreeInfo.off;
    var answered = false;
    try {
      final resp = await _client.get(_uri('/v1/free/info')).timeout(timeout);
      if (resp.statusCode == 200) {
        info = FreeInfo.fromJson(_json(resp.body));
        answered = true;
      }
    } catch (_) {
      // Off, quietly.
    }
    _info = info;
    _infoAt = _now();
    _infoAnswered = answered;
    return info;
  }

  /// Forget the cached info, so the next read asks again.
  void forgetInfo() {
    _info = null;
    _infoAt = null;
  }

  Future<FreeChallenge?> challenge() async {
    try {
      final resp = await _client
          .post(_uri('/v1/free/challenge'), headers: _jsonHeaders)
          .timeout(timeout);
      if (resp.statusCode != 200) return null;
      return FreeChallenge.fromJson(_json(resp.body));
    } catch (_) {
      return null;
    }
  }

  /// One whole registration: a challenge, the proof, the key. A registration
  /// whose answer was lost is sent again first, exactly as it was, while it
  /// is fresh. An assertion the server refuses as bad is forgotten once, and
  /// the registration is tried again with a new attestation.
  Future<FreeRegistration> register(FreeProver prover) async {
    var attempt = await _resendPending(prover) ?? await _attempt(prover);
    final proof = attempt.proof;
    if (attempt.reg.status == FreeRegisterStatus.badProof &&
        proof != null &&
        proof.containsKey('assertion')) {
      await prover.refused(proof);
      attempt = await _attempt(prover);
    }
    return attempt.reg;
  }

  /// The registration left unanswered, sent again unchanged, or null when
  /// there is none or it is too old to matter.
  Future<_Attempt?> _resendPending(FreeProver prover) async {
    final pending = await _store.pending();
    if (pending == null) return null;
    final age = _now().difference(pending.at);
    if (age.isNegative || age >= FreePending.ttl) {
      await _store.clearPending();
      return null;
    }
    return _settle(prover, pending, await _send(pending.body));
  }

  /// A new challenge and proof, sent once. The body is kept before it goes,
  /// so a lost answer can be asked for again.
  Future<_Attempt> _attempt(FreeProver prover) async {
    final challenge = await this.challenge();
    if (challenge == null) {
      return const _Attempt(FreeRegistration(FreeRegisterStatus.network));
    }
    final Map<String, dynamic>? proof;
    try {
      proof = await prover.prove(challenge);
    } on AppAttestError catch (e) {
      return _Attempt(
        FreeRegistration(
          e.kind == AppAttestFailure.unknown
              ? FreeRegisterStatus.unsupported
              : FreeRegisterStatus.network,
        ),
      );
    } catch (_) {
      return const _Attempt(FreeRegistration(FreeRegisterStatus.unsupported));
    }
    if (proof == null) {
      return const _Attempt(FreeRegistration(FreeRegisterStatus.unsupported));
    }
    final pending = FreePending(
      at: _now(),
      body: jsonEncode({...proof, 'challenge': challenge.challenge}),
      proof: proof,
    );
    try {
      await _store.savePending(pending);
    } catch (_) {
      return const _Attempt(FreeRegistration(FreeRegisterStatus.network));
    }
    return _settle(prover, pending, await _send(pending.body));
  }

  /// What the answer to [pending] decides. Success keeps what the proof
  /// relied on; a definitive refusal (400 or 503) ends the pending record.
  /// Anything else leaves it to be sent again.
  Future<_Attempt> _settle(
    FreeProver prover,
    FreePending pending,
    ({FreeRegistration reg, bool refused}) sent,
  ) async {
    try {
      if (sent.reg.ok) {
        await _store.clearPending();
        await prover.accepted(pending.proof);
      } else if (sent.refused) {
        await _store.clearPending();
      }
    } catch (_) {
      // The caller keeps the URL it got. A key that was not saved is
      // attested again on the next registration.
    }
    return _Attempt(sent.reg, pending.proof);
  }

  /// POSTs one registration body and reads the answer.
  Future<({FreeRegistration reg, bool refused})> _send(String body) async {
    try {
      final resp = await _client
          .post(_uri('/v1/free/register'), headers: _jsonHeaders, body: body)
          .timeout(timeout);
      return (
        reg: _answer(resp),
        refused: resp.statusCode == 400 || resp.statusCode == 503,
      );
    } catch (_) {
      return (
        reg: const FreeRegistration(FreeRegisterStatus.network),
        refused: false,
      );
    }
  }

  static FreeRegistration _answer(http.Response resp) {
    final body = _json(resp.body);
    final code = (body?['error'] ?? body?['detail'])?.toString();
    switch (resp.statusCode) {
      case 200:
        final url = body?['sub_url']?.toString().trim() ?? '';
        final speed = body?['speed_mbps'];
        if (url.isEmpty || subTokenOf(url) == null) {
          return const FreeRegistration(FreeRegisterStatus.network);
        }
        return FreeRegistration(
          FreeRegisterStatus.ok,
          subUrl: url,
          speedMbps: speed is num ? speed.toInt() : null,
        );
      case 503:
        return FreeRegistration(
          code == 'free_disabled'
              ? FreeRegisterStatus.disabled
              : FreeRegisterStatus.network,
        );
      case 429:
        return const FreeRegistration(FreeRegisterStatus.rateLimited);
      case 400:
        return FreeRegistration(switch (code) {
          'bad_challenge' => FreeRegisterStatus.badChallenge,
          'bad_proof' => FreeRegisterStatus.badProof,
          _ => FreeRegisterStatus.network,
        });
      default:
        return const FreeRegistration(FreeRegisterStatus.network);
    }
  }

  /// The free servers behind [subUrl], marked as free. Sent with no header
  /// at all: it is our own host.
  Future<FreeProfiles> profiles(String subUrl) async {
    try {
      final resp = await _fetcher.get(Uri.parse(subUrl));
      if (resp.statusCode == 404) {
        return const FreeProfiles(profiles: [], gone: true, unknown: true);
      }
      if (resp.statusCode == 410) {
        return const FreeProfiles(profiles: [], gone: true);
      }
      if (resp.statusCode != 200) return const FreeProfiles();
      final parsed = await Subscription.parseAsync(resp.body);
      final profiles = [
        for (final p in parsed.profiles) p.copyWith(free: true, premium: false),
      ];
      return FreeProfiles(profiles: profiles.isEmpty ? null : profiles);
    } catch (_) {
      return const FreeProfiles();
    }
  }
}

/// A registration that may have lost its answer: the exact body that was
/// sent, and the proof inside it. It is sent again unchanged for [ttl], so
/// the server hands back the same URL instead of a second free key.
@immutable
class FreePending {
  static const ttl = Duration(minutes: 5);

  final DateTime at;
  final String body;
  final Map<String, dynamic> proof;

  const FreePending({
    required this.at,
    required this.body,
    required this.proof,
  });

  Map<String, dynamic> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'body': body,
    'proof': proof,
  };

  static FreePending? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'];
    final body = json['body'];
    final proof = json['proof'];
    if (at is! num || body is! String || proof is! Map<String, dynamic>) {
      return null;
    }
    return FreePending(
      at: DateTime.fromMillisecondsSinceEpoch(at.toInt()),
      body: body,
      proof: proof,
    );
  }
}

/// Where the free key lives on the device. Its URL carries the token, so
/// it is kept encrypted like a subscription URL, apart from the premium one.
/// The App Attest key id and the pending registration are kept the same way.
class FreeStore {
  const FreeStore();

  static const kSubUrl = 'free_subscription_url';
  static const kAttestKeyId = 'free_app_attest_key_id';
  static const kPending = 'free_register_pending';

  Future<String?> subUrl() async {
    final v = await SecretPrefs.readString(kSubUrl);
    return v == null || v.isEmpty ? null : v;
  }

  Future<void> save(String subUrl) => SecretPrefs.writeString(kSubUrl, subUrl);

  Future<void> clear() => SecretPrefs.deleteString(kSubUrl);

  /// The App Attest key this install attested and the server accepted.
  Future<String?> attestKeyId() async {
    final v = await SecretPrefs.readString(kAttestKeyId);
    return v == null || v.isEmpty ? null : v;
  }

  Future<void> saveAttestKeyId(String keyId) =>
      SecretPrefs.writeString(kAttestKeyId, keyId);

  Future<void> clearAttestKeyId() => SecretPrefs.deleteString(kAttestKeyId);

  /// The registration still waiting for its answer, or null. A record that
  /// cannot be read counts as none.
  Future<FreePending?> pending() async {
    final raw = await SecretPrefs.readString(kPending);
    if (raw == null || raw.isEmpty) return null;
    try {
      return FreePending.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> savePending(FreePending pending) =>
      SecretPrefs.writeString(kPending, jsonEncode(pending.toJson()));

  Future<void> clearPending() => SecretPrefs.deleteString(kPending);
}

// --- Proof of work (Android) ---------------------------------------------------

/// How many leading bits of [digest] are zero.
int leadingZeroBits(List<int> digest) {
  var bits = 0;
  for (final byte in digest) {
    if (byte == 0) {
      bits += 8;
      continue;
    }
    var b = byte & 0xff;
    while (b & 0x80 == 0) {
      bits++;
      b <<= 1;
    }
    return bits;
  }
  return bits;
}

/// Whether `SHA-256(challenge || ascii(nonce))` has at least [bits] leading
/// zero bits: the check the server makes.
bool powSatisfied(List<int> challenge, String nonce, int bits) {
  final sink = Sha256().toSync().newHashSink();
  sink.add(challenge);
  sink.add(ascii.encode(nonce));
  sink.close();
  return leadingZeroBits(sink.hashBytes) >= bits;
}

/// The first decimal nonce from [start] that satisfies [bits], or null after
/// [limit] tries. Synchronous: run it off the UI isolate.
String? solvePow(
  List<int> challenge,
  int bits, {
  int start = 0,
  int limit = 1 << 32,
}) {
  final sink = Sha256().toSync().newHashSink();
  final prefix = Uint8List.fromList(challenge);
  for (var i = 0; i < limit; i++) {
    final nonce = (start + i).toString();
    sink.reset();
    sink.add(prefix);
    sink.add(ascii.encode(nonce));
    sink.close();
    if (leadingZeroBits(sink.hashBytes) >= bits) return nonce;
  }
  return null;
}

/// Android's proof: a proof of work, computed on a background isolate so
/// the screen keeps moving. The same for Play, GitHub and F-Droid builds.
class PowProver implements FreeProver {
  /// Never more than this many leading bits, whatever a server asks: past
  /// it the work would run for minutes on a phone.
  static const maxBits = 28;

  /// Runs the search; replaced in tests to keep it on the test isolate.
  final Future<String?> Function(Uint8List challenge, int bits) solve;

  PowProver({Future<String?> Function(Uint8List challenge, int bits)? solve})
    : solve = solve ?? _solveInBackground;

  static Future<String?> _solveInBackground(Uint8List challenge, int bits) =>
      Isolate.run(() => solvePow(challenge, bits));

  @override
  Future<Map<String, dynamic>?> prove(FreeChallenge challenge) async {
    final bytes = challenge.bytes;
    if (bytes == null) return null;
    if (challenge.powBits < 0 || challenge.powBits > maxBits) return null;
    final nonce = await solve(bytes, challenge.powBits);
    if (nonce == null) return null;
    return {'platform': 'android', 'pow_nonce': nonce};
  }

  /// Nothing to keep: a proof of work is not reused.
  @override
  Future<void> accepted(Map<String, dynamic> proof) async {}

  /// Nothing to forget: a refused proof of work is simply not reused.
  @override
  Future<void> refused(Map<String, dynamic> proof) async {}
}

// --- App Attest (iOS) ------------------------------------------------------------

/// What went wrong on the App Attest side, by what the app does next.
enum AppAttestFailure {
  /// This device cannot attest at all.
  unsupported,

  /// Apple could not be reached. Try again with the same key.
  serverUnavailable,

  /// Apple no longer knows the key. Start over with a new one.
  invalidKey,

  /// Apple refused what was sent. Not retried.
  invalidInput,

  /// Anything else.
  unknown,
}

/// A failed App Attest call, as the channel reports it.
class AppAttestError implements Exception {
  final AppAttestFailure kind;

  const AppAttestError(this.kind);

  static AppAttestFailure kindOf(String? code) => switch (code) {
    'unsupported' => AppAttestFailure.unsupported,
    'server_unavailable' => AppAttestFailure.serverUnavailable,
    'invalid_key' => AppAttestFailure.invalidKey,
    'invalid_input' => AppAttestFailure.invalidInput,
    _ => AppAttestFailure.unknown,
  };

  @override
  String toString() => 'AppAttestError(${kind.name})';
}

/// The iOS side of App Attest, over `net.hideip.vpn/app_attest` (see
/// `ios/Runner/AppAttestChannel.swift`). Apple's DeviceCheck framework, no
/// third-party SDK. Failures of the calls below come back as [AppAttestError].
class AppAttestBridge {
  static const channel = MethodChannel('net.hideip.vpn/app_attest');

  final MethodChannel _channel;
  const AppAttestBridge([MethodChannel? channel])
    : _channel = channel ?? AppAttestBridge.channel;

  /// False on a simulator, an older iOS, or a device without the
  /// capability; also false when the platform side is missing.
  Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// A new App Attest key; its id as Apple returns it (base64).
  Future<String?> generateKey() => _call('generateKey');

  /// The attestation object for [keyId] over [clientDataHash], base64.
  Future<String?> attestKey(String keyId, Uint8List clientDataHash) =>
      _call('attestKey', {'keyId': keyId, 'clientDataHash': clientDataHash});

  /// The assertion object for [keyId] over [clientDataHash], base64.
  Future<String?> generateAssertion(String keyId, Uint8List clientDataHash) =>
      _call('generateAssertion', {
        'keyId': keyId,
        'clientDataHash': clientDataHash,
      });

  Future<String?> _call(String method, [Map<String, Object>? args]) async {
    try {
      return await _channel.invokeMethod<String>(method, args);
    } on PlatformException catch (e) {
      throw AppAttestError(AppAttestError.kindOf(e.code));
    }
  }
}

/// iOS's proof, through App Attest. The first registration attests a new
/// key over the challenge. The key id is kept only once the server has
/// accepted that attestation, and every later registration (and renewal)
/// proves the same key with an assertion. A key Apple no longer knows is
/// replaced by a new attestation.
class AppAttestProver implements FreeProver {
  /// Tries for a transient server error, with the same key each time.
  static const serverTries = 3;

  final AppAttestBridge bridge;
  final FreeStore keys;
  final Future<void> Function(Duration) _wait;

  AppAttestProver({
    AppAttestBridge? bridge,
    FreeStore? keys,
    Future<void> Function(Duration)? wait,
  }) : bridge = bridge ?? const AppAttestBridge(),
       keys = keys ?? const FreeStore(),
       _wait = wait ?? ((d) => Future<void>.delayed(d));

  @override
  Future<Map<String, dynamic>?> prove(FreeChallenge challenge) async {
    final bytes = challenge.bytes;
    if (bytes == null) return null;
    if (!await bridge.isSupported()) return null;
    final hash = Uint8List.fromList(Sha256().toSync().hashSync(bytes).bytes);

    final stored = await keys.attestKeyId();
    if (stored != null) {
      try {
        final object = await _tries(
          () => bridge.generateAssertion(stored, hash),
        );
        if (object == null || object.isEmpty) return null;
        return {
          'platform': 'ios',
          'assertion': {'key_id': stored, 'object': object},
        };
      } on AppAttestError catch (e) {
        if (e.kind != AppAttestFailure.invalidKey) rethrow;
        // Apple no longer has this key: start over with a new one.
        await keys.clearAttestKeyId();
      }
    }

    final keyId = await bridge.generateKey();
    if (keyId == null || keyId.isEmpty) return null;
    final object = await _tries(() => bridge.attestKey(keyId, hash));
    if (object == null || object.isEmpty) return null;
    return {
      'platform': 'ios',
      'attestation': {'key_id': keyId, 'object': object},
    };
  }

  /// Runs [call] again after a transient server error, one second and then
  /// two seconds later, and gives up with the last error.
  Future<T> _tries<T>(Future<T> Function() call) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await call();
      } on AppAttestError catch (e) {
        if (e.kind != AppAttestFailure.serverUnavailable ||
            attempt >= serverTries) {
          rethrow;
        }
        await _wait(Duration(seconds: 1 << (attempt - 1)));
      }
    }
  }

  @override
  Future<void> accepted(Map<String, dynamic> proof) async {
    final attestation = proof['attestation'];
    if (attestation is Map && attestation['key_id'] is String) {
      await keys.saveAttestKeyId(attestation['key_id'] as String);
    }
  }

  @override
  Future<void> refused(Map<String, dynamic> proof) async {
    // The server refused the assertion, so the key it was made with is not
    // one to renew with. The next registration attests a new one.
    if (proof.containsKey('assertion')) await keys.clearAttestKeyId();
  }
}

/// The prover for the platform this runs on: App Attest on iOS, a proof of
/// work everywhere else.
FreeProver platformFreeProver() => defaultTargetPlatform == TargetPlatform.iOS
    ? AppAttestProver()
    : PowProver();
