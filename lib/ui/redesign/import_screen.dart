import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_version.dart';
import '../../core/camera_permission.dart';
import '../../core/deep_link.dart';
import '../../core/haptics.dart';
import '../../core/import_payload.dart';
import '../../core/location.dart';
import '../../core/ping.dart';
import '../../core/proxy_profile.dart';
import '../../core/safe_http.dart';
import '../../core/share_link_parser.dart';
import '../../core/sub_info.dart';
import '../../core/subscription.dart';
import '../../core/wg_import.dart';
import '../../state/app_state.dart';
import '../brand.dart';
import '../strings.dart';
import 'hip.dart';
import 'hip_sheet.dart';
import 'home_banners.dart';
import 'qr_popup.dart';
import 'shell.dart';
import 'srv_edit.dart';

enum _Phase { input, parsing, result }

/// Reads the picked file as text, or returns null when the sheet was
/// dismissed. Bytes rather than a path so no `dart:io` handle outlives the
/// picker, and so it behaves the same on a content URI as on a real file.
Future<String?> pickImportFile() async {
  // Any file, then judged by its contents. A picker restricted to `.conf` and
  // `.json` looks tidier but hides the file a provider actually sent on the
  // platforms where those extensions have no MIME type, and a hidden file is
  // a dead end.
  final file = await FilePicker.pickFile();
  if (file == null) return null;
  // A config is text. Something the size of a photo is not, and reading it
  // whole to find that out would only cost memory.
  if (await file.length() > 512 * 1024) return '';
  final bytes = await file.readAsBytes();
  // A NUL byte is the cheapest proof that this is not a text file at all.
  if (bytes.contains(0)) return '';
  return utf8.decode(bytes, allowMalformed: true);
}

/// The platform edges of the import screen, gathered so a widget test can
/// drive the whole flow without a camera, a pasteboard or a file picker.
class ImportHooks {
  final Future<CamPerm> Function() camStatus;
  final Future<CamPerm> Function() camRequest;
  final Future<void> Function() openCamSettings;
  final QrReaderBuilder reader;

  /// Whether the clipboard holds text at all. Asked first because on iOS it
  /// answers without raising the system Allow Paste alert, which is what makes
  /// an empty clipboard tellable from a declined paste.
  final Future<bool> Function() clipboardHasText;

  /// The clipboard text, or null when the system refused to hand it over.
  final Future<String?> Function() clipboardText;

  /// The contents of a picked file, null when the picker was dismissed and an
  /// empty string when the file is not text.
  final Future<String?> Function() pickFile;

  /// The reachability probe on the parsed endpoint, so a test can answer it
  /// without opening a socket.
  final Future<PingResult> Function(String host, int port) ping;

  const ImportHooks({
    this.camStatus = CameraPermission.status,
    this.camRequest = CameraPermission.request,
    this.openCamSettings = CameraPermission.openSettings,
    this.reader = buildQrReader,
    this.clipboardHasText = Clipboard.hasStrings,
    this.clipboardText = _clipboardText,
    this.pickFile = pickImportFile,
    this.ping = _ping,
  });
}

Future<PingResult> _ping(String host, int port) =>
    Ping.measure(host, port, timeout: const Duration(seconds: 3));

Future<String?> _clipboardText() async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  return data?.text;
}

/// The universal importer: paste anything a provider sends (a share link,
/// a subscription URL, a base64 blob) and it becomes a clean, named location.
class ImportScreen extends StatefulWidget {
  final AppState state;
  final HipNav nav;

  /// The screen a back gesture from the input phase returns to; the shell
  /// remembers where the importer was opened from.
  final HipScreen exitTo;

  /// Text to prefill the input with, e.g. from a `hideip://` deep link. The
  /// screen still shows the detected preview and waits for the user to tap
  /// Import; it never auto-imports.
  final String? initialText;

  final ImportHooks hooks;

  const ImportScreen({
    super.key,
    required this.state,
    required this.nav,
    this.exitTo = HipScreen.home,
    this.initialText,
    this.hooks = const ImportHooks(),
  });

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final _text = TextEditingController();
  _Phase _phase = _Phase.input;
  bool _tech = false;
  bool _formats = false;
  bool _qr = false;
  bool _pasteDenied = false;
  String? _error;

