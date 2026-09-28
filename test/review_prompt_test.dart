import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/app_version.dart';
import 'package:hideip_vpn/core/review_launcher.dart';
import 'package:hideip_vpn/core/review_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const policy = ReviewPromptPolicy();
  final now = DateTime.utc(2026, 9, 28, 12);

  /// A state that passes every rule, to knock one rule out at a time.
  const ready = ReviewPromptState(launches: 2, heldConnects: 2);

  bool ask(
    ReviewPromptState s, {
    DateTime? at,
    String version = '1.2.0',
    bool foreground = true,
  }) => policy.shouldPrompt(
    s,
    now: at ?? now,
    version: version,
    inForeground: foreground,
  );

  group('ReviewPromptPolicy', () {
    test('asks once every rule holds', () {
      expect(ask(ready), isTrue);
    });

    test('needs two held connections', () {
      expect(ask(const ReviewPromptState(launches: 3)), isFalse);
      expect(
        ask(const ReviewPromptState(launches: 3).onConnectionHeld()),
        isFalse,
      );
      expect(
        ask(
          const ReviewPromptState(
            launches: 3,
          ).onConnectionHeld().onConnectionHeld(),
        ),
        isTrue,
      );
    });

    test('never on the first launch, however many connections', () {
      const first = ReviewPromptState(launches: 1, heldConnects: 5);
      expect(ask(first), isFalse);
      expect(ask(first.onLaunch()), isTrue);
    });

    test('never in the background', () {
      expect(ask(ready, foreground: false), isFalse);
    });

    test('at most once per app version', () {
      final asked = ready.onPrompted(
        now.subtract(const Duration(days: 400)),
        '1.2.0',
      );
      expect(ask(asked, version: '1.2.0'), isFalse);
      expect(ask(asked, version: '1.3.0'), isTrue);
    });

    test('at most once per 120 days, across versions', () {
      final asked = ready.onPrompted(now, '1.2.0');
      expect(
        ask(asked, version: '1.3.0', at: now.add(const Duration(days: 119))),
        isFalse,
      );
      expect(
        ask(asked, version: '1.3.0', at: now.add(const Duration(days: 120))),
        isTrue,
      );
    });

    test('a clock set back before the last ask does not reopen the window', () {
      final asked = ready.onPrompted(now, '1.2.0');
      expect(
        ask(
          asked,
          version: '1.3.0',
          at: now.subtract(const Duration(days: 300)),
        ),
        isFalse,
      );
    });

    test('a recent failure keeps the prompt away for a day', () {
      final failed = ready.onFailure(now.subtract(const Duration(hours: 2)));
      expect(ask(failed), isFalse);
      expect(ask(failed, at: now.add(const Duration(hours: 22))), isTrue);
    });
  });

  group('ReviewPromptState encoding', () {
    test('round-trips every field', () {
      final s = const ReviewPromptState(
        launches: 4,
        heldConnects: 7,
      ).onPrompted(now, '1.2.0').onFailure(now.add(const Duration(minutes: 5)));
      final back = ReviewPromptState.decode(s.encode());
      expect(back.launches, 4);
      expect(back.heldConnects, 7);
      expect(back.lastPromptAt, now);
      expect(back.lastPromptVersion, '1.2.0');
      expect(back.lastFailureAt, now.add(const Duration(minutes: 5)));
    });

    test('an unreadable record starts from zero', () {
      for (final raw in [null, '', 'not json', '[1,2]', '{"launches":"x"}']) {
        final s = ReviewPromptState.decode(raw);
        expect(s.launches, 0, reason: '$raw');
        expect(s.heldConnects, 0, reason: '$raw');
        expect(s.lastPromptAt, isNull, reason: '$raw');
      }
    });
  });

  group('ReviewPrompter', () {
    late DateTime clock;
    late bool foreground;
    late bool storeAllowed;
    late int sheets;

    ReviewPrompter prompter() => ReviewPrompter(
      now: () => clock,
      inForeground: () => foreground,
      storeAllowed: () async => storeAllowed,
      requestSheet: () async => sheets++,
    );

    Future<ReviewPromptState> stored() async {
      final p = await SharedPreferences.getInstance();
      return ReviewPromptState.decode(p.getString(ReviewPrompter.prefsKey));
    }

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      clock = now;
      foreground = true;
      storeAllowed = true;
      sheets = 0;
    });

    test('asks on the second held connection of a later launch', () async {
      final r = prompter();
      await r.onLaunch();
      await r.onConnectionHeld();
      await r.onConnectionHeld();
      expect(sheets, 0, reason: 'first launch');

      final next = prompter();
      await next.onLaunch();
      await next.onConnectionHeld();
      expect(sheets, 1);
      final s = await stored();
      expect(s.heldConnects, 3);
      expect(s.lastPromptVersion, appVersion);
      expect(s.lastPromptAt, now);

      // Same version, later connections: never again.
      clock = now.add(const Duration(days: 365));
      await next.onConnectionHeld();
      expect(sheets, 1);
    });

    test('a failure just before blocks the ask', () async {
      final r = prompter();
      await r.onLaunch();
      await r.onLaunch();
      await r.onConnectionHeld();
      await r.onFailure();
      await r.onConnectionHeld();
      expect(sheets, 0);
    });

    test(
      'an install the store did not make is never asked, nor recorded',
      () async {
        storeAllowed = false;
        final r = prompter();
        await r.onLaunch();
        await r.onLaunch();
        await r.onConnectionHeld();
        await r.onConnectionHeld();
        expect(sheets, 0);
        expect((await stored()).lastPromptAt, isNull);
      },
    );

    test('in the background the count still goes up, the ask waits', () async {
      final r = prompter();
      await r.onLaunch();
      await r.onLaunch();
      foreground = false;
      await r.onConnectionHeld();
      await r.onConnectionHeld();
      expect(sheets, 0);
      expect((await stored()).heldConnects, 2);
      foreground = true;
      await r.onConnectionHeld();
      expect(sheets, 1);
    });

    test(
      'a store that throws is swallowed and still counts as asked',
      () async {
        final r = ReviewPrompter(
          now: () => clock,
          inForeground: () => true,
          storeAllowed: () async => true,
          requestSheet: () async => throw Exception('no store'),
        );
        await r.onLaunch();
        await r.onLaunch();
        await r.onConnectionHeld();
        await r.onConnectionHeld();
        expect((await stored()).lastPromptVersion, appVersion);
      },
    );

    test('events racing each other are all kept', () async {
      final r = prompter();
      await Future.wait([
        r.onLaunch(),
        r.onConnectionHeld(),
        r.onConnectionHeld(),
        r.onLaunch(),
      ]);
      final s = await stored();
      expect(s.launches, 2);
      expect(s.heldConnects, 2);
    });
  });
}
