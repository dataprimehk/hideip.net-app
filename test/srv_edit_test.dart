import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hideip_vpn/core/ip_lookup.dart';
import 'package:hideip_vpn/core/ping.dart';
import 'package:hideip_vpn/core/share_link_parser.dart';
import 'package:hideip_vpn/core/subscription.dart';
import 'package:hideip_vpn/core/wg_import.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/import_screen.dart';
import 'package:hideip_vpn/ui/redesign/shell.dart';
import 'package:hideip_vpn/ui/redesign/srv_edit.dart';
import 'package:hideip_vpn/ui/strings.dart';

const _uuid = '11111111-1111-1111-1111-111111111111';
const _priv = 'aGlkZWlwLm5ldCB0ZXN0IHByaXZhdGUga2V5IDAwMDE=';
const _pub = 'aGlkZWlwLm5ldCB0ZXN0IHB1YmxpYyBrZXkgMDAwMDE=';
const _psk = 'aGlkZWlwLm5ldCB0ZXN0IHByZXNoYXJlZCBrZXkgMDE=';

String _link(String host, String name) =>
    'vless://$_uuid@$host:443?security=none#$name';

const _wgConf =
    '''
# Name = Attic
[Interface]
PrivateKey = $_priv
Address = 10.66.0.10/32, fd00::10/128
MTU = 1420

[Peer]
PublicKey = $_pub
PresharedKey = $_psk
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = wg.example.com:51820
PersistentKeepalive = 25
''';

/// An app state whose latency probes never open a socket.
class _State extends AppState {
  @override
  Future<void> pingAll() async {}
}

