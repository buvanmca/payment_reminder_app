import 'dart:async';
import 'dart:io' show Platform;

import 'package:another_telephony/telephony.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sms_template.dart' show computeSmsLength;

/// Outcome of an SMS send attempt. Mirrors [ReminderSendResult] but with the
/// device-side failure modes that matter for SIM sends.
enum SmsSendStatus {
  sent,
  /// SEND_SMS permission missing or denied. The user must grant it; retrying
  /// without action will keep failing.
  permissionDenied,
  /// Running on iOS, web, or desktop. UI should hide SMS entry points; this
  /// check is defensive.
  platformUnsupported,
  /// Transient send failure (no SIM, airplane mode, modem error). Safe to
  /// queue for retry by the offline queue.
  deviceError,
}

class SmsSendResult {
  const SmsSendResult({required this.status, this.error});
  final SmsSendStatus status;
  final String? error;

  bool get sent => status == SmsSendStatus.sent;
}

/// Thin wrapper around `another_telephony` so the rest of the app can depend
/// on a typed result + Riverpod provider rather than the plugin's loose API.
///
/// Sends route through Android's SmsManager using the device's default SMS
/// SIM — no carrier API, no third-party gateway. iOS is intentionally
/// unsupported (Apple does not allow programmatic sends without the system
/// composer); on iOS / web / desktop every call returns
/// [SmsSendStatus.platformUnsupported].
class SmsSender {
  SmsSender([Telephony? telephony])
      : _telephony = telephony ?? Telephony.instance;

  final Telephony _telephony;

  bool get isPlatformSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// Triggers the runtime SEND_SMS permission dialog. MUST be called from a
  /// user gesture (button tap) — Android only shows the dialog in that
  /// context. Returns true iff the user grants permission.
  Future<bool> requestPermission() async {
    if (!isPlatformSupported) return false;
    try {
      final granted = await _telephony.requestSmsPermissions;
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Reads current permission without prompting. Used by the scheduler to
  /// decide whether to attempt an automatic send.
  Future<bool> hasPermission() async {
    if (!isPlatformSupported) return false;
    try {
      final granted = await _telephony.requestSmsPermissions;
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<SmsSendResult> send({
    required String phone,
    required String body,
  }) async {
    if (!isPlatformSupported) {
      return const SmsSendResult(
        status: SmsSendStatus.platformUnsupported,
        error: 'SMS-via-SIM is supported on Android only',
      );
    }
    try {
      final permGranted = await _telephony.requestSmsPermissions;
      if (permGranted != true) {
        return const SmsSendResult(
          status: SmsSendStatus.permissionDenied,
          error: 'SMS permission not granted',
        );
      }
      final completer = Completer<SmsSendResult>();
      Timer? timeout;
      // sendSms reports back via the listener; wrap in a timeout so a stuck
      // modem doesn't hang the dispatcher forever.
      timeout = Timer(const Duration(seconds: 30), () {
        if (!completer.isCompleted) {
          completer.complete(const SmsSendResult(
            status: SmsSendStatus.deviceError,
            error: 'Send timed out',
          ));
        }
      });
      // A single SMS frame holds 160 GSM-7 chars (70 for Unicode). Our default
      // reminder renders the amount with a currency symbol (e.g. ₹) — which is
      // outside GSM-7 and forces UCS-2 — plus a multi-line {details} block, so
      // a real reminder almost always spans multiple segments. SmsManager's
      // single-part sendTextMessage does NOT fragment long bodies (it silently
      // fails / truncates), which is why reminders stopped arriving. Route
      // anything over one segment through the plugin's multipart path
      // (divideMessage + sendMultipartTextMessage).
      final isMultipart = computeSmsLength(body).segments > 1;
      await _telephony.sendSms(
        to: phone,
        message: body,
        isMultipart: isMultipart,
        statusListener: (status) {
          if (completer.isCompleted) return;
          if (status == SendStatus.SENT || status == SendStatus.DELIVERED) {
            timeout?.cancel();
            completer.complete(const SmsSendResult(status: SmsSendStatus.sent));
          }
        },
      );
      // SmsManager does not always emit a SENT/DELIVERED status for messages
      // handed off to the radio. If we haven't heard back after a short grace
      // period, treat the handoff itself as success — failures (no SIM,
      // permission revoked) raise a PlatformException above and end up in the
      // catch block below.
      Timer(const Duration(milliseconds: 500), () {
        if (!completer.isCompleted) {
          timeout?.cancel();
          completer.complete(const SmsSendResult(status: SmsSendStatus.sent));
        }
      });
      return completer.future;
    } catch (e) {
      return SmsSendResult(
        status: SmsSendStatus.deviceError,
        error: e.toString(),
      );
    }
  }
}

final smsSenderProvider = Provider<SmsSender>((_) => SmsSender());
