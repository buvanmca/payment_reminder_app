import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/subscription_banner.dart';
import '../core/tab_controller.dart';
import 'customers_tab.dart';
import 'dashboard_tab.dart';
import 'payments_tab.dart';
import 'reports_tab.dart';
import 'settings_tab.dart';
import 'subscriptions_tab.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const _tabs = <Widget>[
    DashboardTab(),
    CustomersTab(),
    SubscriptionsTab(),
    PaymentsTab(),
    ReportsTab(),
    SettingsTab(),
  ];

  static const _items = <NavigationDestination>[
    NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Dashboard'),
    NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'Customers'),
    NavigationDestination(icon: Icon(Icons.subscriptions_outlined), selectedIcon: Icon(Icons.subscriptions), label: 'Plans'),
    NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Payments'),
    NavigationDestination(icon: Icon(Icons.assessment_outlined), selectedIcon: Icon(Icons.assessment), label: 'Reports'),
    NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(tabIndexProvider);
    return Scaffold(
      body: Column(
        children: [
          const SubscriptionBanner(),
          Expanded(child: IndexedStack(index: index, children: _tabs)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => ref.read(tabIndexProvider.notifier).state = i,
        destinations: _items,
      ),
    );
  }
}