Future<_State> _three() async {
  final state = _State();
  await state.addLink(_link('1.0.0.1', 'de-fra-01'));
  await state.addLink(_link('1.0.0.2', 'ch-zur-01'));
  await state.addLink(_link('1.0.0.3', 'it-mil-01'));
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    IpLookup.lookupOverride = (_) async => null;
  });
  tearDown(() => IpLookup.lookupOverride = null);

  group('replaceProfile', () {
    test('keeps the position, the custom name and the selection', () async {
      final state = await _three();
      await state.renameServer(1, 'Home');
      await state.select(1);

      final next = ShareLinkParser.parse(_link('1.0.0.9', 'nl-ams-02'))!;
      await state.replaceProfile(1, next);

      expect(state.profiles.length, 3);
      expect(state.profiles[1].server, '1.0.0.9');
      expect(state.profiles[1].name, 'nl-ams-02');
      expect(
        state.profiles[1].customName,
        'Home',
        reason: 'the name the user gave it survives the edit',
      );
      expect(state.selectedIndex, 1);
      expect(state.profiles[0].server, '1.0.0.1');
      expect(state.profiles[2].server, '1.0.0.3');
    });

    test('a name in the replacement wins over the old custom name', () async {
      final state = await _three();
      await state.renameServer(0, 'Old');
      final next = ShareLinkParser.parse(
        _link('1.0.0.1', 'x'),
      )!.copyWith(customName: 'New');
      await state.replaceProfile(0, next);
      expect(state.profiles[0].customName, 'New');
    });

    test('keeps the geolocated country while the address stays', () async {
      final state = _State();
      await state.addProfiles([
        ShareLinkParser.parse(_link('1.0.0.1', 'a'))!.copyWith(cc: 'DE'),
      ]);
      await state.replaceProfile(
        0,
        ShareLinkParser.parse(_link('1.0.0.1', 'b'))!,
      );
      expect(state.profiles[0].cc, 'DE');

      await state.replaceProfile(
        0,
        ShareLinkParser.parse(_link('1.0.0.2', 'c'))!,
      );
      expect(
        state.profiles[0].cc,
        isNull,
        reason: 'a new address is a new place until it is looked up',
      );
    });

    test('keeps the subscription the server came from', () async {
      final state = _State();
      await state.addProfiles([
        ShareLinkParser.parse(
          _link('1.0.0.1', 'a'),
        )!.copyWith(subUrl: 'https://sub.example.com/x'),
      ]);
      await state.replaceProfile(
        0,
        ShareLinkParser.parse(_link('1.0.0.1', 'b'))!,
      );
      expect(state.profiles[0].subUrl, 'https://sub.example.com/x');
    });

    test('a managed server and a missing position are left alone', () async {
      final state = _State();
      await state.addProfiles([
        ShareLinkParser.parse(_link('1.0.0.1', 'a'))!.copyWith(premium: true),
      ]);
      await state.replaceProfile(
        0,
        ShareLinkParser.parse(_link('1.0.0.2', 'b'))!,
      );
      expect(state.profiles[0].server, '1.0.0.1');
      await state.replaceProfile(
        4,
        ShareLinkParser.parse(_link('1.0.0.2', 'b'))!,
      );
      expect(state.profiles.length, 1);
    });
  });

  group('the text an edit opens on', () {
    test(
      'a WireGuard file rebuilds from the profile and reads back the same',
      () {
        final p = WgImport.parseConfig(_wgConf);
        final text = WgImport.toConfig(p);
        expect(text, contains('# Name = Attic'));
        expect(text, contains('Endpoint = wg.example.com:51820'));
        expect(text, contains('PresharedKey = $_psk'));
        expect(text, isNot(contains('DNS')));
        final again = WgImport.parseConfig(text);
        expect(again.name, p.name);
        expect(again.server, p.server);
        expect(again.port, p.port);
        expect(again.outbound, p.outbound);
      },
    );

    test('an IPv6 endpoint is bracketed', () {
      final p = WgImport.parseConfig(
        _wgConf.replaceFirst('wg.example.com:51820', '[2001:db8::1]:51820'),
      );
      expect(WgImport.toConfig(p), contains('Endpoint = [2001:db8::1]:51820'));
      expect(WgImport.parseConfig(WgImport.toConfig(p)).server, '2001:db8::1');
    });

    test('the fallback name is not written into the file', () {
      final p = WgImport.parseConfig(
        _wgConf.replaceFirst('# Name = Attic\n', ''),
      );
      expect(p.name, 'WireGuard wg.example.com');
      expect(WgImport.toConfig(p), isNot(contains('# Name')));
    });

    test(
      'the stored link wins; without one a share link becomes a config',
      () async {
        final link = _link('1.0.0.1', 'de-fra-01');
        final stored = ShareLinkParser.parse(link)!.copyWith(source: link);
        expect(srvEditText(stored), link);

        final bare = ShareLinkParser.parse(link)!;
        final text = srvEditText(bare);
        expect(text, contains('"outbounds"'));
        final parsed = await Subscription.parseAsync(text);
        expect(parsed.profiles.length, 1);
        expect(parsed.profiles.first.server, '1.0.0.1');
        expect(parsed.profiles.first.port, 443);
        expect(parsed.profiles.first.outbound['uuid'], _uuid);
      },
    );

    test('the stored extras round trip through a map', () {
      final p = ShareLinkParser.parse(
        _link('1.0.0.1', 'a'),
      )!.copyWith(source: 'vless://x');
      final m = p.storedExtras;
      expect(m['source'], 'vless://x');
      final back = ShareLinkParser.parse(
        _link('1.0.0.1', 'a'),
      )!.withStoredExtras(m);
      expect(back.source, 'vless://x');
      expect(
        ShareLinkParser.parse(_link('1.0.0.1', 'a'))!.storedExtras,
        isEmpty,
        reason: 'nothing is written for a profile that has nothing new',
      );
    });
  });

  group('the import screen in edit mode', () {
    HipNav nav(SrvEditCtx ctx, List<String> log) => HipNav(
      go: (s, [_]) => log.add('go:${s.name}'),
      back: () => log.add('back'),
      ctx: () => ctx,
      showSheet: <T>(List<Widget> children) async => null,
      openDetail: (_) {},
      openImport: () {},
      openImportWith: (_) {},
      openPaywall: ({required HipScreen from, String? locId}) {},
      claimBack: (_) {},
      releaseBack: (_) {},
    );

    setUp(() => Hip.reducedMotion = true);
    tearDown(() => Hip.reducedMotion = false);

    // The state persists through the same stores the app uses, whose work
    // does not belong to any one test's clock, so these run on real time.
    Future<void> wait(WidgetTester tester, [int ms = 60]) async {
      await Future<void>.delayed(Duration(milliseconds: ms));
      await tester.pump();
    }

    testWidgets('opens on the config, saves in place and returns', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final state = _State();
        final link = _link('1.0.0.1', 'de-fra-01');
        await state.addProfiles([
          ShareLinkParser.parse(link)!.copyWith(source: link),
          ShareLinkParser.parse(_link('1.0.0.2', 'ch-zur-01'))!,
        ], countFirstProfile: false);
        await state.renameServer(0, 'Office');
        final loc = state.locations.first;
        final log = <String>[];
        final ctx = SrvEditCtx(
          index: 0,
          id: loc.id,
          label: 'Office',
          text: srvEditText(loc.profile),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ImportScreen(
                state: state,
                nav: nav(ctx, log),
                hooks: ImportHooks(ping: (_, _) async => const PingOk(31)),
              ),
            ),
          ),
        );
        await wait(tester);

        expect(find.text(S.srvEditTitle), findsOneWidget);
        expect(find.text(S.tAddConn), findsNothing);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          link,
        );

        // A subscription URL is not one server, so it cannot be an edit.
        await tester.enterText(
          find.byType(TextField),
          'https://sub.example.com/list',
        );
        await wait(tester);
        expect(
          tester.widget<HipCta>(find.widgetWithText(HipCta, S.eImport)).onTap,
          isNull,
        );

        await tester.enterText(
          find.byType(TextField),
          _link('1.0.0.7', 'nl-ams-02'),
        );
        await wait(tester);
        await tester.tap(find.text(S.eImport));
        // Four named steps, a beat each.
        await wait(tester, 1800);

        expect(find.text(S.srvSaveChanges), findsOneWidget);
        expect(find.text(S.e6AddAndConnect), findsNothing);
        await tester.tap(find.text(S.srvSaveChanges));
        await wait(tester, 200);

        expect(log, ['back'], reason: 'an edit returns where it was opened');
        expect(state.profiles.length, 2);
        expect(state.profiles[0].server, '1.0.0.7');
        expect(state.profiles[0].customName, 'Office');
        expect(state.profiles[0].source, _link('1.0.0.7', 'nl-ams-02'));
        expect(state.profiles[1].server, '1.0.0.2');
        expect(state.toast, S.srvUpdated('Office'));
      });
    });

    testWidgets('back from the editor returns rather than leaving to home', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final state = _State();
        final link = _link('1.0.0.1', 'de-fra-01');
        await state.addProfiles([
          ShareLinkParser.parse(link)!,
        ], countFirstProfile: false);
        final loc = state.locations.first;
        final log = <String>[];
        final ctx = SrvEditCtx(
          index: 0,
          id: loc.id,
          label: 'Frankfurt',
          text: srvEditText(loc.profile),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ImportScreen(state: state, nav: nav(ctx, log)),
            ),
          ),
        );
        await wait(tester);
        await tester.tap(find.byIcon(Icons.chevron_left));
        await wait(tester);
        expect(log, ['back']);
      });
    });
  });
}
