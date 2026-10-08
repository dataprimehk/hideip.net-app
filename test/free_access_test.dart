import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/account_service.dart';
import 'package:hideip_vpn/core/account_store.dart';
import 'package:hideip_vpn/core/catalog.dart';
import 'package:hideip_vpn/core/free_access.dart';
import 'package:hideip_vpn/core/pairing.dart';
import 'package:hideip_vpn/core/premium.dart';
import 'package:hideip_vpn/core/premium_catalog.dart';
import 'package:hideip_vpn/core/profile_store.dart';
import 'package:hideip_vpn/core/provisioning.dart';
import 'package:hideip_vpn/core/proxy_profile.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/strings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `base64url("hideip-free-test")`, no padding.
const _challenge = 'aGlkZWlwLWZyZWUtdGVzdA';
const _number = '8236387788950319';
const _premiumSub = 'https://api.test/v1/sub/dev_abc';
final _catalog = Uri.parse('https://mirror.test/catalog');

String _freeSub(int n) => '${ProvisioningService.endpoint}/v1/sub/free_tok_$n';

String _link(String name, [String host = '127.0.0.1']) =>
    'vless://22222222-2222-2222-2222-222222222222@$host:9'
    '?security=none#$name';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

/// `/v1/free/*` as CONTRACT-FREE C5 describes it, and enough of the account
/// API to buy Premium with.
class _Backend {
  final requests = <http.Request>[];
  Object? info = {
    'enabled': true,
    'speed_mbps': 10,
    'data_gb': 0,
    'speed_mode': true,
  };
  bool infoDown = false;
  int powBits = 8;
  String challenge = _challenge;
  http.Response? registerAnswer;
  int registered = 0;
  final goneTokens = <int>{};

  List<http.Request> to(String path) =>
      requests.where((r) => r.url.path == path).toList();

  Map<String, dynamic> body(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  http.Client get client => MockClient((req) async {
    requests.add(req);
    if (req.url == _catalog) return http.Response('', 503);
    final url = req.url.toString();
    for (var n = 1; n <= 5; n++) {
      if (url == _freeSub(n)) {
        if (goneTokens.contains(n)) return http.Response('', 410);
        return http.Response(
          '${_link('free-de-01', '127.0.0.$n')}\n${_link('free-fi-01', '127.0.1.$n')}',
          200,
          headers: {'x-hideip-tier': 'free'},
        );
      }
    }
    if (url == _premiumSub) {
      return http.Response(_link('de-fra-01'), 200);
    }
    switch (req.url.path) {
      case '/v1/free/info':
        if (infoDown) throw http.ClientException('down');
        return info == null ? http.Response('', 404) : _json(info!);
      case '/v1/free/challenge':
        return _json({
          'challenge': challenge,
          'pow_bits': powBits,
          'expires_ms': DateTime.now()
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch,
        });
      case '/v1/free/register':
        final answer = registerAnswer;
        if (answer != null) return answer;
        final b = body(req);
        final bytes = freeChallengeBytes(b['challenge'] as String)!;
        if (b['platform'] == 'android' &&
            !powSatisfied(bytes, b['pow_nonce'] as String, powBits)) {
          return _json({'error': 'bad_proof'}, 400);
        }
        registered++;
        return _json({
          'sub_token': 'free_tok_$registered',
          'sub_url': _freeSub(registered),
          'speed_mbps': 10,
          'wg': null,
        });
      case '/v1/account/signin':
        return _json({
          'active': true,
          'expires_ms': DateTime.now()
              .add(const Duration(days: 30))
              .millisecondsSinceEpoch,
          'subscription_url': _premiumSub,
          'device': {'id': 'dev_abc', 'kind': 'phone', 'name': 'x'},
          'device_token': 'k9Q-token',
          'device_limit': 5,
        });
      case '/v1/account/status':
        return _json({
          'active': true,
          'expires_ms': DateTime.now()
              .add(const Duration(days: 30))
              .millisecondsSinceEpoch,
          'kind': 'yearly',
          'devices': [
            {'id': 'dev_abc', 'kind': 'phone', 'name': 'x'},
          ],
          'device_limit': 5,
        });
    }
    return http.Response('', 404);
  });
}

PowProver _pow() => PowProver(solve: (c, bits) async => solvePow(c, bits));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('proof of work', () {
    final bytes = Uint8List.fromList(utf8.encode('hideip-free-test'));

    test('finds the same first nonce as an independent SHA-256', () {
      // Worked out with Python's hashlib over the same bytes.
      expect(solvePow(bytes, 8), '84');
      expect(solvePow(bytes, 12), '2339');
      expect(powSatisfied(bytes, '2339', 12), isTrue);
      expect(powSatisfied(bytes, '2338', 12), isFalse);
      expect(powSatisfied(bytes, '84', 9), isTrue);
      expect(powSatisfied(bytes, '84', 10), isFalse);
    });

    test('counts leading zero bits exactly', () {
      expect(leadingZeroBits([0x00, 0x0f, 0xff]), 12);
      expect(leadingZeroBits([0x80]), 0);
      expect(leadingZeroBits([0x01]), 7);
      expect(leadingZeroBits([0x00, 0x00]), 16);
      expect(leadingZeroBits(const []), 0);
    });

    test('the challenge is read as base64url, padded or not', () {
      expect(freeChallengeBytes(_challenge), bytes);
      expect(freeChallengeBytes('$_challenge=='), bytes);
      expect(freeChallengeBytes('not base64 !'), isNull);
      expect(freeChallengeBytes(''), isNull);
    });

    test('a work load past the ceiling is not started at all', () async {
      var solved = false;
      final prover = PowProver(
        solve: (c, b) async {
          solved = true;
          return '0';
        },
      );
      final proof = await prover.prove(
        const FreeChallenge(challenge: _challenge, powBits: 29),
      );
      expect(proof, isNull);
      expect(solved, isFalse);
    });

    test('on a background isolate it reaches the same answer', () async {
      final proof = await PowProver().prove(
        const FreeChallenge(challenge: _challenge, powBits: 8),
      );
      expect(proof, {'platform': 'android', 'pow_nonce': '84'});
    });
  });

