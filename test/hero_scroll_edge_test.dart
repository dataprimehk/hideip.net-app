import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/ui/redesign/hero_scroll_edge.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';

void main() {
  setUp(() => Hip.reducedMotion = true);
  tearDown(() => Hip.reducedMotion = false);

  Widget host(ScrollController c, {required int rows}) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: HeroScrollEdge(
              controller: c,
              child: ListView.builder(
                controller: c,
                itemCount: rows,
                itemExtent: 60,
                itemBuilder: (_, i) => Text('row $i'),
              ),
            ),
          ),
        ),
      );

  double fadeOpacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

  testWidgets('the fade shows while the list continues below the edge, '
      'and goes once the end is reached', (tester) async {
    final c = ScrollController();
    addTearDown(c.dispose);
    await tester.pumpWidget(host(c, rows: 20));
    await tester.pump();
    expect(fadeOpacity(tester), 1);

    c.jumpTo(c.position.maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(fadeOpacity(tester), 0);

    c.jumpTo(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(fadeOpacity(tester), 1);
  });

  testWidgets('a list that fits shows no fade', (tester) async {
    final c = ScrollController();
    addTearDown(c.dispose);
    await tester.pumpWidget(host(c, rows: 3));
    await tester.pump();
    expect(fadeOpacity(tester), 0);
  });

  testWidgets('the fade takes no touches', (tester) async {
    final c = ScrollController();
    addTearDown(c.dispose);
    await tester.pumpWidget(host(c, rows: 20));
    await tester.pump();
    // A tap on the row under the fade reaches the row, not the fade.
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 300,
          child: HeroScrollEdge(
            controller: c,
            child: ListView.builder(
              controller: c,
              itemCount: 20,
              itemExtent: 60,
              itemBuilder: (_, i) => GestureDetector(
                onTap: () => tapped = i == 4,
                child: Text('row $i'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(fadeOpacity(tester), 1);
    await tester.tapAt(const Offset(20, 290));
    expect(tapped, isTrue);
  });
}
