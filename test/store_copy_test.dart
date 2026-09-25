import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Runs the copy gate against a throwaway tree holding [files] (path to
/// contents) and returns its exit code.
Future<int> _gate(Map<String, String> files, {bool withLib = true}) async {
  final root = Directory.systemTemp.createTempSync('store-copy-');
  addTearDown(() => root.deleteSync(recursive: true));
  if (withLib) Directory('${root.path}/lib').createSync();
  files.forEach((path, text) {
    File('${root.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  });
  final result = await Process.run(
    'bash',
    [File('scripts/check-store-copy.sh').absolute.path],
    environment: {'STORE_COPY_ROOT': root.path},
  );
  return result.exitCode;
}

void main() {
  test('the app itself passes the gate', () async {
    final result = await Process.run('bash', ['scripts/check-store-copy.sh']);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });

  test('plain sign-in copy passes', () async {
    expect(await _gate({'lib/ui/x.dart': "const a = 'Sign in';"}), 0);
  });

  test('every way of pointing at a purchase elsewhere fails', () async {
    const refused = {
      'bot handle': "const a = 'Get a number from @hideipbot';",
      'card on the site': "const a = 'Buy with card on our website';",
      'buy at the site': "const a = 'Buy at hideip.net';",
      'a license': "const a = 'Enter license';",
      'the premium page': "const a = 'hideip.net/premium';",
      'a price': r"const a = 'Only $2.99 on the web';",
      'a pay page': "const a = 'https://hideip.net/pay';",
      'a payment provider': "const a = 'Pay with Stripe';",
      'a messenger': "const a = 'Open Telegram';",
      'shouting': "const a = 'TELEGRAM';",
      'a deep link': "const a = 'tg://resolve?domain=hideipbot';",
      'a short link': "const a = 'https://t.me/hideipbot';",
      'an identifier': 'Future<void> accountRedeem() async {}',
      'a word split across literals': "const a = 'tele' 'gram';",
      'a word split across lines': "const a = 'Pay with '\n    'Str' 'ipe';",
    };
    for (final entry in refused.entries) {
      expect(await _gate({'lib/ui/x.dart': entry.value}), 1, reason: entry.key);
    }
  });

  test('a file name with a colon in it is still read', () async {
    expect(await _gate({'lib/a:b.dart': "const a = 'x: telegram';"}), 1);
  });

  test('assets, iOS resources and the changelog are read too', () async {
    expect(await _gate({'assets/a.json': '{"x":"Pay via Telegram Stars"}'}), 1);
    expect(
      await _gate({
        'lib/a.dart': 'const a = 1;',
        'ios/Runner/Info.plist': '<string>Buy on Telegram</string>',
      }),
      1,
    );
    expect(
      await _gate({
        'android/app/src/main/res/values/strings.xml':
            '<string name="a">Use a coupon</string>',
      }),
      1,
    );
    expect(await _gate({'CHANGELOG.md': '- Pay by card on the site.'}), 1);
  });

  test('the exceptions are exact lines in exact files', () async {
    const import = "import 'package:cryptography/cryptography.dart';";
    expect(await _gate({'lib/core/catalog.dart': import}), 0);
    // The same line anywhere else is not excepted.
    expect(await _gate({'lib/ui/x.dart': import}), 1);
    // Nor is anything added to the excepted line.
    expect(await _gate({'lib/core/catalog.dart': '$import // stripe'}), 1);
    // Nor a second line in the excepted file.
    expect(
      await _gate({
        'lib/core/catalog.dart': "$import\nconst pay = 'Pay with crypto';",
      }),
      1,
    );
  });

  test('a tree with no lib/ is refused rather than passed', () async {
    expect(await _gate(const {}, withLib: false), 1);
  });
}
