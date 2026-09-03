/// Every user-facing string in the app, in one place.
///
/// Keys follow the vocabulary in `design/Screen Atlas 1.1.0.html`
/// (`script#screen-graph`, `vocabulary[]`) where that vocabulary has an entry;
/// everything else is named after the Atlas state code it belongs to (B0, B14,
/// E6 and so on).
///
/// This is NOT i18n. It is the single place i18n can start from without
/// walking through twelve files again: when the eleven languages come, this
/// class becomes the interface and the generated `AppLocalizations` its
/// implementation.
///
/// House rules for anything added here:
///  * No new user-facing literal may appear in a `lib/ui/` file. If a screen
///    needs a string, it goes in the section for its group below.
///  * Numbers (IP, port, latency, date) are never concatenated into a constant.
///    They arrive as parameters of a function, so a translation can reorder
///    them.
///  * Prices and billing dates come from the store (`PlanInfo`); `S` only
///    frames them.
///  * No em dash and no en dash anywhere in this file. `·` is the only
///    separator in metadata lines.
///  * A full stop ends an explanation, never a label, a button or a badge.
///
/// Each screen owns one section below. A new string is appended to the end
/// of the section it belongs to, so the file never reshuffles under a diff.
abstract final class S {
  // ---------------------------------------------------------------------
  // Vocabulary (Atlas `vocabulary[]`). The words the whole product agrees on.
  // ---------------------------------------------------------------------
  static const tSpeed = 'Speed mode';
  static const tFast = 'Fast mode';
  static const tStealth = 'Stealth';
  static const tKill = 'Kill switch';
  static const tAuto = 'Auto';
  static const tAddConn = 'Add connection';
  static const tProtected = 'Protected';
  static const tExposed = 'Exposed';
  static const tConnect = 'Connect';
  static const tConnecting = 'Connecting…';
  static const tDisconnect = 'Disconnect';
  static const tDisconnecting = 'Disconnecting…';
  static const tLocations = 'Locations';
  static const tSettings = 'Settings';
  static const tPremium = 'Premium';
  static const tFreeTrial = 'Free trial';
  static const tWireGuard = 'WireGuard';
  static const tVless = 'VLESS';

  // ---------------------------------------------------------------------
  // Shared actions and labels used by more than one group.
  // ---------------------------------------------------------------------
  static const aContinue = 'Continue';
  static const aNotNow = 'Not now';
  static const aCancel = 'Cancel';
  static const aClose = 'Close';
  static const aTryAgain = 'Try again';
  static const aOpenSettings = 'Open settings';
  static const aSeePlans = 'See plans';
  static const aRemove = 'Remove';
  static const badgeVoted = 'Voted';

  // ---------------------------------------------------------------------
  // Foundation. State, connection flow and everything the shell says.
  // ---------------------------------------------------------------------

  // B0, Connect with no servers yet.
  static const b0Title = 'No connection yet.';
  static const b0Body =
      'A link, a QR code or a WireGuard config sets one up in about a minute.';
  static const b0SeePremium = 'See Premium locations';

  // B13, the one system permission, shown once before the first Connect.
  static const b13Title = 'One system permission';
  static const b13Body =
      'The system asks for permission to add a VPN configuration. That is what '
      'routes this device through the selected server; hideip.net cannot read '
      'what passes through it.';
  // Disconnect while the system holds an Always-on profile the app did not
  // opt into: traffic stays blocked until the user resolves it in the OS.
  static const alwaysOnTitle = 'Always-on VPN is on';
  static const alwaysOnBody =
      'Android keeps hideip.net\'s Always-on VPN active, so traffic stays '
      'blocked while you are disconnected. Turn it off in Android settings, '
      'or turn on Always-on in Settings to reconnect automatically.';
  static const alwaysOnOpen = 'Open Android settings';
  static const alwaysOnDismiss = 'Dismiss';

  // B14, the system VPN permission was declined.
  static const b14Line =
      'The VPN configuration was declined, so connecting is not possible yet.';
  static const b14Action = aOpenSettings;

  // B15, no network at all.
  static const b15Status = 'No connection';
  static const b15Context = 'This device is not online yet.';
  static const b15CtaNote = 'Connecting needs an internet connection.';