  // Parse progress: which of [_steps] are done / active.
  List<String> _steps = const [];
  int _stepDone = 0;

  // Parse output, waiting for the user to commit.
  List<ProxyProfile> _pending = const [];
  Location? _preview;
  int? _previewPingMs;
  bool _isSubscription = false;

  /// Set when the screen was opened to edit an existing server: saving then
  /// replaces that one in place instead of adding to the list.
  SrvEditCtx? _editing;

  @override
  void initState() {
    super.initState();
    final ctx = widget.nav.ctx();
    if (ctx is SrvEditCtx) _editing = ctx;
    _text.addListener(
      () => setState(() {
        _error = null;
        _pasteDenied = false;
      }),
    );
    // A deep link (or any caller) can hand us text to prefill. We surface the
    // detection preview but never auto-run the import: the user still taps
    // Import so they see exactly what a link is about to add.
    if (widget.initialText != null && widget.initialText!.isNotEmpty) {
      _text.text = widget.initialText!;
    }
    // An edit opens on the server's own config, whatever else was pending.
    final editing = _editing;
    if (editing != null) _text.text = editing.text;
  }

  @override
  void dispose() {
    widget.nav.releaseBack(_back);
    _text.dispose();
    super.dispose();
  }

  /// System back mirrors the header arrow: result/parsing fall back to the
  /// input phase first, input leaves the screen. The claim is held only while
  /// there is an internal step to walk, so the shell knows a back gesture from
  /// the input phase leaves the screen (and can animate towards [ImportScreen.exitTo]).
  void _syncBackClaim() {
    if (_phase == _Phase.input) {
      widget.nav.releaseBack(_back);
    } else {
      widget.nav.claimBack(_back);
    }
  }

  // --- input detection -------------------------------------------------------

  static const _protocolNames = {
    'vless': S.tVless,
    'vmess': 'VMess',
    'ss': 'Shadowsocks',
    'trojan': 'Trojan',
    'hysteria2': 'Hysteria2',
    'hy2': 'Hysteria2',
    'tuic': 'TUIC',
    'anytls': 'AnyTLS',
    'socks': 'SOCKS',
    'socks5': 'SOCKS',
    'socks5h': 'SOCKS',
    'wireguard': S.tWireGuard,
    'wg': S.tWireGuard,
  };

  /// The detection line, plus whether the input is a subscription. The
  /// whitelist behind it is shared with the deep-link path, so a link the
  /// site sends and text pasted by hand are judged by one rule.
  static (String, bool)? _detect(String input, {bool editing = false}) {
    final payload = classifyImportPayload(input);
    if (payload == null) return null;
    // A pasted WireGuard file is a share link to everything downstream, but
    // calling it a link on screen would not match what the person just pasted.
    if (WgImport.looksLikeConfig(input)) return (S.e3Detected, false);
    // An edit replaces one server with one server. A body is read (that is
    // how a rebuilt config comes back) and held to one result later; a URL
    // to fetch is a whole subscription and never one server, so it is out.
    if (editing) {
      return switch (payload.kind) {
        ImportPayloadKind.subscriptionUrl => null,
        ImportPayloadKind.subscriptionBlob => (S.srvConfigDetected, true),
        ImportPayloadKind.shareLink => (
          S.e2Detected(
            _protocolNames[payload.scheme] ?? payload.scheme!.toUpperCase(),
          ),
          false,
        ),
      };
    }
    return switch (payload.kind) {
      ImportPayloadKind.shareLink => (
        S.e2Detected(
          _protocolNames[payload.scheme] ?? payload.scheme!.toUpperCase(),
        ),
        false,
      ),
      ImportPayloadKind.subscriptionUrl => (S.e4UrlDetected, true),
      ImportPayloadKind.subscriptionBlob => (S.e4BlobDetected, true),
    };
  }

  // --- the import pipeline ----------------------------------------------------

