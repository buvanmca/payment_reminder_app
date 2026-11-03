import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'dart:async' show unawaited;

import 'core/auth_state.dart';
import 'core/config.dart';
import 'core/currency.dart';
import 'core/license_state.dart';
import 'core/mpin_state.dart';
import 'core/offline_reminder_queue.dart';
import 'core/reminder_scheduler.dart';
import 'core/theme_controller.dart';
import 'local/local_db.dart';
import 'screens/home_screen.dart';
import 'screens/license_setup_screen.dart';
import 'screens/login_screen.dart';
import 'screens/mpin_setup_screen.dart';
import 'screens/mpin_unlock_screen.dart';
import 'screens/register_screen.dart';
import 'screens/verify_email_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppConfig.load();
  await CurrencyConfig.load();
  // Open the encrypted local DB once during startup so subsequent reads/writes
  // are synchronous from the app's perspective. Failure here is fatal — without
  // local storage the app cannot operate offline-first.
  await LocalDb.instance.open();
  runApp(const ProviderScope(child: PaymentReminderApp()));
}

class PaymentReminderApp extends ConsumerStatefulWidget {
  const PaymentReminderApp({super.key});

  @override
  ConsumerState<PaymentReminderApp> createState() => _PaymentReminderAppState();
}

class _PaymentReminderAppState extends ConsumerState<PaymentReminderApp> {
  OfflineQueueLifecycleObserver? _offlineQueueObserver;
  ReminderSchedulerLifecycleObserver? _schedulerObserver;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    // Build the router ONCE. Recreating it on every build (which used to
    // happen because `auth` was watched directly in build()) hands MaterialApp
    // a fresh GoRouter whose internal stack restarts at `initialLocation: '/'`
    // — so any auth state change silently navigated to '/' regardless of the
    // redirect's intent. Symptom: a 401 during login put the user on the
    // dashboard because the error branch of the redirect returns null and the
    // brand-new router was already sitting at '/'.
    _router = GoRouter(
      initialLocation: '/',
      redirect: (context, state) {
        final loc = state.matchedLocation;
        final isAuthRoute = loc == '/login' || loc == '/register';
        final isMpinRoute = loc == '/mpin/setup' ||
            loc == '/mpin/unlock' ||
            loc == '/mpin/change';
        // Read auth fresh at redirect time; ref.listen below triggers
        // _router.refresh() so this runs whenever auth changes.
        final auth = ref.read(authControllerProvider);
        final mpin = ref.read(mpinControllerProvider);
        final pending = ref.read(pendingVerificationProvider);
        return auth.when(
          // Only redirect when we have a definite answer about login state.
          data: (s) {
            if (!s.isAuthenticated) {
              // Pending email verification supersedes /login: a fresh
              // signup is in flight and the user has the OTP screen waiting.
              // Allow /verify-email to render; bounce anywhere else there.
              if (pending != null) {
                return loc == '/verify-email' ? null : '/verify-email';
              }
              // No session AND no pending verification — only the auth
              // pages are reachable. The MPIN screens require a live
              // session (they read orgId from the auth snapshot), so bounce
              // off them too.
              return isAuthRoute ? null : '/login';
            }

            // Authenticated. The MPIN gate sits between a valid token and
            // the rest of the app. Wait for the MPIN bootstrap to read
            // secure storage before deciding — otherwise the initial
            // unbootstrapped state (isSet: false) would briefly bounce a
            // returning user through /mpin/setup before /mpin/unlock.
            if (!mpin.bootstrapped) return null;

            // /mpin/change is reachable from Settings while the user is
            // already authenticated AND unlocked. Treat it as a normal
            // in-app screen rather than part of the entry gate so the
            // redirect doesn't bounce the user away on every state tick.
            // Safety: if the prerequisites are missing, fall back to the
            // gate that fixes them.
            if (loc == '/mpin/change') {
              if (!mpin.isSet) return '/mpin/setup';
              if (!mpin.isUnlocked) return '/mpin/unlock';
              return null;
            }

            // Order: setup-if-missing → unlock-if-set, and let the user
            // stay on a /mpin route they've already landed on so taps
            // inside those screens don't bounce.
            if (!mpin.isSet) {
              if (loc == '/mpin/setup') return null;
              return '/mpin/setup';
            }
            if (!mpin.isUnlocked) {
              if (loc == '/mpin/unlock') return null;
              return '/mpin/unlock';
            }

            // Fully authenticated and unlocked: keep them out of
            // auth/mpin/verify pages and let everything else render.
            if (isAuthRoute || isMpinRoute || loc == '/verify-email') {
              return '/';
            }
            return null;
          },
          // Loading: don't bounce — keep the current screen during the brief
          // gap while the API call is in-flight.
          loading: () => null,
          // Error during a login/register/verify attempt: STAY on the
          // originating screen. The screens surface the error in a
          // snackbar; we must not let the user fall through to '/'
          // (HomeScreen) — that's what made bad credentials look like a
          // successful login.
          error: (_, __) {
            if (isAuthRoute) return null;
            if (loc == '/verify-email' && pending != null) return null;
            return '/login';
          },
        );
      },
      routes: [
        GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
        GoRoute(path: '/register', builder: (_, __) => const RegisterScreen()),
        GoRoute(path: '/verify-email', builder: (_, __) => const VerifyEmailScreen()),
        GoRoute(path: '/license', builder: (_, __) => const LicenseSetupScreen()),
        GoRoute(path: '/mpin/setup', builder: (_, __) => const MpinSetupScreen()),
        GoRoute(
          path: '/mpin/change',
          builder: (_, __) => const MpinSetupScreen(isChange: true),
        ),
        GoRoute(path: '/mpin/unlock', builder: (_, __) => const MpinUnlockScreen()),
        GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      ],
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Hydrate MPIN state from secure storage before the router has anything
      // to redirect on. Done here (not in the redirect) so a fresh launch
      // doesn't briefly route through the dashboard while storage is still
      // being read.
      await ref.read(mpinControllerProvider.notifier).bootstrap();
      // Hydrate license state from cache + remote refresh in the background.
      await ref.read(licenseControllerProvider.notifier).bootstrap();

      // Start the offline reminder queue worker. Runs every 30s while in
      // foreground and on app resume; also drains once now in case anything
      // was queued in a previous session.
      final queue = ref.read(offlineReminderQueueProvider);
      queue.start();
      _offlineQueueObserver = OfflineQueueLifecycleObserver(queue);
      WidgetsBinding.instance.addObserver(_offlineQueueObserver!);
      unawaited(queue.drain());

      // Start the local reminder scheduler (replaces the deleted backend
      // Hangfire cron). Honors Settings -> Reminder Configuration.
      final scheduler = ref.read(reminderSchedulerProvider);
      scheduler.start();
      _schedulerObserver = ReminderSchedulerLifecycleObserver(scheduler);
      WidgetsBinding.instance.addObserver(_schedulerObserver!);
      unawaited(scheduler.tick());
    });
  }

  @override
  void dispose() {
    if (_offlineQueueObserver != null) {
      WidgetsBinding.instance.removeObserver(_offlineQueueObserver!);
    }
    if (_schedulerObserver != null) {
      WidgetsBinding.instance.removeObserver(_schedulerObserver!);
    }
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Re-evaluate the redirect on any auth state transition (login success /
    // failure, logout, _restore). Without this the router would never notice
    // the change because it's no longer ref.watch-ing inside build().
    ref.listen(authControllerProvider, (_, __) => _router.refresh());
    // Same for MPIN — flipping isSet (after setup) or isUnlocked (after a
    // correct entry) must drive the redirect immediately so the user lands
    // on the dashboard without an extra tap.
    ref.listen(mpinControllerProvider, (_, __) => _router.refresh());
    // Pending email verification appears post-register and clears on
    // successful OTP entry / cancel. The router uses it to decide between
    // /verify-email and /login while there is no session.
    ref.listen(pendingVerificationProvider, (_, __) => _router.refresh());

    final themeMode = ref.watch(themeControllerProvider);

    const seed = Color(0xFF0078D4);
    return MaterialApp.router(
      title: 'PayBells',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorSchemeSeed: seed,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: seed,
      ),
      routerConfig: _router,
    );
  }
}