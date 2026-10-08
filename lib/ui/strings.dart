import 'dart:ui' show PlatformDispatcher;
import '../core/subscription.dart';
import '../core/user_subscription.dart';

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
  // These new provider diagnostics follow the system language. The existing
  // interface currently has English strings only.
  static String subscriptionSkipped(SubscriptionResult result, {String? language}) {
    final parts = <String>[];
    for (final entry in result.unsupported.entries) {
      parts.add(_panelText(0, language).replaceAll('{n}', '${entry.value}').replaceAll('{type}', entry.key));
    }
    if (result.errors.length > result.unsupported.values.fold(0, (a, b) => a + b)) {
      parts.add(_panelText(5, language));
    }
    if (result.placeholders > 0) parts.add(_panelText(6, language));
    return parts.join(' ');
  }

  static String subscriptionFailure(SubscriptionFetchException error, {String? language}) {
    final skipped = error.parsed == null ? '' : subscriptionSkipped(error.parsed!, language: language);
    if (skipped.isNotEmpty) return skipped;
    return _panelText(switch (error.reason) {
      SubscriptionFailure.deviceLimit => 1,
      SubscriptionFailure.hwidRequired => 2,
      SubscriptionFailure.placeholder => 6,
      SubscriptionFailure.empty || SubscriptionFailure.noSupportedProfiles => 3,
      SubscriptionFailure.http => 4,
    }, language);
  }

  static String unsupportedProfile(String type) => _panelText(0, null)
      .replaceAll('{n}', '1').replaceAll('{type}', type);

  static String _panelText(int index, String? language) =>
      (_panelMessages[language ?? PlatformDispatcher.instance.locale.languageCode] ?? _panelMessages['en']!)[index];

  static const _panelMessages = <String, List<String>>{
    'en': ['{n} servers skipped: {type} is not supported.', 'Your provider has reached its device limit. Remove a device in the provider’s bot or panel. Saved servers were kept.', 'The provider requires a supported subscription ID (HWID). Contact your provider. Saved servers were kept.', 'The provider returned no supported servers. Saved servers were kept.', 'The subscription could not be refreshed. Saved servers were kept.', 'Some invalid server entries were skipped.', 'The provider returned a status placeholder instead of a server. Check access and device limits in its bot or panel.'],
    'sr': ['Preskočeno servera: {n}. Tip {type} nije podržan.', 'Dostignut je limit uređaja kod prodavca. Uklonite uređaj u njegovom botu ili panelu. Postojeći serveri su sačuvani.', 'Prodavac zahteva podržani ID pretplate (HWID). Obratite se prodavcu. Postojeći serveri su sačuvani.', 'Prodavac nije vratio podržane servere. Postojeći serveri su sačuvani.', 'Pretplata nije osvežena. Postojeći serveri su sačuvani.', 'Neispravni zapisi servera su preskočeni.', 'Prodavac je vratio statusnu poruku umesto servera. Proverite pristup i limit uređaja u njegovom botu ili panelu.'],
    'ru': ['Пропущено серверов: {n}. Тип {type} не поддерживается.', 'Достигнут лимит устройств провайдера. Удалите устройство в его боте или панели. Сохранённые серверы не изменены.', 'Провайдер требует поддерживаемый ID подписки (HWID). Обратитесь к провайдеру. Сохранённые серверы не изменены.', 'Провайдер не вернул поддерживаемых серверов. Сохранённые серверы не изменены.', 'Не удалось обновить подписку. Сохранённые серверы не изменены.', 'Некорректные записи серверов пропущены.', 'Провайдер вернул сообщение о статусе вместо сервера. Проверьте доступ и лимит устройств в его боте или панели.'],
    'fa': ['{n} سرور رد شد: {type} پشتیبانی نمی‌شود.', 'تعداد دستگاه‌ها به سقف مجاز رسیده است. یک دستگاه را در ربات یا پنل ارائه‌دهنده حذف کنید. سرورهای ذخیره‌شده حفظ شدند.', 'ارائه‌دهنده به شناسه اشتراک معتبر (HWID) نیاز دارد. با او تماس بگیرید. سرورهای ذخیره‌شده حفظ شدند.', 'سرور پشتیبانی‌شده‌ای دریافت نشد. سرورهای ذخیره‌شده حفظ شدند.', 'اشتراک به‌روز نشد. سرورهای ذخیره‌شده حفظ شدند.', 'ورودی‌های نامعتبر سرور رد شدند.', 'ارائه‌دهنده به‌جای سرور پیام وضعیت فرستاد. دسترسی و محدودیت دستگاه را در ربات یا پنل او بررسی کنید.'],
    'zh': ['已跳过 {n} 个服务器：不支持 {type}。', '已达到服务商的设备上限。请在其机器人或面板中移除设备。已保留现有服务器。', '服务商要求有效的订阅标识（HWID）。请联系服务商。已保留现有服务器。', '服务商未返回受支持的服务器。已保留现有服务器。', '无法刷新订阅。已保留现有服务器。', '已跳过无效的服务器条目。', '服务商返回了状态信息而非服务器。请在其机器人或面板中检查访问权限和设备限制。'],
    'ar': ['تم تخطي {n} من الخوادم: النوع {type} غير مدعوم.', 'تم بلوغ حد الأجهزة لدى المزود. احذف جهازًا من بوت المزود أو لوحته. تم الاحتفاظ بالخوادم المحفوظة.', 'يتطلب المزود معرّف اشتراك مدعومًا (HWID). تواصل معه. تم الاحتفاظ بالخوادم المحفوظة.', 'لم يُرجع المزود خوادم مدعومة. تم الاحتفاظ بالخوادم المحفوظة.', 'تعذر تحديث الاشتراك. تم الاحتفاظ بالخوادم المحفوظة.', 'تم تخطي إدخالات خوادم غير صالحة.', 'أرجع المزود رسالة حالة بدلًا من خادم. تحقق من الوصول وحد الأجهزة في البوت أو اللوحة.'],
    'tr': ['{n} sunucu atlandı: {type} desteklenmiyor.', 'Sağlayıcının cihaz sınırına ulaşıldı. Sağlayıcının botundan veya panelinden bir cihazı kaldırın. Kayıtlı sunucular korundu.', 'Sağlayıcı desteklenen bir abonelik kimliği (HWID) istiyor. Sağlayıcınıza başvurun. Kayıtlı sunucular korundu.', 'Sağlayıcı desteklenen sunucu döndürmedi. Kayıtlı sunucular korundu.', 'Abonelik yenilenemedi. Kayıtlı sunucular korundu.', 'Geçersiz sunucu kayıtları atlandı.', 'Sağlayıcı sunucu yerine durum mesajı döndürdü. Botunda veya panelinde erişimi ve cihaz sınırlarını kontrol edin.'],
    'de': ['{n} Server übersprungen: {type} wird nicht unterstützt.', 'Das Gerätelimit des Anbieters wurde erreicht. Entfernen Sie ein Gerät im Bot oder Panel des Anbieters. Gespeicherte Server wurden beibehalten.', 'Der Anbieter benötigt eine unterstützte Abonnement-ID (HWID). Kontaktieren Sie ihn. Gespeicherte Server wurden beibehalten.', 'Der Anbieter hat keine unterstützten Server geliefert. Gespeicherte Server wurden beibehalten.', 'Das Abonnement konnte nicht aktualisiert werden. Gespeicherte Server wurden beibehalten.', 'Ungültige Servereinträge wurden übersprungen.', 'Der Anbieter hat eine Statusmeldung statt eines Servers geliefert. Prüfen Sie Zugang und Gerätelimit in seinem Bot oder Panel.'],
    'es': ['Se omitieron {n} servidores: {type} no es compatible.', 'Se alcanzó el límite de dispositivos del proveedor. Elimine un dispositivo en su bot o panel. Se conservaron los servidores guardados.', 'El proveedor requiere un ID de suscripción compatible (HWID). Contacte con él. Se conservaron los servidores guardados.', 'El proveedor no devolvió servidores compatibles. Se conservaron los servidores guardados.', 'No se pudo actualizar la suscripción. Se conservaron los servidores guardados.', 'Se omitieron entradas de servidor no válidas.', 'El proveedor devolvió un mensaje de estado en lugar de un servidor. Revise el acceso y el límite de dispositivos en su bot o panel.'],
    'fr': ['{n} serveurs ignorés : {type} n’est pas pris en charge.', 'La limite d’appareils du fournisseur est atteinte. Supprimez un appareil dans son bot ou panneau. Les serveurs enregistrés ont été conservés.', 'Le fournisseur exige un identifiant d’abonnement compatible (HWID). Contactez-le. Les serveurs enregistrés ont été conservés.', 'Le fournisseur n’a renvoyé aucun serveur compatible. Les serveurs enregistrés ont été conservés.', 'Impossible d’actualiser l’abonnement. Les serveurs enregistrés ont été conservés.', 'Des entrées de serveur invalides ont été ignorées.', 'Le fournisseur a renvoyé un message d’état au lieu d’un serveur. Vérifiez l’accès et la limite d’appareils dans son bot ou panneau.'],
    'pt': ['{n} servidores ignorados: {type} não é suportado.', 'O limite de dispositivos do fornecedor foi atingido. Remova um dispositivo no bot ou painel dele. Os servidores guardados foram mantidos.', 'O fornecedor exige um ID de assinatura suportado (HWID). Contacte-o. Os servidores guardados foram mantidos.', 'O fornecedor não devolveu servidores suportados. Os servidores guardados foram mantidos.', 'Não foi possível atualizar a assinatura. Os servidores guardados foram mantidos.', 'Foram ignoradas entradas de servidor inválidas.', 'O fornecedor devolveu uma mensagem de estado em vez de um servidor. Verifique o acesso e o limite de dispositivos no bot ou painel dele.'],
    'hi': ['{n} सर्वर छोड़े गए: {type} समर्थित नहीं है।', 'प्रदाता की डिवाइस सीमा पूरी हो गई है। उसके बॉट या पैनल से एक डिवाइस हटाएँ। सहेजे गए सर्वर सुरक्षित हैं।', 'प्रदाता को समर्थित सदस्यता ID (HWID) चाहिए। उससे संपर्क करें। सहेजे गए सर्वर सुरक्षित हैं।', 'प्रदाता ने कोई समर्थित सर्वर नहीं भेजा। सहेजे गए सर्वर सुरक्षित हैं।', 'सदस्यता अपडेट नहीं हो सकी। सहेजे गए सर्वर सुरक्षित हैं।', 'अमान्य सर्वर प्रविष्टियाँ छोड़ दी गईं।', 'प्रदाता ने सर्वर के बजाय स्थिति संदेश भेजा। उसके बॉट या पैनल में पहुँच और डिवाइस सीमा जाँचें।'],
  };

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
      'The VPN request was declined. Connecting needs it.';
  static const b14Action = aTryAgain;

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
  static const toastFreeUnavailable =
      'The free location is not available right now';
  static const toastFreeBusy =
      'Too many free sign-ups from this network today';

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
  static const dSwipeHint = 'Swipe a server left to edit or delete it.';

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
      'All hideip.net locations, Speed mode, no logs, no email.';
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

  /// The paywall's line while the free location is on offer: what stays
  /// free, and what Premium adds.
  static String pwSubFree(int mbps) =>
      'The free location runs at up to $mbps Mbit/s. Premium covers the '
      'whole hideip.net network, on up to five devices.';

  /// The first benefit carries the live number of locations. Without a
  /// catalog to count there is no number, and the row says so plainly rather
  /// than inventing one.
  static String pwAllLocations(int count) => 'All $count hideip.net locations';
  static const pwAllLocationsPlain = 'All hideip.net locations';
  static const pwSpeed = 'Speed mode on every hideip.net location';
  static const pwSpeedSub = 'WireGuard where the network allows it.';
  static const pwBlocked = 'Works on networks that block VPNs';
  static const pwNoLogs = 'No logs, no email, no sign up';
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
      'Votes are anonymous and stay on this device. No sign up, no tracking.';

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
  static const obB1Note = 'No email · No logs';

  static const obB2Title = 'A server\nhides it.';
  static const obB2Accent = 'hides';
  static const obB2Body =
      "Websites see the server's address, not yours. No free servers are "
      'built in: add your own link, or use hideip.net locations.';
  static const obB2TechKey = 'SEEN AS';
  static const obB2TechIp = '198.51.100.24';
  static const obB2TechPlace = 'Frankfurt, DE';

  /// Onboarding beat two while the free location is on offer: the beat no
  /// longer says that no free servers are built in.
  static const obB2BodyFree =
      "Websites see the server's address, not yours. One free location is "
      'built in: add your own link, or use hideip.net Premium locations.';

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
      'No email, no sign up. Access can also be added later, in Settings.';
  static const obExplore = 'Explore the app first';

  // ---------------------------------------------------------------------
  // Home ASCII engine. No strings beyond the address samples, which
  // live in the engine because they are drawn glyphs, not copy.
  // ---------------------------------------------------------------------

  // 1.1.1, settings screens.
  static String setPrivacyRowSub(bool on) =>
      on ? 'Usage counts on' : 'Usage counts off';
  static const setPrivacyExplain =
      'Three one-time signals, sent once per install and never again: '
      'opening the app for the first time, adding your first connection, '
      'and completing your first successful connect. Each one carries only '
      'its own name and whether you are on Android or iOS. No IP address, '
      'no account number and no device identifier travels with it.';

  // 1.1.1, home hero
  // ---------------------------------------------------------------------

  /// Spoken hint on the address row: a long press opens the details sheet.
  static const homeIpHoldHint = 'Hold for details';

  /// Ends a search from the field itself, keyboard or no keyboard.
  static const homeSearchCancel = 'Cancel';

  /// The address sheet: what the lookup knows about the address on show.
  /// A row the lookup could not fill is left out rather than dashed.
  static const heroIpTitle = 'Public IP address';
  static const heroIpAddress = 'Address';
  static const heroIpCity = 'City';
  static const heroIpCountry = 'Country';
  static const heroIpNetwork = 'Network';

  // 1.1.1, servers: editing in place, swipe actions, naming and location.

  /// The two buttons a swiped row stops on.
  static const srvEdit = 'Edit';
  static const srvDelete = 'Delete';

  /// The confirmation under Delete: the row's label is the sheet title.
  static const srvRemoveAsk = 'Remove this server?';
  static const srvRemoveBody =
      'It is removed from this device. The link from your provider keeps '
      'working, so it can be added again at any time.';

  /// Edit config, on the detail screen and behind the swipe.
  static const srvEditConfig = 'Edit config';
  static const srvEditConfigSub =
      'Change the keys, the endpoint or anything else in the config.';
  static const srvEditTitle = 'Edit server';
  static const srvSaveChanges = 'Save changes';
  /// Edit mode, first step: the config is read again before it can be saved.
  static const srvEditContinue = 'Continue';
  /// Edit mode, result card: nothing is added, the server is replaced.
  static const srvEditReady = 'Ready to save';
  static String srvUpdated(String name) => '$name updated';
  static const srvConfigDetected = 'Config detected';
  static const srvEditOneOnly =
      'An edit takes one server, and this holds more than one.';
  static const srvEditFromSub =
      'This server comes from a subscription. The next refresh brings back '
      'the version your provider sends.';

  /// The tag on a row or a header that hideip.net runs.
  static const srvBrandTag = 'hideip.net';

  /// The Location row on the detail screen and the picker behind it.
  static const srvLocation = 'Location';
  static const srvLocationUnknown = 'Not known yet';
  static String srvLocationSetByYou(String place) => '$place, set by you';
  static const srvLocationTitle = 'Where is this server?';
  static const srvLocationBody =
      'The country sets the flag and the map pin. The city is optional.';
  static const srvCountrySearch = 'Search countries';
  static const srvCityHint = 'City (optional)';
  static const srvUseDetected = 'Use the detected location';
  static const srvLocationSaved = 'Location updated';

  /// The name field on the import result.
  static const srvNameHint = 'Name';
  static const srvNamedFromPlace =
      'The name comes from where the address is. Change it above if you like.';

  // ---------------------------------------------------------------------
  // Account number (1.2.0). Signing in with a 16-digit account number
  // instead of a store purchase. Nothing here says where a number comes
  // from; the screen is a sign-in and only that.
  // ---------------------------------------------------------------------

  /// The number's own section on the Account screen, and its row on the
  /// Premium page. The screen itself is titled [accountTitle].
  static const accountNumberTitle = 'Account number';

  static const accountHelp =
      'Enter the 16-digit account number of your hideip.net subscription. '
      'It works instead of a username and password.';
  static const accountFieldHint = '0000 0000 0000 0000';
  static const accountCtaSignIn = 'Sign in';
  static const accountPaste = 'Paste';

  /// Why a sign-in did not go through. The server's own words are never
  /// shown; these are.
  static const accountErrInvalid =
      'That does not look like an account number. Check the digits and try '
      'again.';
  static const accountErrUnknown = 'This account number is not recognized.';
  static const accountErrRevoked = 'This account number is no longer valid.';
  static String accountErrDeviceLimit(int n) =>
      'This account is already signed in on $n devices. Remove one from '
      'another device first.';
  static const accountErrNetwork =
      'Could not reach hideip.net. Check your connection and try again.';

  /// Where the account stands. It does not renew, so its date is the day
  /// its time runs out, never a renewal.
  static const accountOutOfTime = 'This account has run out of time.';

  /// Time added to the number anywhere reaches this device by itself; the
  /// line says so without saying where time is added.
  static const accountOutOfTimeNote =
      'Time added to this number shows up here on its own.';
  static const accountCheckAgain = 'Check again';
  static String accountActiveUntil(String date) => 'Active until $date';
  static String accountEndedOn(String date) => 'Ended on $date';

  /// The devices on the account.
  static const accountThisDevice = 'This device';
  static String accountRemoveDevice(String name) => 'Remove $name?';

  /// The number itself, masked until asked for.
  static const accountReveal = 'Show account number';
  static const accountHide = 'Hide';
  static const accountCopy = 'Copy';
  static const accountCopied = 'Account number copied';
  static const accountKeepSafe =
      'Anyone with this number can use your subscription. It is the only way '
      'to access it and it cannot be recovered.';

  /// A new number for the same account.
  static const accountRotate = 'Get a new account number';
  static const accountRotateBody =
      'Your time and devices stay. The old number stops working right away.';
  static const accountRotateAlso = 'Also sign out other devices';
  static const accountRotateDone = 'New account number ready. Save it now.';

  /// Signing out on this device.
  static const accountSignOut = 'Sign out on this device';
  /// What signing out does, in the order people ask it: this device, the
  /// number elsewhere, the way back. The device's slot is given back on the
  /// way out (AppState.signOutAccount).
  static const accountSignOutBody =
      'This device loses Premium and its Premium servers. The account number '
      'keeps working on your other devices, and this device\'s place is freed '
      'for another one. You can sign in again with the same number at any '
      'time.';

  /// Signing out while a store subscription is still running: Premium
  /// stays, only the number leaves.
  static String accountSignOutBodyStore(String store) =>
      'Premium stays on here through your $store subscription. Only the '
      'account number leaves this device: it keeps working on your other '
      'devices, and this device\'s place is freed. You can sign in with it '
      'again at any time.';

  /// The Settings row.
  static const setAccountNumberSub = 'Sign in or manage your account number';
  static const setAccountNumberSignedIn = 'Signed in';

  /// This device was taken off the account from another one. The number is
  /// kept, so signing back in is one tap.
  static const accountDeviceSignedOut = 'This device was signed out.';

  /// The server is limiting attempts from this network for a while.
  static const accountErrTooMany =
      'Too many attempts. Try again in a few minutes.';

  /// A new number was asked for, the answer never came, and the old number
  /// no longer answers: it was most likely issued.
  static const accountRotateLost =
      'The new account number was probably issued but did not reach this '
      'device. Contact support with your proof of purchase to get it.';

  /// Signed in while a store subscription that lasts longer stays in force.
  static const accountSaved = 'Account number saved.';

  // ---------------------------------------------------------------------
  // One account number (1.2.0). The number is the Premium; a store
  // subscription is how time gets added to it.
  // ---------------------------------------------------------------------

  // Written for someone with a phone, a tablet and a TV who only wants to
  // know how the others get Premium and whether that costs again.
  static String accountExplainStore(String store) =>
      'One subscription, up to 5 devices. To add a tablet or another phone, '
      'install hideip.net there and sign in with this number. Your $store '
      'subscription keeps them all paid.';
  static const accountExplain =
      'One number, up to 5 devices. To add a tablet or another phone, '
      'install hideip.net there and sign in with this number.';

  /// The number a store purchase just made, shown once.
  static const accountFreshTitle = 'Your account number';
  static const accountFreshBody =
      'Premium is tied to this number. Save it to use Premium on your other '
      'devices. You can always see it again here.';

  /// The billing row, and its way to the store's own page.
  static String accountBilling(String store, String date) =>
      '$store subscription · renews $date';
  static String accountBillingUndated(String store) => '$store subscription';
  static const accountManage = 'Manage';
  static String accountManageStore(String store) => 'Manage in $store';

  /// Deleting the number for good. The store subscription is the store's.
  static const accountDelete = 'Delete account number';
  static const accountDeleteBody =
      'The number stops working and every device is signed out. This cannot '
      'be undone.';
  static String accountDeleteBodyStore(String store) =>
      'The number stops working and every device is signed out. This cannot '
      'be undone. Your $store subscription is not cancelled by this: it keeps '
      'billing until you cancel it in $store.';
  static const accountDeleted = 'Account number deleted';

  static String accountLinkedElsewhere(String store) =>
      'This $store subscription already adds time to a different account '
      'number.';

  /// Signing out while the store subscription adds time to the number.
  static String accountSignOutBodyLinked(String store) =>
      'This device signs out of the account number. Your $store subscription '
      'keeps adding time to it. Restore purchases signs this device back in.';

  /// A device that signed out while its store subscription keeps paying.
  static String storePausedTitle(String store) =>
      'Your $store subscription is active';
  static const storePausedBody =
      'This device signed out of the account number. Restore your purchase '
      'to use Premium here again.';

  /// A device on the account without its number, putting the number in.
  static const accountEnterNumber = 'Enter account number';

  /// Starting a store subscription on a number that is already in force.
  static String accountSubscribeStore(String store) => 'Subscribe with $store';
  static const accountSubscribeSub =
      'Adds time to this number and renews on its own.';

  /// The 1.2.0 way of linking, offered while the server has nothing newer.
  static const accountLinkCode = 'Show a code instead';

  // ---------------------------------------------------------------------
  // Account (1.2.1). The screen laid out by the questions people ask: does
  // it work and until when, how another device gets it, how it is paid.
  // Then pairing a new device from the code it shows.
  // ---------------------------------------------------------------------

  // --- Screen ---------------------------------------------------------------

  /// The screen title, and the Settings row that leads to it.
  static const accountTitle = 'Account';

  // --- Status card: does it work, and until when ---------------------------

  static const accountStatusOn = 'Premium is on';
  static const accountStatusOff = 'Premium is off';
  static const accountStatusReplaced = 'Number changed';
  static const accountStatusSignedOut = 'Signed out';
  static const accountStatusRevoked = 'Number no longer valid';

  /// Under "Active until {date}": who keeps it going.
  static String accountStatusRenewsThrough(String store) => 'Renews through $store.';
  static const accountStatusEndsUnlessAdded =
      'Ends on that date unless time is added to the number.';

  static const accountStatusReplacedLine =
      'This account number was changed on another device.';

  /// Only said while Premium really is on here.
  static const accountStatusReplacedStillOn = 'Premium still works on this device.';
  static const accountStatusSignedOutLine =
      'This device was signed out from another device.';
  static const accountStatusSignedOutKept =
      'The number is still kept here, so signing back in takes one tap.';

  static const accountCtaSignInNewNumber = 'Sign in with the new number';
  static const accountCtaSignInAnotherNumber = 'Sign in with another number';

  // --- Devices: how do I put it on another device --------------------------

  static const accountDevicesTitle = 'Devices';

  /// "3 of 5", in mono, beside the section label.
  static String accountDevicesCount(int used, int limit) => '$used of $limit';
  static const accountDevicesEmpty = 'No devices are on this account yet.';
  static const accountDevicesFailed = 'The devices could not be loaded.';

  static const accountAddDevice = 'Add a device';
  static const accountAddDeviceSub = 'Phone, tablet, TV, browser or computer';
  static const accountAddDeviceOff =
      'New devices can be added once Premium is on again.';

  /// What a device is, in its row and on the confirmation.
  static const accountKindPhone = 'Phone';
  static const accountKindTablet = 'Tablet';
  static const accountKindTv = 'TV';
  static const accountKindBrowser = 'Browser';
  static const accountKindDesktop = 'Desktop';
  static const accountKindDevice = 'Device';
  static const accountDeviceUnnamed = 'Unnamed device';

  /// The platform a new device reports, by its own name. Null for one this
  /// build does not know, which is then left out rather than shown raw.
  static String? accountPlatform(String? wire) => switch (wire) {
    'android' => 'Android',
    'ios' => 'iOS',
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    'chrome' => 'Chrome',
    _ => null,
  };

  // --- Account number ------------------------------------------------------

  static const accountNumberShow = 'Show';
  static const accountNumberNote =
      'The number signs hideip.net in on another device. Anyone with it can '
      'use this Premium, and it cannot be recovered.';
  static const accountNumberNotHere = 'Not on this device';
  static const accountNumberNotHereNote =
      'Entering the number shows it here and lets the other devices use this '
      'Premium.';

  // --- Payment: how do I pay -----------------------------------------------

  static const accountPaymentTitle = 'Payment';

  // --- More options --------------------------------------------------------

  static const accountMoreOptions = 'More options';
  static const accountRotateSub =
      'Time and devices stay. The old number stops working.';

  // --- Add a device sheet --------------------------------------------------

  static String accountAddShare(int limit) =>
      'Up to $limit devices share this Premium.';
  static String accountAddInUse(int used, int limit) => '$used of $limit are in use.';

  /// The new pairing: the new device shows both, this phone reads either.
  static const accountAddHowV2 =
      'hideip.net on the new device shows a QR code and a short code.';

  /// The 1.2.0 pairing, while the server has nothing newer.
  static const accountAddHowLegacy =
      'A browser or computer shows a QR code that this phone scans.';
  static const accountScanQr = 'Scan QR code';
  static const accountScanQrSub = 'The new device is shown here before it is added.';

  /// Under the full-screen scanner, which only ever reads another device's
  /// code. The import screen has its own hint for a server's code.
  static const accountScanHint =
      'Point the camera at the QR code on the other device';

  static const accountEnterCode = 'Enter code';
  static const accountEnterCodeSub = 'For a TV or computer across the room.';
  static const accountOrSignIn = 'Or sign in on the new device';
  static const accountSignInNote =
      'The account number signs in any device. Anyone with it can use this '
      'Premium.';

  // --- Entering the code the new device shows -------------------------------

  static const accountCodeBody =
      'The code is on the screen of the new device, next to its QR code.';
  static const accountCodeHint = 'XXXX-XXXX';
  static const accountCodeBadChars =
      'This code has a character that hideip.net codes never use. The code '
      'on the new device is worth checking again.';
  static const accountCameraOff =
      'The camera is turned off for hideip.net in system settings. The code '
      'works the same way.';

  // --- Confirming the new device -------------------------------------------

  static const accountConfirmTitle = 'Add this device?';
  static const accountConfirmCodeLabel = 'Request code';
  static const accountConfirmCodeNote =
      'The same code is on the screen of the new device.';
  static const accountGrantManage = 'Can manage this account';
  static const accountGrantManageSub =
      'It can add and remove devices and change the account number.';
  static const accountUseOnly =
      'This device uses Premium. It cannot manage the '
      'account.';
  static String accountExpiresIn(String time) => 'Expires in $time';
  static const accountApprove = 'Add device';
  static const accountApproving = 'Adding…';
  static const accountDoneTitle = 'Device added';
  static String accountDoneBody(String name) => '$name uses this Premium now.';
  static String accountDoneManage(String name) =>
      '$name can also manage this account.';
  static const accountDone = 'Done';

  // --- No place left -------------------------------------------------------

  static String accountLimitTitle(int limit) => 'All $limit places are in use';
  static const accountLimitBody =
      'Removing a device makes room. This request stays open while it is '
      'valid.';

  // --- Why a pairing step did not go through --------------------------------

  static const accountErrUnknownCode =
      'No request matches this code. The code on the new device is worth '
      'checking, or the new device can show a new one.';
  static const accountErrUnknownLink =
      'This request is no longer open. The new device can show a new QR code.';
  static const accountErrBadCode = 'That is not a hideip.net code.';
  static const accountErrExpired =
      'This request has expired. The new device can show a new code.';
  static const accountErrCancelled = 'The new device cancelled this request.';
  static const accountErrInactive =
      'Premium is off on this account, so no device can be added right now.';
  static const accountErrNotPermitted =
      'This device cannot add or change devices on the account. A device '
      'that manages the account can, and so can the account number.';
  static const accountErrUnauthorized =
      'This device is no longer signed in to the account.';
  static const accountErrUnsupported = 'Adding devices this way is not available yet.';
  static const accountErrSelf = 'A device cannot change its own permissions.';

  // --- The last device that manages the account ----------------------------

  static const accountLastManagerTitle = 'Last device that manages the account';
  static const accountLastManagerBody =
      'After this, no device can manage the account. The account number '
      'still can, so it is worth keeping somewhere safe.';

  // --- One device, opened from the list ------------------------------------

  static String accountDeviceAdded(String date) => 'Added $date';
  static String accountDeviceSeen(String date) => 'Last used $date';
  static const accountDeviceNeverUsed = 'Not used yet';
  static const accountDeviceManages = 'Manages the account';

  /// Approving the request this device shows itself. Approval happens on
  /// another device; this one only waits.
  static const accountErrOwnRequest =
      'This is the request this device shows. Another device that manages '
      'the account approves it.';

  // --- This device, asking another one for access ---------------------------

  /// The one way in for someone who already pays, wherever a new device
  /// starts: onboarding, the paywall, an ended trial and an empty Home.
  static const accountHaveSubscription = 'I already have a subscription';

  /// Above the QR code and the short code this device shows.
  static const accountNewDeviceIntro =
      'Another device with this Premium adds this one by scanning the QR '
      'code or entering the short code.';
  static const accountNewDeviceQrLabel = 'QR code that adds this device';
  static const accountNewDeviceWaiting = 'Waiting for the other device.';
  static const accountNewDeviceStoring = 'Signing in…';

  /// Why the code on show stopped working. Each ends with a new code.
  static const accountNewDeviceExpired = 'This code has expired.';
  static const accountNewDeviceCancelled = 'This request was cancelled.';
  static const accountNewDeviceRevoked =
      'The other device took this approval back.';
  static const accountNewDeviceInactive =
      'Premium is off on that account, so this device cannot be added right '
      'now.';
  static const accountNewDeviceNewCode = 'Show a new code';

  /// On a device that already has Premium or an account: nothing is shown
  /// until the move is confirmed.
  static const accountNewDeviceShow = 'Show a code for this device';
  static const accountSwitchTitle = 'Use another account on this device?';
  static const accountSwitchBody =
      'Nothing changes here until the other device adds this one. Then this '
      'device uses that account instead.';
  static String accountSwitchBodyStore(String store) =>
      'Nothing changes here until the other device adds this one. Then this '
      'device uses that account instead. The $store subscription stays with '
      'the account it pays for now.';

  /// Under the code: the account number as the other way in.
  static const accountNewDeviceOrNumber = 'Or sign in with the account number';

  // ---------------------------------------------------------------------
  // Free location (1.2.1). One slower hideip.net location for anyone, with
  // no account: an open row marked Free, never a locked premium row. Its
  // speed comes from the server and arrives as a parameter.
  // ---------------------------------------------------------------------

  /// The badge on a free row, and the label over the free rows.
  static const freeTag = 'Free';

  /// The one row offered before the catalog names a free server.
  static const freeLocation = 'Free location';
  static String freeSpeed(int mbps) => 'Up to $mbps Mbit/s';
  static const freeNoAccount = 'No account needed';

  /// A free server's row: how fast it may go, then where it is, so a
  /// narrow row cuts the place before the speed. Without a limit the place
  /// stands alone.
  static String freeSub(String place, int mbps) =>
      mbps > 0 ? 'Up to $mbps Mbit/s · $place' : place;

  /// While the free key is asked for. The proof the server asks for takes
  /// a few seconds on a phone.
  static const freeGetting = 'Getting the free location ready…';
}
