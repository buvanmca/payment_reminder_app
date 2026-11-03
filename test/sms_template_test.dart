import 'package:flutter_test/flutter_test.dart';
import 'package:payment_reminder_app/core/sms_template.dart';

void main() {
  group('renderMessageTemplate', () {
    test('substitutes all known placeholders', () {
      final result = renderMessageTemplate(
        'Hi {name}, your {plan} of {amount} is due on {dueDate}.',
        name: 'Riya',
        amount: 1500,
        dueDate: DateTime(2026, 6, 20),
        plan: 'Monthly',
      );
      // Default currency is INR (₹) until the user picks another in Settings.
      expect(result, 'Hi Riya, your Monthly of ₹1,500 is due on 20 Jun.');
    });

    test('falls back to "subscription" when plan is null', () {
      final result = renderMessageTemplate(
        'Your {plan} payment is due.',
        name: 'X',
        amount: 100,
        dueDate: DateTime(2026, 1, 1),
      );
      expect(result, 'Your subscription payment is due.');
    });

    test('leaves unknown placeholders untouched', () {
      final result = renderMessageTemplate(
        'Hi {name}, balance: {totally_unknown}',
        name: 'Sam',
        amount: 0,
        dueDate: DateTime(2026, 1, 1),
      );
      expect(result, 'Hi Sam, balance: {totally_unknown}');
    });

    test('{amount} includes the currency symbol and lakh grouping (INR default)', () {
      final result = renderMessageTemplate(
        '{amount}',
        name: '',
        amount: 1234567,
        dueDate: DateTime(2026, 1, 1),
      );
      expect(result, '₹12,34,567');
    });

    test('substitutes {currency} with the symbol', () {
      final result = renderMessageTemplate(
        'Pay in {currency}',
        name: 'X',
        amount: 0,
        dueDate: DateTime(2026, 1, 1),
      );
      expect(result, 'Pay in ₹');
    });
  });

  group('renderMessageTemplate {details}', () {
    test('substitutes the {details} block', () {
      final r = renderMessageTemplate(
        'Hi {name}:\n{details}\nTotal {amount}',
        name: 'Riya',
        amount: 3800,
        dueDate: DateTime(2026, 6, 20),
        details: '- Gym: ₹1,500\n- Locker: ₹300',
      );
      expect(r, 'Hi Riya:\n- Gym: ₹1,500\n- Locker: ₹300\nTotal ₹3,800');
    });

    test('empty {details} collapses the blank-line gap', () {
      final r = renderMessageTemplate(
        'A\n\n{details}\n\nB',
        name: 'X',
        amount: 0,
        dueDate: DateTime(2026, 1, 1),
        details: '',
      );
      expect(r, 'A\n\nB');
    });
  });

  group('formatOverdueDetails', () {
    test('bullets each item with lakh-grouped amounts', () {
      final out = formatOverdueDetails([
        (name: 'Gym Monthly', amount: 1500.0),
        (name: 'Personal Training', amount: 234567.0),
      ]);
      expect(out, '- Gym Monthly: ₹1,500\n- Personal Training: ₹2,34,567');
    });

    test('empty list yields empty string', () {
      expect(formatOverdueDetails(const []), '');
    });
  });

  group('computeSmsLength', () {
    test('empty string is 0 segments', () {
      final info = computeSmsLength('');
      expect(info.length, 0);
      expect(info.segments, 0);
      expect(info.isUnicode, false);
    });

    test('short ASCII fits in one GSM-7 segment', () {
      final info = computeSmsLength('Hi Riya, your bill is due tomorrow.');
      expect(info.segments, 1);
      expect(info.isUnicode, false);
    });

    test('161-char ASCII spans two segments', () {
      final body = 'a' * 161;
      final info = computeSmsLength(body);
      expect(info.segments, 2);
      expect(info.isUnicode, false);
    });

    test('any non-ASCII char drops to Unicode 70-char segments', () {
      final info = computeSmsLength('Hi — please pay');
      expect(info.isUnicode, true);
      expect(info.segments, 1);
    });
  });
}
