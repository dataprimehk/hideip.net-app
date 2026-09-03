import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../strings.dart';
import 'hip.dart';
import 'settings_screen.dart' show openUrl, privacyUrl;

/// Settings -> Privacy: what "Anonymous usage counts" actually means, in
/// full, and the one switch behind it.
///
/// The switch used to sit directly in the Settings list; it still does
/// exactly the same thing, it is just a tap deeper now. A control that
/// stores require to exist and be honest about does not have to sit at the
/// same level as the things people open every day.
///
/// Pushed with a plain [MaterialPageRoute] rather than through [HipNav]: it
/// is a single leaf reached from one place, the same way the QR scanner is
/// reached from linked devices, so it carries its own [Scaffold] instead of
/// asking the shell's screen switch to learn a route it opens only once.
class SetPrivacyScreen extends StatelessWidget {
  final AppState state;
  const SetPrivacyScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final prefs = state.prefs;
        return Scaffold(
          backgroundColor: Hip.surface,
          body: SafeArea(
            child: Column(children: [
              HipNavHead(
                title: S.setPrivacySection,
                onBack: () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 18),
                      child: Text(S.setPrivacyExplain,
                          style: Hip.sans(400, Hip.bodySize,
                              color: Hip.muted, height: 1.5)),
                    ),
                    HipListGroup(children: [
                      HipListRow(
                        title: S.setPrivacyPolicy,
                        trailing: Icon(Icons.open_in_new,
                            size: 16, color: Hip.muted2),
                        onTap: () => openUrl(privacyUrl),
                      ),
                    ]),
                    const SizedBox(height: 18),
                    HipListGroup(children: [
                      HipListRow(
                        title: S.setUsage,
                        subtitle: S.setUsageSub,
                        trailing: HipToggle(
                          on: prefs.usageCounts,
                          onChanged: (v) => state
                              .updatePrefs(prefs.copyWith(usageCounts: v)),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}
