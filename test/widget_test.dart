// Smoke test for the app entrypoint.
//
// The previous contents were the default Flutter counter template (it
// referenced a non-existent `MyApp` and never compiled). PaymentReminderApp
// boots SQLCipher, secure storage and auth on first frame, so a full
// `pumpWidget` would need those plugins mocked. This keeps a lightweight check
// that the real root widget compiles and constructs; behavioral coverage lives
// in the pure-Dart suites (sms_template_test.dart, reminder_render_test.dart).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:payment_reminder_app/main.dart';

void main() {
  test('root widget constructs', () {
    const app = PaymentReminderApp();
    expect(app, isA<Widget>());
  });
}
