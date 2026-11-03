import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/api_client.dart';
import '../core/auth_state.dart';
import '../core/config.dart';
import '../core/currency.dart';
import '../core/license_state.dart';
import '../core/mpin_state.dart';
import '../core/reminder_dispatcher.dart';
import '../core/tab_controller.dart';
import '../core/theme_controller.dart';
import '../local/backup_service.dart';
import 'pending_reminders_screen.dart';
import 'reminder_config_screen.dart';

class SettingsTab extends ConsumerStatefulWidget {
  const SettingsTab({super.key});
  @override
  ConsumerState<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<SettingsTab> {
  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final email = auth.maybeWhen(data: (s) => s.email ?? '-', orElse: () => '-');

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // Developer-only diagnostics. kDebugMode is false in profile/release
          // builds, so these are hidden in production and visible only in dev.
          if (kDebugMode) ...[
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('Logged in as'),
              subtitle: Text(email),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('Backend URL'),
              subtitle: Text(AppConfig.apiBaseUrl),
              trailing: const Icon(Icons.edit_outlined),
              onTap: _editBackendUrl,
            ),
            ListTile(
              leading: const Icon(Icons.network_check),
              title: const Text('Test connection'),
              subtitle: const Text('Ping the backend health endpoint'),
              onTap: _testConnection,
            ),
          ],
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('Reminder Configuration'),
            subtitle: const Text('Configure reminder cycle, channel and follow-ups'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ReminderConfigScreen(),
              ),
            ),
          ),
          _buildPendingTile(),
          const Divider(),
          _buildLicenseTile(),
          const Divider(),
          _buildMpinTile(),
          const Divider(),
          _buildThemeTile(),
          _buildCurrencyTile(),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.cloud_upload_outlined, color: Colors.indigo),
            title: const Text('Backup data'),
            subtitle: const Text(
                'Export plans, customers, subscriptions, payments and reminder history to a JSON file you can save'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _backupNow,
          ),
          ListTile(
            leading: const Icon(Icons.restore, color: Colors.deepOrange),
            title: const Text('Restore from backup'),
            subtitle: const Text(
                'Import a previously exported backup. Replaces existing data on this device.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _restoreFromFile,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Log out', style: TextStyle(color: Colors.red)),
            onTap: () => ref.read(authControllerProvider.notifier).logout(),
          ),
          const SizedBox(height: 24),
          const Center(
            child: Text(
              'PayBells MVP v0.1\n(c) 2026',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingTile() {
    final count = ref.watch(pendingReminderCountProvider);
    // Lazy-refresh on first build so a fresh launch shows the right count
    // even before the worker's first tick.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final dao = ref.read(pendingRemindersDaoProvider);
      final n = await dao.count();
      if (n != count) {
        ref.read(pendingReminderCountProvider.notifier).state = n;
      }
    });
    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.schedule_send),
          if (count > 0)
            Positioned(
              right: -6,
              top: -4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                ),
              ),
            ),
        ],
      ),
      title: const Text('Pending Reminders'),
      subtitle: Text(
        count == 0
            ? 'No reminders waiting to send'
            : '$count reminder${count == 1 ? '' : 's'} queued offline',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const PendingRemindersScreen()),
      ),
    );
  }

  Widget _buildLicenseTile() {
    final st = ref.watch(licenseControllerProvider);
    final df = DateFormat('dd-MMM-yyyy');
    final hasKey = (st.licenseKey ?? '').isNotEmpty;
    final showDate = st.validUntil != null &&
        (st.gate == LicenseGate.active || st.gate == LicenseGate.expired);
    final statusLabel = switch (st.gate) {
      LicenseGate.active => 'Active',
      LicenseGate.expired => 'Expired',
      LicenseGate.invalid => 'Invalid key',
      LicenseGate.deviceConflict => 'Bound to another device',
      LicenseGate.networkError => 'Offline (cached)',
      LicenseGate.unknown => 'Not activated',
    };
    final statusColor = switch (st.gate) {
      LicenseGate.active => Colors.green.shade700,
      LicenseGate.expired || LicenseGate.invalid || LicenseGate.deviceConflict => Colors.red,
      LicenseGate.networkError => Colors.orange,
      LicenseGate.unknown => Colors.grey,
    };
    final subtitle = StringBuffer();
    if (hasKey) {
      subtitle.write('Key: ${st.licenseKey}');
      if (showDate) subtitle.write('  •  Valid until ${df.format(st.validUntil!)}');
    } else {
      subtitle.write('Tap to activate your license key');
    }
    return ListTile(
      leading: Icon(Icons.verified_user_outlined, color: statusColor),
      title: Row(
        children: [
          const Text('License & Subscription'),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: statusColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              statusLabel,
              style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      subtitle: Text(subtitle.toString()),
      trailing: PopupMenuButton<String>(
        tooltip: 'Actions',
        icon: const Icon(Icons.more_vert),
        onSelected: (v) async {
          if (v == 'open') {
            context.push('/license');
          } else if (v == 'refresh') {
            await _refreshLicense();
          } else if (v == 'clear') {
            await _confirmClearLicense();
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: 'open',
            child: ListTile(
                leading: Icon(Icons.vpn_key_outlined),
                title: Text('Activate / change key')),
          ),
          if (hasKey)
            const PopupMenuItem(
              value: 'refresh',
              child: ListTile(
                  leading: Icon(Icons.refresh), title: Text('Re-validate now')),
            ),
          if (hasKey)
            const PopupMenuItem(
              value: 'clear',
              child: ListTile(
                  leading: Icon(Icons.delete_outline, color: Colors.red),
                  title: Text('Clear license')),
            ),
        ],
      ),
      onTap: () => context.push('/license'),
    );
  }

  Future<void> _refreshLicense() async {
    final st = ref.read(licenseControllerProvider);
    final key = st.licenseKey;
    if (key == null || key.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await ref.read(licenseControllerProvider.notifier).refresh(key);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      backgroundColor: result.isActive ? Colors.green.shade700 : Colors.orange.shade700,
      content: Text('License status: ${result.gate.name}'
          '${result.message != null ? "  -  ${result.message}" : ""}'),
    ));
  }

  Future<void> _confirmClearLicense() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear license?'),
        content: const Text(
            'Removes the stored key and cached state. You will need to re-enter '
            'the key to send reminders or create new records.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(licenseControllerProvider.notifier).clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('License cleared')),
    );
  }

  Widget _buildMpinTile() {
    final mpin = ref.watch(mpinControllerProvider);
    final subtitle = mpin.isSet
        ? 'Used to unlock the app on this device'
        : 'Not set up yet';
    return ListTile(
      leading: const Icon(Icons.pin_outlined),
      title: const Text('MPIN'),
      subtitle: Text(subtitle),
      trailing: PopupMenuButton<String>(
        tooltip: 'MPIN actions',
        icon: const Icon(Icons.more_vert),
        onSelected: (v) async {
          if (v == 'change') {
            await _changeMpin();
          } else if (v == 'reset') {
            await _resetMpin();
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'change',
            child: ListTile(
              leading: const Icon(Icons.lock_reset),
              title: Text(mpin.isSet ? 'Change MPIN' : 'Set up MPIN'),
            ),
          ),
          if (mpin.isSet)
            const PopupMenuItem(
              value: 'reset',
              child: ListTile(
                leading: Icon(Icons.delete_outline, color: Colors.red),
                title: Text('Reset MPIN'),
              ),
            ),
        ],
      ),
    );
  }

  /// Push the change screen, which asks for the current MPIN, then a new
  /// one (rejected if it equals the current). For the "no MPIN yet" case
  /// (theoretical — the Settings tab is gated behind unlock) fall through
  /// to the standard /mpin/setup flow.
  Future<void> _changeMpin() async {
    final mpin = ref.read(mpinControllerProvider);
    if (!mpin.isSet) {
      context.go('/mpin/setup');
      return;
    }
    context.go('/mpin/change');
  }

  Future<void> _resetMpin() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset MPIN?'),
        content: const Text(
            'You will be signed out so you can re-enter your password and '
            'pick a new MPIN.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset & sign out'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(mpinControllerProvider.notifier).clear();
    await ref.read(authControllerProvider.notifier).logout();
  }

  Widget _buildCurrencyTile() {
    final cur = ref.watch(currencyProvider);
    return ListTile(
      leading: const Icon(Icons.payments_outlined),
      title: const Text('Currency'),
      subtitle: Text('${cur.label} — shown across the app and in reminders'),
      trailing: const Icon(Icons.chevron_right),
      onTap: _pickCurrency,
    );
  }

  Future<void> _pickCurrency() async {
    final current = ref.read(currencyProvider);
    final picked = await showDialog<Currency>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Currency'),
        children: [
          for (final c in kSupportedCurrencies)
            RadioListTile<Currency>(
              value: c,
              groupValue: current,
              title: Text(c.label),
              onChanged: (v) => Navigator.pop(ctx, v),
            ),
        ],
      ),
    );
    if (picked == null || picked.code == current.code) return;
    await ref.read(currencyProvider.notifier).set(picked);
    // Bump the data revision so the money-displaying tabs re-render in the new
    // currency without needing a manual refresh.
    ref.read(dataRevisionProvider.notifier).state++;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Currency set to ${picked.label}')),
    );
  }

  Widget _buildThemeTile() {
    final mode = ref.watch(themeControllerProvider);
    final label = switch (mode) {
      ThemeMode.light => 'Light',
      ThemeMode.dark => 'Dark',
      ThemeMode.system => 'System default',
    };
    final icon = switch (mode) {
      ThemeMode.light => Icons.light_mode_outlined,
      ThemeMode.dark => Icons.dark_mode_outlined,
      ThemeMode.system => Icons.brightness_auto_outlined,
    };
    return ListTile(
      leading: Icon(icon),
      title: const Text('Appearance'),
      subtitle: Text(label),
      trailing: const Icon(Icons.chevron_right),
      onTap: _pickTheme,
    );
  }

  Future<void> _pickTheme() async {
    final current = ref.read(themeControllerProvider);
    final picked = await showDialog<ThemeMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Theme'),
        children: [
          RadioListTile<ThemeMode>(
            value: ThemeMode.system,
            groupValue: current,
            title: const Text('System default'),
            secondary: const Icon(Icons.brightness_auto_outlined),
            onChanged: (v) => Navigator.pop(ctx, v),
          ),
          RadioListTile<ThemeMode>(
            value: ThemeMode.light,
            groupValue: current,
            title: const Text('Light'),
            secondary: const Icon(Icons.light_mode_outlined),
            onChanged: (v) => Navigator.pop(ctx, v),
          ),
          RadioListTile<ThemeMode>(
            value: ThemeMode.dark,
            groupValue: current,
            title: const Text('Dark'),
            secondary: const Icon(Icons.dark_mode_outlined),
            onChanged: (v) => Navigator.pop(ctx, v),
          ),
        ],
      ),
    );
    if (picked != null) {
      await ref.read(themeControllerProvider.notifier).setMode(picked);
    }
  }

  Future<void> _editBackendUrl() async {
    final controller = TextEditingController(text: AppConfig.apiBaseUrl);
    final newUrl = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backend URL'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                hintText: 'http://192.168.1.42:5080',
                labelText: 'URL',
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              "Real device on Wi-Fi: use your PC's LAN IP.\n"
              'Android emulator: http://10.0.2.2:5080',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('Reset to default'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newUrl == null) return;
    await AppConfig.setApiBaseUrl(newUrl);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Backend URL set to ${AppConfig.apiBaseUrl}')),
    );
  }

  Future<void> _testConnection() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text('Pinging ${AppConfig.apiBaseUrl}/api/health ...'),
      ),
    );
    try {
      final dio = ref.read(apiClientProvider).dio;
      final res = await dio.get(
        '/api/health',
        options: Options(
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          content: Text('OK (HTTP ${res.statusCode})'),
        ),
      );
    } on DioException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 6),
          content: Text('Failed: ${e.type.name} - ${e.message ?? e.toString()}'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          content: Text('Failed: $e'),
        ),
      );
    }
  }

  Future<void> _backupNow() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final json = await BackupService().exportToJson();
      final stamp = DateFormat('yyyyMMdd-HHmm').format(DateTime.now());
      final filename = 'paybell-backup-$stamp.json';
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, filename));
      await file.writeAsString(json, flush: true);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        subject: 'PayBells backup ($stamp)',
      );
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.green.shade700,
        content: Text('Backup ready: $filename'),
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 6),
        content: Text('Backup failed: $e'),
      ));
    }
  }

  Future<void> _restoreFromFile() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;
      final f = picked.files.first;
      final bytes = f.bytes ??
          (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (bytes == null) {
        throw const BackupException('Could not read the selected file');
      }
      // Cap at ~50 MiB to avoid OOM on a wildly oversized file. A real
      // backup of typical small-business data is well under 5 MiB.
      if (bytes.length > 50 * 1024 * 1024) {
        throw const BackupException('Backup file is unexpectedly large (>50 MB)');
      }
      final text = utf8.decode(bytes);
      final payload = BackupService.parseAndValidate(text);
      final counts = BackupService.countsFromPayload(payload);
      if (!mounted) return;
      final ok = await _confirmRestore(counts, f.name);
      if (ok != true) return;
      final result = await BackupService().restoreFromPayload(payload);
      // Bump the data revision so every tab re-fetches its data.
      ref.read(dataRevisionProvider.notifier).state++;
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.green.shade700,
        duration: const Duration(seconds: 5),
        content: Text('Restored ${result.total} records from ${f.name}'),
      ));
    } on BackupException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 6),
        content: Text(e.message),
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 6),
        content: Text('Restore failed: $e'),
      ));
    }
  }

  Future<bool?> _confirmRestore(Map<String, int> counts, String filename) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore from backup?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Source: $filename',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const Text('This backup contains:'),
            const SizedBox(height: 4),
            Text('  • ${counts['plans'] ?? 0} plans'),
            Text('  • ${counts['customers'] ?? 0} customers'),
            Text('  • ${counts['subscriptions'] ?? 0} subscriptions'),
            Text('  • ${counts['payments'] ?? 0} payments'),
            Text('  • ${counts['reminder_history'] ?? 0} reminder log entries'),
            const SizedBox(height: 12),
            const Text(
              'All current plans, customers, subscriptions, payments and reminder history on this device will be PERMANENTLY REPLACED with the backup contents.',
              style: TextStyle(color: Colors.red),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Replace & Restore'),
          ),
        ],
      ),
    );
  }
}
