import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/account_service.dart';
import 'package:hideip_vpn/core/account_store.dart';
import 'package:hideip_vpn/core/premium.dart';
import 'package:hideip_vpn/core/provisioning.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _number = '8236387788950319';
const _fresh = '5997190828766207';
const _subUrl = 'https://api.test/v1/sub/dev_abc';
const _storeUrl = 'https://api.test/v1/sub/store_tok';
const _proof = PurchasePayload.android(
  purchaseToken: 'play-token',
  productId: PremiumProducts.yearly,
);
final _catalog = Uri.parse('https://mirror.test/catalog');

String _link(String name) =>
    'vless://11111111-1111-1111-1111-111111111111@127.0.0.1:9'
    '?security=none#$name';

/// The account API as the backend documents it, with the answers a test
/// can change and every request kept for asserting on.
class _Backend {
  final requests = <http.Request>[];
  bool active = true;
  int statusCode = 200;
  int signinCode = 200;
  Completer<void>? signinEntered;
  Completer<void>? signinRelease;
  DateTime expires = DateTime.now().add(const Duration(days: 30));
  List<String> devices = ['dev_abc'];
  bool? storeLinked;

  Map<String, dynamic> body(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  List<http.Request> to(String path) =>
      requests.where((r) => r.url.path == path).toList();

  http.Client get client => MockClient((req) async {
    requests.add(req);
    final ms = expires.millisecondsSinceEpoch;
    switch (req.url.path) {
      case '/v1/account/signin':
        signinEntered?.complete();
        await signinRelease?.future;
        if (signinCode != 200) return http.Response('', signinCode);
        if (statusCode != 200) {
          return http.Response(jsonEncode({'detail': 'x'}), statusCode);
        }
        return http.Response(
          jsonEncode(
            active
                ? {
                    'active': true,
                    'expires_ms': ms,
                    'subscription_url': _subUrl,
                    'device': {
                      'id': 'dev_abc',
                      'kind': 'phone',
                      'name': 'Android phone',
                    },
                    'device_token': 'k9Q-token',
                    'device_limit': 5,
                  }
                : {
                    'active': false,
                    'expires_ms': ms,
                    'subscription_url': null,
                    'device': null,
                    'device_token': null,
                    'device_limit': 5,
                  },
          ),
          200,
        );
      case '/v1/account/status':
        if (statusCode != 200) {
          return http.Response(jsonEncode({'detail': 'x'}), statusCode);
        }
        return http.Response(
          jsonEncode({
            'active': active,
            'expires_ms': ms,
            'kind': 'yearly',
            'devices': [
              for (final id in devices) {'id': id, 'kind': 'phone', 'name': id},
            ],
            'device_limit': 5,
            'store_linked': ?storeLinked,
          }),
          200,
        );
      case '/v1/account/revoke':
        return http.Response(jsonEncode({'ok': true, 'revoked': 1}), 200);
      case '/v1/account/rotate':
        return http.Response(
          jsonEncode({'account_number': _fresh, 'expires_ms': ms}),
          200,
        );
      case '/v1/account/delete':
        return http.Response(jsonEncode({'deleted': true}), 200);
    }
    return http.Response('', 404);
  });
}

/// Premium profiles served at the account's subscription URL, and a store
/// purchase that provisions its own; the signed catalog mirror is down, so
/// the legacy path answers. [_provisionAccount] is the `account` block a
/// backend that puts purchases on account numbers adds; null is one that
/// does not.
final _provisions = <http.Request>[];
Map<String, dynamic>? _provisionAccount;
ProvisioningService _provisioning() => ProvisioningService(
  client: MockClient((req) async {
    if (req.url == _catalog) return http.Response('', 503);
    if (req.url.path == '/v1/provision') {
      _provisions.add(req);
      return http.Response(
        jsonEncode({
          'subscription_url': _storeUrl,
          'account': ?_provisionAccount,
        }),
        200,
      );
    }
    if (req.url.toString() == _subUrl) {
      return http.Response('${_link('de-fra-01')}\n${_link('ch-zur-02')}', 200);
    }
    if (req.url.toString() == _storeUrl) {
      return http.Response(_link('store-ams-01'), 200);
    }
    return http.Response('', 404);
  }),
  catalogSources: [_catalog],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Backend backend;
  late AppState state;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _provisions.clear();
    _provisionAccount = null;
    await PremiumSub.clear();
    await const AccountStore().clear();
    backend = _Backend();
    state = AppState(
      accounts: AccountService(client: backend.client),
      provisioning: _provisioning(),
    );
  });

  test('signing in puts the account in force, like a purchase', () async {
    final r = await state.signInWithAccountNumber('8236 3877 8895 0319');
    await pumpEventQueue();

    expect(r.result, AccountResult.ok);
    expect(state.premium.source, PremiumSource.account);
    expect(state.premium.isOn, isTrue);
    expect(await PremiumSub.url(), _subUrl);
    expect(state.profiles.where((p) => p.premium), hasLength(2));
    expect(state.accountSignedIn, isTrue);
    expect(state.accountNumber, _number);
    // The kind arrives with the status call that follows the sign-in.
    expect(state.premium.plan, PremiumPlan.yearly);

    final stored = await const AccountStore().load();
    expect(stored!.number, _number);
    expect(stored.deviceToken, 'k9Q-token');
    expect(stored.deviceId, 'dev_abc');

    // It survives a restart.
    final loaded = await Premium.load();
    expect(loaded.source, PremiumSource.account);
    expect(loaded.isOn, isTrue);
  });

  test('the link API gets this device token, not the URL token', () async {
    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();

    expect(state.subToken, 'k9Q-token');
    expect(state.canLinkDevices, isTrue);
  });

  test('an account out of time keeps the number and says expired', () async {
    backend.active = false;
    backend.expires = DateTime.now().subtract(const Duration(days: 3));

    final r = await state.signInWithAccountNumber(_number);

    expect(r.result, AccountResult.inactive);
    expect(state.accountSignedIn, isTrue);
    expect((await const AccountStore().load())!.number, _number);
    expect(state.premium.status, PremiumStatus.expired);
    expect(state.premium.source, PremiumSource.account);
    expect(state.premium.isOn, isFalse);
    expect(state.profiles.where((p) => p.premium), isEmpty);
    expect(state.canLinkDevices, isFalse);
  });

  test('a refused number changes nothing on the device', () async {
    backend.statusCode = 404;

    final r = await state.signInWithAccountNumber(_number);

    expect(r.result, AccountResult.unknown);
    expect(state.accountSignedIn, isFalse);
    expect(state.premium.status, PremiumStatus.none);
    expect(await const AccountStore().load(), isNull);
  });

  test('signing out clears everything and takes the device off', () async {
    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();

    await state.signOutAccount();
    await pumpEventQueue();

    expect(state.accountSignedIn, isFalse);
    expect(state.accountNumber, isNull);
    expect(await const AccountStore().load(), isNull);
    expect(state.premium.isOn, isFalse);
    expect(state.premium.status, PremiumStatus.none);
    expect(await PremiumSub.url(), isNull);
    expect(state.profiles.where((p) => p.premium), isEmpty);
    expect(state.subToken, isNull);
    final revoke = backend.to('/v1/account/revoke');
    expect(revoke, hasLength(1));
    expect(backend.body(revoke.single), {
      'account_number': _number,
      'device_id': 'dev_abc',
    });
  });

  test('signing in again reuses this device instead of a new slot', () async {
    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();
    await state.signInWithAccountNumber(_number);

    final signins = backend.to('/v1/account/signin');
    expect(backend.body(signins.first)['device_token'], isNull);
    expect(backend.body(signins.last)['device_token'], 'k9Q-token');
  });

  test(
    'a device removed from elsewhere loses its servers, not the number',
    () async {
      await state.signInWithAccountNumber(_number);
      await pumpEventQueue();

      backend.devices = ['dev_other'];
      await state.refreshAccount(force: true);

      // The number stays, so signing back in is one tap.
      expect(state.accountSignedIn, isTrue);
      expect(state.accountNumber, _number);
      expect(state.accountDeviceSignedOut, isTrue);
      final stored = await const AccountStore().load();
      expect(stored!.number, _number);
      expect(stored.deviceToken, isNull);
      expect(stored.deviceId, isNull);
      // What the device held on the account is gone.
      expect(state.premium.isOn, isFalse);
      expect(state.profiles.where((p) => p.premium), isEmpty);
      expect(state.subToken, isNull);
      // No new sign-in quietly puts it back.
      expect(backend.to('/v1/account/signin'), hasLength(1));

      // Signing in again takes a fresh slot, on purpose.
      backend.devices = ['dev_abc'];
      await state.signInWithAccountNumber(_number);
      await pumpEventQueue();
      expect(state.accountDeviceSignedOut, isFalse);
      expect(state.premium.isOn, isTrue);
      expect(
        backend.body(backend.to('/v1/account/signin').last)['device_token'],
        isNull,
      );
    },
  );

  test('only signing out forgets the number', () async {
    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();
    backend.devices = ['dev_other'];
    await state.refreshAccount(force: true);
    expect(state.accountNumber, _number);

    await state.signOutAccount();
    expect(state.accountNumber, isNull);
    expect(await const AccountStore().load(), isNull);
  });

  test('a revoked account loses its servers but keeps the number', () async {
    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();

    backend.statusCode = 403;
    await state.refreshAccount(force: true);

    expect(state.accountIssue, AccountIssue.revoked);
    expect(state.accountSignedIn, isTrue);
    expect(state.premium.isOn, isFalse);
    expect(state.profiles.where((p) => p.premium), isEmpty);
  });

  test('a store subscription that lasts longer stays in force', () async {
    final storeEnds = DateTime.now().add(const Duration(days: 300));
    state.storeEntitlementForTesting(
      Premium(
        status: PremiumStatus.active,
        plan: PremiumPlan.yearly,
        renews: storeEnds,
      ),
    );

    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();

    expect(state.accountSignedIn, isTrue);
    expect(state.premium.source, PremiumSource.store);
    expect(state.premium.renews, storeEnds);
    expect(await PremiumSub.url(), isNull);
  });

  test('the server decides when an account ends, not the date', () async {
    // A date already behind the device clock, while the server says active:
    // time was added somewhere this device has not heard about yet, or the
    // clock is wrong. Either way the account stays on.
    backend.expires = DateTime.now().subtract(const Duration(days: 1));
    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();

    expect(state.premium.isOn, isTrue);
    expect(state.premium.source, PremiumSource.account);
    expect(state.profiles.where((p) => p.premium), hasLength(2));

    backend.active = false;
    await state.refreshAccount(force: true);
    expect(state.premium.isOn, isFalse);
    expect(state.premium.status, PremiumStatus.expired);
    expect(state.accountNumber, _number);
  });

  test('a number replaced elsewhere leaves this device running', () async {
    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();

    backend.statusCode = 404;
    await state.refreshAccount(force: true);

    expect(state.accountIssue, AccountIssue.numberReplaced);
    expect(state.premium.isOn, isTrue);
    expect(await PremiumSub.url(), _subUrl);
    expect(state.profiles.where((p) => p.premium), hasLength(2));
    expect(state.accountNumber, _number);
  });

  test('the background check runs at most once in six hours', () async {
    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();
    final after = backend.to('/v1/account/status').length;

    expect(await state.refreshAccount(), isNull);
    expect(backend.to('/v1/account/status'), hasLength(after));

    // The account screen always asks.
    expect(await state.refreshAccount(force: true), isNotNull);
    expect(backend.to('/v1/account/status'), hasLength(after + 1));
  });

  test('too many attempts is its own answer', () async {
    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();

    backend.statusCode = 429;
    final status = await state.refreshAccount(force: true);
    expect(status!.result, AccountResult.tooManyAttempts);
    expect(state.premium.isOn, isTrue);
  });

  test('a lost rotation answer with the old number gone says so', () async {
    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();

    // The rotate answer is lost on the way; the old number is then unknown
    // to the server.
    final lost = AppState(
      accounts: AccountService(
        client: MockClient((req) async {
          if (req.url.path == '/v1/account/rotate') {
            throw http.ClientException('connection reset');
          }
          if (req.url.path == '/v1/account/status') {
            return http.Response(
              jsonEncode({'detail': 'unknown_account'}),
              404,
            );
          }
          return http.Response('', 500);
        }),
      ),
      provisioning: _provisioning(),
    );
    // The same stored account, read the way a launch reads it.
    await lost.loadAccountForTesting();

    final r = await lost.rotateAccountNumber();
    expect(r.maybeIssued, isTrue);
    expect(lost.accountIssue, AccountIssue.numberReplaced);
  });

  group('a store subscription next to an account number', () {
    for (final renewalDays in [90, 400]) {
      test(
        'a renewal queued during account takeover selects the longer source (days=$renewalDays)',
        () async {
          final now = DateTime.now();
          await state.storeEntitlementForTesting(
            Premium(
              status: PremiumStatus.active,
              renews: now.add(const Duration(days: 60)),
            ),
            _proof,
          );
          await pumpEventQueue();
          await state.signInWithAccountNumber(_number);
          await pumpEventQueue();
          backend.expires = now.add(const Duration(days: 365));
          backend.signinEntered = Completer<void>();
          backend.signinRelease = Completer<void>();
          final takeover = state.refreshAccount(force: true);
          await backend.signinEntered!.future;
          final renewal = state.storeEntitlementForTesting(
            Premium(
              status: PremiumStatus.active,
              renews: now.add(Duration(days: renewalDays)),
            ),
            _proof,
          );
          backend.signinRelease!.complete();
          await takeover;
          await renewal;
          final accountWins = renewalDays < 365;
          expect(
            state.premium.source,
            accountWins ? PremiumSource.account : PremiumSource.store,
          );
          expect(await PremiumSub.url(), accountWins ? _subUrl : _storeUrl);
          expect(
            state.profiles.where((p) => p.premium),
            hasLength(accountWins ? 2 : 1),
          );
          expect(
            _provisions,
            hasLength(accountWins ? 1 : 2),
            reason: 'only the winning store renewal provisions',
          );
          await state.refreshAccount(force: true);
          expect(await PremiumSub.url(), accountWins ? _subUrl : _storeUrl);
        },
      );
    }

    for (final priorProof in [false, true]) {
      test(
        'a store arrival during signout is provisioned with its own proof (prior=$priorProof)',
        () async {
          backend.expires = DateTime.now().add(const Duration(days: 300));
          await state.signInWithAccountNumber(_number);
          await pumpEventQueue();
          if (priorProof) {
            await state.storeEntitlementForTesting(
              Premium(
                status: PremiumStatus.active,
                renews: DateTime.now().add(const Duration(days: 10)),
              ),
              _proof,
            );
            await pumpEventQueue();
          }
          const renewal = PurchasePayload.android(
            purchaseToken: 'arriving-token',
            productId: PremiumProducts.yearly,
          );
          final signingOut = state.signOutAccount();
          final arrival = state.storeEntitlementForTesting(
            Premium(
              status: PremiumStatus.active,
              renews: DateTime.now().add(const Duration(days: 30)),
            ),
            renewal,
          );
          await signingOut;
          await arrival;
          expect(state.premium.source, PremiumSource.store);
          expect(state.premium.isOn, isTrue);
          expect(await PremiumSub.url(), _storeUrl);
          expect((await PremiumSub.proof())?.toJson(), renewal.toJson());
          expect(_provisions, isNotEmpty);
          expect(
            jsonDecode(_provisions.last.body)['purchase_token'],
            'arriving-token',
          );
        },
      );
    }

    test(
      'retains fresh store proofs without replacing a longer account',
      () async {
        backend.expires = DateTime.now().add(const Duration(days: 300));
        await state.signInWithAccountNumber(_number);
        await pumpEventQueue();
        final ends = DateTime.now().add(const Duration(days: 30));
        state.storeEntitlementForTesting(
          Premium(status: PremiumStatus.active, renews: ends),
          _proof,
        );
        await pumpEventQueue();
        expect((await PremiumSub.proof())?.toJson(), _proof.toJson());
        const renewal = PurchasePayload.android(
          purchaseToken: 'renewal-token',
          productId: PremiumProducts.yearly,
        );
        state.storeEntitlementForTesting(
          Premium(
            status: PremiumStatus.active,
            renews: ends.add(const Duration(days: 30)),
          ),
          renewal,
        );
        // An older replay must not replace the newer purchase proof.
        state.storeEntitlementForTesting(
          Premium(status: PremiumStatus.active, renews: ends),
          _proof,
        );
        await pumpEventQueue();
        expect((await PremiumSub.proof())?.toJson(), renewal.toJson());
        expect(state.premium.source, PremiumSource.account);
        expect(await PremiumSub.url(), _subUrl);
        expect(_provisions, isEmpty);
        await state.signOutAccount();
        expect(state.premium.source, PremiumSource.store);
        expect(await PremiumSub.url(), _storeUrl);
        expect(
          jsonDecode(_provisions.single.body)['purchase_token'],
          'renewal-token',
        );
      },
    );

    test(
      'failed account takeover keeps store source and retries signin',
      () async {
        final ends = DateTime.now().add(const Duration(days: 60));
        state.storeEntitlementForTesting(
          Premium(status: PremiumStatus.active, renews: ends),
          _proof,
        );
        await pumpEventQueue();
        await state.signInWithAccountNumber(_number);
        await pumpEventQueue();
        expect(state.premium.source, PremiumSource.store);
        expect(await PremiumSub.url(), _storeUrl);
        backend.expires = DateTime.now().add(const Duration(days: 365));
        backend.signinCode = 503;
        await state.refreshAccount(force: true);
        expect(state.premium.source, PremiumSource.store);
        expect((await Premium.load()).source, PremiumSource.store);
        expect(await PremiumSub.url(), _storeUrl);
        expect(state.subToken, 'store_tok');
        expect(
          state.profiles.where((p) => p.premium).single.name,
          'store-ams-01',
        );
        final attempts = backend.to('/v1/account/signin').length;
        backend.signinCode = 200;
        await state.refreshAccount(force: true);
        expect(backend.to('/v1/account/signin'), hasLength(attempts + 1));
        expect(state.premium.source, PremiumSource.account);
        expect(await PremiumSub.url(), _subUrl);
        expect(state.subToken, 'k9Q-token');
        expect(state.profiles.where((p) => p.premium), hasLength(2));
      },
    );

    Future<void> storeLive() async {
      await PremiumSub.saveProof(_proof);
      state.storeEntitlementForTesting(
        Premium(
          status: PremiumStatus.active,
          plan: PremiumPlan.yearly,
          renews: DateTime.now().add(const Duration(days: 10)),
        ),
      );
    }

    test('a running store subscription is what sign-out promises stays', () async {
      expect(state.storeEntitlementLive, isFalse);
      await storeLive();
      await pumpEventQueue();
      expect(state.storeEntitlementLive, isTrue);
      // A lapsed one keeps its page but carries nothing past sign-out.
      state.storeEntitlementForTesting(
        Premium(
          status: PremiumStatus.expired,
          plan: PremiumPlan.yearly,
          renews: DateTime.now().add(const Duration(days: 11)),
        ),
      );
      await pumpEventQueue();
      expect(state.hasStoreEntitlement, isTrue);
      expect(state.storeEntitlementLive, isFalse);
    });

    test('comes back on its own when the account is signed out', () async {
      await storeLive();
      // The account runs longer, so it takes over.
      backend.expires = DateTime.now().add(const Duration(days: 300));
      await state.signInWithAccountNumber(_number);
      await pumpEventQueue();
      expect(state.premium.source, PremiumSource.account);
      expect(state.hasStoreEntitlement, isTrue);

      await state.signOutAccount();
      await pumpEventQueue();

      expect(state.premium.source, PremiumSource.store);
      expect(state.premium.isOn, isTrue);
      expect(_provisions, isNotEmpty, reason: 'no manual restore needed');
      expect(await PremiumSub.url(), _storeUrl);
      expect(
        state.profiles.where((p) => p.premium).single.name,
        'store-ams-01',
      );
    });

    test('comes back when the account runs out of time', () async {
      await storeLive();
      backend.expires = DateTime.now().add(const Duration(days: 300));
      await state.signInWithAccountNumber(_number);
      await pumpEventQueue();

      backend.active = false;
      await state.refreshAccount(force: true);
      await pumpEventQueue();

      expect(state.premium.source, PremiumSource.store);
      expect(state.premium.isOn, isTrue);
      expect(await PremiumSub.url(), _storeUrl);
      expect(await PremiumSub.proof(), isNotNull);
    });
  });

  group('a store purchase on the account number', () {
    final accountEnds = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().add(const Duration(days: 400)).millisecondsSinceEpoch,
    );
    final storeEnds = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().add(const Duration(days: 35)).millisecondsSinceEpoch,
    );
    // Play hands the app no expiry; the device makes one up a year out.
    final madeUp = DateTime.now().add(const Duration(days: 365));

    Map<String, dynamic> account({
      String linked = 'joined',
      String? number,
      DateTime? ends,
      String deviceId = 'dev_abc',
      String deviceToken = 'k9Q-token',
    }) => {
      'linked': linked,
      'number': number,
      'active': true,
      'expires_ms': (ends ?? accountEnds).millisecondsSinceEpoch,
      'kind': 'yearly',
      'device_token': deviceToken,
      'device': {'id': deviceId, 'kind': 'phone', 'name': 'Android phone'},
      'subscription_url': _subUrl,
      'device_limit': 5,
      'store': {
        'platform': 'android',
        'expires_ms': storeEnds.millisecondsSinceEpoch,
      },
    };

    Future<void> purchase({DateTime? renews}) async {
      await state.storeEntitlementForTesting(
        Premium(
          status: PremiumStatus.active,
          plan: PremiumPlan.yearly,
          renews: renews ?? madeUp,
        ),
        _proof,
      );
      await pumpEventQueue();
    }

    Map<String, dynamic> sent(http.Request r) =>
        jsonDecode(r.body) as Map<String, dynamic>;

    test('a first purchase makes a number and shows it once', () async {
      _provisionAccount = account(linked: 'new', number: _number);
      await purchase();

      final body = sent(_provisions.single);
      expect(body['v'], 2);
      expect(body.containsKey('device_token'), isFalse);
      expect(body['device'], {'kind': 'phone', 'name': 'Android phone'});

      expect(state.premium.source, PremiumSource.account);
      expect(state.premium.isOn, isTrue);
      expect(state.accountSignedIn, isTrue);
      expect(state.accountNumber, _number);
      expect(state.accountNumberKnown, isTrue);
      expect(state.accountCanManage, isTrue);
      expect(state.freshAccountNumber, _number);
      expect(await PremiumSub.url(), _subUrl);
      expect(state.profiles.where((p) => p.premium), hasLength(2));
      expect(state.subToken, 'k9Q-token');
      final stored = await const AccountStore().load();
      expect(stored!.number, _number);
      expect(stored.deviceToken, 'k9Q-token');
      expect(stored.deviceId, 'dev_abc');

      // The store is how the account is paid for.
      expect(state.storeLinked, isTrue);
      expect(state.storeName, 'Google Play');
      expect(state.storeRenews, storeEnds);
      expect(state.storeLinkedElsewhere, isFalse);
      expect(state.hasStoreEntitlement, isTrue);

      // The number waits to be seen across a restart, and only until then.
      final later = AppState(
        accounts: AccountService(client: backend.client),
        provisioning: _provisioning(),
      );
      await later.loadAccountForTesting();
      expect(later.freshAccountNumber, _number);
      later.ackFreshAccountNumber();
      expect(later.freshAccountNumber, isNull);
      await pumpEventQueue();
      final again = AppState(
        accounts: AccountService(client: backend.client),
        provisioning: _provisioning(),
      );
      await again.loadAccountForTesting();
      expect(again.freshAccountNumber, isNull);
      expect(again.accountNumber, _number);
    });

    test('the date is the server one, not one the device made up', () async {
      _provisionAccount = account(linked: 'new', number: _number);
      await purchase();

      expect(state.premium.renews, accountEnds);
      expect(state.accountExpires, accountEnds);
      expect((await Premium.load()).renews, accountEnds);
      // Play gives the device no date of its own to show.
      expect(state.storeRenews, storeEnds);
    });

    test('a number out of time is named, so a purchase renews it', () async {
      backend.active = false;
      backend.expires = DateTime.now().subtract(const Duration(days: 3));
      await state.signInWithAccountNumber(_number);
      await pumpEventQueue();
      expect(state.accountDeviceSignedOut, isFalse);
      _provisionAccount = account();
      await purchase();

      final body = sent(_provisions.single);
      expect(body['account_number'], _number);
      expect(body.containsKey('device_token'), isFalse);
      expect(state.accountNumber, _number);
      expect(state.freshAccountNumber, isNull);
      expect(state.premium.source, PremiumSource.account);
      expect(state.premium.isOn, isTrue);
      expect(state.accountCanManage, isTrue);
    });

    test('another account answering does not keep this number', () async {
      await state.signInWithAccountNumber(_number);
      await pumpEventQueue();
      // The subscription already pays for a different account, which signs
      // this device in under its own entry.
      _provisionAccount = account(
        linked: 'existing',
        deviceId: 'dev_other',
        deviceToken: 'other-token',
      );
      await purchase();

      expect(state.accountSignedIn, isTrue);
      expect(state.accountNumber, isNull);
      expect(state.accountNumberKnown, isFalse);
      final stored = await const AccountStore().load();
      expect(stored!.number, isNull);
      expect(stored.deviceToken, 'other-token');
    });

    test('the same entry handed back keeps this number', () async {
      await state.signInWithAccountNumber(_number);
      await pumpEventQueue();
      _provisionAccount = account(linked: 'existing', deviceToken: 'renewed');
      await purchase();

      expect(state.accountNumber, _number);
      expect((await const AccountStore().load())!.deviceToken, 'renewed');
    });

    test('a purchase joins the number this device is signed in to', () async {
      await state.signInWithAccountNumber(_number);
      await pumpEventQueue();
      _provisionAccount = account();
      await purchase();

      expect(sent(_provisions.single)['device_token'], 'k9Q-token');
      expect(state.premium.source, PremiumSource.account);
      expect(state.premium.renews, accountEnds);
      expect(state.accountNumber, _number);
      expect(state.freshAccountNumber, isNull);
      expect(state.storeLinked, isTrue);
      expect(await PremiumSub.url(), _subUrl);
    });

    test('a renewal goes onto the linked account it pays for', () async {
      _provisionAccount = account(linked: 'new', number: _number);
      await purchase();
      final later = DateTime.fromMillisecondsSinceEpoch(
        accountEnds.add(const Duration(days: 30)).millisecondsSinceEpoch,
      );
      _provisionAccount = account(linked: 'existing', ends: later);
      await purchase(renews: madeUp.add(const Duration(days: 30)));

      expect(_provisions, hasLength(2));
      expect(sent(_provisions.last)['device_token'], 'k9Q-token');
      expect(state.premium.source, PremiumSource.account);
      expect(state.premium.renews, later);
      expect(state.accountNumber, _number);
      expect(state.freshAccountNumber, _number);
    });

    test('a restore without the number signs in all the same', () async {
      _provisionAccount = account(linked: 'existing');
      await purchase();

      expect(state.accountSignedIn, isTrue);
      expect(state.accountNumberKnown, isFalse);
      expect(state.accountNumber, isNull);
      expect(state.accountCanManage, isTrue);
      expect(state.freshAccountNumber, isNull);
      expect(state.premium.source, PremiumSource.account);
      expect(state.premium.isOn, isTrue);
      expect(state.profiles.where((p) => p.premium), hasLength(2));

      // It survives a restart without a number.
      final later = AppState(
        accounts: AccountService(client: backend.client),
        provisioning: _provisioning(),
      );
      await later.loadAccountForTesting();
      expect(later.accountSignedIn, isTrue);
      expect(later.accountNumber, isNull);

      // The account is asked about with this device's token.
      await state.refreshAccount(force: true);
      expect(backend.body(backend.to('/v1/account/status').last), {
        'device_token': 'k9Q-token',
      });
      expect(state.premium.isOn, isTrue);

      // Removing a device works the same way.
      expect(await state.removeAccountDevice('dev_other'), AccountResult.ok);
      expect(backend.body(backend.to('/v1/account/revoke').single), {
        'device_token': 'k9Q-token',
        'device_id': 'dev_other',
      });

      // A new number is how it gets one, and it keeps it.
      final r = await state.rotateAccountNumber();
      expect(r.accountNumber, _fresh);
      expect(backend.body(backend.to('/v1/account/rotate').single), {
        'device_token': 'k9Q-token',
        'revoke_devices': false,
      });
      expect(state.accountNumber, _fresh);
      expect(state.accountNumberKnown, isTrue);
      expect((await const AccountStore().load())!.number, _fresh);
      expect(state.premium.isOn, isTrue);
    });

    test('taken off elsewhere without a number, the device lets go', () async {
      _provisionAccount = account(linked: 'existing');
      await purchase();
      backend.statusCode = 404;
      await state.refreshAccount(force: true);

      expect(state.accountSignedIn, isFalse);
      expect(state.premium.isOn, isFalse);
      expect(state.profiles.where((p) => p.premium), isEmpty);
      // A renewal on its own does not put it back.
      await purchase(renews: madeUp.add(const Duration(days: 30)));
      expect(_provisions, hasLength(1));
      expect(state.accountSignedIn, isFalse);
    });

    test('a subscription on another number leaves this one alone', () async {
      backend.expires = DateTime.now().add(const Duration(days: 300));
      await state.signInWithAccountNumber(_number);
      await pumpEventQueue();
      _provisionAccount = {'error': 'linked_elsewhere', 'device_limit': 5};
      await purchase(renews: DateTime.now().add(const Duration(days: 400)));

      expect(state.storeLinkedElsewhere, isTrue);
      expect(state.storeLinked, isFalse);
      expect(state.accountNumber, _number);
      expect((await const AccountStore().load())!.number, _number);
      // The earlier rule still runs the device: here the store lasts longer.
      expect(state.premium.source, PremiumSource.store);
      expect(await PremiumSub.url(), _storeUrl);
    });

    test('a full account runs the purchase the way it ran before', () async {
      _provisionAccount = {'error': 'device_limit_reached', 'device_limit': 5};
      await purchase();

      expect(state.accountSignedIn, isFalse);
      expect(state.storeLinked, isFalse);
      expect(state.premium.source, PremiumSource.store);
      expect(state.premium.isOn, isTrue);
      expect(await PremiumSub.url(), _storeUrl);
      expect(
        state.profiles.where((p) => p.premium).single.name,
        'store-ams-01',
      );
    });

    test('a number made with an error is still kept and shown', () async {
      _provisionAccount = {
        'error': 'device_limit_reached',
        'number': _number,
        'device_limit': 5,
      };
      await purchase();

      // The purchase runs the way it did before accounts...
      expect(state.premium.source, PremiumSource.store);
      expect(await PremiumSub.url(), _storeUrl);
      // ...and the number it made is not lost.
      expect(state.freshAccountNumber, _number);
      expect(state.accountNumber, _number);
      expect(state.accountDeviceSignedOut, isTrue);
      expect((await const AccountStore().load())!.number, _number);
      expect(await const AccountStore().freshNumber(), _number);
    });

    test('a number made with an error leaves a working account be', () async {
      await state.signInWithAccountNumber(_number);
      await pumpEventQueue();
      _provisionAccount = {'error': 'unavailable', 'number': _fresh};
      await purchase();

      expect(state.accountNumber, _number);
      expect((await const AccountStore().load())!.deviceToken, 'k9Q-token');
      expect(state.freshAccountNumber, _fresh);
    });

    test('without an account block nothing changes from before', () async {
      await purchase();

      expect(sent(_provisions.single)['v'], 2);
      expect(state.accountSignedIn, isFalse);
      expect(state.storeLinked, isFalse);
      expect(state.storeLinkedElsewhere, isFalse);
      expect(state.premium.source, PremiumSource.store);
      expect(state.premium.renews, madeUp);
      expect(await PremiumSub.url(), _storeUrl);
    });

    test('a device signed out from elsewhere cannot manage', () async {
      await state.signInWithAccountNumber(_number);
      await pumpEventQueue();
      expect(state.accountCanManage, isTrue);
      backend.devices = ['dev_other'];
      await state.refreshAccount(force: true);
      expect(state.accountDeviceSignedOut, isTrue);
      expect(state.accountCanManage, isFalse);

      expect(
        await state.removeAccountDevice('dev_other'),
        AccountResult.invalid,
      );
      final r = await state.rotateAccountNumber();
      expect(r.result, AccountResult.invalid);
      expect(backend.to('/v1/account/revoke'), isEmpty);
      expect(backend.to('/v1/account/rotate'), isEmpty);
      expect(state.accountNumber, _number);
    });

    test('a revoked number cannot be managed either', () async {
      await state.signInWithAccountNumber(_number);
      await pumpEventQueue();
      backend.statusCode = 403;
      await state.refreshAccount(force: true);
      expect(state.accountCanManage, isFalse);
      expect(
        await state.removeAccountDevice('dev_other'),
        AccountResult.invalid,
      );
      expect((await state.rotateAccountNumber()).result, AccountResult.invalid);
      expect(backend.to('/v1/account/revoke'), isEmpty);
      expect(backend.to('/v1/account/rotate'), isEmpty);
    });

    test('not signed in, there is nothing to manage', () async {
      expect(state.accountCanManage, isFalse);
      expect(state.accountNumberKnown, isFalse);
      expect(
        await state.removeAccountDevice('dev_abc'),
        AccountResult.invalid,
      );
      expect((await state.rotateAccountNumber()).result, AccountResult.invalid);
      expect(await state.deleteAccountNumber(), AccountResult.invalid);
      expect(backend.requests, isEmpty);
    });

    test('deleting the number forgets it and keeps the billing', () async {
      _provisionAccount = account(linked: 'new', number: _number);
      await purchase();

      expect(await state.deleteAccountNumber(), AccountResult.ok);
      expect(backend.body(backend.to('/v1/account/delete').single), {
        'account_number': _number,
      });
      expect(state.accountSignedIn, isFalse);
      expect(state.accountNumber, isNull);
      expect(state.freshAccountNumber, isNull);
      expect(await const AccountStore().load(), isNull);
      expect(await const AccountStore().freshNumber(), isNull);
      expect(state.premium.isOn, isFalse);
      expect(await PremiumSub.url(), isNull);
      expect(state.profiles.where((p) => p.premium), isEmpty);
      expect(state.storeLinked, isFalse);
      // The store side is untouched: still on record, proof kept.
      expect(state.hasStoreEntitlement, isTrue);
      expect(state.storeName, 'Google Play');
      expect(await PremiumSub.proof(), isNotNull);

      // A renewal does not quietly make a new number.
      await purchase(renews: madeUp.add(const Duration(days: 30)));
      expect(_provisions, hasLength(1));
      expect(state.accountSignedIn, isFalse);
    });

    test('a failed delete keeps everything', () async {
      _provisionAccount = account(linked: 'new', number: _number);
      await purchase();
      final failing = AppState(
        accounts: AccountService(
          client: MockClient((_) async => http.Response('', 503)),
        ),
        provisioning: _provisioning(),
      );
      await failing.loadAccountForTesting();

      expect(await failing.deleteAccountNumber(), AccountResult.network);
      expect(failing.accountNumber, _number);
      expect((await const AccountStore().load())!.number, _number);
    });

    test('signing out of a linked account stays signed out', () async {
      _provisionAccount = account(linked: 'new', number: _number);
      await purchase();

      await state.signOutAccount();
      await pumpEventQueue();
      expect(state.accountSignedIn, isFalse);
      expect(state.premium.isOn, isFalse);
      expect(_provisions, hasLength(1), reason: 'the store does not take over');
      expect(backend.body(backend.to('/v1/account/revoke').single), {
        'account_number': _number,
        'device_id': 'dev_abc',
      });

      // A renewal on its own leaves it there; a restore brings it back.
      await purchase(renews: madeUp.add(const Duration(days: 30)));
      expect(state.accountSignedIn, isFalse);
      expect(_provisions, hasLength(1));

      _provisionAccount = account(linked: 'existing');
      await state.restorePurchases();
      await purchase(renews: madeUp.add(const Duration(days: 60)));
      expect(_provisions, hasLength(2));
      expect(state.accountSignedIn, isTrue);
      expect(state.accountNumberKnown, isFalse);
      expect(state.premium.isOn, isTrue);
    });

    test('an account run out while the store pays is topped up at once', () async {
      _provisionAccount = account(linked: 'new', number: _number);
      await purchase();
      backend.active = false;
      final topped = DateTime.fromMillisecondsSinceEpoch(
        accountEnds.add(const Duration(days: 365)).millisecondsSinceEpoch,
      );
      _provisionAccount = account(linked: 'existing', ends: topped);

      await state.refreshAccount(force: true);

      expect(_provisions, hasLength(2));
      expect(sent(_provisions.last)['device_token'], 'k9Q-token');
      expect(state.premium.isOn, isTrue);
      expect(state.premium.renews, topped);
      expect(state.accountNumber, _number);
      expect(await PremiumSub.url(), _subUrl);
    });

    test('a past date with the store still paying skips the wait', () async {
      _provisionAccount = account(
        linked: 'new',
        number: _number,
        ends: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      await purchase();
      // The server says the account has time, with a date already behind.
      backend.expires = DateTime.now().subtract(const Duration(minutes: 1));
      await state.refreshAccount(force: true);
      final asked = backend.to('/v1/account/status').length;

      // Inside the six hours, but the account's date has passed.
      expect(await state.refreshAccount(), isNotNull);
      expect(backend.to('/v1/account/status'), hasLength(asked + 1));
    });

    test('the status answer has the last word on the link', () async {
      _provisionAccount = account(linked: 'new', number: _number);
      await purchase();
      expect(state.storeLinked, isTrue);

      backend.storeLinked = false;
      await state.refreshAccount(force: true);
      expect(state.storeLinked, isFalse);

      backend.storeLinked = true;
      await state.refreshAccount(force: true);
      expect(state.storeLinked, isTrue);
    });

    test('signing back in after a remote sign-out links again', () async {
      _provisionAccount = account(linked: 'new', number: _number);
      await purchase();
      state.ackFreshAccountNumber();
      backend.devices = ['dev_other'];
      await state.refreshAccount(force: true);
      expect(state.accountDeviceSignedOut, isTrue);
      expect(state.storeLinked, isFalse);

      // Left alone, a launch does not sign it back in.
      await state.refreshPremiumForTesting();
      expect(_provisions, hasLength(1));

      backend.devices = ['dev_abc'];
      await state.signInWithAccountNumber(_number);
      await pumpEventQueue();
      expect(state.accountDeviceSignedOut, isFalse);

      // The next launch asks which number the subscription pays for.
      _provisionAccount = account(linked: 'existing');
      await state.refreshPremiumForTesting();
      expect(_provisions, hasLength(2));
      expect(sent(_provisions.last)['device_token'], 'k9Q-token');
      expect(state.storeLinked, isTrue);
      expect(state.accountNumber, _number);

      // And a renewal goes onto it again.
      await purchase(renews: madeUp.add(const Duration(days: 30)));
      expect(_provisions, hasLength(3));
    });

    test('another number signed in drops the link', () async {
      _provisionAccount = account(linked: 'new', number: _number);
      await purchase();
      expect(state.storeLinked, isTrue);

      // The sign-in mock answers for any number with the same device.
      await state.signInWithAccountNumber(_fresh);
      await pumpEventQueue();
      expect(state.accountNumber, _fresh);
      expect(state.storeLinked, isFalse);
      expect(state.freshAccountNumber, isNull);

      // The next launch asks which number the subscription pays for now.
      _provisionAccount = {'error': 'linked_elsewhere', 'device_limit': 5};
      await state.refreshPremiumForTesting();
      expect(_provisions, hasLength(2));
      expect(state.storeLinkedElsewhere, isTrue);
      expect(state.accountNumber, _fresh);
    });

    group('an install from before', () {
      Future<void> storeOnRecord() async {
        await PremiumSub.saveProof(_proof);
        await state.storeEntitlementForTesting(
          Premium(
            status: PremiumStatus.active,
            plan: PremiumPlan.yearly,
            renews: DateTime.now().add(const Duration(days: 10)),
          ),
        );
      }

      test('puts its subscription on the signed-in number once', () async {
        backend.expires = DateTime.now().add(const Duration(days: 300));
        await state.signInWithAccountNumber(_number);
        await pumpEventQueue();
        await storeOnRecord();
        expect(state.premium.source, PremiumSource.account);
        expect(_provisions, isEmpty);

        _provisionAccount = account();
        await state.refreshPremiumForTesting();

        expect(_provisions, hasLength(1));
        expect(sent(_provisions.single)['device_token'], 'k9Q-token');
        expect(sent(_provisions.single)['v'], 2);
        expect(state.storeLinked, isTrue);
        expect(state.accountNumber, _number);
        expect(state.premium.renews, accountEnds);

        // Once: not on the next launch, not after a restart.
        await state.refreshPremiumForTesting();
        final later = AppState(
          accounts: AccountService(client: backend.client),
          provisioning: _provisioning(),
        );
        await later.loadAccountForTesting();
        await later.refreshPremiumForTesting();
        expect(_provisions, hasLength(1));
      });

      test('gets a number for a subscription without one', () async {
        await storeOnRecord();
        _provisionAccount = account(linked: 'new', number: _number);
        await state.refreshPremiumForTesting();

        expect(state.accountNumber, _number);
        expect(state.freshAccountNumber, _number);
        expect(state.premium.source, PremiumSource.account);
        expect(await PremiumSub.url(), _subUrl);
      });

      test('asks again while the backend has no accounts for it', () async {
        await storeOnRecord();
        await state.refreshPremiumForTesting();
        expect(_provisions, hasLength(1));
        expect(state.accountSignedIn, isFalse);
        expect(state.premium.source, PremiumSource.store);

        await state.refreshPremiumForTesting();
        expect(_provisions, hasLength(2));
      });

      test('a refusal is an answer too', () async {
        await storeOnRecord();
        _provisionAccount = {'error': 'linked_elsewhere', 'device_limit': 5};
        await state.refreshPremiumForTesting();
        expect(state.storeLinkedElsewhere, isTrue);
        await state.refreshPremiumForTesting();
        expect(_provisions, hasLength(1));
      });

      test('without a purchase proof there is nothing to ask', () async {
        await state.refreshPremiumForTesting();
        expect(_provisions, isEmpty);
      });
    });
  });

  group('the persisted entitlement', () {
    test('a record from before account numbers is a store one', () async {
      final renews = DateTime.now().add(const Duration(days: 10));
      SharedPreferences.setMockInitialValues({
        'premium_v1': jsonEncode({
          'status': 'active',
          'plan': 'yearly',
          'renews': renews.millisecondsSinceEpoch,
        }),
      });
      final p = await Premium.load();
      expect(p.source, PremiumSource.store);
      expect(p.isOn, isTrue);
      expect(p.plan, PremiumPlan.yearly);
    });

    test('an unknown source reads as store, never as a crash', () async {
      SharedPreferences.setMockInitialValues({
        'premium_v1': jsonEncode({
          'status': 'active',
          'plan': null,
          'renews': null,
          'source': 'somewhere-new',
        }),
      });
      expect((await Premium.load()).source, PremiumSource.store);
    });

    test('a store entitlement lapses on load by its date', () async {
      await Premium(
        status: PremiumStatus.active,
        renews: DateTime.now().subtract(const Duration(hours: 1)),
      ).save();
      expect((await Premium.load()).status, PremiumStatus.expired);
    });

    test('an account entitlement never lapses by the device date', () async {
      await Premium(
        status: PremiumStatus.active,
        renews: DateTime.now().subtract(const Duration(hours: 1)),
        source: PremiumSource.account,
      ).save();
      final p = await Premium.load();
      expect(p.status, PremiumStatus.active);
      expect(p.source, PremiumSource.account);
    });
  });
}