  // B16, the handshake is taking its time.
  static const b16Slow =
      'Still handshaking. Filtered networks can take longer.';

  // B6, the connection failed sheet.
  static const b6Title = 'Connection failed';
  static const b6Body =
      'The server did not respond. Networks that filter traffic often block '
      'servers imported from a provider.';
  static const b6BodyByo =
      'hideip.net locations are built to keep working on filtered networks.';
  static const b6Another = 'Choose another location';

  // F5, the subscription already covers five devices.
  static const f5Title = 'Speed mode is set up on 5 devices';
  static const f5Body =
      'A subscription covers five devices. Speed mode can be turned off on one '
      'of them to free a slot. Everything else keeps working; this connection '
      'stays stealth in the meantime.';

  // C4, the notification pre-prompt after the first vote.
  static const c4Title = 'Location updates';
  static const c4Body =
      'hideip.net can notify you when a location you voted for becomes '
      'available. Nothing else is sent.';

  // Connection errors and confirmations the state layer raises.
  static const errNoServer = 'Select a server first.';
  static const errNoPlatform = 'VPN is not yet supported on this platform.';
  static String errConnect(Object detail) => 'Failed to connect: $detail';
  static const toastRestored = 'Purchases restored';
  static const toastNothingToRestore = 'No purchases to restore';
  static const toastNoSubscription = 'No active subscription found';
  static const toastLinkEmpty = 'That link carries nothing we can import';
  static const toastLinkNeedsPremium =
      'Premium is needed to link another device';

  /// The tunnel chip, always visible while connected. Simple view names the
  /// path in words; Advanced view carries the full chain instead.
  static const tunnelSpeed = '$tSpeed · $tWireGuard';
  static const tunnelBlocked = '$tStealth · $tWireGuard blocked here';
  static String tunnelStealth(String proto) => '$tStealth · $proto';
  static String tunnelChain(String proto, String host) => '$proto · $host';

  /// Session duration under an hour, e.g. `4m 07s`.
  static String durMinutes(int minutes, int seconds) =>
      '${minutes}m ${seconds.toString().padLeft(2, '0')}s';

  /// Session duration of an hour or more, e.g. `2h 05m`.
  static String durHours(int hours, int minutes) =>
      '${hours}h ${minutes.toString().padLeft(2, '0')}m';

  /// Auto's subtitle: it names the server it would pick and why.
  static String autoSub(String city, int ms, {bool managed = false}) =>
      'Fastest right now: $city · $ms ms${managed ? ' · hideip.net' : ''}';

  /// A locked row in Simple view: country and the real measured latency.
  static String lockedSub(String country, int ms) => '$country · $ms ms';

  /// Notification channel names and the two things the app may ever send.
  static const notifConnTitle = 'Connection alerts';
  static const notifConnBody = 'Tell you if the VPN drops';
  static const notifVoteTitle = 'Voting updates';
  static const notifVoteBody =
      'When a location you voted for becomes available';

  // ---------------------------------------------------------------------
  // Home. Statcard, banners, search, session card, empty state.
  // ---------------------------------------------------------------------

  /// The Servers/Map switch on the hero panel.
  static const homeSegServers = 'Servers';
  static const homeSegMap = 'Map';

  /// The status card. The status word itself comes from the vocabulary
  /// (`tExposed`, `tProtected`, `tConnecting`, `tDisconnecting`, `b15Status`).
  static const homeCopyIp = 'Copy IP';
  static const homeCopiedIp = 'IP copied';
  static const homeIpUnknown = 'unknown';

  /// The context line under the address. Exposed names who the address
  /// belongs to and where it sits; connected names the exit.
  static String ctxExposed(String isp, String place) => '$isp · $place';
  static String ctxPlace(String city, String region) => '$city, $region';

  /// Search on Home. Results carry locked rows too, so the one condition
  /// worth naming is named once, under the group.
  static const homeSearchHint = 'Search locations';
  static const homeSearchClear = 'Clear';
  static const homeResults = 'Results';
  static const homeNoMatch = 'No locations match.';
  static const homePremiumOnly = 'These locations come with Premium.';

