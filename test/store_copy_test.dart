import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('store copy source gate passes', () async {
    final result = await Process.run('bash', ['scripts/check-store-copy.sh']);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });
  test('the gate rejects source copy without broad exceptions', () async {
    final root = Directory.systemTemp.createTempSync('store-copy-');
    addTearDown(() => root.deleteSync(recursive: true));
    Directory('${root.path}/lib/core').createSync(recursive: true);
    Directory('${root.path}/assets').createSync();
    final script = File('scripts/check-store-copy.sh').absolute.path;
    final source = File('${root.path}/lib/copy.dart')
      ..writeAsStringSync("const text = 'buy online';");
    var result = await Process.run(
      'bash',
      [script],
      environment: {'STORE_COPY_ROOT': root.path},
    );
    expect(result.exitCode, 1);
    source.writeAsStringSync("const text = 'Get a subscription';");
    result = await Process.run(
      'bash',
      [script],
      environment: {'STORE_COPY_ROOT': root.path},
    );
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    // An identifier counts as much as a sentence.
    source.writeAsStringSync('Future<void> accountRedeem() async {}');
    result = await Process.run(
      'bash',
      [script],
      environment: {'STORE_COPY_ROOT': root.path},
    );
    expect(result.exitCode, 1);
    // The allowlist is exact lines in exact files, never a whole file.
    final catalog = File('${root.path}/lib/core/catalog.dart')
      ..writeAsStringSync("import 'package:cryptography/cryptography.dart';");
    source.writeAsStringSync("const text = 'Get a subscription';");
    result = await Process.run(
      'bash',
      [script],
      environment: {'STORE_COPY_ROOT': root.path},
    );
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    catalog.writeAsStringSync(
      "import 'package:cryptography/cryptography.dart';\n"
      "const pay = 'Pay with crypto';",
    );
    result = await Process.run(
      'bash',
      [script],
      environment: {'STORE_COPY_ROOT': root.path},
    );
    expect(result.exitCode, 1);
    catalog.writeAsStringSync('');
    File('${root.path}/assets/copy.txt').writeAsStringSync('t.me/somewhere');
    result = await Process.run(
      'bash',
      [script],
      environment: {'STORE_COPY_ROOT': root.path},
    );
    expect(result.exitCode, 1);
  });
}
