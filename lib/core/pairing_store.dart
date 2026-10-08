/// Where an asking device keeps its open request across restarts.
///
/// The poll secret and, once approved, the device token are secrets, so the
/// whole record lives in [SecretPrefs]. A write there is read back and
/// compared before it returns, which is what lets the device tell the
/// server "stored" only after the credentials really are.
library;

import 'dart:convert';

import 'pairing.dart';
import 'secret_prefs.dart';

/// An open request and, once collected, its answer.
class PendingLink {
  final LinkTicket ticket;

  /// The device was on another account when it asked, and the user agreed
  /// to move. That account stays in force until the new one is stored and
  /// acknowledged.
  final bool switching;

  /// The collected answer, stored before the server is told it arrived.
  final LinkHandoff? handoff;

  const PendingLink({
    required this.ticket,
    this.switching = false,
    this.handoff,
  });

  PendingLink withHandoff(LinkHandoff next) =>
      PendingLink(ticket: ticket, switching: switching, handoff: next);

  Map<String, dynamic> toJson() => {
    'ticket': ticket.toJson(),
    'switching': switching,
    'handoff': ?handoff?.toJson(),
  };

  static PendingLink? fromJson(Object? json) {
    if (json is! Map) return null;
    final ticket = LinkTicket.fromJson(json['ticket']);
    if (ticket == null) return null;
    final raw = json['handoff'];
    return PendingLink(
      ticket: ticket,
      switching: json['switching'] == true,
      handoff: raw == null ? null : LinkHandoff.fromPollJson(raw),
    );
  }
}

class PendingLinkStore {
  const PendingLinkStore();

  static const key = 'pairing_request_v2';

  Future<PendingLink?> load() async {
    final raw = await SecretPrefs.readString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return PendingLink.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// Throws when the record could not be written and read back.
  Future<void> save(PendingLink link) =>
      SecretPrefs.writeString(key, jsonEncode(link.toJson()));

  Future<void> clear() => SecretPrefs.deleteString(key);
}