  /// The two list sections and the door to the full list.
  static const homeRecommended = 'Recommended';
  static const homeRecentFastest = 'Recent and fastest';
  static const homeFastest = 'Fastest servers';
  static const homeAllLocations = 'All locations';
  static String homeAllLocationsSub(int servers) =>
      '$servers ${servers == 1 ? 'server' : 'servers'} · import and manage';

  /// Auto before any latency has been measured: it can still say what it is
  /// for, it just cannot name a city yet.
  static const autoSubUnknown = 'Picks the fastest server';

  /// The session card: throughput, how long the session has been up, and the
  /// chip naming what carries it (`tunnelChip` on the state).
  static String speedMbs(String value) => '$value MB/s';
  static String speedKbs(String value) => '$value KB/s';
  static const speedDown = 'Download';
  static const speedUp = 'Upload';

  // B7, the Speed mode upsell while connected without a subscription.
  static const b7Title = 'A faster connection is available with Premium.';
  static const b7Body = 'Speed mode uses WireGuard on hideip.net locations.';
  static const b7Dismiss = 'Dismiss';

  // B8, the trial reminder the day before it renews.
  static const b8Title = 'Your free trial ends tomorrow.';
  static String b8Body(String price) =>
      'Every location and Speed mode, $price a year.';
  static const b8Action = 'Keep Premium';

  // B9, a connection link sitting in the clipboard. Offered once, never
  // imported on its own.
  static const b9Line = 'Connection link in your clipboard';
  static const b9Add = 'Add';
  static const b9Dismiss = 'Dismiss';

  /// An open row in Simple view: the country and the real measured latency,
  /// the same shape a locked row shows so the two compare at a glance.
  static String homeRowSub(String country, int ms) => '$country · $ms ms';

  // ---------------------------------------------------------------------
  // Locations and Manage server.
  // ---------------------------------------------------------------------

  // D1, the locked hideip.net group: what a plan opens, priced under it.
  static const d1StripTitle = 'These locations come with Premium.';
  static const d1StripSub = 'The yearly plan starts with seven free days.';

  // D2, the locked group expands in place; the order stays by latency.
  static String d2ShowAll(int total) => 'Show all $total locations';

  // D3, Auto and the two groups of the list.
  static const d3AutoIdle = 'Always picks the fastest server';
  static const dYourServers = 'Your servers';
  static const dNoServers =
      'No servers yet. A connection from your provider, or your own WireGuard '
      'config, can be added at any time.';
  static const dNamesCleaned =
      'Names and flags are cleaned up automatically from whatever your '
      'provider sends.';
  static const dManage = 'Manage';

  // The managed group before its servers land, and after the plan ends.
  static const dSettingUp = 'Setting up your servers';
  static const dSettingUpSub = 'Premium locations appear here shortly';
  static const dExpired = 'Subscription expired';
  static const dExpiredSub = 'Renew it to get your premium locations back';

  // D6, a location this install voted for went live.
  static String d6Title(String city) => '$city is live.';
  static const d6Sub = 'This is one of the locations you voted for.';
  static const d6Dismiss = 'Dismiss';

  // Coming next: the pointer from Locations into voting on the map.
  static const dComingNext = 'Coming next';
  static const dVoteTitle = 'Vote for new locations';
  static const dVoteSub = 'Anonymous voting on the map';
  static const dYourVote = 'Your vote';
  static const dVotes = 'votes';
  static const dVoteNote =
      'Anonymous, one vote per country. Tap a country on the map to change '
      'yours.';

  // G1, manage one of the user's own servers. Reachable in Simple view too.
  static const gThisServer = 'This server';
  static String gManagedBy(String proto) => '$proto · run by hideip.net';
  static String gFromProvider(String proto, String provider) =>
      '$proto · from $provider';
  static const gYourProvider = 'your provider';
  static const gTesting = 'Testing…';
  static const gTest = 'Test';
  static String gMs(int ms) => '$ms ms';

  // G2, inline rename. The provider's raw name stays referenced underneath,
  // so renaming never loses what the link actually said.
  static const gName = 'Name';
  static String gNameSub(String name, String rawName) =>
      '$name. The provider called it $rawName.';
  static const gSave = 'Save';

