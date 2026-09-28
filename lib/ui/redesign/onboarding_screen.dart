import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/haptics.dart';
import '../../core/ip_lookup.dart';
import '../../state/app_state.dart';
import '../brand.dart';
import '../strings.dart';
import 'ascii/ob3_ascii.dart';
import 'hip.dart';
import 'shell.dart';

/// Onboarding v3: three beats over the ASCII rain, then the access choice.
///
/// Ported from `design/onboarding-v3/ob3.jsx`. Each beat is a headline with
/// one accented word, a sentence, and a mono proof line: the promise is made
/// concrete by a number rather than by an adjective. Beat one shows the
/// visitor's own address, so it only appears once the lookup has one; nothing
/// on this screen is ever an invented number.
///
/// The choreography is the point of the screen and it is exact: the wave
/// starts the moment the button is tapped, the old text leaves over 300 ms,
/// and the new text enters over 450 ms after a 50 ms beat, while the wave
/// front is still crossing. Everything goes through [Hip.dur], so the whole
/// thing collapses to a cut when the user asked for less motion.
///
/// Replaying the intro from Settings skips the choice screen: someone who
/// already has the app does not pick how to start again.
class OnboardingScreen extends StatefulWidget {
  final AppState state;
  final HipNav nav;
  const OnboardingScreen({super.key, required this.state, required this.nav});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

/// The progress glyphs. Decoration, not copy: the spoken form is [S.obStep].
const String _progOn = '█';
const String _progOff = '░';

/// The context that reopens onboarding on the choice screen instead of beat
/// one. The choice stamps it on itself before it opens the paywall, so both
/// ways out of the paywall (its X and the system back) land where the user
/// left, not three beats earlier.
const Map<String, Object> kObAtChoice = {'at': 'choice'};

/// How many beats come before the choice screen.
const int _beats = 3;

/// What `parseIpLookupBody` writes into [IpGeo.city] when the database has no
/// name for the range. It is the map pin's own label, not a place, so the
/// proof line treats it as an unknown city.
const String _unknownCity = 'you';

/// The tail of the beat one proof line: `{ISP} · {City}, {CC}`.
///
/// The lookup answers each of those with null on a range it does not know, so
/// the line degrades a part at a time instead of all at once: without the
/// provider it reads `{City}, {CC}`, without the country code `{City}`, and
/// with nothing known at all it is dropped rather than padded with a guess.
///
/// Top level so the degradation can be tested without a live lookup.
String? obGeoTail(IpGeo? geo) {
  if (geo == null) return null;
  final city = geo.city == _unknownCity ? null : geo.city;
  final cc = geo.cc;
  final place = city == null ? null : (cc == null ? city : '$city, $cc');
  final isp = geo.isp;
  if (isp == null) return place;
  return place == null ? isp : '$isp ${S.obTechSep} $place';
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  final Ob3AsciiController _ascii = Ob3AsciiController();

  int _step = 0;
  bool _out = false;
  bool _reduced = false;
  Timer? _timer;

  late final AnimationController _inCtrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
  late final Animation<double> _enter = CurvedAnimation(
    parent: _inCtrl,
    // 450 ms of movement after a 50 ms beat, on the design's own easing.
    curve: const Interval(0.1, 1, curve: Cubic(.22, .61, .36, 1)),
  );
  late final AnimationController _outCtrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
  late final Animation<double> _leave =
      CurvedAnimation(parent: _outCtrl, curve: Curves.ease);

  @override
  void initState() {
    super.initState();
    widget.nav.claimBack(_sysBack);
    if (_atChoice) {
      _step = _beats;
      _ascii.setGlobe(false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context) || Hip.reducedMotion;
    _inCtrl.duration = Hip.dur(const Duration(milliseconds: 500));
    _outCtrl.duration = Hip.dur(const Duration(milliseconds: 300));
    if (_inCtrl.value == 0) _playIn();
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.nav.releaseBack(_sysBack);
    _inCtrl.dispose();
    _outCtrl.dispose();
    _ascii.dispose();
    super.dispose();
  }

  /// Whether this is a replay from Settings. The context bag the nav carries
  /// is `{'replay': true}`; a bare `true` is accepted too, so an older caller
  /// keeps working.
  bool get _replay {
    final ctx = widget.nav.ctx();
    if (ctx is bool) return ctx;
    if (ctx is Map) return ctx['replay'] == true;
    return false;
  }

  /// Whether the screen was reopened on the choice (see [kObAtChoice]).
  /// Never during a replay: a replay has no choice screen to return to.
  bool get _atChoice {
    final ctx = widget.nav.ctx();
    return !_replay && ctx is Map && ctx['at'] == kObAtChoice['at'];
  }

  bool get _plans => kPlansAvailable && widget.state.plansOffered;

  void _playIn() {
    if (_reduced) {
      _inCtrl.value = 1;
      return;
    }
    _inCtrl.forward(from: 0);
  }

  /// System back walks the beats; on the first one it leaves the app.
  void _sysBack() {
    if (_step > 0) {
      _goBack();
    } else {
      SystemNavigator.pop();
    }
  }

  void _setStep(int to) {
    setState(() => _step = to);
    _ascii.setGlobe(to < _beats);
  }

  void _goBack() {
    if (_out) return;
    _outCtrl.value = 0;
    _setStep(_step - 1);
    _playIn();
  }

  /// Forward: the wave starts first, the text follows it out, and the next
  /// beat enters while the front is still crossing the screen.
  void _goForward(int to) {
    if (_out) return;
    if (_replay && to >= _beats) {
      _finish();
      return;
    }
    _ascii.wave();
    setState(() => _out = true);
    if (_reduced) {
      _outCtrl.value = 1;
    } else {
      _outCtrl.forward(from: 0);
    }
    _timer?.cancel();
    _timer = Timer(
      _reduced ? Duration.zero : Hip.dur(const Duration(milliseconds: 300)),
      () {
        if (!mounted) return;
        setState(() => _out = false);
        _outCtrl.value = 0;
        _setStep(to);
        _playIn();
      },
    );
  }

  Future<void> _finish() async {
    await widget.state.updatePrefs(widget.state.prefs.copyWith(onboarded: true));
    if (!mounted) return;
    widget.nav.go(HipScreen.home);
  }

  void _openImport() {
    Haptics.selection();
    widget.nav.openImport();
    // Leaving onboarding through import counts as having seen it.
    widget.state.updatePrefs(widget.state.prefs.copyWith(onboarded: true));
  }

  void _openPaywall() {
    Haptics.selection();
    // Re-entering onboarding only swaps its context; the stack keeps it, so
    // coming back from the paywall reopens this screen and not beat one.
    widget.nav.go(HipScreen.onboarding, kObAtChoice);
    widget.nav.openPaywall(from: HipScreen.onboarding);
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return Container(
      color: Hip.dark,
      child: Stack(children: [
        Positioned.fill(
          child: IgnorePointer(child: Ob3Ascii(controller: _ascii)),
        ),
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom),
            child: _step >= _beats ? _choice() : _beat(_step),
          ),
        ),
      ]),
    );
  }

  /// The entering and leaving transform, shared by every screen of the flow.
  Widget _animated({required Widget child}) {
    return AnimatedBuilder(
      animation: Listenable.merge([_enter, _leave]),
      builder: (context, inner) {
        final enter = _enter.value;
        final leave = _leave.value;
        final opacity = ((1 - leave) * enter).clamp(0.0, 1.0);
        final dx = _out ? -14 * leave : 18 * (1 - enter);
        return Opacity(
          opacity: opacity,
          child: Transform.translate(offset: Offset(dx, 0), child: inner),
        );
      },
      child: child,
    );
  }

  // -------------------------------------------------------------------
  // Beats
  // -------------------------------------------------------------------

  Widget _beat(int idx) {
    final last = idx == _beats - 1;
    return Column(children: [
      if (idx == 0)
        const Padding(
          padding: EdgeInsets.fromLTRB(26, 12, 26, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: HipWordmark(size: 20, color: Colors.white),
          ),
        )
      else
        HipNavHead(title: '', onBack: _goBack, onDark: true),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _animated(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _progress(idx),
                    _title(idx),
                    const SizedBox(height: 14),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 305),
                      child: Text(
                        switch (idx) {
                          0 => S.obB1Body,
                          1 => S.obB2Body,
                          _ => S.obB3Body,
                        },
                        style: Hip.sans(400, 15.5,
                            color: Colors.white.withValues(alpha: .66),
                            height: 1.55),
                      ),
                    ),
                    ?_tech(idx),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(22, 14, 22, 22),
        child: Column(children: [
          HipCta(
            switch (idx) {
              0 => S.obB1Cta,
              _ => last && _replay ? S.obDone : S.obNext,
            },
            onTap: () => _goForward(idx + 1),
          ),
          // Fixed slot; the CTA does not jump between beats that carry a
          // footnote and beats that do not.
          SizedBox(
            height: 30,
            child: idx == 0 ? const HipSubnote(S.obB1Note, onDark: true) : null,
          ),
        ]),
      ),
    ]);
  }

  /// Three mono glyphs: solid for the beats reached, hollow for the rest.
  Widget _progress(int at) {
    return Semantics(
      label: S.obStep(at + 1, _beats),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < _beats; i++)
            Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 6),
              child: Text(
                i <= at ? _progOn : _progOff,
                style: Hip.mono(
                  400,
                  13,
                  height: 1,
                  color: i == at
                      ? Brand.hsl(220, 95, 64)
                      : Colors.white.withValues(alpha: i < at ? .4 : .22),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _title(int idx) {
    final style = Hip.sans(750, 37,
        color: Colors.white, height: 1.08, letterSpacing: -1.48);
    final (text, accent, color) = switch (idx) {
      0 => (S.obB1Title, S.obB1Accent, Brand.hsl(4, 80, 64)),
      1 => (S.obB2Title, S.obB2Accent, Brand.hsl(210, 95, 66)),
      _ => (S.obB3Title, null, Colors.white),
    };
    if (accent == null) return Text(text, style: style);
    final at = text.indexOf(accent);
    if (at < 0) return Text(text, style: style);
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: text.substring(0, at)),
        TextSpan(text: accent, style: TextStyle(color: color)),
        TextSpan(text: text.substring(at + accent.length)),
      ]),
      style: style,
    );
  }

  /// The mono proof line. Beat one is the only one that needs live data, and
  /// it is left out entirely until the lookup returns: the address on this
  /// screen is the user's own or it is nothing.
  Widget? _tech(int idx) {
    final (String key, String value, Color tone, String? tail) = switch (idx) {
      0 => (
          S.obB1TechKey,
          widget.state.publicIp ?? '',
          Brand.hsl(4, 80, 68),
          obGeoTail(widget.state.userGeo),
        ),
      1 => (
          S.obB2TechKey,
          S.obB2TechIp,
          Brand.hsl(210, 95, 66),
          S.obB2TechPlace,
        ),
      _ => (
          S.obB3TechKey,
          S.obB3TechValue,
          Colors.white.withValues(alpha: .8),
          S.obB3TechPort,
        ),
    };
    if (value.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Wrap(
        spacing: 9,
        runSpacing: 5,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(key,
              style: Hip.mono(600, 10,
                  letterSpacing: .9,
                  color: Colors.white.withValues(alpha: .38))),
          Text(value, style: Hip.mono(600, 11.5, color: tone)),
          if (tail != null) ...[
            Text(S.obTechSep,
                style: Hip.mono(400, 11.5,
                    color: Colors.white.withValues(alpha: .28))),
            Text(tail,
                style: Hip.mono(500, 11.5,
                    color: Colors.white.withValues(alpha: .55))),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // Choice
  // -------------------------------------------------------------------

  Widget _choice() {
    return Column(children: [
      HipNavHead(title: '', onBack: _goBack, onDark: true),
      Expanded(
        child: _animated(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
            children: [
              Text(S.obChoiceTitle,
                  style: Hip.sans(750, 31,
                      color: Colors.white,
                      height: 1.12,
                      letterSpacing: -1.085)),
              const SizedBox(height: 12),
              Text(S.obChoiceBody,
                  style: Hip.sans(400, 15,
                      color: Colors.white.withValues(alpha: .66),
                      height: 1.55)),
              const SizedBox(height: 22),
              // The plans option only exists where a purchase can complete;
              // otherwise the screen is the import path and nothing else.
              if (_plans)
                _option(
                  icon: Icons.shield_outlined,
                  iconBg: Brand.hsl(220, 95, 60, .18),
                  iconFg: Brand.hsl(220, 95, 70),
                  title: S.obChoiceTrial,
                  sub: S.obChoiceTrialSub,
                  onTap: _openPaywall,
                ),
              _option(
                icon: Icons.qr_code_2,
                iconBg: Brand.hsl(152, 60, 46, .16),
                iconFg: Brand.hsl(152, 60, 58),
                title: S.obChoiceImport,
                sub: S.obChoiceImportSub,
                onTap: _openImport,
              ),
              const HipSubnote(S.obChoiceNote, onDark: true),
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(22, 14, 22, 22),
        child: Column(children: [
          HipCta(S.obExplore, obGhost: true, onTap: _finish),
          const SizedBox(height: 30),
        ]),
      ),
    ]);
  }

  Widget _option({
    required IconData icon,
    required Color iconBg,
    required Color iconFg,
    required String title,
    required String sub,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Hip.radius),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Brand.hsl(222, 20, 11, .94),
              border: Border.all(
                  color: Colors.white.withValues(alpha: .15), width: 1.5),
              borderRadius: BorderRadius.circular(Hip.radius),
            ),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, size: 22, color: iconFg),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: Hip.sans(650, 15.5,
                              color: Colors.white, letterSpacing: -.155)),
                      const SizedBox(height: 2),
                      Text(sub,
                          style: Hip.sans(400, 12.5,
                              color: Colors.white.withValues(alpha: .55),
                              height: 1.4)),
                    ]),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right,
                  size: 17, color: Colors.white.withValues(alpha: .35)),
            ]),
          ),
        ),
      ),
    );
  }
}