  group('the service', () {
    late _Backend backend;
    setUp(() => backend = _Backend());

    test('info is kept for five minutes, a failure for less', () async {
      var now = DateTime(2026, 10, 8, 12);
      final free = FreeService(client: backend.client, now: () => now);
      expect((await free.info()).enabled, isTrue);
      now = now.add(const Duration(minutes: 4));
      await free.info();
      expect(backend.to('/v1/free/info'), hasLength(1));

      backend.infoDown = true;
      now = now.add(const Duration(minutes: 2));
      expect((await free.info()).enabled, isFalse);
      now = now.add(const Duration(seconds: 20));
      await free.info();
      expect(backend.to('/v1/free/info'), hasLength(2));
      now = now.add(const Duration(seconds: 15));
      await free.info();
      expect(backend.to('/v1/free/info'), hasLength(3));
    });

    test('404 or an unreadable body is off', () async {
      backend.info = null;
      expect(
        (await FreeService(client: backend.client).info()).enabled,
        isFalse,
      );
      backend.info = 'nope';
      expect(
        (await FreeService(client: backend.client).info()).enabled,
        isFalse,
      );
    });

    test('every refusal the contract names maps to its own value', () async {
      final cases = {
        _json({'error': 'free_disabled'}, 503): FreeRegisterStatus.disabled,
        _json({'error': 'rate_limited'}, 429): FreeRegisterStatus.rateLimited,
        _json({'error': 'bad_challenge'}, 400): FreeRegisterStatus.badChallenge,
        _json({'error': 'bad_proof'}, 400): FreeRegisterStatus.badProof,
        _json({'error': 'bad_request'}, 400): FreeRegisterStatus.network,
        http.Response('', 500): FreeRegisterStatus.network,
        _json({'sub_url': 'https://x.test/nothing'}):
            FreeRegisterStatus.network,
      };
      for (final e in cases.entries) {
        backend.registerAnswer = e.key;
        final r = await FreeService(client: backend.client).register(_pow());
        expect(r.status, e.value, reason: e.key.body);
        expect(r.ok, isFalse);
      }
    });

    test('nothing that names the device goes to the free routes', () async {
      final free = FreeService(client: backend.client);
      await free.info();
      final reg = await free.register(_pow());
      await free.profiles(reg.subUrl!);
      for (final r in backend.requests) {
        final names = r.headers.keys.map((k) => k.toLowerCase()).toSet();
        expect(
          names.intersection({
            'x-hwid',
            'x-device-os',
            'x-ver-os',
            'x-device-model',
            'user-agent',
          }),
          isEmpty,
          reason: r.url.path,
        );
      }
      final sent = backend.body(backend.to('/v1/free/register').single);
      expect(sent.keys.toSet(), {'platform', 'pow_nonce', 'challenge'});
      expect(sent['challenge'], _challenge);
    });

    test('the free subscription is marked free, never premium', () async {
      final got = await FreeService(
        client: backend.client,
      ).profiles(_freeSub(1));
      expect(got.profiles, hasLength(2));
      expect(got.profiles!.every((p) => p.free && !p.premium), isTrue);
      backend.goneTokens.add(1);
      final gone = await FreeService(
        client: backend.client,
      ).profiles(_freeSub(1));
      expect(gone.gone, isTrue);
    });
  });