  // G1/G3, where the server came from and what refreshing it did.
  static const gSource = 'Source';
  static const gSourceSub =
      'A single link, added by hand. It does not update on its own.';
  static const gSubscription = 'Subscription';
  static const gRefreshBusy = 'Checking with your provider…';
  static String gRefreshDone(int servers) =>
      'Updated just now. $servers ${servers == 1 ? 'server' : 'servers'}.';
  static const gRefreshError =
      'The subscription could not be reached. The servers already on this '
      'device keep working.';
  static String gRefreshIdle(String ago) =>
      'Updated $ago. Refreshes on its own.';
  static const gAgoJustNow = 'just now';
  static String gAgoMinutes(int minutes) =>
      minutes == 1 ? '1 minute ago' : '$minutes minutes ago';
  static String gAgoHours(int hours) =>
      hours == 1 ? '1 hour ago' : '$hours hours ago';
  static String gAgoDays(int days) => days == 1 ? '1 day ago' : '$days days ago';

  // G4, Advanced only: the raw outbound.
  static const gRawConfig = 'Raw config';
  static const gCopyConfig = 'Copy config';
  static const gCopyFull = 'Copy full config';
  static const gCopyFullTitle = 'Copy full config?';
  static const gCopyFullBody =
      'The full config contains credentials that can be used to access this '
      'server. It will be marked sensitive and expire after one minute.';
  static const gCopyFullAction = 'Copy for 1 minute';
  static const gToastRedacted = 'Redacted config copied';
  static const gToastFull = 'Full config copied for 1 minute';
  static const gToastFullFailed = 'Could not copy full config';

  // G5, removal is confirmed and says what keeps working afterwards.
  static const gRemove = 'Remove server';
  static String g5Title(String city) => 'Remove $city?';
  static const g5Body =
      'The server is removed from this device. The link from your provider '
      'keeps working, so it can be added again at any time.';
  static String gRemoved(String city) => '$city removed';

  // ---------------------------------------------------------------------
  // Import.
  // ---------------------------------------------------------------------

  // E1, the empty field and the three actions under it.
  static const e1Placeholder =
      'Paste anything: a vless:// or vmess:// link, a subscription URL, or '
      'your own WireGuard config.';
  static const e1ScanQr = 'Scan QR code';
  static const e1Paste = 'Paste';
  static const e1OpenFile = 'Open file';
  static const e1Subnote =
      'Any link from any provider works, and your own WireGuard config too.';
  static const e1WhichFormats = 'Which formats?';

  // The formats the parser really accepts. Kept in step with
  // `ShareLinkParser.supportedSchemes` and `Subscription.parseAsync`, not with
  // what a provider's marketing page happens to list.
  static const e1Formats =
      'VLESS, VMess, Trojan, Shadowsocks, Hysteria2, TUIC, AnyTLS, ShadowTLS, '
      'SOCKS and HTTP links · subscription URLs and pasted subscription '
      'bodies · wireguard:// links and full WireGuard configs · sing-box JSON '
      'and Clash YAML files';

  // E2 to E4, the live detection line under the field.
  static String e2Detected(String protocol) => '$protocol link detected';
  static const e2Unknown =
      'Not recognized yet. Keep typing or paste the full link.';
  static const e3Detected = 'WireGuard configuration detected';
  static const e4UrlDetected = 'Subscription link detected';
  static const e4BlobDetected = 'Subscription content detected';

  // Everything that can go wrong on the input phase, said without blame.
  static const eImport = 'Import';
  static const eNotALink = 'That does not look like a server link.';
  static String eSubStatus(int code) =>
      'The subscription server answered $code.';
  static String eSubFailed(String reason) =>
      'Could not read the subscription: $reason';
  static const eSubEmpty = 'The subscription contains no servers.';
  static const eClipboardEmpty = 'The clipboard is empty.';
  static const eFileNotText = 'That file does not look like a config.';

