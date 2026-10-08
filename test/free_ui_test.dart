import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/account_service.dart';
import 'package:hideip_vpn/core/account_store.dart';
import 'package:hideip_vpn/core/free_access.dart';
import 'package:hideip_vpn/core/location.dart';
import 'package:hideip_vpn/core/pairing.dart';
import 'package:hideip_vpn/core/provisioning.dart';
import 'package:hideip_vpn/core/secret_prefs.dart';
import 'package:hideip_vpn/core/share_link_parser.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/free_rows.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/home_hero.dart';
import 'package:hideip_vpn/ui/redesign/locations_screen.dart';
import 'package:hideip_vpn/ui/redesign/locked_row.dart';
import 'package:hideip_vpn/ui/strings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/account_fakes.dart';

const _challenge = 'aGlkZWlwLWZyZWUtdGVzdA';
const _number = '8236387788950319';
final _catalog = Uri.parse('https://mirror.test/catalog');

String _freeSub(int n) => '${ProvisioningService.endpoint}/v1/sub/free_tok_$n';

String _link(String name, [String host = '127.0.0.1']) =>
    'vless://22222222-2222-2222-2222-222222222222@$host:9'
    '?security=none#$name';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

/// The free routes of CONTRACT-FREE C5, the switch in [info], and an
/// account sign-in that can come back with no time on it.
class _Backend {
  final requests = <http.Request>[];
  Object? info = {
    'enabled': true,
    'speed_mbps': 10,
    'data_gb': 0,
    'speed_mode': true,
  };
  bool infoDown = false;
  bool accountActive = false;
  http.Response? registerAnswer;
  int registered = 0;

  List<http.Request> to(String path) =>
      requests.where((r) => r.url.path == path).toList();

  http.Client get client => MockClient((req) async {
    requests.add(req);
    if (req.url == _catalog) return http.Response('', 503);
    final url = req.url.toString();
    for (var n = 1; n <= 3; n++) {
      if (url == _freeSub(n)) {
        return http.Response(
          '${_link('free-de-01', '127.0.0.$n')}\n'
          '${_link('free-fi-01', '127.0.1.$n')}',
          200,
        );
      }
    }
    switch (req.url.path) {
      case '/v1/free/info':
        if (infoDown) throw http.ClientException('down');
        return info == null ? http.Response('', 404) : _json(info!);
      case '/v1/free/challenge':
        return _json({
          'challenge': _challenge,
          'pow_bits': 8,
          'expires_ms': DateTime.now()
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch,
        });
      case '/v1/free/register':
        final answer = registerAnswer;
        if (answer != null) return answer;
        registered++;
        return _json({
          'sub_token': 'free_tok_$registered',
          'sub_url': _freeSub(registered),
          'speed_mbps': 10,
          'wg': null,
        });
      case '/v1/account/signin':
        return _json({
          'active': accountActive,
          'expires_ms': DateTime.now()
              .subtract(const Duration(days: 3))
              .millisecondsSinceEpoch,
          'device': {'id': 'dev_abc', 'kind': 'phone', 'name': 'x'},
          'device_token': 'k9Q-token',
          'device_limit': 5,
        });
    }
    return http.Response('', 404);
  });
}

late _Backend _backend;

AppState _fresh() => AppState(
  accounts: AccountService(client: _backend.client),
  provisioning: ProvisioningService(
    client: _backend.client,
    catalogSources: [_catalog],
  ),
  pairing: PairingClient(client: _backend.client),
  free: FreeService(client: _backend.client),
  freeProver: PowProver(solve: (c, bits) async => solvePow(c, bits)),
  linkPollInterval: null,
  tablet: false,
);

/// Lets the mocked network answer between frames.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Lets the probes and saves a tap started run out before the test ends:
/// a store write left halfway would hold its lock into the next test.
Future<void> _drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await _settle(tester);
}

/// Runs [work] in the test's own zone, letting the mocked network answer,
/// until it is done.
Future<void> _drive(WidgetTester tester, Future<void> work) async {
  var done = false;
  work.whenComplete(() => done = true).ignore();
  for (var i = 0; i < 200 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done, isTrue, reason: 'the work did not finish');
  await work;
}

