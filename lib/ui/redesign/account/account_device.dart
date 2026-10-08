/// One device on the account, as the 1.2.1 screens show it: the K8 row of
/// pairing v2, which knows TVs, tablets and who may manage the account, and
/// the 1.2.0 [LinkedDevice] it grew out of.
library;

export '../../../core/pairing.dart'
    show AccountDevice, DeviceKind, deviceKindOf, kindCanManage;

import 'package:flutter/material.dart' show IconData, Icons;

import '../../../core/pairing.dart';
import '../../strings.dart';

String deviceKindLabel(DeviceKind kind) => switch (kind) {
  DeviceKind.phone => S.accountKindPhone,
  DeviceKind.tablet => S.accountKindTablet,
  DeviceKind.desktop => S.accountKindDesktop,
  DeviceKind.tv => S.accountKindTv,
  DeviceKind.extension => S.accountKindBrowser,
  DeviceKind.unknown => S.accountKindDevice,
};

IconData deviceKindIcon(DeviceKind kind) => switch (kind) {
  DeviceKind.phone => Icons.smartphone_outlined,
  DeviceKind.tablet => Icons.tablet_mac_outlined,
  DeviceKind.desktop => Icons.desktop_windows_outlined,
  DeviceKind.tv => Icons.tv_outlined,
  DeviceKind.extension => Icons.language_outlined,
  DeviceKind.unknown => Icons.devices_other_outlined,
};