  // E5, the four named parse steps.
  static const e5ReadLink = 'Reading the link';
  static const e5FetchSub = 'Fetching the subscription';
  static const e5DetectProtocol = 'Detecting the protocol';
  static const e5CheckEndpoint = 'Checking the endpoint';
  static const e5NameIt = 'Naming it';
  static String e5FoundServers(int n) =>
      n == 1 ? 'Found 1 server' : 'Found $n servers';
  static String e5DetectedProtocol(String protocol) => 'Detected $protocol';
  static const e5Verified = 'Endpoint verified';
  static const e5NotReachable = 'Endpoint not reachable yet';
  static String e5NamedIt(String city) => 'Named it $city';

  // E6 and E10, the result card.
  static const e6Ready = 'Ready to add';
  static const e6Verified = 'Verified';
  static const e6Technical = 'Technical details';
  static const e6AddAndConnect = 'Add and connect';
  static const e6AddOnly = 'Add without connecting';
  static String e6From(String provider) => 'from $provider';
  static const e6Fast = 'fast';
  static const e6Good = 'good';
  static const e6Slow = 'slow';
  static String e6Speed(String word, int ms) => '$word ($ms ms)';
  static String e6Added(String city) => '$city added';
  static String e6Renamed(String rawName, String city) =>
      'We renamed “$rawName” to $city. The original is kept in Advanced view.';
  static const kvProtocol = 'protocol';
  static const kvEndpoint = 'endpoint';
  static const kvFlow = 'flow';
  static const kvSni = 'sni';
  static const kvOriginalName = 'original name';

  // E4, the subscription result: it keeps itself in sync, and a refresh that
  // fails later never takes servers off the device.
  static const e4Added = 'Subscription added; it will stay in sync';
  static String e4SubNote(int n) => n == 1
      ? '1 server. If a later refresh fails, the server already on this '
          'device stays.'
      : '$n servers. If a later refresh fails, the servers already on this '
          'device stay.';

  // E10, a WireGuard file names its own server.
  static const e10OwnServer = 'your own WireGuard server';
  static String e10NameFromComment(String city) =>
      'The name $city comes from the comment at the top of the config.';

  // E7 to E9, the inline QR popup.
  static const e7Title = 'Scan QR code';
  static const e7Head = 'Camera access';
  static const e7Body =
      'The camera is used only to read QR codes, directly on this device. '
      'Nothing is recorded or saved.';
  static const e7Allow = 'Allow camera';
  static const e8Head = 'Camera is turned off';
  static const e8Body =
      'Camera access is turned off in system settings. A link can also be '
      'pasted into the text field.';
  static const e8PasteInstead = 'Paste a link instead';
  static const e9Hint = 'Point the camera at a server QR code';
  static const e9Found = 'Code found';

  // E11, iOS declined the system Allow Paste alert.
  static const e11PasteDenied =
      'Paste was not allowed. Long press the field to paste manually.';

  // ---------------------------------------------------------------------
  // Settings, Paywall, Premium manage, Trial expired.
  // ---------------------------------------------------------------------

  // A `|segment|` inside a legal line renders in mono at full opacity: it is
  // always a price or a date, and the pipes let a translation move it.

  // --- Settings, section labels ---
  static const setAccount = 'Account';
  static const setInterface = 'Interface';
  static const setConnection = 'Connection';
  static const setPrivacySection = 'Privacy';
  static const setNotifications = 'Notifications';
  static const setConnections = 'Connections';
  static const setHelp = 'Help';

  // F1, the card that sells. Shown only while there is no subscription;
  // selling stops the moment someone has paid.
  static const setSellTitle = 'Every location, stealth by default.';
  static const setSellBody =
      'All hideip.net locations, Speed mode, no logs, no account.';
  static const setSellCta = 'Try 7 days free';
  static String setSellLegal(String price) =>
      'Then |$price| per year. Cancel anytime.';

  // F2, the Account rows once there is a subscription.
  static const setPremiumOn = 'On';
  static String setPremiumTrial(String date) => 'Free trial; ends $date';
  static String setPremiumActive(String plan, String date) =>
      '$plan plan; renews $date';
  static const setPremiumEnded = 'Subscription ended; not renewing';
  static const setPremiumNone = 'Not subscribed; 7 days free to start';
  static const setLinkedDevices = 'Linked devices';
  static const setLinkedDevicesSub =
      'Use Premium in your browser and on desktop';

