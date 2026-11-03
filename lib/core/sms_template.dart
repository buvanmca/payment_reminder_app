import 'package:intl/intl.dart';

import 'currency.dart';

/// Default SMS body. Users can override via Reminder Configuration. `{details}`
/// expands to one line per overdue subscription; `{amount}` is the total
/// (rendered with the selected currency symbol, e.g. ₹1,500 / $1,500).
const String defaultSmsTemplate =
    'Hi {name}, your overdue payments:\n{details}\nTotal due: {amount}. - PayBells';

/// Default email subject. Users can override via Reminder Configuration.
/// Supports the same placeholders as the body. Avoids `{plan}` since a customer
/// reminder may cover several plans.
const String defaultEmailSubject = 'Payment reminder — {amount} due';

/// Default email body. Users can override via Reminder Configuration. Rendered
/// on-device with the same placeholders as the SMS template ([renderMessageTemplate]).
/// `{details}` lists each overdue subscription; `{amount}` is the total.
const String defaultEmailBody =
    'Dear {name},\n\n'
    'This is a friendly reminder of your overdue payments:\n\n'
    '{details}\n\n'
    'Total due: {amount}\n\n'
    'Please make the payment at your earliest convenience.\n\n'
    'Thank you,\nPayBells';

/// Renders [template] by substituting `{name}`, `{plan}`, `{amount}`,
/// `{dueDate}`, `{currency}`, and `{details}` with the supplied values.
/// `{amount}` includes the selected currency symbol (e.g. ₹1,500 / $1,500);
/// `{currency}` is just the symbol. `{details}` is an itemized list of overdue
/// subscriptions (see [formatOverdueDetails]); pass null/empty when there's
/// nothing to itemize. Unknown placeholders are left as-is so the user can spot
/// typos in the editor. Shared by the SMS and email reminder editors.
String renderMessageTemplate(
  String template, {
  required String name,
  required double amount,
  required DateTime dueDate,
  String? plan,
  String? details,
}) {
  // Amount is formatted in the currently-selected currency (symbol + grouping).
  final amountFmt = CurrencyConfig.money.format(amount.round());
  final dueFmt = DateFormat('d MMM').format(dueDate);
  final rendered = template
      .replaceAll('{name}', name)
      .replaceAll('{plan}', plan ?? 'subscription')
      .replaceAll('{amount}', amountFmt)
      .replaceAll('{currency}', CurrencyConfig.symbol)
      .replaceAll('{dueDate}', dueFmt)
      .replaceAll('{details}', details ?? '');
  // An empty {details} can leave a 3+ newline gap; collapse to a single blank
  // line so the message stays tidy.
  return rendered.replaceAll(RegExp(r'\n{3,}'), '\n\n');
}

/// Formats overdue subscriptions into the `{details}` block — one bullet line
/// per item, e.g. `- Gym Monthly: $1,500`. Amounts use the selected currency.
String formatOverdueDetails(List<({String name, double amount})> items) {
  return items
      .map((i) => '- ${i.name}: ${CurrencyConfig.money.format(i.amount.round())}')
      .join('\n');
}

/// Result of length analysis for the SMS editor preview.
class SmsLengthInfo {
  const SmsLengthInfo({
    required this.length,
    required this.segments,
    required this.isUnicode,
  });
  final int length;
  final int segments;
  final bool isUnicode;
}

/// Heuristic segment count. Pure GSM-7 messages fit 160 chars per segment
/// (153 in concatenated form); anything containing a non-GSM character drops
/// the limit to 70/67. We do not need exact carrier-perfect math here — only
/// a "your message is N segments" hint for the user.
SmsLengthInfo computeSmsLength(String body) {
  final isUnicode = _hasNonGsmChar(body);
  final length = body.length;
  if (length == 0) return const SmsLengthInfo(length: 0, segments: 0, isUnicode: false);

  final int singleLimit = isUnicode ? 70 : 160;
  final int multiLimit = isUnicode ? 67 : 153;

  final int segments =
      length <= singleLimit ? 1 : ((length + multiLimit - 1) ~/ multiLimit);
  return SmsLengthInfo(length: length, segments: segments, isUnicode: isUnicode);
}

bool _hasNonGsmChar(String s) {
  // GSM-7 covers the basic Latin set, a handful of accented chars, and a
  // small symbol block. Anything outside the BMP basic Latin range we treat
  // as Unicode for sizing purposes — close enough for a UI hint.
  for (final r in s.runes) {
    if (r > 0x7F) return true;
  }
  return false;
}
