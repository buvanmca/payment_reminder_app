import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/feature_flags.dart';
import '../core/reminder_config.dart';
import '../core/sms_sender.dart';
import '../core/sms_template.dart';
import '../widgets/whatsapp_icon.dart';

class ReminderConfigScreen extends ConsumerWidget {
  const ReminderConfigScreen({super.key});

  static const _availableDays = [14, 10, 7, 5, 3, 2, 1];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(reminderConfigProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reminder Configuration'),
        actions: [
          IconButton(
            tooltip: 'Restore defaults',
            icon: const Icon(Icons.restore),
            onPressed: () => _confirmReset(context, ref),
          ),
        ],
      ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (cfg) => _ConfigForm(initial: cfg),
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore defaults?'),
        content: const Text('All reminder settings will be reset to recommended values.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok == true) {
      try {
        await ref.read(reminderConfigProvider.notifier).reset();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Reminder settings restored')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Colors.red.shade700,
              content: Text('Reset failed: $e'),
            ),
          );
        }
      }
    }
  }
}

class _ConfigForm extends ConsumerStatefulWidget {
  const _ConfigForm({required this.initial});
  final ReminderConfig initial;

  @override
  ConsumerState<_ConfigForm> createState() => _ConfigFormState();
}

class _ConfigFormState extends ConsumerState<_ConfigForm> {
  late ReminderConfig _cfg;
  bool _dirty = false;
  late final TextEditingController _smsTemplateCtrl;
  late final TextEditingController _emailSubjectCtrl;
  late final TextEditingController _emailTemplateCtrl;