  // Interface.
  static const setTheme = 'Theme';
  static const setThemeLight = 'Light';
  static const setThemeDark = 'Dark';
  static const setThemeSystem = 'System';
  static const setThemeNote =
      'The app follows the system appearance unless a theme is chosen here.';
  static const setAdvanced = 'Advanced view';
  static const setAdvancedSub = 'Show protocols, endpoints and raw configs';

  // Connection.
  static const setAutoConnect = 'Connect on launch';
  static const setKillSub =
      'Block traffic and reconnect if the VPN drops unexpectedly';
  static const setKillSubIos =
      'Reconnect automatically if the VPN drops unexpectedly';
  static const setKillLater = 'Applies fully from the next connection';
  static const setBadgeNew = 'New';
  static const setSpeedSub =
      'WireGuard on hideip.net locations, where the network allows it';
  static const setSpeedLocked = 'Part of Premium. WireGuard on hideip.net '
      'locations; importing your own config is free.';
  static const setSpeedLater = 'Applies from the next connection';
  static const setSpeedNote = 'Speed mode applies to hideip.net locations. '
      'Imported servers keep their own protocol.';

  // F3, the one row Advanced view adds.
  static const setRouting = 'Protocol and routing';

  /// How the server is chosen, then the protocol that server really runs.
  static String setRoutingSub(String selection, String proto) =>
      '$selection · $proto';

  // Android only: the in-app opt-in and the shortcut into system settings.
  static const setAlwaysOn = 'Always-on VPN';
  static const setAlwaysOnSub = "Reconnect the last server when Android's "
      'Always-on VPN starts hideip.net';
  static const setAlwaysOnHint =
      'Tap the gear next to hideip.net and turn on Always-on VPN';
  static const setVpnSettings = 'Android VPN settings';
  static const setVpnChecking = 'Checking the system Always-on state…';
  static const setVpnOff = 'System Always-on is off · tap to open';
  static const setVpnOn = 'System Always-on is on';
  static const setVpnOnLockdown =
      'System Always-on is on, with Block connections without VPN';

  // Privacy.
  static const setUsage = 'Anonymous usage counts';
  static const setUsageSub =
      'Three one-time events, no identifiers. Details at hideip.net/privacy';

  // F4, notifications refused in system settings.
  static const setNotifBlocked =
      'Notifications are turned off in system settings.';
  static const setNotifAllow = 'Allow notifications';

  // Connections.
  static const setAddConnSub =
      'From any provider, or your own WireGuard server';
  static const setManageServers = 'Manage servers';

  // Help.
  static const setIntroAgain = 'See intro again';
  static const setIntroAgainSub = 'The three screens from the first launch';
  static const setPrivacyPolicy = 'Privacy Policy';
  static const setTerms = 'Terms of Use';
  static const setFooter = 'hideip.net · Open source · No logs';
  static const setFooterBoth = 'hideip.net · Open source · No logs\n'
      'Same app on iOS and Android.';

  // --- H1, H2, the paywall ---
  static const pwTitle = 'Every location, one plan.';
  static String pwTitleCity(String city) => '$city is part of the plan.';
  static const pwSub = 'One subscription covers the whole hideip.net network, '
      'on up to five devices.';

  /// The first benefit carries the live number of locations. Without a
  /// catalog to count there is no number, and the row says so plainly rather
  /// than inventing one.
  static String pwAllLocations(int count) => 'All $count hideip.net locations';
  static const pwAllLocationsPlain = 'All hideip.net locations';
  static const pwSpeed = 'Speed mode on every hideip.net location';
  static const pwSpeedSub = 'WireGuard where the network allows it.';
  static const pwBlocked = 'Works on networks that block VPNs';
  static const pwNoLogs = 'No logs, no account, no email';
  static const pwDevices = 'Up to five devices';
  static const pwSave = 'Save 50%';
  static String pwPer(String per) => 'per $per';
  static String pwPerMonth(String perMonth) =>
      'That is $perMonth per month. The first 7 days are free.';
  static const pwTrialFree = 'The first 7 days are free.';
  static const pwMonthlyNote =
      'Billed monthly. The free trial comes with the yearly plan.';
  static String pwLegalTrial(String date, String store) =>
      'Nothing is charged before |$date|. The plan renews automatically and '
      'can be cancelled anytime in $store settings.';
  static String pwLegalNow(String store) =>
      'The first charge happens right away. The plan renews automatically and '
      'can be cancelled anytime in $store settings.';
  static const pwCtaTrial = 'Start 7-day free trial';
  static const pwCtaBuy = 'Get Premium';
  static const pwFailed = "That didn't go through, and you haven't been "
      'charged. Check your payment method, then try again; or restore an '
      'earlier purchase.';
  static const pwRestore = 'Restore purchases';
  static String pwConfirming(String store) => 'Confirming with the $store';
  static const pwChecking = 'Checking your previous purchases';
  static const pwBusySub = 'This usually takes a moment.';

