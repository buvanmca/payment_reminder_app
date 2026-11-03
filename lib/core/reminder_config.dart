import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sms_template.dart';

/// User-facing channel preference. Distinct from
/// [ReminderHistoryDao.ReminderChannel] (which only models per-message
/// dispatch); this one lets the user request "both channels" for a single
/// scheduled reminder.
enum ReminderChannel { whatsapp, email, both }

/// Operating mode for the on-device SMS reminder feature. SMS is independent
/// of [ReminderChannel] — a user can have e.g. WhatsApp scheduled and SMS
/// automatic at the same time.
enum SmsMode {
  /// SMS feature off entirely. No buttons shown, scheduler ignores SMS.
  disabled,
  /// "Send SMS" buttons visible per-customer, but the scheduler does NOT
  /// dispatch SMS automatically.
  instant,
  /// Buttons visible AND the scheduler dispatches SMS at the configured time
  /// alongside the user's WhatsApp/email channel.
  automatic,
}

int _channelToWire(ReminderChannel c) => switch (c) {
      ReminderChannel.whatsapp => 1,
      ReminderChannel.email => 2,
      ReminderChannel.both => 4,
    };

ReminderChannel _channelFromWire(int v) => switch (v) {
      1 => ReminderChannel.whatsapp,
      2 => ReminderChannel.email,
      4 => ReminderChannel.both,
      _ => ReminderChannel.whatsapp,
    };

int _smsModeToWire(SmsMode m) => switch (m) {
      SmsMode.disabled => 0,
      SmsMode.instant => 1,
      SmsMode.automatic => 2,
    };

SmsMode _smsModeFromWire(int v) => switch (v) {
      1 => SmsMode.instant,
      2 => SmsMode.automatic,
      _ => SmsMode.disabled,
    };

/// Upgrades templates saved before currency support: the amount now renders
/// with the selected currency symbol via `{amount}`, so a stored literal
/// `Rs.{amount}` would double up ("Rs.$1,500"). Strip the legacy prefix.
String _migrateCurrencyLiteral(String s) =>
    s.replaceAll('Rs.{amount}', '{amount}').replaceAll('Rs. {amount}', '{amount}');

class ReminderConfig {
  const ReminderConfig({
    // WhatsApp is disabled app-wide (see feature_flags.kWhatsAppEnabled), so
    // the default channel is Email. SMS is controlled separately via smsMode.
    this.channel = ReminderChannel.email,
    this.daysBeforeDue = const [7, 3, 1],
    this.sendOnDueDate = true,
    this.sendHour = 9,
    this.sendMinute = 0,
    this.overdueRepeatEveryDays = 2,
    this.overdueMaxFollowUps = 5,
    this.autoRetryOnFailure = true,
    this.maxRetries = 2,
    this.weekdaysOnly = false,
    this.smsMode = SmsMode.disabled,
    this.smsTemplate = defaultSmsTemplate,
    this.emailSubject = defaultEmailSubject,
    this.emailTemplate = defaultEmailBody,
  });

  final ReminderChannel channel;
  final List<int> daysBeforeDue;
  final bool sendOnDueDate;
  final int sendHour;
  final int sendMinute;
  final int overdueRepeatEveryDays;
  final int overdueMaxFollowUps;
  final bool autoRetryOnFailure;
  final int maxRetries;
  final bool weekdaysOnly;
  final SmsMode smsMode;
  final String smsTemplate;
  final String emailSubject;
  final String emailTemplate;

  ReminderConfig copyWith({
    ReminderChannel? channel,
    List<int>? daysBeforeDue,
    bool? sendOnDueDate,
    int? sendHour,
    int? sendMinute,
    int? overdueRepeatEveryDays,
    int? overdueMaxFollowUps,
    bool? autoRetryOnFailure,
    int? maxRetries,
    bool? weekdaysOnly,
    SmsMode? smsMode,
    String? smsTemplate,
    String? emailSubject,
    String? emailTemplate,
  }) {
    return ReminderConfig(
      channel: channel ?? this.channel,
      daysBeforeDue: daysBeforeDue ?? this.daysBeforeDue,
      sendOnDueDate: sendOnDueDate ?? this.sendOnDueDate,
      sendHour: sendHour ?? this.sendHour,
      sendMinute: sendMinute ?? this.sendMinute,
      overdueRepeatEveryDays: overdueRepeatEveryDays ?? this.overdueRepeatEveryDays,
      overdueMaxFollowUps: overdueMaxFollowUps ?? this.overdueMaxFollowUps,
      autoRetryOnFailure: autoRetryOnFailure ?? this.autoRetryOnFailure,
      maxRetries: maxRetries ?? this.maxRetries,
      weekdaysOnly: weekdaysOnly ?? this.weekdaysOnly,
      smsMode: smsMode ?? this.smsMode,
      smsTemplate: smsTemplate ?? this.smsTemplate,
      emailSubject: emailSubject ?? this.emailSubject,
      emailTemplate: emailTemplate ?? this.emailTemplate,
    );
  }

