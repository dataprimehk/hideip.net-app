import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

const int subscriptionMaxBytes = 2 * 1024 * 1024;

/// A small, bounded response used for untrusted subscription and catalog GETs.
class SafeHttpResponse {
  final int statusCode;
  final Map<String, String> headers;
  final Uint8List bodyBytes;

  const SafeHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
  });

  String get body {
    try {
      return utf8.decode(bodyBytes);
    } on FormatException {
      // Some long-lived subscription panels still omit a charset and emit
      // Latin-1. Keep compatibility without accepting malformed UTF-8 as if
      // it were valid UTF-8.
      return latin1.decode(bodyBytes);
    }
  }
}

class SafeHttpException implements Exception {
  final String message;
  const SafeHttpException(this.message);

  @override
  String toString() => message;
}

typedef HostResolver = Future<List<InternetAddress>> Function(String host);

/// Fetches untrusted remote configuration without letting the URL become an
/// SSRF primitive. Production requests resolve first, reject every non-public
/// answer, then pin the TLS socket to one of the addresses that was checked.
/// Redirects repeat the full check and response bodies are streamed into a
/// hard byte ceiling.
class SafeHttpFetcher {
  final http.Client? _testClient;
  final HostResolver _resolver;

  SafeHttpFetcher({HostResolver? resolver})
    : _testClient = null,
      _resolver = resolver ?? InternetAddress.lookup;

  /// Only dependency-injected unit tests use an ordinary client. The URL and
  /// response policies still apply; DNS pinning is exercised by production.
  SafeHttpFetcher.forTesting(http.Client client, {HostResolver? resolver})
    : _testClient = client,
      _resolver = resolver ?? InternetAddress.lookup;

  Future<SafeHttpResponse> get(
    Uri initial, {
    Map<String, String> headers = const {},
    int maxBytes = subscriptionMaxBytes,
    Duration timeout = const Duration(seconds: 20),
    int maxRedirects = 4,
  }) async {
    var uri = _validatedUri(initial);
    for (var redirect = 0; ; redirect++) {
      http.Client? ownedClient;
      final client =
          _testClient ??
          (ownedClient = await _pinnedClient(uri, timeout: timeout));
      try {
        final request = http.Request('GET', uri)
          ..followRedirects = false
          ..persistentConnection = false
          ..headers.addAll({
            for (final e in headers.entries)
              if (!const {'x-hwid', 'x-device-os', 'x-ver-os', 'x-device-model'}.contains(e.key.toLowerCase()) ||
                  (!isHideipHost(uri.host) && uri.origin == initial.origin))
                e.key: e.value,
          })
          ..headers['Accept-Encoding'] = 'identity';
        final response = await client.send(request).timeout(timeout);

        if (_isRedirect(response.statusCode)) {
          await response.stream.drain<void>();
          if (redirect >= maxRedirects) {
            throw const SafeHttpException('Too many redirects.');
          }
          final location = response.headers['location'];
          if (location == null || location.isEmpty) {
            throw const SafeHttpException('The redirect has no destination.');
          }
          uri = _validatedUri(uri.resolve(location));
          continue;
        }

        final encoding = response.headers['content-encoding']
            ?.trim()
            .toLowerCase();
        if (encoding != null && encoding.isNotEmpty && encoding != 'identity') {
          await response.stream.drain<void>();
          throw const SafeHttpException(
            'Compressed subscriptions are not accepted.',
          );
        }
        final declared = int.tryParse(response.headers['content-length'] ?? '');
        if (declared != null && declared > maxBytes) {
          await response.stream.drain<void>();
          throw SafeHttpException('The response exceeds $maxBytes bytes.');
        }

        final bytes = BytesBuilder(copy: false);
        var length = 0;
        await for (final chunk in response.stream.timeout(timeout)) {
          length += chunk.length;
          if (length > maxBytes) {
            throw SafeHttpException('The response exceeds $maxBytes bytes.');
          }
          bytes.add(chunk);
        }
        return SafeHttpResponse(
          statusCode: response.statusCode,
          headers: response.headers,
          bodyBytes: bytes.takeBytes(),
        );
      } finally {
        ownedClient?.close();
      }
    }
  }