  Future<void> _runImport() async {
    final input = _text.text.trim();
    final det = _detect(input, editing: _editing != null);
    if (det == null) return;
    final (_, isSub) = det;

    setState(() {
      _phase = _Phase.parsing;
      _syncBackClaim();
      _stepDone = 0;
      _error = null;
      _isSubscription = isSub;
      _steps = [
        isSub ? S.e5FetchSub : S.e5ReadLink,
        S.e5DetectProtocol,
        S.e5CheckEndpoint,
        S.e5NameIt,
      ];
    });

    try {
      // Step 1: obtain profiles.
      List<ProxyProfile> profiles;
      if (isSub &&
          input.startsWith(RegExp(r'https?://', caseSensitive: false))) {
        final res = await SafeHttpFetcher().get(
          Uri.parse(input),
          headers: subscriptionHeaders,
          timeout: const Duration(seconds: 12),
        );
        if (res.statusCode != 200) throw S.eSubStatus(res.statusCode);
        final parsed = await Subscription.parseAsync(res.body);
        if (parsed.profiles.isEmpty) throw _subError(parsed);
        // Remember the origin so the app can re-pull it on later launches
        // when the provider rotates its servers.
        profiles = parsed.profiles
            .map((p) => p.copyWith(subUrl: input))
            .toList();
        // Capture any plan metadata the provider sent (data used, expiry,
        // panel link) so the locations screen can show it under this sub.
        final info = SubInfo.fromHeaders(
          res.headers,
          fetchedAt: DateTime.now(),
        );
        if (info != null) await SubInfoStore.put(input, info);
      } else if (isSub) {
        final parsed = await Subscription.parseAsync(input);
        if (parsed.profiles.isEmpty) throw _subError(parsed);
        profiles = parsed.profiles;
      } else {
        final p = ShareLinkParser.parse(input);
        if (p == null) throw S.eNotALink;
        profiles = [p];
      }
      if (_editing != null && profiles.length != 1) throw S.srvEditOneOnly;
      // A single link or file is kept as the user pasted it, so a later edit
      // opens on the same text. A provider's body is not: every server in it
      // would carry the whole body.
      if (profiles.length == 1 && (!isSub || _editing != null)) {
        profiles = [profiles.first.copyWith(source: input)];
      }
      await _advance(1);

      // Step 2: protocol identified; rewrite the step label with the truth.
      final first = Location.derive(profiles.first, 0);
      _steps[1] = isSub
          ? S.e5FoundServers(profiles.length)
          : S.e5DetectedProtocol(first.protoLabel);
      await _advance(2);

      // Step 3: reachability probe (informative; failure does not block).
      final ping = await widget.hooks.ping(
        profiles.first.server,
        profiles.first.port,
      );
      _previewPingMs = ping is PingOk ? ping.ms : null;
      _steps[2] = ping is PingOk ? S.e5Verified : S.e5NotReachable;
      await _advance(3);

      // Step 4: clean name.
      _steps[3] = S.e5NamedIt(first.city);
      await _advance(4);

      setState(() {
        _pending = profiles;
        _preview = first;
        _phase = _Phase.result;
        _syncBackClaim();
      });
    } catch (e) {
      Haptics.error();
      setState(() {
        _phase = _Phase.input;
        _syncBackClaim();
        _error = e is ProfileParseException ? e.message : e.toString();
      });
    }
  }

  static String _subError(SubscriptionResult r) =>
      r.errors.isNotEmpty ? S.eSubFailed(r.errors.first) : S.eSubEmpty;

  /// Marks step [n] done with a small beat so the progress reads naturally.
  Future<void> _advance(int n) async {
    await Future.delayed(const Duration(milliseconds: 340));
    if (mounted) setState(() => _stepDone = n);
  }

  Future<void> _commit({required bool connect}) async {
    await widget.state.addProfiles(_pending, select: true);
    final city = _preview!.city;
    var go = connect;
    if (go && widget.state.needsVpnPrimer) {
      // B13 reads the same here as on Home: the one system permission is
      // explained before the OS asks, whichever button led to the first
      // Connect. Offered once per install, whatever the answer.
      if (!mounted) return;
      final answer = await showHipSheet<bool>(context,
          children: const [VpnPrimerSheet()]);
      await widget.state.markVpnPrimerSeen();
      go = answer == true;
    }
    widget.state.showToast(S.e6Added(city));
    widget.nav.go(HipScreen.home);
    if (go) {
      await Future.delayed(const Duration(milliseconds: 250));
      await widget.state.connect();
    }
  }