  Map<String, dynamic> toJson() => {
        'channel': _channelToWire(channel),
        'daysBeforeDue': daysBeforeDue,
        'sendOnDueDate': sendOnDueDate,
        'sendHour': sendHour,
        'sendMinute': sendMinute,
        'overdueRepeatEveryDays': overdueRepeatEveryDays,
        'overdueMaxFollowUps': overdueMaxFollowUps,
        'autoRetryOnFailure': autoRetryOnFailure,
        'maxRetries': maxRetries,
        'weekdaysOnly': weekdaysOnly,
        'smsMode': _smsModeToWire(smsMode),
        'smsTemplate': smsTemplate,
        'emailSubject': emailSubject,
        'emailTemplate': emailTemplate,
      };

  factory ReminderConfig.fromJson(Map<String, dynamic> json) {
    return ReminderConfig(
      channel: _channelFromWire((json['channel'] as num?)?.toInt() ?? 1),
      daysBeforeDue: ((json['daysBeforeDue'] as List?) ?? const [7, 3, 1])
          .map((e) => (e as num).toInt())
          .toList(),
      sendOnDueDate: (json['sendOnDueDate'] as bool?) ?? true,
      sendHour: (json['sendHour'] as num?)?.toInt() ?? 9,
      sendMinute: (json['sendMinute'] as num?)?.toInt() ?? 0,
      overdueRepeatEveryDays: (json['overdueRepeatEveryDays'] as num?)?.toInt() ?? 2,
      overdueMaxFollowUps: (json['overdueMaxFollowUps'] as num?)?.toInt() ?? 5,
      autoRetryOnFailure: (json['autoRetryOnFailure'] as bool?) ?? true,
      maxRetries: (json['maxRetries'] as num?)?.toInt() ?? 2,
      weekdaysOnly: (json['weekdaysOnly'] as bool?) ?? false,
      smsMode: _smsModeFromWire((json['smsMode'] as num?)?.toInt() ?? 0),
      smsTemplate: _migrateCurrencyLiteral((json['smsTemplate'] as String?) ?? defaultSmsTemplate),
      emailSubject: _migrateCurrencyLiteral((json['emailSubject'] as String?) ?? defaultEmailSubject),
      emailTemplate: _migrateCurrencyLiteral((json['emailTemplate'] as String?) ?? defaultEmailBody),
    );
  }
}

/// Local-only reminder config controller. Persists to SharedPreferences so
/// the schedule is available offline. The previous backend-side
/// /api/org-settings endpoint and OrganizationSettings table were removed
/// during the local-first refactor — config now lives entirely on-device.
class ReminderConfigController extends StateNotifier<AsyncValue<ReminderConfig>> {
  ReminderConfigController() : super(const AsyncValue.loading()) {
    _load();
  }

  static const _storageKey = 'paybell_reminder_config_v2';
  static const _legacyStorageKey = 'paybell_reminder_config_v1';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var raw = prefs.getString(_storageKey);
      if (raw == null || raw.isEmpty) {
        // One-time migration from the v1 key. fromJson tolerates missing
        // smsMode/smsTemplate fields (defaults to disabled + default
        // template) so the old payload deserializes cleanly.
        final legacy = prefs.getString(_legacyStorageKey);
        if (legacy != null && legacy.isNotEmpty) {
          await prefs.setString(_storageKey, legacy);
          await prefs.remove(_legacyStorageKey);
          raw = legacy;
        }
      }
      if (raw == null || raw.isEmpty) {
        state = const AsyncValue.data(ReminderConfig());
        return;
      }
      final json = jsonDecode(raw) as Map<String, dynamic>;
      state = AsyncValue.data(ReminderConfig.fromJson(json));
    } catch (e, st) {
      // Corrupt stored config: fall back to defaults rather than block the UI.
      state = const AsyncValue.data(ReminderConfig());
      // Best-effort log via assertion in debug.
      assert(() {
        // ignore: avoid_print
        print('reminder config load failed: $e\n$st');
        return true;
      }());
    }
  }

  Future<void> refresh() => _load();

  Future<void> save(ReminderConfig cfg) async {
    state = AsyncValue.data(cfg);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(cfg.toJson()));
  }

  Future<void> reset() => save(const ReminderConfig());

  /// Returns the currently-loaded config (or defaults if not yet loaded).
  /// Useful for the scheduler tick where we don't want to await the provider.
  ReminderConfig get current => state.maybeWhen(
        data: (c) => c,
        orElse: () => const ReminderConfig(),
      );
}

final reminderConfigProvider =
    StateNotifierProvider<ReminderConfigController, AsyncValue<ReminderConfig>>(
  (ref) => ReminderConfigController(),
);