/// Subscription state for hideip.net Premium.
///
/// The store (StoreKit / Play Billing) is the source of truth: state changes
/// only in response to store events (see PurchaseService). A copy is persisted
/// locally so the UI knows the standing across launches; server-side receipt
/// validation arrives together with the provisioning backend.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum PremiumStatus { none, trial, active, expired }

enum PremiumPlan { monthly, yearly }

/// Where an entitlement comes from: a store subscription, or an account
/// number signed in on this device. The two are separate entitlements; the
/// app runs on whichever lasts longer.
enum PremiumSource { store, account }

/// Store product identifiers, identical on both stores by design.
class PremiumProducts {
  static const monthly = 'net.hideip.vpn.premium.monthly';
  static const yearly = 'net.hideip.vpn.premium.yearly';
  static const all = {monthly, yearly};

  static String idOf(PremiumPlan plan) =>
      plan == PremiumPlan.yearly ? yearly : monthly;

  static PremiumPlan? planOf(String productId) => switch (productId) {
        monthly => PremiumPlan.monthly,
        yearly => PremiumPlan.yearly,
        _ => null,
      };
}

/// The signed proof of a store purchase the provisioning backend re-validates
/// server-side, tagged with the store it came from. iOS carries the StoreKit 2
/// [jws]; Android carries the Play [purchaseToken]. [productId] identifies the
/// plan on both. Persisted as JSON so a provision that failed offline can be
/// retried on a later launch (see [PremiumSub]).
class PurchasePayload {
  final String platform; // 'ios' | 'android'
  final String? jws; // iOS: StoreKit 2 signed transaction
  final String? purchaseToken; // Android: Play purchase token
  final String productId;

  const PurchasePayload({
    required this.platform,
    required this.productId,
    this.jws,
    this.purchaseToken,
  });

  const PurchasePayload.ios({required String jws, required String productId})
      : this(platform: 'ios', jws: jws, productId: productId);

  const PurchasePayload.android(
      {required String purchaseToken, required String productId})
      : this(
            platform: 'android',
            purchaseToken: purchaseToken,
            productId: productId);

  Map<String, dynamic> toJson() => {
        'platform': platform,
        if (jws != null) 'jws': jws,
        if (purchaseToken != null) 'purchaseToken': purchaseToken,
        'productId': productId,
      };

  /// Parse a persisted payload. A legacy record is a bare JWS string (iOS was
  /// the only store when the field was written); treat it as an iOS payload so
  /// existing subscribers keep re-provisioning across the upgrade. The product
  /// id is unknown for those, but the backend derives the plan from the JWS.
  static PurchasePayload? tryParse(String raw) {
    if (raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return PurchasePayload(
        platform: map['platform'] as String? ?? 'ios',
        jws: map['jws'] as String?,
        purchaseToken: map['purchaseToken'] as String?,
        productId: map['productId'] as String? ?? '',
      );
    } catch (_) {
      // Not JSON: a legacy bare-JWS record from the iOS-only era.
      return PurchasePayload.ios(jws: raw, productId: '');
    }
  }
}

/// Display data for the two variants of the single Premium plan. Prices are
/// USD fallbacks for when the store catalog has not loaded (yet); live,
/// locale-priced values come through [withPrice].
class PlanInfo {
  final String name;
  final String price;
  final String per;

  /// How the plan bills, as a phrase: the fallback for when there is nothing
  /// better to say than the period itself.
  final String period;

  /// Whether the first period is the 7-day free trial (yearly only).
  final bool trial;

  /// The yearly total restated as a monthly figure, when it can be stated at
  /// all. [withPrice] drops it: a per-month amount cannot be worked out from
  /// a formatted total in a currency this app does not parse, and a wrong
  /// one would be a price claim.
  final String? perMonth;

  const PlanInfo(this.name, this.price, this.per, this.period,
      {this.trial = false, this.perMonth});

  static const yearly = PlanInfo('Yearly', r'$29.99', 'year', 'billed yearly',
      trial: true, perMonth: r'$2.50');
  static const monthly =
      PlanInfo('Monthly', r'$4.99', 'month', 'billed monthly');

  static PlanInfo of(PremiumPlan plan) =>
      plan == PremiumPlan.yearly ? yearly : monthly;

  /// The plan's short note under its name: the monthly equivalent where one
  /// is known, the billing period otherwise.
  String get note => perMonth == null ? period : '$perMonth per month';

  /// The same plan with the store's localized price string.
  PlanInfo withPrice(String price) =>
      PlanInfo(name, price, per, period, trial: trial);
}

class Premium {
  static const _kPrefs = 'premium_v1';

  final PremiumStatus status;
  final PremiumPlan? plan;

  /// When the period ends. For a store subscription that is the renewal
  /// date; an account number does not renew, so for one it is simply the
  /// day its time runs out.
  final DateTime? renews;
  final PremiumSource source;

  const Premium.none()
      : status = PremiumStatus.none,
        plan = null,
        renews = null,
        source = PremiumSource.store;

  const Premium({
    required this.status,
    this.plan,
    this.renews,
    this.source = PremiumSource.store,
  });

  bool get isOn =>
      status == PremiumStatus.trial || status == PremiumStatus.active;

  Premium copyWith({
    PremiumStatus? status,
    PremiumPlan? plan,
    DateTime? renews,
    PremiumSource? source,
  }) =>
      Premium(
        status: status ?? this.status,
        plan: plan ?? this.plan,
        renews: renews ?? this.renews,
        source: source ?? this.source,
      );

  /// Load the persisted standing. A subscription whose period lapsed while
  /// the app was closed comes back as [PremiumStatus.expired]; the next store
  /// event (a renewal arriving on the purchase stream) un-expires it.
  static Future<Premium> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPrefs);
    if (raw == null || raw.isEmpty) return const Premium.none();
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      var status = PremiumStatus.values.byName(map['status'] as String);
      final planName = map['plan'] as String?;
      final renewsMs = map['renews'] as int?;
      final renews = renewsMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(renewsMs);
      if (renews != null &&
          renews.isBefore(DateTime.now()) &&
          (status == PremiumStatus.trial || status == PremiumStatus.active)) {
        status = PremiumStatus.expired;
      }
      // Written before account numbers existed, a record has no source and
      // is a store subscription.
      final sourceName = map['source'] as String?;
      return Premium(
        status: status,
        plan: planName == null ? null : PremiumPlan.values.byName(planName),
        renews: renews,
        source: PremiumSource.values.asNameMap()[sourceName] ??
            PremiumSource.store,
      );
    } catch (_) {
      return const Premium.none();
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kPrefs,
        jsonEncode({
          'status': status.name,
          'plan': plan?.name,
          'renews': renews?.millisecondsSinceEpoch,
          'source': source.name,
        }));
  }
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Jul 26, 2026", matching the prototype's date style without pulling intl.
String formatPremiumDate(DateTime d) =>
    '${_months[d.month - 1]} ${d.day}, ${d.year}';