  // H4, the purchase went through.
  static const pwDoneTitle = "You're in.";
  static const pwDoneTrial = 'Your 7-day free trial is active.';
  static const pwDoneTrialNew =
      'Your 7-day free trial is active. New locations just arrived:';
  static const pwDonePaid = 'Premium is active.';
  static const pwDonePaidNew =
      'Premium is active. New locations just arrived:';
  static String pwDoneLegalTrial(String date) =>
      'First charge on |$date| unless you cancel before then.';
  static String pwDoneLegalPaid(String date) => 'The plan renews on |$date|.';
  static const pwDoneCta = 'Start browsing';
  static String pwPing(int ms) => '$ms ms';

  // --- H6, H7, H8, Premium manage ---
  static const pmBrand = 'hideip.net Premium';
  static String pmPlanName(String plan) => '$plan plan';
  static const pmSubscription = 'Subscription';
  static const pmPlan = 'Plan';
  static const pmTrialEnds = 'Trial ends';
  static const pmRenews = 'Renews';
  static const pmBilling = 'Billing';
  static String pmManage(String store) => 'Manage in $store';
  static const pmManageSub = 'Change plan, cancel, or update payment';
  static String pmSubnote(String store) => 'Billing is handled by the $store;\n'
      'hideip.net never sees your payment details.';
  static const pmRestart = 'Restart Premium';
  static const pmActive = 'Active';
  static const pmExpired = 'Expired';
  static const pmChecking = 'Checking your previous purchases…';

  // --- H5, the trial lapsed ---
  static const expTitle = 'Your free trial has ended';
  static const expBody = 'Nothing was charged. Your settings and imported '
      "connections are untouched; Premium locations are paused until you're "
      'back.';
  static const expPaused = 'Paused locations';
  static const expCta = 'Continue with Premium';
  static const expCtaImport = 'Use your own connection link';

  // ---------------------------------------------------------------------
  // Map and voting.
  // ---------------------------------------------------------------------

  // C1, the map hint. Before the first vote it invites and carries the
  // allowance; after it, the allowance stays on its own.
  static const c1Hint = 'Tap a country to vote for the next location';
  static String c1HintLeft(int left, int max) => '$left of $max left';
  static String c1VotesLeft(int left, int max) => '$left of $max votes left';

  // C2, the vote panel on a country with no hideip.net node yet.
  static String c2Count(int n) => '$n voted for a server here';
  static const c2Vote = 'Vote';
  static const c2NoVotes = 'No votes left';
  static String c2LeftThisRound(int left, int max) =>
      '$left of $max votes left this round';
  static String c2Resets(String date) => 'Votes reset on $date';
  static const c2Anon =
      'Votes are anonymous and stay on this device. No account, no tracking.';

  // C3, the same panel once the country is voted for. The thanks line says
  // what the app can actually do, which depends on the notification
  // permission; it never promises an alert it cannot send.
  static const c3Remove = 'Remove vote';
  static const c3Voted = badgeVoted;
  static String c3ThanksSoon(String country) =>
      'Thanks for voting. We will let you know when $country is up.';
  static const c3ThanksOff =
      'Thanks for voting. Notifications are turned off in system settings.';
  static const c3Thanks = 'Thanks for voting.';