  /// The profile this edit started from, or null when the list moved on.
  ProxyProfile? get _edited {
    final editing = _editing;
    if (editing == null) return null;
    final profiles = widget.state.profiles;
    final at = _editIndex;
    return at == null || at >= profiles.length ? null : profiles[at];
  }

  /// Where the edited server sits now: found by identity first, since a
  /// refresh may have moved it, then by the position it had.
  int? get _editIndex {
    final editing = _editing;
    if (editing == null) return null;
    for (final l in widget.state.locations) {
      if (l.id == editing.id) return l.index;
    }
    return editing.index;
  }

  /// Puts the parsed server where the edited one sits. Its custom name, its
  /// subscription and the selection stay; see [AppState.replaceProfile].
  Future<void> _commitEdit() async {
    final editing = _editing!;
    final index = _editIndex ?? editing.index;
    final next = _pending.first;
    await widget.state.replaceProfile(index, next);
    final profiles = widget.state.profiles;
    final saved = index < profiles.length ? profiles[index] : next;
    widget.state.showToast(
      S.srvUpdated(saved.customName ?? Location.derive(saved, index).city),
    );
    widget.nav.back();
  }

  // --- quick actions -----------------------------------------------------------

  /// Takes the payload out of one of our own import links. The QR a desktop
  /// browser shows is an app link, and scanning or pasting it here would
  /// otherwise be read as a subscription URL pointing at hideip.net itself.
  static String _unwrap(String input) => parseDeepLink(input)?.text ?? input;

  void _openQr() => setState(() {
    _qr = true;
    _pasteDenied = false;
  });

  void _closeQr() => setState(() => _qr = false);

  /// A scan fills the same field a paste would fill and stops there. The
  /// import still needs a tap, so nothing a stranger's code carries is ever
  /// added by pointing a camera at it.
  void _onScanned(String raw) {
    _closeQr();
    if (raw.isEmpty) return;
    _text.text = _unwrap(raw);
  }

