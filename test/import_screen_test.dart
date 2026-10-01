import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/camera_permission.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/import_screen.dart';
import 'package:hideip_vpn/ui/redesign/shell.dart';
import 'package:hideip_vpn/ui/strings.dart';

const _link =
    'vless://11111111-2222-3333-4444-555555555555@203.0.113.77:443'
    '?security=reality&sni=cdn.example.com#ch-zur-reality-03';

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

Future<void> _pump(WidgetTester tester, {ImportHooks? hooks}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ImportScreen(
          state: AppState(),
          nav: _nav(),
          hooks: hooks ?? const ImportHooks(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// A stand-in for the camera preview: a button that reports one code.
Widget _fakeReader(
  BuildContext context, {
  required ValueChanged<String> onCode,
}) => Center(
  child: TextButton(onPressed: () => onCode(_link), child: const Text('fire')),
);

void main() {
  setUp(() {
    // The scanline and the disclosure chevron loop and animate; frozen, every
    // pumpAndSettle below can actually settle.
    Hip.reducedMotion = true;
  });
  tearDown(() => Hip.reducedMotion = false);

  testWidgets('offers scan, paste and open file, in that order', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text(S.e1ScanQr), findsOneWidget);
    expect(find.text(S.e1Paste), findsOneWidget);
    expect(find.text(S.e1OpenFile), findsOneWidget);

    final scan = tester.getCenter(find.text(S.e1ScanQr));
    final paste = tester.getCenter(find.text(S.e1Paste));
    final file = tester.getCenter(find.text(S.e1OpenFile));
    expect(scan.dx, lessThan(paste.dx));
    expect(paste.dx, lessThan(file.dx));
  });

  testWidgets('Which formats? opens and lists what the parser reads', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.textContaining(S.e1Formats), findsNothing);
    await tester.tap(find.text(S.e1WhichFormats));
    await tester.pumpAndSettle();
    expect(find.textContaining(S.e1Formats), findsOneWidget);
    // The name clean-up note moved here from Locations.
    expect(find.textContaining(S.dNamesCleaned), findsOneWidget);
  });

  testWidgets('unknown input keeps Import disabled and blames nobody', (
    tester,
  ) async {
    await _pump(tester);

    await tester.enterText(find.byType(TextField), 'my friend sent me this');
    await tester.pumpAndSettle();

    expect(find.text(S.e2Unknown), findsOneWidget);
    final cta = tester.widget<HipCta>(find.widgetWithText(HipCta, S.eImport));
    expect(cta.onTap, isNull);

    await tester.enterText(find.byType(TextField), _link);
    await tester.pumpAndSettle();
    expect(find.text(S.e2Detected(S.tVless)), findsOneWidget);
    expect(
      tester.widget<HipCta>(find.widgetWithText(HipCta, S.eImport)).onTap,
      isNotNull,
    );
  });

  testWidgets('the QR popup asks first, then scans into the field only', (
    tester,
  ) async {
    await _pump(
      tester,
      hooks: ImportHooks(
        camStatus: () async => CamPerm.ask,
        camRequest: () async => CamPerm.granted,
        reader: _fakeReader,
      ),
    );

    await tester.tap(find.text(S.e1ScanQr));
    await tester.pumpAndSettle();
    expect(find.text(S.e7Head), findsOneWidget);
    expect(find.text(S.e7Body), findsOneWidget);

    await tester.tap(find.text(S.e7Allow));
    await tester.pumpAndSettle();
    expect(find.text(S.e9Hint), findsOneWidget);

    await tester.tap(find.text('fire'));
    await tester.pumpAndSettle();

    // The code lands in the same field a paste would fill, the popup is gone,
    // and nothing was imported: the parse steps never ran.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, _link);
    expect(find.text(S.e9Hint), findsNothing);
    expect(find.text(S.e5DetectProtocol), findsNothing);
    expect(
      tester.widget<HipCta>(find.widgetWithText(HipCta, S.eImport)).onTap,
      isNotNull,
    );
  });

  testWidgets('a denied camera offers settings and a way back to pasting', (
    tester,
  ) async {
    await _pump(
      tester,
      hooks: ImportHooks(
        camStatus: () async => CamPerm.denied,
        reader: _fakeReader,
      ),
    );

    await tester.tap(find.text(S.e1ScanQr));
    await tester.pumpAndSettle();
    expect(find.text(S.e8Head), findsOneWidget);
    expect(find.text(S.aOpenSettings), findsOneWidget);
    expect(find.text(S.e8PasteInstead), findsOneWidget);
  });

  testWidgets('a refused paste offers the manual way instead of nothing', (
    tester,
  ) async {
    await _pump(
      tester,
      hooks: ImportHooks(
        clipboardHasText: () async => true,
        clipboardText: () async => null,
      ),
    );

    await tester.tap(find.text(S.e1Paste));
    await tester.pumpAndSettle();

    expect(find.text(S.e11PasteDenied), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('an empty clipboard says so rather than blaming a permission', (
    tester,
  ) async {
    await _pump(
      tester,
      hooks: ImportHooks(
        clipboardHasText: () async => false,
        clipboardText: () async => null,
      ),
    );

    await tester.tap(find.text(S.e1Paste));
    await tester.pumpAndSettle();

    expect(find.text(S.eClipboardEmpty), findsOneWidget);
    expect(find.text(S.e11PasteDenied), findsNothing);
  });
}
