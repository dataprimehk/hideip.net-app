import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/account_number.dart';

/// Runs [formatter] the way a text field does: from [old] to what the user
/// produced, with the cursor at the end of it unless told otherwise.
TextEditingValue _edit(
  String old,
  String typed, {
  int? cursor,
  TextInputFormatter formatter = const AccountNumberFormatter(),
}) => formatter.formatEditUpdate(
  TextEditingValue(
    text: old,
    selection: TextSelection.collapsed(offset: old.length),
  ),
  TextEditingValue(
    text: typed,
    selection: TextSelection.collapsed(offset: cursor ?? typed.length),
  ),
);

void main() {
  group('the reference numbers', () {
    const valid = [
      '8236387788950319',
      '5997190828766207',
      '1594117572942268',
      '1021047491341032',
      '1234567890123452',
      '9000000000000001',
      '5555555555555557',
    ];

    test('every valid vector passes the check digit', () {
      for (final n in valid) {
        expect(luhnValid(n), isTrue, reason: n);
        expect(isValidAccountNumber(n), isTrue, reason: n);
      }
    });

    test('the invalid vector and a transposition are caught', () {
      expect(luhnValid('1234567890123456'), isFalse);
      expect(isValidAccountNumber('1234567890123456'), isFalse);
      expect(luhnValid('2134567890123452'), isFalse);
      expect(isValidAccountNumber('2134567890123452'), isFalse);
    });

    test('a valid check digit on the wrong length is still not a number', () {
      // 18 is a Luhn-valid string, but no account number is two digits.
      expect(luhnValid('18'), isTrue);
      expect(isValidAccountNumber('18'), isFalse);
      expect(isValidAccountNumber('82363877889503190'), isFalse);
    });

    test('an empty or non-digit string is never valid', () {
      expect(luhnValid(''), isFalse);
      expect(luhnValid('abcd'), isFalse);
      expect(isValidAccountNumber(''), isFalse);
    });
  });

  group('normalizing', () {
    test('keeps the digits and drops every separator', () {
      expect(normalizeAccountNumber('8236 3877 8895 0319'), '8236387788950319');
      expect(normalizeAccountNumber('8236-3877-8895-0319'), '8236387788950319');
      expect(normalizeAccountNumber('8236.3877.8895.0319'), '8236387788950319');
      expect(
        normalizeAccountNumber('  8236\n3877\t8895 0319\n'),
        '8236387788950319',
      );
      expect(
        normalizeAccountNumber('Account: 8236 3877 8895 0319.'),
        '8236387788950319',
      );
    });

    test('reads the digits an Arabic keyboard types', () {
      expect(normalizeAccountNumber('٨٢٣٦ ٣٨٧٧'), '82363877');
      expect(normalizeAccountNumber('۸۲۳۶'), '8236');
    });

    test('a pasted number with separators is valid', () {
      expect(isValidAccountNumber('8236-3877-8895-0319'), isTrue);
    });
  });

  group('showing the number', () {
    test('four groups of four', () {
      expect(displayAccountNumber('8236387788950319'), '8236 3877 8895 0319');
      expect(displayAccountNumber('8236-3877'), '8236 3877');
      expect(displayAccountNumber('823638'), '8236 38');
      expect(displayAccountNumber(''), '');
    });

    test('masked, only the last four show', () {
      expect(maskAccountNumber('8236387788950319'), '•••• •••• •••• 0319');
      expect(maskAccountNumber('8236387788950319', short: true), '•••• 0319');
    });
  });

  group('pulling the number out of a pasted message', () {
    // The trial message from the Telegram bot, copied whole.
    const message = 'Your 24-hour trial is ready. Your hideip.net account '
        'number:\n\n8236 3877 8895 0319\n\nActive until 2 Oct 2026, 14:05 '
        'UTC.\n\nIt works on up to 5 devices.';

    test('a whole bot message gives the number, not the 24 in front', () {
      expect(extractAccountNumber(message), '8236387788950319');
    });

    test('the number in one run or with hyphens is found too', () {
      expect(extractAccountNumber('code 8236387788950319, 5 devices'),
          '8236387788950319');
      expect(extractAccountNumber('24h: 8236-3877-8895-0319'),
          '8236387788950319');
    });

    test('a group with a bad check digit falls back to all the digits', () {
      expect(extractAccountNumber('8236 3877 8895 0318'), '8236387788950318');
    });

    test('plain typing is unchanged', () {
      expect(extractAccountNumber('8236 38'), '823638');
      expect(extractAccountNumber(''), '');
    });

    test('the field formatter keeps only the number from a pasted message',
        () {
      final v = _edit('', message);
      expect(v.text, '8236 3877 8895 0319');
      expect(v.selection.baseOffset, v.text.length);
    });
  });

  group('the field formatter', () {
    test('groups by four while typing', () {
      expect(_edit('', '8').text, '8');
      expect(_edit('823', '8236').text, '8236');
      expect(_edit('8236', '82363').text, '8236 3');
      expect(_edit('8236 3', '8236 38').selection.baseOffset, 7);
    });

    test('drops letters and punctuation as they are typed', () {
      expect(_edit('8236', '8236a').text, '8236');
      expect(_edit('8236', '8236-').text, '8236');
    });

    test('a paste with separators comes out grouped', () {
      final v = _edit('', '8236-3877-8895-0319');
      expect(v.text, '8236 3877 8895 0319');
      expect(v.selection.baseOffset, v.text.length);
      expect(_edit('', '8236.3877\n8895 0319').text, '8236 3877 8895 0319');
    });

    test('a seventeenth digit is refused', () {
      const full = '8236 3877 8895 0319';
      final v = _edit(full, '${full}7');
      expect(v.text, full);
      expect(normalizeAccountNumber(v.text).length, 16);
    });

    test('a paste longer than a number keeps the first sixteen digits', () {
      expect(_edit('', '8236 3877 8895 0319 1234').text, '8236 3877 8895 0319');
    });

    test('the cursor stays behind the same digit after regrouping', () {
      // A digit inserted after the second one, in "8236 3877".
      final v = _edit('8236 3877', '82136 3877', cursor: 3);
      expect(v.text, '8213 6387 7');
      expect(v.selection.baseOffset, 3);
      // Behind the fifth digit, the cursor jumps the space.
      final w = _edit('8236', '82361', cursor: 5);
      expect(w.text, '8236 1');
      expect(w.selection.baseOffset, 6);
    });

    test('deleting a digit regroups what is left', () {
      final v = _edit('8236 3877', '8236 387');
      expect(v.text, '8236 387');
      final w = _edit('8236 3', '8236 ');
      expect(w.text, '8236');
    });
  });
}
