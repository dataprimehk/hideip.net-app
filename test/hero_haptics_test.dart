import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hideip_vpn/core/haptics.dart';
import 'package:hideip_vpn/state/app_state.dart';

const _uuid = '11111111-1111-1111-1111-111111111111';
const _link = 'vless://$_uuid@203.0.113.9:443?security=none#de-fra-01';

/// The native side, reduced to what the connect and disconnect paths ask of
/// it. [consent] is what the OS dialog answers.
void _mockVpn({bool consent = true}) {
  var running = false;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('net.hideip.vpn/control'),
          (call) async {
    switch (call.method) {
      case 'prepare':
        return consent;
      case 'isPrepared':
        return consent;
      case 'start':
        running = true;
        return true;
      case 'stop':
        running = false;
        return null;
      case 'status':
        return <String, Object?>{
          'running': running,
          'error': null,
          'alwaysOn': false,
          'lockdown': false,
        };
      case 'stats':
        return <String, Object?>{
          'uplink': 10,
          'downlink': 20,
          'uplinkTotal': 100,
          'downlinkTotal': 200,
        };
    }
    return null;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final pulses = <HapticKind, int>{};
  int count(HapticKind k) => pulses[k] ?? 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    pulses.clear();
    Haptics.sink = (k) => pulses[k] = count(k) + 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  tearDown(() {
    Haptics.sink = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('net.hideip.vpn/control'), null);
  });

  test('the sink takes every pulse and nothing reaches the platform',
      () async {
    var platformCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') platformCalls++;
      return null;
    });
    Haptics.selection();
    Haptics.tap();
    Haptics.success();
    Haptics.error();
    expect(count(HapticKind.selection), 1);
    expect(count(HapticKind.tap), 1);
    expect(count(HapticKind.success), 1);
    expect(count(HapticKind.error), 1);
    expect(platformCalls, 0);
  });

  test('connect lands one medium pulse, and the status poll adds none',
      () async {
    _mockVpn();
    final state = AppState();
    await state.addLink(_link);

    await state.connect();
    expect(state.conn, ConnState.connected);
    expect(count(HapticKind.success), 1);
    expect(count(HapticKind.tap), 0);
    expect(count(HapticKind.error), 0);

    // The poll runs every two seconds while connected and reports the same
    // running tunnel each time. Two ticks later the count must not have moved.
    await Future<void>.delayed(const Duration(milliseconds: 4500));
    expect(count(HapticKind.success), 1);

    await state.disconnect();
    expect(state.conn, ConnState.disconnected);
    expect(count(HapticKind.tap), 1);
    expect(count(HapticKind.success), 1);
    expect(count(HapticKind.error), 0);
  });

  test('a disconnect over an idle tunnel is silent', () async {
    _mockVpn();
    final state = AppState();
    await state.addLink(_link);

    await state.disconnect();
    expect(count(HapticKind.tap), 0);
    expect(count(HapticKind.success), 0);
  });

  test('a refused consent pulses nothing', () async {
    _mockVpn(consent: false);
    final state = AppState();
    await state.addLink(_link);

    await state.connect();
    expect(state.conn, ConnState.disconnected);
    expect(pulses, isEmpty);
  });

  test('a second connection lands its own pulse', () async {
    _mockVpn();
    final state = AppState();
    await state.addLink(_link);

    await state.connect();
    await state.disconnect();
    await state.connect();
    expect(count(HapticKind.success), 2);
    expect(count(HapticKind.tap), 1);
    await state.disconnect();
    expect(count(HapticKind.tap), 2);
  });
}