  bool get _smsAvailable => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    _cfg = widget.initial;
    _smsTemplateCtrl = TextEditingController(text: _cfg.smsTemplate);
    _emailSubjectCtrl = TextEditingController(text: _cfg.emailSubject);
    _emailTemplateCtrl = TextEditingController(text: _cfg.emailTemplate);
  }

  @override
  void dispose() {
    _smsTemplateCtrl.dispose();
    _emailSubjectCtrl.dispose();
    _emailTemplateCtrl.dispose();
    super.dispose();
  }

  void _update(ReminderConfig next) {
    setState(() {
      _cfg = next;
      _dirty = true;
    });
  }

  Future<void> _onSmsModeChanged(SmsMode mode) async {
    if (mode == SmsMode.disabled) {
      _update(_cfg.copyWith(smsMode: mode));
      return;
    }
    final smsSender = ref.read(smsSenderProvider);
    final granted = await smsSender.requestPermission();
    if (!mounted) return;
    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Colors.orange.shade700,
        duration: const Duration(seconds: 5),
        content: const Text(
          'SMS permission denied. Grant SEND_SMS in Android settings to enable.',
        ),
      ));
      _update(_cfg.copyWith(smsMode: SmsMode.disabled));
      return;
    }
    _update(_cfg.copyWith(smsMode: mode));
  }

  void _resetSmsTemplate() {
    _smsTemplateCtrl.text = defaultSmsTemplate;
    _update(_cfg.copyWith(smsTemplate: defaultSmsTemplate));
  }

  void _resetEmailTemplate() {
    _emailSubjectCtrl.text = defaultEmailSubject;
    _emailTemplateCtrl.text = defaultEmailBody;
    _update(_cfg.copyWith(
      emailSubject: defaultEmailSubject,
      emailTemplate: defaultEmailBody,
    ));
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(reminderConfigProvider.notifier).save(_cfg);
      if (!mounted) return;
      setState(() => _dirty = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('Reminder settings saved')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          content: Text('Save failed: $e'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            _SectionHeader(
              icon: Icons.send_outlined,
              title: 'Delivery channel',
              subtitle: 'How reminders are delivered to customers',
            ),
            SegmentedButton<ReminderChannel>(
              // WhatsApp is disabled app-wide (feature_flags.kWhatsAppEnabled);
              // const collection-if works because the flag is a compile-time
              // constant.
              segments: const [
                if (kWhatsAppEnabled)
                  ButtonSegment(
                    value: ReminderChannel.whatsapp,
                    icon: WhatsAppIcon(size: 18),
                    label: Text('WhatsApp'),
                  ),
                ButtonSegment(
                  value: ReminderChannel.email,
                  icon: Icon(Icons.email_outlined),
                  label: Text('Email'),
                ),
                if (kWhatsAppEnabled)
                  ButtonSegment(
                    value: ReminderChannel.both,
                    icon: Icon(Icons.all_inbox_outlined),
                    label: Text('Both'),
                  ),
              ],
              // When WhatsApp is off, a config persisted with channel
              // whatsapp/both has no matching segment — coerce the selection
              // to Email so the control always has a valid value.
              selected: {
                kWhatsAppEnabled ? _cfg.channel : ReminderChannel.email
              },
              onSelectionChanged: (s) => _update(_cfg.copyWith(channel: s.first)),
            ),
            const SizedBox(height: 24),
            ..._buildEmailSection(),
            if (_smsAvailable) ..._buildSmsSection(),
            _SectionHeader(
              icon: Icons.event_repeat_outlined,
              title: 'Reminder cycle',
              subtitle: 'When to send reminders before the due date',
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final d in ReminderConfigScreen._availableDays)
                  FilterChip(
                    label: Text('$d ${d == 1 ? "day" : "days"} before'),
                    selected: _cfg.daysBeforeDue.contains(d),
                    onSelected: (sel) {
                      final next = [..._cfg.daysBeforeDue];
                      if (sel) {
                        next.add(d);
                      } else {
                        next.remove(d);
                      }
                      next.sort((a, b) => b.compareTo(a));
                      _update(_cfg.copyWith(daysBeforeDue: next));
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Send on due date'),
              subtitle: const Text('Final nudge on the day payment is due'),
              value: _cfg.sendOnDueDate,
              onChanged: (v) => _update(_cfg.copyWith(sendOnDueDate: v)),
            ),
            const SizedBox(height: 16),
            _SectionHeader(
              icon: Icons.access_time,
              title: 'Daily send time',
              subtitle: 'Time of day reminders are dispatched',
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.schedule_outlined),
                title: Text(_formatTime(_cfg.sendHour, _cfg.sendMinute)),
                subtitle: const Text('Reminders for the day are queued at this time'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(hour: _cfg.sendHour, minute: _cfg.sendMinute),
                  );
                  if (picked != null) {
                    _update(_cfg.copyWith(sendHour: picked.hour, sendMinute: picked.minute));
                  }
                },
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Weekdays only'),
              subtitle: const Text('Skip reminders on Saturday and Sunday'),
              value: _cfg.weekdaysOnly,
              onChanged: (v) => _update(_cfg.copyWith(weekdaysOnly: v)),
            ),
            const SizedBox(height: 16),
            _SectionHeader(
              icon: Icons.warning_amber_outlined,
              title: 'Overdue follow-up',
              subtitle: 'Repeat reminders if payment is missed',
            ),
            _StepperTile(
              label: 'Repeat every',
              suffix: _cfg.overdueRepeatEveryDays == 1 ? 'day' : 'days',
              value: _cfg.overdueRepeatEveryDays,
              min: 1,
              max: 14,
              onChanged: (v) => _update(_cfg.copyWith(overdueRepeatEveryDays: v)),
            ),
            _StepperTile(
              label: 'Max follow-ups',
              suffix: 'after due',
              value: _cfg.overdueMaxFollowUps,
              min: 0,
              max: 30,
              onChanged: (v) => _update(_cfg.copyWith(overdueMaxFollowUps: v)),
            ),
            const SizedBox(height: 16),
            _SectionHeader(
              icon: Icons.refresh,
              title: 'Delivery retries',
              subtitle: 'What to do when a reminder fails to send',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-retry on failure'),
              value: _cfg.autoRetryOnFailure,
              onChanged: (v) => _update(_cfg.copyWith(autoRetryOnFailure: v)),
            ),
            if (_cfg.autoRetryOnFailure)
              _StepperTile(
                label: 'Max retries',
                suffix: 'attempts',
                value: _cfg.maxRetries,
                min: 1,
                max: 5,
                onChanged: (v) => _update(_cfg.copyWith(maxRetries: v)),
              ),
            const SizedBox(height: 24),
            _SummaryCard(cfg: _cfg),
          ],
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: FilledButton.icon(
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save changes'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: _dirty ? _save : null,
          ),
        ),
      ],
    );
  }

  static String _formatTime(int h, int m) {
    final period = h >= 12 ? 'PM' : 'AM';
    final hour12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    final mm = m.toString().padLeft(2, '0');
    return '$hour12:$mm $period';
  }

  List<Widget> _buildEmailSection() {
    final theme = Theme.of(context);
    final sampleSubject = renderMessageTemplate(
      _cfg.emailSubject,
      name: 'Riya',
      amount: 1500,
      dueDate: DateTime.now().add(const Duration(days: 1)),
      plan: 'Monthly',
    );
    final sampleBody = renderMessageTemplate(
      _cfg.emailTemplate,
      name: 'Riya',
      amount: 1500,
      dueDate: DateTime.now().add(const Duration(days: 1)),
      plan: 'Monthly',
    );
    return [
      const _SectionHeader(
        icon: Icons.email_outlined,
        title: 'Email reminders',
        subtitle: 'Customize the subject and message sent by email',
      ),
      TextFormField(
        controller: _emailSubjectCtrl,
        decoration: const InputDecoration(
          labelText: 'Subject',
          helperText: 'Placeholders: {name}, {plan}, {amount}, {dueDate}',
          border: OutlineInputBorder(),
        ),
        onChanged: (v) => _update(_cfg.copyWith(emailSubject: v)),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _emailTemplateCtrl,
        minLines: 4,
        maxLines: 10,
        decoration: const InputDecoration(
          labelText: 'Message body',
          helperText:
              'Placeholders: {name}, {plan}, {amount}, {dueDate}, {details}. '
              'Remove {details} to drop the itemized list.',
          helperMaxLines: 2,
          border: OutlineInputBorder(),
        ),
        onChanged: (v) => _update(_cfg.copyWith(emailTemplate: v)),
      ),
      const SizedBox(height: 8),
      Card(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Preview', style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              Text('Subject: $sampleSubject',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(sampleBody, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          icon: const Icon(Icons.restore, size: 16),
          label: const Text('Reset to default template'),
          onPressed: _resetEmailTemplate,
        ),
      ),
      const SizedBox(height: 16),
    ];
  }

  List<Widget> _buildSmsSection() {
    final sample = renderMessageTemplate(
      _cfg.smsTemplate,
      name: 'Riya',
      amount: 1500,
      dueDate: DateTime.now().add(const Duration(days: 1)),
      plan: 'Monthly',
    );
    final length = computeSmsLength(sample);
    final theme = Theme.of(context);
    return [
      const _SectionHeader(
        icon: Icons.sms_outlined,
        title: 'SMS reminders (Android)',
        subtitle: 'Send reminders directly from this device\'s SIM',
      ),
      SegmentedButton<SmsMode>(
        segments: const [
          ButtonSegment(value: SmsMode.disabled, label: Text('Off')),
          ButtonSegment(value: SmsMode.instant, label: Text('Instant only')),
          ButtonSegment(value: SmsMode.automatic, label: Text('Automatic')),
        ],
        selected: {_cfg.smsMode},
        onSelectionChanged: (s) => _onSmsModeChanged(s.first),
      ),
      const SizedBox(height: 8),
      if (_cfg.smsMode != SmsMode.disabled) ...[
        Text(
          _cfg.smsMode == SmsMode.instant
              ? 'A "Send SMS" button appears next to each customer with a balance.'
              : 'Plus the scheduler dispatches SMS at the configured send time '
                  '${kWhatsAppEnabled ? "alongside WhatsApp / Email." : "alongside your Email reminders."}',
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _smsTemplateCtrl,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Message template',
            helperText:
                'Placeholders: {name}, {plan}, {amount}, {dueDate}, {details}. '
                'Remove {details} to drop the itemized list.',
            helperMaxLines: 2,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => _update(_cfg.copyWith(smsTemplate: v)),
        ),
        const SizedBox(height: 8),
        Card(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Preview', style: theme.textTheme.labelMedium),
                const SizedBox(height: 4),
                Text(sample, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 6),
                Text(
                  '${length.length} chars - ${length.segments} segment'
                  '${length.segments == 1 ? '' : 's'}'
                  '${length.isUnicode ? ' (Unicode)' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            icon: const Icon(Icons.restore, size: 16),
            label: const Text('Reset to default template'),
            onPressed: _resetSmsTemplate,
          ),
        ),
      ],
      const SizedBox(height: 16),
    ];
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StepperTile extends StatelessWidget {
  const _StepperTile({
    required this.label,
    required this.suffix,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final String suffix;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: value > min ? () => onChanged(value - 1) : null,
          ),
          SizedBox(
            width: 64,
            child: Text(
              '$value $suffix',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: value < max ? () => onChanged(value + 1) : null,
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.cfg});
  final ReminderConfig cfg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final daysList = [...cfg.daysBeforeDue]..sort((a, b) => b.compareTo(a));
    final daysText = daysList.isEmpty ? 'none' : daysList.map((d) => '${d}d').join(', ');
    // WhatsApp is disabled app-wide; a config still persisted as whatsapp/both
    // is reported as Email here to match what the scheduler actually sends.
    final effectiveChannel =
        kWhatsAppEnabled ? cfg.channel : ReminderChannel.email;
    final channelText = switch (effectiveChannel) {
      ReminderChannel.whatsapp => 'WhatsApp',
      ReminderChannel.email => 'Email',
      ReminderChannel.both => 'WhatsApp + Email',
    };
    final smsText = switch (cfg.smsMode) {
      SmsMode.disabled => 'off',
      SmsMode.instant => 'instant only',
      SmsMode.automatic => 'automatic + instant',
    };
    return Card(
      color: theme.colorScheme.primaryContainer.withOpacity(0.4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Summary', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text('Channel: $channelText'),
            Text('SMS reminders: $smsText'),
            Text('Pre-due reminders: $daysText'
                '${cfg.sendOnDueDate ? " + on due date" : ""}'),
            Text('Sent at ${_ConfigFormState._formatTime(cfg.sendHour, cfg.sendMinute)}'
                '${cfg.weekdaysOnly ? " (weekdays only)" : ""}'),
            Text('Overdue: every ${cfg.overdueRepeatEveryDays}d, '
                'up to ${cfg.overdueMaxFollowUps} follow-ups'),
            Text(cfg.autoRetryOnFailure
                ? 'Auto-retry: up to ${cfg.maxRetries} attempts on failure'
                : 'Auto-retry: off'),
          ],
        ),
      ),
    );
  }
}
