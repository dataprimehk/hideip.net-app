import 'dart:convert';

import '../../core/proxy_profile.dart';
import '../../core/wg_import.dart';

/// What the import screen is handed when it opens to edit a server rather
/// than add one. It rides on the nav stack as the import screen's context,
/// so the shell needs no new route for it and back returns to wherever the
/// edit was started.
class SrvEditCtx {
  /// Position of the profile being edited in [AppState.profiles].
  final int index;

  /// Its identity ([Location.id]) at the time, to check the position still
  /// points at the same server when the edit is saved.
  final String id;

  /// The label shown at the time, for the title and the toast.
  final String label;

  /// The config text the editor opens with.
  final String text;

  const SrvEditCtx({
    required this.index,
    required this.id,
    required this.label,
    required this.text,
  });
}

/// The text to edit a profile as: the link or file it was imported from
/// when that was kept, otherwise a rebuilt form. A WireGuard tunnel rebuilds
/// as the `[Interface]` / `[Peer]` file; anything else as a sing-box config
/// with one outbound, which the importer reads back the same way it reads a
/// provider's body.
String srvEditText(ProxyProfile p) {
  final source = p.source;
  if (source != null && source.trim().isNotEmpty) return source;
  if (p.protocol == WgImport.protocol) return WgImport.toConfig(p);
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert({
    'outbounds': [p.taggedOutbound('proxy'), ...p.extraOutbounds],
  });
}
