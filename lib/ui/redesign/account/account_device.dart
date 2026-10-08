/// One device on the account, as the 1.2.1 screens show it: the K8 row of
/// pairing v2, which knows TVs, tablets and who may manage the account, and
/// the 1.2.0 [LinkedDevice] it grew out of.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;

import '../../../core/device_link.dart';
import 'account_strings.dart';

/// What kind of device it is. Only ever for the icon and the label: the
/// server decides what a device may do, never the kind it says it is.
enum DeviceKind { phone, tablet, desktop, tv, extension, unknown }

/// Reads a wire `kind`. A kind this build does not know yet is shown as a
/// plain device instead of hiding the row.
DeviceKind deviceKindOf(Object? raw) =>
    switch (raw?.toString().trim().toLowerCase()) {
      'phone' => DeviceKind.phone,
      'tablet' => DeviceKind.tablet,
      'desktop' => DeviceKind.desktop,
      'tv' => DeviceKind.tv,
      'extension' => DeviceKind.extension,
      _ => DeviceKind.unknown,
    };

String deviceKindLabel(DeviceKind kind) => switch (kind) {
  DeviceKind.phone => SA.kindPhone,
  DeviceKind.tablet => SA.kindTablet,
  DeviceKind.desktop => SA.kindDesktop,
  DeviceKind.tv => SA.kindTv,
  DeviceKind.extension => SA.kindBrowser,
  DeviceKind.unknown => SA.kindDevice,
};

IconData deviceKindIcon(DeviceKind kind) => switch (kind) {
  DeviceKind.phone => Icons.smartphone_outlined,
  DeviceKind.tablet => Icons.tablet_mac_outlined,
  DeviceKind.desktop => Icons.desktop_windows_outlined,
  DeviceKind.tv => Icons.tv_outlined,
  DeviceKind.extension => Icons.language_outlined,
  DeviceKind.unknown => Icons.devices_other_outlined,
};

/// Whether a device of [kind] can be given the right to manage the account
/// (K7: phones, tablets and computers only).
bool kindCanManage(DeviceKind kind) =>
    kind == DeviceKind.phone ||
    kind == DeviceKind.tablet ||
    kind == DeviceKind.desktop;

@immutable
class AccountDevice {
  final String id;
  final DeviceKind kind;

  /// What the device calls itself. Never empty: an unnamed device is still
  /// told apart in the list.
  final String name;
  final DateTime? createdAt;
  final DateTime? lastSeenAt;

  /// Whether it may manage the account, or null when the server did not say
  /// (a server from before pairing v2).
  final bool? manage;

  /// The device this list was read on.
  final bool current;

  const AccountDevice({
    required this.id,
    required this.kind,
    required this.name,
    this.createdAt,
    this.lastSeenAt,
    this.manage,
    this.current = false,
  });

  /// One K8 row. Null without an id: a device that cannot be addressed
  /// cannot be removed either.
  static AccountDevice? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id']?.toString().trim() ?? '';
    if (id.isEmpty) return null;
    final name = json['name']?.toString().trim() ?? '';
    final permissions = json['permissions'];
    final manage = permissions is Map ? permissions['manage'] : null;
    return AccountDevice(
      id: id,
      kind: deviceKindOf(json['kind']),
      name: name.isEmpty ? SA.deviceUnnamed : name,
      createdAt: _seconds(json['created_at']),
      lastSeenAt: _seconds(json['last_seen_at']),
      manage: manage is bool ? manage : null,
      current: json['current'] == true,
    );
  }

  /// A 1.2.0 row, which knows no TVs, tablets or permissions.
  factory AccountDevice.fromLinked(LinkedDevice d, {bool current = false}) =>
      AccountDevice(
        id: d.id,
        kind: switch (d.kind) {
          LinkedDeviceKind.phone => DeviceKind.phone,
          LinkedDeviceKind.desktop => DeviceKind.desktop,
          LinkedDeviceKind.extension => DeviceKind.extension,
          LinkedDeviceKind.unknown => DeviceKind.unknown,
        },
        name: d.name,
        createdAt: d.createdAt,
        lastSeenAt: d.lastSeenAt,
        current: current,
      );

  AccountDevice copyWith({bool? manage, bool? current}) => AccountDevice(
    id: id,
    kind: kind,
    name: name,
    createdAt: createdAt,
    lastSeenAt: lastSeenAt,
    manage: manage ?? this.manage,
    current: current ?? this.current,
  );

  String get kindLabel => deviceKindLabel(kind);
}

DateTime? _seconds(Object? raw) {
  final n = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
  if (n == null || n <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(n * 1000);
}