  Future<void> _pasteClipboard() async {
    final has = await widget.hooks.clipboardHasText();
    if (!has) {
      setState(() => _error = S.eClipboardEmpty);
      return;
    }
    final text = await widget.hooks.clipboardText();
    final trimmed = text?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      // The clipboard holds text but the system did not hand it over: on iOS
      // that is the Allow Paste alert being declined. There is still a way in.
      setState(() {
        _error = null;
        _pasteDenied = true;
      });
      return;
    }
    _text.text = _unwrap(trimmed);
  }

  Future<void> _openFile() async {
    final text = await widget.hooks.pickFile();
    if (text == null) return; // dismissed
    if (text.trim().isEmpty) {
      setState(() => _error = S.eFileNotText);
      return;
    }
    _text.text = text.trim();
  }

  void _back() {
    if (_qr) {
      _closeQr();
      return;
    }
    if (_phase != _Phase.input) {
      setState(() {
        _phase = _Phase.input;
        _syncBackClaim();
      });
      return;
    }
    // An edit was opened from a server's own screen or row; back returns
    // there rather than to where the importer is usually launched from.
    if (_editing != null) {
      widget.nav.back();
      return;
    }
    widget.nav.go(widget.exitTo);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SafeArea(
          bottom: false,
          child: Column(
            children: [
              HipNavHead(
                title: _editing == null ? S.tAddConn : S.srvEditTitle,
                onBack: _back,
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: switch (_phase) {
                    _Phase.input => _buildInput(),
                    _Phase.parsing => _buildParsing(),
                    _Phase.result => _buildResult(),
                  },
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  22,
                  14,
                  22,
                  MediaQuery.paddingOf(context).bottom + 14,
                ),
                child: switch (_phase) {
                  _Phase.input => HipCta(
                    S.eImport,
                    onTap: _detect(_text.text, editing: _editing != null) == null
                        ? null
                        : _runImport,
                  ),
                  _Phase.parsing => const SizedBox(),
                  _Phase.result when _editing != null => HipCta(
                    S.srvSaveChanges,
                    onTap: _commitEdit,
                  ),
                  _Phase.result => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      HipCta(
                        S.e6AddAndConnect,
                        onTap: () => _commit(connect: true),
                      ),
                      const SizedBox(height: 8),
                      HipCta(
                        S.e6AddOnly,
                        quiet: true,
                        onTap: () => _commit(connect: false),
                      ),
                    ],
                  ),
                },
              ),
            ],
          ),
        ),
        if (_qr)
          QrPopup(
            onCode: _onScanned,
            onClose: _closeQr,
            onPasteInstead: () {
              _closeQr();
              _pasteClipboard();
            },
            camStatus: widget.hooks.camStatus,
            camRequest: widget.hooks.camRequest,
            openCamSettings: widget.hooks.openCamSettings,
            readerBuilder: widget.hooks.reader,
          ),
      ],
    );
  }

  Widget _buildInput() {
    final det = _detect(_text.text, editing: _editing != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 118),
          decoration: BoxDecoration(
            color: Hip.card,
            borderRadius: BorderRadius.circular(Hip.radius),
            border: Border.all(
              color: Hip.dm ? Brand.hsl(222, 12, 27) : Brand.hsl(0, 0, 84),
              width: 1.5,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
          child: TextField(
            controller: _text,
            maxLines: 5,
            minLines: 3,
            style: Hip.mono(500, 12.5, color: Hip.ink, height: 1.55),
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: S.e1Placeholder,
              hintStyle: Hip.sans(400, 13.5, color: Hip.muted2, height: 1.5),
            ),
          ),
        ),
        if (_pasteDenied)
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            decoration: BoxDecoration(
              color: Hip.line2,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              S.e11PasteDenied,
              style: Hip.sans(
                500,
                Hip.calloutSize,
                color: Hip.inkSoft,
                height: 1.5,
              ),
            ),
          ),
        if (_error != null)
          _DetectBox(text: _error!, tone: _Tone.error)
        else if (det != null)
          _DetectBox(text: det.$1, tone: _Tone.ok)
        else if (_text.text.trim().isNotEmpty)
          const _DetectBox(text: S.e2Unknown, tone: _Tone.neutral),
        const SizedBox(height: 12),
        // Three actions, not three formats. What a link is called is answered
        // below, behind a quiet disclosure, so the buttons stay about doing.
        Row(
          children: [
            Expanded(
              child: _QuickAction(
                icon: Icons.qr_code_scanner,
                label: S.e1ScanQr,
                onTap: _openQr,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _QuickAction(
                icon: Icons.content_paste_outlined,
                label: S.e1Paste,
                onTap: _pasteClipboard,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _QuickAction(
                icon: Icons.description_outlined,
                label: S.e1OpenFile,
                onTap: _openFile,
              ),
            ),
          ],
        ),
        const HipSubnote(S.e1Subnote),
        Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _formats = !_formats),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedRotation(
                    turns: _formats ? .25 : 0,
                    duration: Hip.dur(const Duration(milliseconds: 200)),
                    child: Icon(
                      Icons.chevron_right,
                      size: 14,
                      color: Hip.muted,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    S.e1WhichFormats,
                    style: Hip.sans(600, 12.5, color: Hip.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_formats)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Text(
              S.e1Formats,
              textAlign: TextAlign.center,
              style: Hip.sans(400, 12.5, color: Hip.muted, height: 1.6),
            ),
          ),
      ],
    );
  }

  Widget _buildParsing() {
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        children: [
          for (var i = 0; i < _steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _stepDone > i
                          ? Hip.successSoft
                          : _stepDone == i
                          ? Hip.blueSoft
                          : Hip.line2,
                    ),
                    child: _stepDone > i
                        ? Icon(Icons.check, size: 14, color: Hip.success)
                        : _stepDone == i
                        ? Padding(
                            padding: const EdgeInsets.all(6),
                            child: CircularProgressIndicator(
                              strokeWidth: 1.8,
                              color: Hip.blue,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _steps[i],
                    style: Hip.sans(
                      550,
                      Hip.bodySize,
                      color: _stepDone > i ? Hip.ink : Hip.muted2,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// `fast (38 ms)`, on the same thresholds the signal bars use, so a row and
  /// a result card never disagree about the same number.
  static String _speed(int ms) => S.e6Speed(
    ms < 120
        ? S.e6Fast
        : ms < 250
        ? S.e6Good
        : S.e6Slow,
    ms,
  );

  Widget _buildResult() {
    final loc = _preview!;
    final renamed = loc.city.toLowerCase() != loc.rawName.toLowerCase();
    final isWg = loc.profile.protocol == WgImport.protocol;
    // A WireGuard file carries a name only in the comment at the top; without
    // one the importer falls back to the endpoint.
    final namedByComment = isWg && loc.rawName != 'WireGuard ${loc.host}';
    final o = loc.profile.outbound;
    final tls = o['tls'] is Map ? o['tls'] as Map : const {};
    final ms = _previewPingMs;
    final subtitle = [
      if (loc.provider != null)
        S.e6From(loc.provider!)
      else if (isWg)
        S.e10OwnServer,
      if (ms != null) _speed(ms),
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DetectBox(
          text: _editing != null
              ? S.e6Ready
              : _isSubscription
                  ? S.e4Added
                  : S.e6Ready,
          tone: _Tone.ok,
        ),
        const SizedBox(height: 12),
        HipCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  HipFlag(cc: loc.cc),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${loc.city}, ${loc.country}',
                          style: Hip.sans(
                            650,
                            15.5,
                            color: Hip.ink,
                            letterSpacing: -.15,
                          ),
                        ),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: Hip.sans(550, 12, color: Hip.muted),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (ms != null) HipBadge.ok(S.e6Verified),
                ],
              ),
              GestureDetector(
                onTap: () => setState(() => _tech = !_tech),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 2),
                  child: Row(
                    children: [
                      AnimatedRotation(
                        turns: _tech ? .25 : 0,
                        duration: Hip.dur(const Duration(milliseconds: 200)),
                        child: Icon(
                          Icons.chevron_right,
                          size: 14,
                          color: Hip.muted,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        S.e6Technical,
                        style: Hip.sans(600, 12.5, color: Hip.muted),
                      ),
                    ],
                  ),
                ),
              ),
              if (_tech)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Hip.line2,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _kv(S.kvProtocol, loc.protoLabel),
                      _kv(S.kvEndpoint, loc.host),
                      if (o['flow'] is String)
                        _kv(S.kvFlow, o['flow'] as String),
                      if (tls['server_name'] is String)
                        _kv(S.kvSni, tls['server_name'] as String),
                      _kv(S.kvOriginalName, loc.rawName),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (_editing != null && _edited?.subUrl != null)
          const HipSubnote(S.srvEditFromSub)
        else if (_isSubscription && _editing == null)
          HipSubnote(S.e4SubNote(_pending.length))
        else if (renamed)
          HipSubnote(S.e6Renamed(loc.rawName, loc.city))
        else if (namedByComment)
          HipSubnote(S.e10NameFromComment(loc.city)),
      ],
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1.5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 104,
          child: Text(k, style: Hip.mono(500, 11, color: Hip.muted)),
        ),
        Expanded(
          child: Text(v, style: Hip.mono(600, 11, color: Hip.ink)),
        ),
      ],
    ),
  );
}

enum _Tone { ok, neutral, error }

class _DetectBox extends StatelessWidget {
  final String text;
  final _Tone tone;
  const _DetectBox({required this.text, required this.tone});

  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon) = switch (tone) {
      _Tone.ok => (Hip.successSoft, Hip.success, Icons.check),
      _Tone.neutral => (Hip.line2, Hip.muted, Icons.visibility_outlined),
      _Tone.error => (
        Hip.danger.withValues(alpha: .08),
        Hip.danger,
        Icons.error_outline,
      ),
    };
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: fg),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: Hip.sans(600, Hip.calloutSize, color: fg, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(minHeight: 60),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 13),
        decoration: BoxDecoration(
          color: Hip.card,
          border: Border.all(color: Hip.line, width: 1.5),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: Hip.blue),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: Hip.sans(600, Hip.calloutSize, color: Hip.ink),
            ),
          ],
        ),
      ),
    );
  }
}
