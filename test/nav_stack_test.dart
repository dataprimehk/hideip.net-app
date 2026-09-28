import 'package:flutter_test/flutter_test.dart';

import 'package:hideip_vpn/ui/redesign/onboarding_screen.dart';
import 'package:hideip_vpn/ui/redesign/shell.dart';

void main() {
  test(
    'account navigation follows the feature flag without losing context',
    () {
      final nav = HipNavStack();
      nav.go(HipScreen.premium, 'manage');
      nav.go(HipScreen.account);
      expect(
        nav.screen,
        kAccountSignIn ? HipScreen.account : HipScreen.premium,
      );
      expect(nav.depth, kAccountSignIn ? 2 : 1);
      if (!kAccountSignIn) expect(nav.ctx, 'manage');
      nav.go(HipScreen.paywall);
      expect(nav.screen, HipScreen.paywall);
    },
  );

  test('back returns to where the user came from, not up a fixed hierarchy',
      () {
    final nav = HipNavStack();
    nav.go(HipScreen.settings);
    nav.go(HipScreen.detail);
    expect(nav.screen, HipScreen.detail);

    // The old shell always sent detail back to Locations. Reaching it from
    // Settings has to come back to Settings.
    nav.back();
    expect(nav.screen, HipScreen.settings);
    nav.back();
    expect(nav.screen, HipScreen.home);
  });

  test('the same screen is never stacked twice', () {
    final nav = HipNavStack();
    nav.go(HipScreen.locations);
    nav.go(HipScreen.detail);
    nav.go(HipScreen.locations); // back to a screen already on the stack
    // Locations left the stack before the current screen was pushed, so it
    // is on the stack once at most, and back cannot loop between the two.
    expect(nav.entries.map((e) => e.screen), [HipScreen.home, HipScreen.detail]);

    nav.back();
    expect(nav.screen, HipScreen.detail);
    nav.back();
    expect(nav.screen, HipScreen.home);
    expect(nav.depth, 0);
  });

  test('arriving home collapses the stack', () {
    final nav = HipNavStack();
    nav.go(HipScreen.locations);
    nav.go(HipScreen.import);
    expect(nav.depth, 2);

    // A finished import lands on Home; there is nothing to walk back into.
    nav.go(HipScreen.home);
    expect(nav.depth, 0);
    expect(nav.backTarget, isNull);
  });

  test('context comes back with the screen it belonged to', () {
    final nav = HipNavStack();
    nav.go(HipScreen.locations, 'group:hideip');
    expect(nav.ctx, 'group:hideip');

    nav.go(HipScreen.paywall, 'loc:198.51.100.24:443');
    expect(nav.ctx, 'loc:198.51.100.24:443');

    nav.back();
    expect(nav.screen, HipScreen.locations);
    expect(nav.ctx, 'group:hideip');
  });

  test('re-entering the current screen only swaps its context', () {
    final nav = HipNavStack();
    nav.go(HipScreen.locations, 'a');
    final depth = nav.depth;
    nav.go(HipScreen.locations, 'b');
    expect(nav.depth, depth);
    expect(nav.ctx, 'b');
  });

  test('the root screens hand back to the system', () {
    final nav = HipNavStack();
    expect(nav.backTarget, isNull);

    final onboarding = HipNavStack(screen: HipScreen.onboarding);
    expect(onboarding.backTarget, isNull);

    nav.go(HipScreen.settings);
    expect(nav.backTarget, HipScreen.home);
  });

  test('back from a screen reached without a push lands on home', () {
    // A deep link can drop the user straight onto a sub-screen.
    final nav = HipNavStack(screen: HipScreen.import);
    expect(nav.backTarget, HipScreen.home);
    nav.back();
    expect(nav.screen, HipScreen.home);
  });

  test('closing the paywall from onboarding reopens the choice screen', () {
    // First run: onboarding is the root, with no context.
    final nav = HipNavStack(screen: HipScreen.onboarding);
    // The choice stamps itself before it opens the offer ...
    nav.go(HipScreen.onboarding, kObAtChoice);
    nav.go(HipScreen.paywall);
    expect(nav.backTarget, HipScreen.onboarding);

    // ... so the way back carries it, and the stack is empty again.
    nav.back();
    expect(nav.screen, HipScreen.onboarding);
    expect(nav.ctx, kObAtChoice);
    expect(nav.depth, 0);
  });
}