Widget _locations(AppState state) => MaterialApp(
  home: Scaffold(
    body: LocationsScreen(state: state, nav: fakeNav()),
  ),
);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Keys in memory: a platform keystore call left open by one widget
    // test would hold its key's lock into the next.
    SecretPrefs.installKeyVaultForTesting(MemorySecureKeyVault());
    await PremiumSub.clear();
    await const AccountStore().clear();
    await const FreeStore().clear();
    _backend = _Backend();
    Hip.reducedMotion = true;
  });

  tearDown(() => Hip.reducedMotion = false);

  group('the state', () {
    test('a tap chooses the free location without connecting', () async {
      final state = _fresh();
      await state.refreshFreeInfo();
      expect(_backend.to('/v1/free/register'), isEmpty);

      expect(await state.selectFree(), isTrue);
      expect(_backend.to('/v1/free/register'), hasLength(1));
      expect(state.activeLocation!.profile.free, isTrue);
      expect(state.prefs.autoSelect, isFalse);
      expect(state.conn, ConnState.disconnected);
    });

    test('a refused key says so and keeps the choice as it was', () async {
      final state = _fresh();
      await state.addLink(_link('my-own', '10.0.0.1'));
      await state.refreshFreeInfo();
      _backend.registerAnswer = _json({'error': 'rate_limited'}, 429);

      expect(await state.selectFree(), isFalse);
      expect(state.toast, S.toastFreeBusy);
      expect(state.locations, hasLength(1));
      expect(state.activeLocation!.profile.free, isFalse);
    });

    test(
      'Auto keeps to the user\'s own servers, free only as a fallback',
      () async {
        final state = _fresh();
        await state.refreshFreeInfo();
        await state.ensureFreeAccess();
        expect(state.autoCandidates, hasLength(2));
        expect(state.autoCandidates.every((l) => l.profile.free), isTrue);

        await state.addLink(_link('my-own', '10.0.0.1'));
        expect(state.autoCandidates, hasLength(1));
        expect(state.autoCandidates.single.profile.free, isFalse);
      },
    );

    test('an account signed in, even out of time, is not offered the free '
        'location', () async {
      final state = _fresh();
      await state.refreshFreeInfo();
      expect(state.freeOffered, isTrue);

      final signed = await state.signInWithAccountNumber(_number);
      expect(signed.result, AccountResult.inactive);
      expect(state.premium.isOn, isFalse);
      expect(state.accountSignedIn, isTrue);
      expect(state.freeOffered, isFalse);
      expect(state.freeLocations, isEmpty);
      expect(await state.ensureFreeAccess(), FreeAccessResult.premium);
      expect(_backend.to('/v1/free/challenge'), isEmpty);
      expect(FreeOffer.of(state).any, isFalse);
    });
  });

  group('Locations', () {
    testWidgets('on: an open Free row with its speed, not a locked one', (
      tester,
    ) async {
      _phone(tester);
      final state = _fresh();
      await _drive(tester, state.refreshFreeInfo());
      await tester.pumpWidget(_locations(state));
      await _settle(tester);

      expect(find.text(S.freeTag.toUpperCase()), findsOneWidget);
      final row = find.byType(FreeOfferRow);
      expect(row, findsOneWidget);
      expect(find.text(S.freeLocation), findsOneWidget);
      expect(find.text(S.freeSpeed(10)), findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.byType(LockedRow)),
        findsNothing,
      );
      // Nothing asked for yet: the key waits for the tap.
      expect(_backend.to('/v1/free/register'), isEmpty);

      await tester.tap(row);
      await _settle(tester);
      expect(_backend.to('/v1/free/register'), hasLength(1));
      expect(state.activeLocation!.profile.free, isTrue);
      await _drain(tester);
    });

    testWidgets('held: the free servers in their own group, badged, still', (
      tester,
    ) async {
      _phone(tester);
      final state = _fresh();
      await _drive(tester, () async {
        await state.refreshFreeInfo();
        await state.ensureFreeAccess();
      }());
      await tester.pumpWidget(_locations(state));
      await _settle(tester);

      expect(find.text(S.freeTag.toUpperCase()), findsOneWidget);
      expect(find.byType(FreeOfferRow), findsNothing);
      // Both free servers carry the badge and the speed. Neither slides,
      // and neither counts as one of the user's own.
      expect(find.text(S.freeTag), findsNWidgets(2));
      expect(find.textContaining('Up to 10 Mbit/s'), findsNWidgets(2));
      expect(find.byType(HipSwipeRow), findsNothing);
      expect(find.text(S.dNoServers), findsOneWidget);
    });

    testWidgets('off: no free row, and the list is as it was', (tester) async {
      _phone(tester);
      _backend.info = {'enabled': false};
      final state = _fresh();
      await _drive(tester, state.refreshFreeInfo());
      await tester.pumpWidget(_locations(state));
      await _settle(tester);

      expect(find.text(S.freeTag.toUpperCase()), findsNothing);
      expect(find.byType(FreeOfferRow), findsNothing);
      expect(find.text(S.tAuto), findsOneWidget);
      expect(find.text(S.dYourServers.toUpperCase()), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a network that fails hides the row and breaks nothing', (
      tester,
    ) async {
      _phone(tester);
      _backend.infoDown = true;
      final state = _fresh();
      await _drive(tester, state.refreshFreeInfo());
      await tester.pumpWidget(_locations(state));
      await _settle(tester);

      expect(find.text(S.freeTag.toUpperCase()), findsNothing);
      expect(find.byType(FreeOfferRow), findsNothing);
      expect(find.text(S.tAuto), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('catalog rows before the key are offered open, by name', (
      tester,
    ) async {
      _phone(tester);
      final row = Location.derive(
        ShareLinkParser.parse(_link('Frankfurt'))!.copyWith(free: true),
        0,
      );
      final tapped = <Location?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocationsBody(
              mix: Mix.byo,
              advanced: false,
              subscribed: false,
              showManagedSection: false,
              managedGroup: ManagedGroup.locked,
              free: FreeOffer(offered: [row], speedMbps: 10),
              onFreeOffer: tapped.add,
              pingOf: (_) => null,
              levelOf: (_) => 0,
              nameOf: (l) => l.label,
              subInfoOf: (_) => null,
              onBack: () {},
              onSelect: (_) {},
              onManage: (_) {},
              onLockedTap: (_, _) {},
              onShowAll: () {},
              onSeePlans: () {},
              onAdd: () {},
              onDismissWinner: () {},
              onWinner: (_) {},
            ),
          ),
        ),
      );
      expect(find.byType(FreeOfferRow), findsOneWidget);
      expect(find.text(S.freeLocation), findsNothing);
      await tester.tap(find.byType(FreeOfferRow));
      expect(tapped.single, row);
    });
  });

  group('Home', () {
    // As the shell hosts it: rebuilt whenever the state changes.
    Widget home(AppState state) => MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: state,
          builder: (_, _) => HomeHeroScreen(state: state, nav: fakeNav()),
        ),
      ),
    );

    testWidgets('empty, with the free location on: one row under the block', (
      tester,
    ) async {
      _phone(tester);
      final state = _fresh();
      await _drive(tester, state.refreshFreeInfo());
      await tester.pumpWidget(home(state));
      await _settle(tester);

      expect(find.text(S.b0Title), findsOneWidget);
      expect(find.byType(FreeOfferRow), findsOneWidget);
      await tester.tap(find.byType(FreeOfferRow));
      await _settle(tester);
      expect(_backend.to('/v1/free/register'), hasLength(1));
      // Home has a server now, and Connect is the action again.
      expect(find.text(S.b0Title), findsNothing);
      expect(find.text(S.tConnect), findsOneWidget);
      expect(find.text(S.freeTag), findsWidgets);
      expect(state.conn, ConnState.disconnected);
      await _drain(tester);
    });

    testWidgets('empty, with the free location off: the block alone', (
      tester,
    ) async {
      _phone(tester);
      _backend.info = {'enabled': false};
      final state = _fresh();
      await _drive(tester, state.refreshFreeInfo());
      await tester.pumpWidget(home(state));
      await _settle(tester);

      expect(find.text(S.b0Title), findsOneWidget);
      expect(find.byType(FreeOfferRow), findsNothing);
    });
  });
}
