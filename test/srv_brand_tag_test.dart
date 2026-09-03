import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hideip_vpn/core/location.dart';
import 'package:hideip_vpn/core/proxy_profile.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/detail_screen.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/locations_screen.dart';
import 'package:hideip_vpn/ui/redesign/shell.dart';
import 'package:hideip_vpn/ui/strings.dart';

ProxyProfile _profile(String name, String host, {bool premium = false}) =>
    ProxyProfile(
      name: name,
      protocol: 'vless',
      server: host,
      port: 443,
      outbound: const {'type': 'vless'},
      premium: premium,
    );

Location _loc(
  String name,
  String host, {
  bool premium = false,
  int index = 0,
}) => Location.derive(_profile(name, host, premium: premium), index);

Widget _list({required Mix mix, List<Location> user = const []}) => MaterialApp(
  home: Scaffold(
    body: LocationsBody(
      mix: mix,
      advanced: false,
      subscribed: true,
      showManagedSection: true,
      managedGroup: ManagedGroup.servers,
      managed: [_loc('de-fra-01', '203.0.113.10', premium: true, index: 1)],
      userLocations: user,
      pingOf: (_) => 24,
      levelOf: (_) => 3,
      nameOf: (l) => l.city,
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
);

HipNav _nav() => HipNav(
  go: (_, [_]) {},
  back: () {},
  ctx: () => null,
  showSheet: <T>(List<Widget> children) async => null,
  openDetail: (_) {},
  openImport: () {},
  openImportWith: (_) {},
  openPaywall: ({required HipScreen from, String? locId}) {},
  claimBack: (_) {},
  releaseBack: (_) {},
);

/// The tag inside the row (or card) that carries [title].
Finder _tagBeside(String title) => find.descendant(
  of: find.ancestor(of: find.text(title), matching: find.byType(HipListRow)),
  matching: find.byType(HipBrandTag),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(1000, 4000);
    view.devicePixelRatio = 1;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  });

  testWidgets('in a mixed list only the hideip.net rows carry the tag', (
    tester,
  ) async {
    await tester.pumpWidget(
      _list(mix: Mix.mixed, user: [_loc('ch-zur-reality-03', '198.51.100.10')]),
    );
    expect(_tagBeside('Frankfurt'), findsOneWidget);
    expect(_tagBeside('Zurich'), findsNothing);
    expect(find.text(S.srvBrandTag), findsOneWidget);
    // The two groups keep their own headers: the wordmark above the fleet,
    // the label above the user's servers.
    expect(find.byType(HipWordmark), findsOneWidget);
    expect(find.text(S.dYourServers.toUpperCase()), findsOneWidget);
  });

  testWidgets(
    'with nothing of the user\'s own there is nothing to tell apart',
    (tester) async {
      await tester.pumpWidget(_list(mix: Mix.hip));
      expect(find.byType(HipBrandTag), findsNothing);
    },
  );

  testWidgets('the detail header carries the tag for a managed server only', (
    tester,
  ) async {
    Widget detail(Location loc) => MaterialApp(
      home: Scaffold(
        body: DetailScreen(state: AppState(), nav: _nav(), location: loc),
      ),
    );

    await tester.pumpWidget(
      detail(_loc('de-fra-01', '203.0.113.10', premium: true)),
    );
    await tester.pump();
    expect(find.byType(HipBrandTag), findsOneWidget);

    await tester.pumpWidget(detail(_loc('ch-zur-01', '198.51.100.10')));
    await tester.pump();
    expect(find.byType(HipBrandTag), findsNothing);
  });
}