  Future<http.Client> _pinnedClient(
    Uri uri, {
    required Duration timeout,
  }) async {
    final literal = InternetAddress.tryParse(uri.host);
    final addresses = literal == null ? await _resolver(uri.host) : [literal];
    if (addresses.isEmpty ||
        addresses.any((address) => !isPublicInternetAddress(address))) {
      throw const SafeHttpException(
        'The subscription host is not a public address.',
      );
    }
    final pinned = addresses.first;
    final native = HttpClient();
    native.autoUncompress = false;
    native.connectionTimeout = timeout;
    native.findProxy = (_) => 'DIRECT';
    native.connectionFactory = (requested, proxyHost, proxyPort) async {
      if (proxyHost != null || proxyPort != null) {
        throw const SafeHttpException(
          'Proxies are not used for subscription downloads.',
        );
      }
      final task = await Socket.startConnect(pinned, requested.port);
      final socket = task.socket.then(
        (plain) => SecureSocket.secure(
          plain,
          host: requested.host,
          supportedProtocols: const ['http/1.1'],
        ),
      );
      return ConnectionTask.fromSocket<Socket>(socket, task.cancel);
    };
    return IOClient(native);
  }
}

Uri _validatedUri(Uri input) {
  if (input.scheme.toLowerCase() != 'https' || input.host.isEmpty) {
    throw const SafeHttpException('Subscription URLs must use HTTPS.');
  }
  if (input.userInfo.isNotEmpty) {
    throw const SafeHttpException(
      'Subscription URLs cannot contain user info.',
    );
  }
  final host = input.host.toLowerCase();
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local')) {
    throw const SafeHttpException('The subscription host is local.');
  }
  final literal = InternetAddress.tryParse(host);
  if (literal != null && !isPublicInternetAddress(literal)) {
    throw const SafeHttpException(
      'The subscription host is not a public address.',
    );
  }
  return input.hasFragment ? input.replace(fragment: null) : input;
}

bool _isRedirect(int statusCode) =>
    statusCode == 301 ||
    statusCode == 302 ||
    statusCode == 303 ||
    statusCode == 307 ||
    statusCode == 308;

/// True only for addresses suitable as public Internet destinations.
bool isPublicInternetAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (bytes.length == 4) return _publicV4(bytes);
  if (bytes.length != 16) return false;

  // IPv4-mapped IPv6 (::ffff:a.b.c.d) must inherit the IPv4 decision.
  if (bytes.take(10).every((value) => value == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff) {
    return _publicV4(bytes.sublist(12));
  }

  // unspecified/loopback, discard-only, ULA, link/site-local, multicast and
  // documentation ranges are never valid subscription destinations.
  if (bytes.every((value) => value == 0)) return false;
  if (bytes.take(15).every((value) => value == 0) && bytes[15] == 1) {
    return false;
  }
  if (bytes[0] == 0x01 && bytes.sublist(1, 8).every((value) => value == 0)) {
    return false;
  }
  if ((bytes[0] & 0xfe) == 0xfc) return false; // fc00::/7
  if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) {
    return false; // fe80::/10
  }
  if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0) {
    return false; // fec0::/10
  }
  if (bytes[0] == 0xff) return false; // ff00::/8
  if (bytes[0] == 0x20 &&
      bytes[1] == 0x01 &&
      bytes[2] == 0x0d &&
      bytes[3] == 0xb8) {
    return false; // 2001:db8::/32
  }
  return true;
}

bool _publicV4(List<int> b) {
  final a = b[0];
  final c = b[1];
  final d = b[2];
  if (a == 0 || a == 10 || a == 127) return false;
  if (a == 100 && c >= 64 && c <= 127) return false;
  if (a == 169 && c == 254) return false;
  if (a == 172 && c >= 16 && c <= 31) return false;
  if (a == 192 && c == 168) return false;
  if (a == 192 && c == 0 && d == 0) return false;
  if (a == 192 && c == 0 && d == 2) return false;
  if (a == 198 && (c == 18 || c == 19)) return false;
  if (a == 198 && c == 51 && d == 100) return false;
  if (a == 203 && c == 0 && d == 113) return false;
  if (a >= 224) return false;
  return true;
}

/// Include subdomains and the DNS trailing-dot form.
bool isHideipHost(String host) {
  final normalized = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  return normalized == 'hideip.net' || normalized.endsWith('.hideip.net');
}