  // Map chrome: the status line under the map, its controls and the labels
  // drawn on the plane itself.
  static const cMapLoading = 'LOADING MAP…';
  static const cMapAll = 'All locations';
  static const cMapRecenter = 'Recenter';
  static String cMapYou(String city) => '$city · you';
  static const cMapYouAnon = 'you';
  static const cMapTagAction = ' · $tConnect';
  static String cMapMs(int ms) => '$ms MS';
  static const cMapMsUnknown = '…';
  static String cMapHudYou(String city, String coords) =>
      'YOU · $city · $coords';
  static const cMapHudYouUnknown = 'YOU · LOCATION UNKNOWN';
  static String cMapHudExit(String city, String? coords, String ping) =>
      'EXIT $city${coords == null ? '' : ' · $coords'} · $ping';
  static String cMapHudExitHost(String host, String ping) =>
      'EXIT $host · $ping';
  static String cMapHudLink(String city) => 'LINK → $city · HANDSHAKE…';
  static const cMapHudClosing = 'CLOSING TUNNEL…';
  static String cMapCoords(String lat, String ns, String lon, String ew) =>
      '$lat°$ns $lon°$ew';

  // ---------------------------------------------------------------------
  // Onboarding v3.
  // ---------------------------------------------------------------------

  /// The three beats. Each headline ships whole and names the one word that
  /// carries the accent colour, so a translation can put that word wherever
  /// its own grammar puts it. The line break is part of the headline.
  static const obB1Title = 'Your IP is\nexposed.';
  static const obB1Accent = 'exposed';
  static const obB1Body =
      'Your IP address and location are public. Every website you open can '
      'read them, along with your internet provider.';
  static const obB1TechKey = 'PUBLIC';
  static const obB1Cta = 'Get started';
  static const obB1Note = 'No account · No logs';

  static const obB2Title = 'One tap\nhides it.';
  static const obB2Accent = 'hides';
  static const obB2Body =
      'Websites see an address from hideip.net, never yours. One button turns '
      'it on and off.';
  static const obB2TechKey = 'SEEN AS';
  static const obB2TechIp = '198.51.100.24';
  static const obB2TechPlace = 'Frankfurt, DE';

  static const obB3Title = 'Works where\nVPNs get blocked.';
  static const obB3Body =
      'Some networks and countries block VPN apps. hideip.net looks like '
      'ordinary browsing, so those blocks miss it.';
  static const obB3TechKey = 'TRAFFIC';
  static const obB3TechValue = 'looks like https';
  static const obB3TechPort = 'port 443';

  /// Metadata separator on the proof line.
  static const obTechSep = '·';

  static const obNext = 'Next';

  /// Beat three replayed from Settings ends the intro instead of asking again.
  static const obDone = 'Done';

  /// Spoken progress. The glyphs themselves are decoration and carry no text.
  static String obStep(int at, int of) => 'Step $at of $of';

  /// The choice screen (skipped on replay).
  static const obChoiceTitle = 'How do you\nwant to start?';
  static const obChoiceBody = 'Both ways work. This can be changed at any time.';
  static const obChoiceTrial = 'Try Premium free for 7 days';
  static const obChoiceTrialSub = 'Locations from hideip.net appear instantly.';
  static const obChoiceImport = 'I have a link, QR code or config';
  static const obChoiceImportSub =
      'From hideip.net, a provider or your own server. The app reads it and '
      'sets everything up.';
  static const obChoiceNote =
      'No account, no sign up. Access can also be added later, in Settings.';
  static const obExplore = 'Explore the app first';

  // ---------------------------------------------------------------------
  // Home ASCII engine. No strings beyond the address samples, which
  // live in the engine because they are drawn glyphs, not copy.
  // ---------------------------------------------------------------------

  // 1.1.1, home hero
  // ---------------------------------------------------------------------

  /// Spoken hint on the address row: a long press opens the details sheet.
  static const homeIpHoldHint = 'Hold for details';

  /// The address sheet: what the lookup knows about the address on show.
  /// A row the lookup could not fill is left out rather than dashed.
  static const heroIpTitle = 'Public IP address';
  static const heroIpAddress = 'Address';
  static const heroIpCity = 'City';
  static const heroIpCountry = 'Country';
  static const heroIpNetwork = 'Network';
}
