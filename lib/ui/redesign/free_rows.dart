import 'package:flutter/material.dart';

import '../../core/location.dart';
import '../../state/app_state.dart';
import '../strings.dart';
import 'detail_screen.dart' show rowPlace, serverLabel;
import 'hip.dart';

/// What the free location has to show right now (C8, PLAN-FREE A1/A2).
///
/// Before the key: the rows the signed catalog names, or one plain row when
/// it names none; tapping one asks for the key. After it: the free servers
/// themselves, which are ordinary servers in the list from then on. Nothing
/// at all when the server has the free location off or cannot be asked, or
/// while Premium is on. An account number with no time left is not Premium:
/// it sees the free location like any device without Premium (AF-23).
@immutable
class FreeOffer {
  /// Free servers this install holds: real, selectable servers.
  final List<Location> held;

  /// Catalog rows to offer before the key is asked for.
  final List<Location> offered;

  /// One plain "Free location" row: offered, but no catalog row to name.
  final bool plain;

  /// Speed per user in Mbit/s, 0 when the server sets no limit.
  final int speedMbps;

  /// The key is being asked for.
  final bool busy;

  const FreeOffer({
    this.held = const [],
    this.offered = const [],
    this.plain = false,
    this.speedMbps = 0,
    this.busy = false,
  });

  static const none = FreeOffer();

  factory FreeOffer.of(AppState state) {
    final held = state.freeHeldLocations;
    final offered = held.isEmpty ? state.freeLocations : const <Location>[];
    return FreeOffer(
      held: held,
      offered: offered,
      plain: held.isEmpty && offered.isEmpty && state.freeOffered,
      speedMbps: state.freeInfo.speedMbps,
      busy: state.freeBusy,
    );
  }

  /// Anything to show.
  bool get any => held.isNotEmpty || offered.isNotEmpty || plain;

  /// Rows that still need the key before they connect.
  bool get beforeKey => held.isEmpty && (offered.isNotEmpty || plain);
}

/// A free row offered before the key exists: [location] from the catalog,
/// or the one plain row when it is null. Open, marked Free, with its speed;
/// never a lock and never the paywall.
class FreeOfferRow extends StatelessWidget {
  final Location? location;
  final int speedMbps;
  final bool busy;
  final VoidCallback? onTap;

  const FreeOfferRow({
    super.key,
    this.location,
    required this.speedMbps,
    this.busy = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l = location;
    final String subtitle;
    if (busy) {
      subtitle = S.freeGetting;
    } else if (l != null) {
      subtitle = S.freeSub(rowPlace(l), speedMbps);
    } else {
      subtitle = speedMbps > 0 ? S.freeSpeed(speedMbps) : S.freeNoAccount;
    }
    return HipListRow(
      leading: l == null
          ? HipFlag(
              cc: '',
              child: Icon(Icons.public, size: 19, color: Hip.blueDeep),
            )
          : HipFlag(cc: l.cc),
      title: l == null ? S.freeLocation : serverLabel(l),
      titleBadge: HipBadge.ok(S.freeTag),
      subtitle: subtitle,
      trailing: busy
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Hip.muted2,
              ),
            )
          : Icon(Icons.chevron_right, size: 17, color: Hip.muted2),
      onTap: busy ? null : onTap,
    );
  }
}

/// The badge a free server carries in any list.
Widget freeBadge() => HipBadge.ok(S.freeTag);
