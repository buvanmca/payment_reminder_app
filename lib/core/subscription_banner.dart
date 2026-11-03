import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'license_state.dart';

/// Banner shown when the license is missing or inactive. Tapping it opens
/// the license setup screen via the GoRouter `/license` route.
class SubscriptionBanner extends ConsumerWidget {
  const SubscriptionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(licenseControllerProvider);
    if (state.isActive) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final color = state.gate == LicenseGate.networkError
        ? theme.colorScheme.tertiaryContainer
        : theme.colorScheme.errorContainer;
    final fg = state.gate == LicenseGate.networkError
        ? theme.colorScheme.onTertiaryContainer
        : theme.colorScheme.onErrorContainer;
    final label = switch (state.gate) {
      LicenseGate.unknown => 'No license activated. Tap to set up.',
      LicenseGate.active => '',
      LicenseGate.expired => 'Subscription expired. Renew to send reminders.',
      LicenseGate.invalid => 'License key not recognized. Tap to fix.',
      LicenseGate.deviceConflict =>
        'License is bound to a different device. Tap for details.',
      LicenseGate.networkError => 'Could not validate license — using cached state.',
    };
    return Material(
      color: color,
      child: InkWell(
        onTap: () => context.push('/license'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: fg, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(label, style: TextStyle(color: fg))),
              Icon(Icons.chevron_right, color: fg, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

/// Helper: gates write actions on subscription status.
class LicenseGuard {
  static bool allowWrite(WidgetRef ref) =>
      ref.read(licenseControllerProvider).isActive;

  static void blockWithMessage(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Subscription inactive — open Settings to renew.'),
        duration: Duration(seconds: 3),
      ),
    );
  }
}