  group('App Attest', () {
    late _Backend backend;
    final calls = <MethodCall>[];
    var supported = true;

    setUp(() {
      backend = _Backend();
      calls.clear();
      supported = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppAttestBridge.channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'isSupported' => supported,
              'generateKey' => 'a2V5LWlk',
              'attestKey' => 'b2JqZWN0',
              _ => null,
            };
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppAttestBridge.channel, null);
    });

    test('a fresh key is attested over the hash of the challenge', () async {
      final reg = await FreeService(
        client: backend.client,
      ).register(const AppAttestProver());
      expect(reg.ok, isTrue);
      final attest = calls.singleWhere((c) => c.method == 'attestKey');
      final args = attest.arguments as Map;
      expect(args['keyId'], 'a2V5LWlk');
      final hash = await Sha256().hash(utf8.encode('hideip-free-test'));
      expect(args['clientDataHash'], hash.bytes);
      expect(
        hex(hash.bytes),
        'a55e9ac656c73d20b139c841b2f89b633ecf2489d7d1425e11756f038a88bc35',
      );
      final sent = backend.body(backend.to('/v1/free/register').single);
      expect(sent, {
        'platform': 'ios',
        'attestation': {'key_id': 'a2V5LWlk', 'object': 'b2JqZWN0'},
        'challenge': _challenge,
      });
    });

    test('a device without App Attest does not ask at all', () async {
      supported = false;
      final reg = await FreeService(
        client: backend.client,
      ).register(const AppAttestProver());
      expect(reg.status, FreeRegisterStatus.unsupported);
      expect(backend.to('/v1/free/register'), isEmpty);
      expect(calls.where((c) => c.method == 'generateKey'), isEmpty);
    });

