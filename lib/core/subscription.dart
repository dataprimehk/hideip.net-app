import 'dart:convert';
import 'dart:isolate';

import 'package:yaml/yaml.dart';

import 'clash_parser.dart';
import 'proxy_profile.dart';
import 'safe_http.dart';
import 'share_link_parser.dart';
import 'singbox_json_parser.dart';

/// Decodes a subscription payload into a list of [ProxyProfile]s.
///
/// A subscription body may be any of the formats seller panels serve:
///  1. a sing-box JSON object with an `outbounds` array,
///  2. a Clash-family YAML document with a `proxies:` list,
///  3. a base64 blob whose decoded text is newline-separated share links, or
///  4. plain newline-separated share links.
///
/// Detection runs in that order. Lines/entries that fail to parse are collected
/// in [SubscriptionResult.errors] rather than aborting the whole set.
class Subscription {
  static const int maxProfiles = 500;
  static const int maxEntries = 1000;
  static const int maxErrors = 100;
  static const int maxNesting = 32;
  static const int maxFields = 10000;
  static const int maxStringLength = 64 * 1024;

  /// Parse raw subscription body text (already fetched over HTTP, or pasted).
  static SubscriptionResult parse(String body) {
    _checkBodySize(body);
    final trimmed = body.trim();
    _checkBracketNesting(trimmed);

    // 1. sing-box JSON: a JSON object carrying an `outbounds` array.
    final json = _tryJsonOutbounds(trimmed);
    if (json != null) {
      final errors = <String>[];
      final profiles = SingboxJsonParser.parse(json, errors: errors);
      return _result(profiles, errors);
    }

    // 2. Clash YAML: a mapping with a top-level `proxies:` list. Only attempt
    // YAML when the body is not a link list / base64 blob (those parse as YAML
    // scalars and would waste work).
    final yaml = _tryClashYaml(trimmed);
    if (yaml != null) {
      final errors = <String>[];
      final profiles = ClashParser.parse(yaml, errors: errors);
      return _result(profiles, errors);
    }

    // 3 + 4. base64 blob or plain link list (the original fallback path).
    final text = _maybeBase64Decode(trimmed);
    final lines = const LineSplitter().convert(text);

    final profiles = <ProxyProfile>[];
    final errors = <String>[];
    final unsupported = <String, int>{};
    var placeholders = 0;
    if (lines.length > maxEntries) {
      throw const SubscriptionLimitException(
        'The subscription has too many entries.',
      );
    }
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final l = line.trim();
      if (l.isEmpty) continue;
      try {
        if (ShareLinkParser.isPanelPlaceholder(l)) {
          placeholders++;
          continue;
        }
        final p = ShareLinkParser.parse(l);
        if (p != null) {
          profiles.add(p);
          if (profiles.length > maxProfiles) {
            throw const SubscriptionLimitException(
              'The subscription has too many profiles.',
            );
          }
        }
      } catch (e) {
        if (e is SubscriptionLimitException) rethrow;
        if (e is UnsupportedProfileException) {
          unsupported.update(e.feature, (n) => n + 1, ifAbsent: () => 1);
        }
        if (errors.length < maxErrors) {
          errors.add(e is UnsupportedProfileException
              ? 'Line ${index + 1} -> ${e.message}'
              : 'Line ${index + 1} -> Could not parse profile.');
        }
      }
    }
    return SubscriptionResult(profiles: profiles, errors: errors, unsupported: unsupported, placeholders: placeholders);
  }

  /// Parsing can involve third-party JSON/YAML. Keep that work off the UI
  /// isolate after the cheap byte and nesting guards have run.
  static Future<SubscriptionResult> parseAsync(String body) async {
    _checkBodySize(body);
    _checkBracketNesting(body);
    return Isolate.run(() => parse(body));
  }

  /// Returns the decoded JSON object when [body] is a sing-box config with an
  /// `outbounds` array, else null.
  static Map<String, dynamic>? _tryJsonOutbounds(String body) {
    if (!body.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && (decoded['outbounds'] is List || decoded['endpoints'] is List)) {
        _validateTree(decoded);
        return decoded;
      }
    } catch (error) {
      if (error is SubscriptionLimitException) rethrow;
      // not JSON; fall through
    }
    return null;
  }

  /// Returns the parsed YAML mapping when [body] is a Clash document with a
  /// top-level `proxies:` list, else null.
  static Map<dynamic, dynamic>? _tryClashYaml(String body) {
    // A link list / base64 blob is not YAML we care about; skip cheaply.
    if (!body.contains('proxies:')) return null;
    _checkYamlIndentation(body);
    try {
      final doc = loadYaml(body);
      if (doc is Map && doc['proxies'] is List) {
        _validateTree(doc);
        // Convert YamlMap/YamlList into plain Dart maps/lists so downstream
        // code never depends on the yaml package types.
        return _plain(doc) as Map<dynamic, dynamic>;
      }
    } catch (error) {
      if (error is SubscriptionLimitException) rethrow;
      // not YAML; fall through
    }
    return null;
  }

  /// Deep-converts YamlMap/YamlList (and scalars) into plain Map/List/values.
  static Object? _plain(Object? node) {
    if (node is YamlMap) {
      return node.map((k, v) => MapEntry(_plain(k), _plain(v)));
    }
    if (node is YamlList) {
      return node.map(_plain).toList();
    }
    return node;
  }

  /// A whole-body base64 blob has no "://" and decodes to text containing one.
  /// If decoding doesn't reveal links, treat the body as plain text.
  static String _maybeBase64Decode(String body) {
    if (body.contains('://')) return body; // already plain links
    try {
      final bytes = base64.decode(_padBase64(body));
      if (bytes.length > subscriptionMaxBytes) {
        throw const SubscriptionLimitException(
          'The decoded subscription is too large.',
        );
      }
      final decoded = utf8.decode(bytes);
      if (decoded.contains('://')) return decoded;
    } catch (error) {
      if (error is SubscriptionLimitException) rethrow;
      // not base64; fall through
    }
    return body;
  }

  static String _padBase64(String s) {
    var out = s
        .replaceAll('-', '+')
        .replaceAll('_', '/')
        .replaceAll('\n', '')
        .replaceAll('\r', '');
    final mod = out.length % 4;
    if (mod > 0) out += '=' * (4 - mod);
    return out;
  }

  static SubscriptionResult _result(
    List<ProxyProfile> profiles,
    List<String> errors,
  ) {
    if (profiles.length > maxProfiles) {
      throw const SubscriptionLimitException(
        'The subscription has too many profiles.',
      );
    }
    return SubscriptionResult(
      profiles: profiles,
      errors: errors.take(maxErrors).map(_shortError).toList(growable: false),
    );
  }

  static void _checkBodySize(String body) {
    if (body.length > subscriptionMaxBytes ||
        utf8.encode(body).length > subscriptionMaxBytes) {
      throw const SubscriptionLimitException('The subscription is too large.');
    }
  }

  static void _checkBracketNesting(String body) {
    var depth = 0;
    var quoted = false;
    var escaped = false;
    for (final code in body.codeUnits) {
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (code == 0x5c) {
          escaped = true;
        } else if (code == 0x22) {
          quoted = false;
        }
        continue;
      }
      if (code == 0x22) {
        quoted = true;
      } else if (code == 0x7b || code == 0x5b) {
        depth++;
        if (depth > maxNesting) {
          throw const SubscriptionLimitException(
            'The subscription is nested too deeply.',
          );
        }
      } else if ((code == 0x7d || code == 0x5d) && depth > 0) {
        depth--;
      }
    }
  }

  static void _checkYamlIndentation(String body) {
    for (final line in const LineSplitter().convert(body)) {
      var spaces = 0;
      while (spaces < line.length && line.codeUnitAt(spaces) == 0x20) {
        spaces++;
      }
      if (spaces > maxNesting * 2) {
        throw const SubscriptionLimitException(
          'The subscription is nested too deeply.',
        );
      }
    }
  }

  static void _validateTree(Object? root) {
    var fields = 0;
    final path = <Object>{};

    void visit(Object? value, int depth) {
      if (depth > maxNesting) {
        throw const SubscriptionLimitException(
          'The subscription is nested too deeply.',
        );
      }
      if (value is String) {
        if (value.length > maxStringLength) {
          throw const SubscriptionLimitException(
            'A subscription field is too large.',
          );
        }
        return;
      }
      if (value is Map) {
        if (value.length > maxEntries || !path.add(value)) {
          throw const SubscriptionLimitException(
            'The subscription structure is too complex.',
          );
        }
        fields += value.length;
        if (fields > maxFields) {
          throw const SubscriptionLimitException(
            'The subscription has too many fields.',
          );
        }
        for (final entry in value.entries) {
          visit(entry.key, depth + 1);
          visit(entry.value, depth + 1);
        }
        path.remove(value);
        return;
      }
      if (value is List) {
        if (value.length > maxEntries || !path.add(value)) {
          throw const SubscriptionLimitException(
            'The subscription structure is too complex.',
          );
        }
        fields += value.length;
        if (fields > maxFields) {
          throw const SubscriptionLimitException(
            'The subscription has too many fields.',
          );
        }
        for (final item in value) {
          visit(item, depth + 1);
        }
        path.remove(value);
      }
    }

    visit(root, 0);
  }

  static String _shortError(String value) =>
      value.length <= 256 ? value : '${value.substring(0, 256)}...';
}

class SubscriptionLimitException implements Exception {
  final String message;
  const SubscriptionLimitException(this.message);

  @override
  String toString() => message;
}

class SubscriptionResult {
  final List<ProxyProfile> profiles;
  final List<String> errors;
  final Map<String, int> unsupported;
  final int placeholders;
  const SubscriptionResult({required this.profiles, required this.errors, this.unsupported = const {}, this.placeholders = 0});

  bool get isEmpty => profiles.isEmpty;
}
