import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hideip_vpn/core/location.dart';
import 'package:hideip_vpn/core/proxy_profile.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/hip_sheet.dart';
import 'package:hideip_vpn/ui/redesign/locations_screen.dart';
import 'package:hideip_vpn/ui/strings.dart';

/// A list of swipe rows over a plain list of names, with the same Delete
/// confirmation the Locations screen asks.
class _Harness extends StatefulWidget {
  final List<String> names;
  final List<String> edited;
  final List<String> tapped;
  const _Harness({
    required this.names,
    required this.edited,
    required this.tapped,
  });

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late final List<String> _names = [...widget.names];

  Future<void> _ask(String name) async {
    final go = await showHipSheet<bool>(
      context,
      children: removeSwipedSheet(
        name: name,
        onCancel: () => Navigator.of(context).pop(false),
        onRemove: () => Navigator.of(context).pop(true),
      ),
    );
    if (go == true) setState(() => _names.remove(name));
  }

  @override
  Widget build(BuildContext context) {
    return HipSwipeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          HipListGroup(
            children: [
              for (final n in _names)
                HipSwipeRow(
                  key: ValueKey(n),
                  onEdit: () => widget.edited.add(n),
                  onDelete: () => _ask(n),
                  child: HipListRow(
                    title: n,
                    subtitle: 'Somewhere',
                    onTap: () => widget.tapped.add(n),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<({List<String> edited, List<String> tapped})> _pump(
  WidgetTester tester,
) async {
  final edited = <String>[];
  final tapped = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: _Harness(
          names: const ['Zurich', 'Milan'],
          edited: edited,
          tapped: tapped,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (edited: edited, tapped: tapped);
}

/// How far the row's content has slid to the left.
double _shift(WidgetTester tester, String name) =>
    tester.getTopLeft(find.byKey(ValueKey(name))).dx -
    tester.getTopLeft(find.text(name)).dx +
    14; // the row's own left padding

Future<void> _open(WidgetTester tester, String name) async {
  await tester.drag(find.text(name), const Offset(-200, 0));
  await tester.pumpAndSettle();
}

/// One of the two buttons behind the row named [name]; every row carries
/// its own pair, so the label alone is not enough.
Finder _button(String name, String label) =>
    find.descendant(of: find.byKey(ValueKey(name)), matching: find.text(label));

/// The row's frame, which does not move when its content slides.
Offset _rowCenter(WidgetTester tester, String name) =>
    tester.getCenter(find.byKey(ValueKey(name)));

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
  bool locked = false,
  int index = 0,
}) => Location.derive(
  _profile(name, host, premium: premium),
  index,
).copyWith(locked: locked);

void main() {
  setUp(() {
    Hip.reducedMotion = false;
    HipSwipeRow.closeOpen();
  });

  group('swipe row', () {
    testWidgets(
      'a partial swipe reveals the buttons and the row settles on them',
      (tester) async {
        final r = await _pump(tester);
        expect(_shift(tester, 'Zurich'), closeTo(0, .5));

        // Mid-drag the content follows the finger, short of the buttons.
        final g = await tester.startGesture(
          tester.getCenter(find.text('Zurich')),
        );
        await g.moveBy(const Offset(-30, 0));
        await tester.pump();
        await g.moveBy(const Offset(-70, 0));
        await tester.pump();
        final mid = _shift(tester, 'Zurich');
        expect(mid, greaterThan(40));
        expect(mid, lessThan(HipSwipeRow.actionsWidth));

        // Let go past the halfway mark: it snaps onto the two buttons.
        await g.up();
        await tester.pumpAndSettle();
        expect(_shift(tester, 'Zurich'), closeTo(HipSwipeRow.actionsWidth, .5));
        expect(HipSwipeRow.anyOpen, isTrue);

        await tester.tap(_button('Zurich', S.srvEdit));
        await tester.pumpAndSettle();
        expect(r.edited, ['Zurich']);
        expect(
          _shift(tester, 'Zurich'),
          closeTo(0, .5),
          reason: 'a button tap closes the row',
        );
      },
    );

    testWidgets('a short swipe springs back', (tester) async {
      await _pump(tester);
      final g = await tester.startGesture(
        tester.getCenter(find.text('Zurich')),
      );
      await g.moveBy(const Offset(-40, 0));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect(_shift(tester, 'Zurich'), closeTo(0, .5));
      expect(HipSwipeRow.anyOpen, isFalse);
    });

    testWidgets(
      'a swipe all the way stops on the buttons and removes nothing',
      (tester) async {
        await _pump(tester);
        await tester.drag(find.text('Zurich'), const Offset(-700, 0));
        await tester.pumpAndSettle();

        expect(_shift(tester, 'Zurich'), closeTo(HipSwipeRow.actionsWidth, .5));
        expect(find.text('Zurich'), findsOneWidget);
        expect(
          find.text(S.srvRemoveAsk),
          findsNothing,
          reason: 'no swipe, however long, asks or removes on its own',
        );
      },
    );

    testWidgets('Delete asks, Cancel keeps, Remove removes', (tester) async {
      await _pump(tester);
      await _open(tester, 'Zurich');
      await tester.tap(_button('Zurich', S.srvDelete));
      await tester.pumpAndSettle();

      // The sheet names the server and asks once.
      expect(find.text(S.srvRemoveAsk), findsOneWidget);
      expect(find.text('Zurich'), findsNWidgets(2));
      expect(find.text(S.aRemove), findsOneWidget);

      await tester.tap(find.text(S.aCancel));
      await tester.pumpAndSettle();
      expect(find.text(S.srvRemoveAsk), findsNothing);
      expect(find.text('Zurich'), findsOneWidget, reason: 'Cancel keeps it');

      await _open(tester, 'Zurich');
      await tester.tap(_button('Zurich', S.srvDelete));
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.aRemove));
      await tester.pumpAndSettle();
      expect(find.text('Zurich'), findsNothing, reason: 'Remove removes it');
      expect(find.text('Milan'), findsOneWidget);
    });

    testWidgets('one row open at a time; a tap elsewhere closes it', (
      tester,
    ) async {
      await _pump(tester);
      await _open(tester, 'Zurich');
      await _open(tester, 'Milan');
      expect(
        _shift(tester, 'Zurich'),
        closeTo(0, .5),
        reason: 'opening the second row closed the first',
      );
      expect(_shift(tester, 'Milan'), closeTo(HipSwipeRow.actionsWidth, .5));

      // Empty space under the list belongs to the area, so a tap there closes.
      await tester.tapAt(const Offset(200, 500));
      await tester.pumpAndSettle();
      expect(_shift(tester, 'Milan'), closeTo(0, .5));
      expect(HipSwipeRow.anyOpen, isFalse);
    });

    testWidgets('a closed row still taps through; an open row closes on tap', (
      tester,
    ) async {
      final r = await _pump(tester);
      await tester.tap(find.text('Zurich'));
      await tester.pump();
      expect(r.tapped, ['Zurich']);

      await _open(tester, 'Zurich');
      await tester.tapAt(_rowCenter(tester, 'Zurich'));
      await tester.pumpAndSettle();
      expect(r.tapped, ['Zurich'], reason: 'the tap closed the row instead');
      expect(_shift(tester, 'Zurich'), closeTo(0, .5));
    });

    testWidgets('scrolling closes the open row', (tester) async {
      await _pump(tester);
      await _open(tester, 'Zurich');
      await tester.drag(find.text('Milan'), const Offset(0, -60));
      await tester.pumpAndSettle();
      expect(HipSwipeRow.anyOpen, isFalse);
    });

    testWidgets('a row that is not enabled does not move', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HipListGroup(
              children: [
                HipSwipeRow(
                  key: const ValueKey('Oslo'),
                  enabled: false,
                  onEdit: () {},
                  onDelete: () {},
                  child: const HipListRow(title: 'Oslo'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.drag(find.text('Oslo'), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(_shift(tester, 'Oslo'), closeTo(0, .5));
      expect(find.text(S.srvEdit), findsNothing);
    });
  });

  group('on the Locations screen', () {
    setUp(() {
      final view = TestWidgetsFlutterBinding.ensureInitialized()
          .platformDispatcher
          .views
          .first;
      view.physicalSize = const Size(1000, 4000);
      view.devicePixelRatio = 1;
      addTearDown(view.resetPhysicalSize);
      addTearDown(view.resetDevicePixelRatio);
    });

    Widget list({bool withActions = true}) => MaterialApp(
      home: Scaffold(
        body: LocationsBody(
          mix: Mix.mixed,
          advanced: false,
          subscribed: true,
          showManagedSection: true,
          managedGroup: ManagedGroup.servers,
          managed: [_loc('de-fra-01', '203.0.113.10', premium: true, index: 1)],
          locked: [
            _loc(
              'gb-lon-01',
              '203.0.113.20',
              premium: true,
              locked: true,
              index: -1,
            ),
          ],
          userLocations: [_loc('ch-zur-reality-03', '198.51.100.10')],
          pingOf: (_) => 24,
          levelOf: (_) => 3,
          nameOf: (l) => l.city,
          subInfoOf: (_) => null,
          onBack: () {},
          onSelect: (_) {},
          onManage: (_) {},
          onEdit: withActions ? (_) {} : null,
          onDelete: withActions ? (_) {} : null,
          onLockedTap: (_, _) {},
          onShowAll: () {},
          onSeePlans: () {},
          onAdd: () {},
          onDismissWinner: () {},
          onWinner: (_) {},
        ),
      ),
    );

    Finder swipeOf(String title) =>
        find.ancestor(of: find.text(title), matching: find.byType(HipSwipeRow));

    testWidgets('only the user\'s own rows swipe', (tester) async {
      await tester.pumpWidget(list());
      expect(swipeOf('Zurich'), findsOneWidget);
      expect(
        swipeOf('Frankfurt'),
        findsNothing,
        reason: 'a managed hideip.net row does not swipe',
      );
    });

    testWidgets('without the actions nothing swipes', (tester) async {
      await tester.pumpWidget(list(withActions: false));
      expect(find.byType(HipSwipeRow), findsNothing);
    });
  });
}