    test('a platform error reads as unsupported, not a crash', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppAttestBridge.channel, (call) async {
            if (call.method == 'isSupported') return true;
            throw PlatformException(code: 'generate_failed');
          });
      final reg = await FreeService(
        client: backend.client,
      ).register(const AppAttestProver());
      expect(reg.status, FreeRegisterStatus.unsupported);
    });
  });

  group('the app', () {
    late _Backend backend;
    late AppState state;

    AppState fresh() => AppState(
      accounts: AccountService(client: backend.client),
      provisioning: ProvisioningService(
        client: backend.client,
        catalogSources: [_catalog],
      ),
      pairing: PairingClient(client: backend.client),
      free: FreeService(client: backend.client),
      freeProver: _pow(),
      linkPollInterval: null,
      tablet: false,
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await PremiumSub.clear();
      await const AccountStore().clear();
      await const FreeStore().clear();
      backend = _Backend();
      state = fresh();
    });

    test('knowing it is on asks for nothing else', () async {
      await state.refreshFreeInfo();
      expect(state.freeOffered, isTrue);
      expect(state.freeInfo.speedMbps, 10);
      expect(state.freeHeld, isFalse);
      expect(backend.requests.map((r) => r.url.path), ['/v1/free/info']);
    });

    test(
      'the key is asked for on the tap, and gives nothing but servers',
      () async {
        await state.refreshFreeInfo();
        expect(await state.ensureFreeAccess(), FreeAccessResult.ok);

        expect(backend.to('/v1/free/challenge'), hasLength(1));
        expect(backend.to('/v1/free/register'), hasLength(1));
        expect(state.freeHeld, isTrue);
        final free = state.profiles.where((p) => p.free).toList();
        expect(free, hasLength(2));
        expect(free.every((p) => !p.premium), isTrue);
        expect(await const FreeStore().subUrl(), _freeSub(1));

        // No account, no link rights, no premium, no subscription token.
        expect(state.premium.isOn, isFalse);
        expect(state.subToken, isNull);
        expect(state.canLinkDevices, isFalse);
        expect(state.pairingAuth, isNull);
        expect(state.accountSignedIn, isFalse);
        expect(await PremiumSub.url(), isNull);
        expect(
          backend.requests.where(
            (r) =>
                r.url.path.startsWith('/v1/link') ||
                r.url.path.startsWith('/v1/account'),
          ),
          isEmpty,
        );
        // The servers survive a restart, still marked free.
        final kept = await ProfileStore.load();
        expect(kept.where((p) => p.free), hasLength(2));

        // A second tap uses what is held.
        expect(await state.ensureFreeAccess(), FreeAccessResult.ok);
        expect(backend.to('/v1/free/register'), hasLength(1));
      },
    );

    test('switched off: no row and no key', () async {
      backend.info = {'enabled': false};
      await state.refreshFreeInfo();
      expect(state.freeOffered, isFalse);
      expect(state.freeLocations, isEmpty);
      expect(await state.ensureFreeAccess(), FreeAccessResult.disabled);
      expect(backend.to('/v1/free/challenge'), isEmpty);
    });

    test('switched off between the info and the tap', () async {
      await state.refreshFreeInfo();
      backend.registerAnswer = _json({'error': 'free_disabled'}, 503);
      expect(await state.ensureFreeAccess(), FreeAccessResult.disabled);
      expect(state.freeOffered, isFalse);
      expect(state.freeHeld, isFalse);
    });

    test('a network that is down hides the row and breaks nothing', () async {
      await state.addLink(_link('my-own'));
      backend.infoDown = true;
      await state.refreshFreeInfo();
      expect(state.freeOffered, isFalse);
      expect(state.locations, hasLength(1));

      expect(await state.connectFree(), isFalse);
      expect(state.toast, S.toastFreeUnavailable);
      expect(state.conn, ConnState.disconnected);
      expect(state.error, isNull);
      expect(state.profiles, hasLength(1));
      expect(state.selected!.name, 'my-own');
    });

    test('a refused proof keeps nothing', () async {
      await state.refreshFreeInfo();
      backend.registerAnswer = _json({'error': 'bad_proof'}, 400);
      expect(await state.ensureFreeAccess(), FreeAccessResult.rejected);
      expect(await const FreeStore().subUrl(), isNull);
      expect(state.freeHeld, isFalse);
      expect(state.freeBusy, isFalse);
    });

    test('too many keys from one network says so', () async {
      await state.refreshFreeInfo();
      backend.registerAnswer = _json({'error': 'rate_limited'}, 429);
      expect(await state.connectFree(), isFalse);
      expect(state.toast, S.toastFreeBusy);
    });

    test('a key the server forgot is asked for again, once per run', () async {
      await state.refreshFreeInfo();
      await state.ensureFreeAccess();
      backend.goneTokens.add(1);

      await state.startFreeForTesting();
      expect(backend.to('/v1/free/register'), hasLength(2));
      expect(await const FreeStore().subUrl(), _freeSub(2));
      expect(state.profiles.where((p) => p.free), hasLength(2));
      expect(state.profiles.where((p) => p.free).first.server, '127.0.0.2');

      backend.goneTokens.add(2);
      await state.startFreeForTesting();
      expect(backend.to('/v1/free/register'), hasLength(2));
      expect(await const FreeStore().subUrl(), isNull);
      expect(state.freeHeld, isFalse);

      // A tap still asks, as it always may.
      expect(await state.ensureFreeAccess(), FreeAccessResult.ok);
      expect(backend.to('/v1/free/register'), hasLength(3));
    });

    test('Premium takes the free key and its servers away', () async {
      await state.refreshFreeInfo();
      await state.ensureFreeAccess();
      expect(state.freeHeld, isTrue);

      await state.signInWithAccountNumber(_number);
      await pumpEventQueue();

      expect(state.premium.isOn, isTrue);
      expect(state.freeHeld, isFalse);
      expect(state.freeOffered, isFalse);
      expect(await const FreeStore().subUrl(), isNull);
      expect(state.profiles.where((p) => p.premium), hasLength(1));
      expect((await ProfileStore.load()).where((p) => p.free), isEmpty);

      final before = backend.requests.length;
      expect(await state.ensureFreeAccess(), FreeAccessResult.premium);
      expect(backend.requests.length, before);
    });

    test('a store purchase ends the free key at once', () async {
      await state.refreshFreeInfo();
      await state.ensureFreeAccess();
      expect(state.freeHeld, isTrue);

      await state.storeAnswerForTesting(
        Premium(
          status: PremiumStatus.active,
          plan: PremiumPlan.yearly,
          renews: DateTime.now().add(const Duration(days: 365)),
        ),
        const PurchasePayload.android(
          purchaseToken: 'play-token',
          productId: PremiumProducts.yearly,
        ),
      );
      await pumpEventQueue();
      expect(state.premium.isOn, isTrue);
      expect(state.freeHeld, isFalse);
      expect(await const FreeStore().subUrl(), isNull);
    });

    test('a launch with Premium on drops a free key left behind', () async {
      await state.refreshFreeInfo();
      await state.ensureFreeAccess();
      await state.signInWithAccountNumber(_number);
      await pumpEventQueue();
      await const FreeStore().save(_freeSub(1));

      final again = fresh();
      await again.loadPremiumForTesting();
      await again.startFreeForTesting();
      expect(await const FreeStore().subUrl(), isNull);
      expect(backend.to('/v1/free/info'), hasLength(1));
    });

    test('free servers are not edited like the user own ones', () async {
      await state.refreshFreeInfo();
      await state.ensureFreeAccess();
      final i = state.profiles.indexWhere((p) => p.free);
      final before = state.profiles[i];
      await state.setServerLocation(i, cc: 'JP');
      await state.replaceProfile(
        i,
        before.copyWith(name: 'changed', free: false),
      );
      expect(state.profiles[i].ccOverride, isNull);
      expect(state.profiles[i].name, before.name);
      expect(state.profiles[i].free, isTrue);
    });
  });

  group('the catalog', () {
    Future<CatalogDocument> signed(List<Map<String, dynamic>> servers) async {
      final payload = {
        'epoch': 9,
        'generated_at': '2026-10-08T10:00:00Z',
        'servers': servers,
      };
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPairFromSeed(
        List<int>.generate(32, (i) => i),
      );
      final signature = await algorithm.sign(
        utf8.encode(canonicalCatalogJson(payload)),
        keyPair: keyPair,
      );
      final body = jsonEncode({
        ...payload,
        'signature': base64Encode(signature.bytes),
      });
      return (await decodeVerifiedCatalog(body, catalogVerificationPublicKey))!;
    }

    Map<String, dynamic> server(String id, String host, {String? tier}) => {
      'id': id,
      'label': id,
      'host': host,
      'sort_weight': 10,
      'audience': 'all',
      'tier': ?tier,
      'endpoints': [
        {
          'protocol': 'vless-reality',
          'port': 443,
          'public_key': 'PK',
          'short_id': 'ab',
          'sni': 'x.test.invalid',
          'flow': '',
        },
      ],
    };

    test('a free server is never a premium profile or a locked row', () async {
      final doc = await signed([
        server('Frankfurt', '203.0.113.1'),
        server('Helsinki Free', '203.0.113.2', tier: 'free'),
        server('Tokyo', '203.0.113.3', tier: 'premium'),
      ]);
      expect(doc.servers.map((s) => s.tier), ['premium', 'free', 'premium']);

      final premium = profilesFromCatalog(
        doc,
        const CatalogIdentity(uuid: 'u', subToken: 't'),
      );
      expect(premium.map((p) => p.server), ['203.0.113.1', '203.0.113.3']);

      final locked = PremiumCatalog.lockedLocationsFrom(doc);
      expect(locked.map((l) => l.profile.server), [
        '203.0.113.1',
        '203.0.113.3',
      ]);
      expect(locked.every((l) => l.locked), isTrue);

      final free = PremiumCatalog.freeLocationsFrom(doc);
      expect(free.single.profile.server, '203.0.113.2');
      expect(free.single.locked, isFalse);
      expect(free.single.profile.free, isTrue);
      expect(free.single.profile.premium, isFalse);
      expect(free.single.profile.outbound, isEmpty);
    });

    test('a catalog from before tiers is all premium', () async {
      final doc = await signed([server('Frankfurt', '203.0.113.1')]);
      expect(doc.servers.single.free, isFalse);
      expect(PremiumCatalog.freeLocationsFrom(doc), isEmpty);
    });
  });

  test('the free mark survives the profile store', () async {
    SharedPreferences.setMockInitialValues({});
    await ProfileStore.save([
      const ProxyProfile(
        name: 'f',
        protocol: 'vless',
        server: '127.0.0.1',
        port: 9,
        outbound: {'type': 'vless'},
        free: true,
      ),
      const ProxyProfile(
        name: 'o',
        protocol: 'vless',
        server: '127.0.0.2',
        port: 9,
        outbound: {'type': 'vless'},
      ),
    ]);
    final back = await ProfileStore.load();
    expect(back.map((p) => p.free), [true, false]);
  });
}

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
