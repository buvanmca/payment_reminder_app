import 'package:flutter_test/flutter_test.dart';
import 'package:payment_reminder_app/core/sms_template.dart';

/// Pure-Dart coverage for the rendering/segment logic the reminder fixes rely
/// on. The DB-backed pieces (outstanding-as-of-now, active-only reminders,
/// multi-select delete) require a device/FFI sqlite harness and are covered by
/// the manual test checklist instead.
void main() {
  group('SMS multipart decision (task: SMS not sending)', () {
    // The sender now routes anything over one segment through the plugin's
    // multipart path. These tests pin the segment math that drives that
    // decision so a real ₹ reminder is recognised as multi-segment.
    test('default INR reminder with itemized details spans >1 segment', () {
      final details = formatOverdueDetails([
        (name: 'Gym Monthly', amount: 1500.0),
        (name: 'Locker', amount: 300.0),
      ]);
      final body = renderMessageTemplate(
        defaultSmsTemplate,
        name: 'Anand',
        amount: 1800,
        dueDate: DateTime(2026, 6, 20),
        details: details,
      );
      final info = computeSmsLength(body);
      // ₹ is outside GSM-7 → UCS-2 (70-char segments); the body overflows one.
      expect(info.isUnicode, isTrue);
      expect(info.segments, greaterThan(1),
          reason: 'real reminders must be sent multipart, not single-part');
    });

    test('single-plan default reminder is still multi-segment in INR', () {
      final details = formatOverdueDetails([(name: 'Gym Monthly', amount: 1500.0)]);
      final body = renderMessageTemplate(
        defaultSmsTemplate,
        name: 'Riya',
        amount: 1500,
        dueDate: DateTime(2026, 6, 20),
        details: details,
      );
      expect(computeSmsLength(body).segments, greaterThan(1));
    });

    test('short ASCII reminder stays single-segment (no multipart)', () {
      final info = computeSmsLength('Hi Anand, your payment is due tomorrow.');
      expect(info.isUnicode, isFalse);
      expect(info.segments, 1);
    });
  });

  group('details placeholder removal (task: email body formatting)', () {
    final details = formatOverdueDetails([
      (name: 'Gym', amount: 1500.0),
      (name: 'Locker', amount: 300.0),
    ]);

    test('removing {details} drops the itemized section entirely', () {
      const tmpl = 'Dear {name},\n\nPlease pay {amount}.\n\nThank you, PayBell';
      final body = renderMessageTemplate(
        tmpl,
        name: 'Riya',
        amount: 1800,
        dueDate: DateTime(2026, 1, 1),
        details: details,
      );
      // None of the itemized lines must leak in when the placeholder is gone.
      expect(body.contains('Gym'), isFalse);
      expect(body.contains('Locker'), isFalse);
      expect(body.contains('- '), isFalse);
      expect(body, 'Dear Riya,\n\nPlease pay ₹1,800.\n\nThank you, PayBell');
    });

    test('keeping {details} renders the itemized section', () {
      const tmpl = 'Dear {name}:\n{details}\nTotal {amount}';
      final body = renderMessageTemplate(
        tmpl,
        name: 'Riya',
        amount: 1800,
        dueDate: DateTime(2026, 1, 1),
        details: details,
      );
      expect(body.contains('- Gym: ₹1,500'), isTrue);
      expect(body.contains('- Locker: ₹300'), isTrue);
    });
  });
}
