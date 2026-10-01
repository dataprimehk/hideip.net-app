/// The account number: sixteen digits, the last one a Luhn check digit, that
/// stand in for a username and a password on hideip.net.
///
/// Shown in four groups of four (`8236 3877 8895 0319`), always in the mono
/// face. Typed or pasted in any shape: every character that is not a digit
/// is dropped, and the check digit is verified here, before anything is sent,
/// so a typo never reaches the server as an unknown account.
library;

import 'package:flutter/services.dart';

/// How many digits an account number has.
const int accountNumberLength = 16;

/// The digits of [raw], in order, with everything else dropped. Arabic-Indic
/// and Eastern Arabic-Indic digits count as the digits they are, since that
/// is what a numeric keyboard types in those locales.
String normalizeAccountNumber(String raw) {
  final out = StringBuffer();
  for (final rune in raw.runes) {
    if (rune >= 0x30 && rune <= 0x39) {
      out.writeCharCode(rune);
    } else if (rune >= 0x0660 && rune <= 0x0669) {
      out.writeCharCode(0x30 + rune - 0x0660);
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      out.writeCharCode(0x30 + rune - 0x06F0);
    }
  }
  return out.toString();
}

/// The account number inside [raw], for pasted text that may be more than
/// the number: a whole bot message reads "Your 24-hour trial is ready" and a
/// date before and after it, and taking every digit in it would glue the 24
/// onto the front. Looks for sixteen digits standing on their own (in groups
/// of four or in one run) with a valid check digit; without one, it is the
/// plain [normalizeAccountNumber], which is also what typing produces.
String extractAccountNumber(String raw) {
  final ascii = StringBuffer();
  for (final rune in raw.runes) {
    if (rune >= 0x0660 && rune <= 0x0669) {
      ascii.writeCharCode(0x30 + rune - 0x0660);
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      ascii.writeCharCode(0x30 + rune - 0x06F0);
    } else {
      ascii.writeCharCode(rune);
    }
  }
  final grouped = RegExp(r'(?<!\d)\d{4}(?:[ \u00A0-]?\d{4}){3}(?!\d)');
  for (final m in grouped.allMatches(ascii.toString())) {
    final digits = normalizeAccountNumber(m.group(0)!);
    if (luhnValid(digits)) return digits;
  }
  return normalizeAccountNumber(raw);
}

/// The Luhn check (ISO/IEC 7812-1) over [digits16]. False for an empty
/// string or anything that is not made of ASCII digits only.
bool luhnValid(String digits16) {
  if (digits16.isEmpty) return false;
  var total = 0;
  for (var i = 0; i < digits16.length; i++) {
    final unit = digits16.codeUnitAt(digits16.length - 1 - i);
    if (unit < 0x30 || unit > 0x39) return false;
    var d = unit - 0x30;
    if (i.isOdd) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    total += d;
  }
  return total % 10 == 0;
}

/// Whether [raw] holds a well-formed account number: sixteen digits once
/// the separators are gone, with a valid check digit.
bool isValidAccountNumber(String raw) {
  final digits = normalizeAccountNumber(raw);
  return digits.length == accountNumberLength && luhnValid(digits);
}

/// [raw] in four groups of four, separated by a space. A shorter input is
/// grouped as far as it goes.
String displayAccountNumber(String raw) {
  final digits = normalizeAccountNumber(raw);
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && i % 4 == 0) out.write(' ');
    out.write(digits[i]);
  }
  return out.toString();
}

/// The last four digits of [raw] behind dots: `•••• •••• •••• 0319`, or
/// `•••• 0319` when [short].
String maskAccountNumber(String raw, {bool short = false}) {
  final digits = normalizeAccountNumber(raw);
  final tail = digits.length <= 4
      ? digits
      : digits.substring(digits.length - 4);
  return short ? '•••• $tail' : '•••• •••• •••• $tail';
}

/// Keeps the field in the displayed shape while the user types or pastes:
/// digits only, grouped by four, never more than sixteen. The cursor stays
/// behind the same digit it was behind before the regrouping.
class AccountNumberFormatter extends TextInputFormatter {
  const AccountNumberFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var digits = extractAccountNumber(newValue.text);
    if (digits.length > accountNumberLength) {
      digits = digits.substring(0, accountNumberLength);
    }
    final text = displayAccountNumber(digits);
    // How many digits sit in front of the cursor in what was typed.
    final end = newValue.selection.isValid
        ? newValue.selection.end.clamp(0, newValue.text.length)
        : newValue.text.length;
    var before = normalizeAccountNumber(newValue.text.substring(0, end)).length;
    if (before > digits.length) before = digits.length;
    // The same digit count, in the grouped text.
    var offset = 0;
    var seen = 0;
    while (offset < text.length && seen < before) {
      if (text[offset] != ' ') seen++;
      offset++;
    }
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}
