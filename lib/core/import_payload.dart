import 'share_link_parser.dart';
import 'wg_import.dart';

/// What a piece of import text is. The three shapes the importer knows how to
/// turn into servers: a single share link, a subscription URL to fetch, or a
/// subscription body pasted straight in.
enum ImportPayloadKind { shareLink, subscriptionUrl, subscriptionBlob }

/// A payload the importer can act on, with the scheme it was recognized by.
class ImportPayload {
  final ImportPayloadKind kind;

  /// Lowercase scheme of a link payload, null for a pasted body.
  final String? scheme;

  const ImportPayload(this.kind, [this.scheme]);

  @override
  bool operator ==(Object other) =>
      other is ImportPayload && other.kind == kind && other.scheme == scheme;

  @override
  int get hashCode => Object.hash(kind, scheme);

  @override
  String toString() => 'ImportPayload(${kind.name}, $scheme)';
}

final RegExp _schemeRe = RegExp(r'^([a-z0-9]+)://', caseSensitive: false);
final RegExp _blobRe = RegExp(r'^[A-Za-z0-9+/=_\-]{40,}$');

/// Classifies import text, or returns null when nothing here is importable.
///
/// This is the whitelist, and it is deliberately the only one: text typed on
/// the import screen and a payload carried by a `hideip://` or app link are
/// judged by the same rule, so a link cannot slip a scheme past the importer
/// that a person pasting the same string could not. A scheme outside
/// [ShareLinkParser.supportedSchemes] is refused here rather than deeper in,
/// where an `intent:` or `file:` payload would already have been handed to
/// something that tries to make sense of it.
///
/// `http(s)` reads as a subscription to fetch rather than as the HTTP proxy
/// the parser can also build from it: that is what providers send, and the
/// distinction is only reachable from the subscription result anyway.
ImportPayload? classifyImportPayload(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  // A WireGuard file is multi-line but describes exactly one server, so it is
  // judged before the rule below or it would be read as a provider's body and
  // fail with an error about links.
  if (WgImport.looksLikeConfig(text)) {
    return const ImportPayload(ImportPayloadKind.shareLink, 'wireguard');
  }

  // More than one line is a provider's body even when the first line is a
  // link: read as a single link, everything after the first server would be
  // dropped without a word.
  if (text.contains('\n')) {
    return const ImportPayload(ImportPayloadKind.subscriptionBlob);
  }

  // A sing-box config saved minified is one line and carries no scheme, so
  // neither rule above catches it. Opened through the file picker it is the
  // same body a provider would send, and the subscription parser already
  // reads an `outbounds` array; without this branch it is refused outright.
  if (text.startsWith('{') && (text.contains('"outbounds"') || text.contains('"endpoints"'))) {
    return const ImportPayload(ImportPayloadKind.subscriptionBlob);
  }

  final match = _schemeRe.firstMatch(text);
  if (match != null) {
    final scheme = match.group(1)!.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      return ImportPayload(ImportPayloadKind.subscriptionUrl, scheme);
    }
    if (ShareLinkParser.supportedSchemes.contains(scheme)) {
      return ImportPayload(ImportPayloadKind.shareLink, scheme);
    }
    return null;
  }

  // No scheme and one line: a base64 subscription body, or nothing usable.
  return _blobRe.hasMatch(text)
      ? const ImportPayload(ImportPayloadKind.subscriptionBlob)
      : null;
}
