import 'package:flutter_riverpod/flutter_riverpod.dart';

class AppTabs {
  static const int dashboard = 0;
  static const int customers = 1;
  static const int plans = 2;
  static const int payments = 3;
  static const int reports = 4;
  static const int settings = 5;
}

final tabIndexProvider = StateProvider<int>((_) => AppTabs.dashboard);

enum AppIntent { addCustomer, recordPayment }

final pendingIntentProvider = StateProvider<AppIntent?>((_) => null);

/// Filter applied to the Plans (Subscriptions) tab. Set by the Dashboard's
/// Payment Due Summary pills before navigating; cleared by the Plans tab's
/// "Clear filter" affordance.
enum PlansFilter { none, overdue, dueToday, thisWeek, upcoming }

final plansFilterProvider = StateProvider<PlansFilter>((_) => PlansFilter.none);

/// Monotonically increasing counter bumped after any local-DB mutation
/// (customer / plan / payment add/edit/delete, reminder send). Tab data
/// providers `ref.watch` it so they re-fetch on the next build, so adding a
/// payment in one tab refreshes the dashboard / customers / plans tabs
/// without the user pressing Refresh. HomeScreen keeps every tab mounted via
/// IndexedStack, so autoDispose alone is not enough.
final dataRevisionProvider = StateProvider<int>((_) => 0);
