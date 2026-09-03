import 'package:flutter/material.dart';

import '../brand.dart';
import 'hip.dart';
import 'home_status_card.dart' show StatusTone;

/// The one line the hero folds down to while the user is searching: the
/// tone dot, the status word and the address, in the status card's own
/// colours, so the connection state stays readable above the results.
///
/// It exists because a keyboard and large text together left no room for a
/// single result under the full hero. The wordmark stays above it and the
/// search field below; everything else steps aside until the search ends.
class HeroCompactLine extends StatelessWidget {
  final StatusTone tone;
  final String status;
  final String? ip;
  const HeroCompactLine({
    super.key,
    required this.tone,
    required this.status,
    this.ip,
  });

  /// The status card's tone colours (`_sc` in home_status_card.dart). The
  /// card owns them; this line borrows them and has to be kept in step.
  static Color colorOf(StatusTone tone) => switch (tone) {
        StatusTone.off => Brand.hsl(220, 8, 60),
        StatusTone.busy => Brand.hsl(220, 95, 62),
        StatusTone.safe => Brand.hsl(152, 60, 52),
        StatusTone.risk => Brand.hsl(4, 82, 64),
      };

  @override
  Widget build(BuildContext context) {
    final sc = colorOf(tone);
    final address = ip;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Row(children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: sc, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            status.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Hip.sans(750, 10.5,
                color: sc, letterSpacing: .95, height: 1.1),
          ),
        ),
        if (address != null) ...[
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              address,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Hip.mono(650, 13,
                  color: Colors.white.withValues(alpha: .85),
                  letterSpacing: .2,
                  height: 1.15),
            ),
          ),
        ],
      ]),
    );
  }
}
