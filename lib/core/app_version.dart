/// Single source of truth for the app version string used off the wire.
///
/// Keep [appVersion] in sync with the `version:` field in pubspec.yaml (the
/// part before the `+` build number). Bump both together on every release.
const String appVersion = '1.1.1';

/// The User-Agent every subscription/provisioning HTTP fetch must send, so
/// seller panels can recognise the client and pick the right response format
/// (Clash YAML, sing-box JSON, or a plain/base64 link list).
const String subscriptionUserAgent = 'hideip/$appVersion';

/// The header map to merge into any subscription fetch.
Map<String, String> get subscriptionHeaders =>
    {'User-Agent': subscriptionUserAgent};
