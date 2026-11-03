import 'dart:async' show unawaited;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../local/device_id.dart';
import '../local/local_db.dart';
import 'api_client.dart';
import 'auth_storage.dart';
import 'license_state.dart';
import 'mpin_state.dart';
import 'tab_controller.dart';

class AuthSnapshot {
  const AuthSnapshot({this.token, this.email, this.name, this.orgId});
  final String? token;
  final String? email;
  final String? name;
  final String? orgId;
  bool get isAuthenticated => token != null && token!.isNotEmpty;
}

/// Snapshot of an in-flight email-verification challenge. Set by
/// AuthController.register on a successful submit, cleared by
/// AuthController.verifyEmail on success or AuthController.logout. While
/// non-null, the router parks the user on /verify-email.
class PendingVerification {
  const PendingVerification({
    required this.email,
    required this.expiresAtUtc,
    required this.resendAvailableAtUtc,
    required this.attemptsRemaining,
    required this.deliveredByEmail,
  });

  final String email;
  final DateTime expiresAtUtc;
  final DateTime resendAvailableAtUtc;
  final int attemptsRemaining;
  /// False when the backend is in dev mode (SMTP not configured) and the
  /// OTP was logged to console rather than mailed. The verify screen
  /// surfaces a hint so testers know where to find it.
  final bool deliveredByEmail;

  PendingVerification copyWith({
    DateTime? expiresAtUtc,
    DateTime? resendAvailableAtUtc,
    int? attemptsRemaining,
    bool? deliveredByEmail,
  }) =>
      PendingVerification(
        email: email,
        expiresAtUtc: expiresAtUtc ?? this.expiresAtUtc,
        resendAvailableAtUtc: resendAvailableAtUtc ?? this.resendAvailableAtUtc,
        attemptsRemaining: attemptsRemaining ?? this.attemptsRemaining,
        deliveredByEmail: deliveredByEmail ?? this.deliveredByEmail,
      );

  static PendingVerification fromJson(Map<String, dynamic> json) =>
      PendingVerification(
        email: (json['email'] as String?) ?? '',
        expiresAtUtc: DateTime.tryParse(json['expiresAtUtc'] as String? ?? '')
                ?.toUtc() ??
            DateTime.now().toUtc().add(const Duration(minutes: 10)),
        resendAvailableAtUtc:
            DateTime.tryParse(json['resendAvailableAtUtc'] as String? ?? '')
                    ?.toUtc() ??
                DateTime.now().toUtc(),
        attemptsRemaining: (json['attemptsRemaining'] as num?)?.toInt() ?? 5,
        deliveredByEmail:
            (json['deliveredByEmail'] as bool?) ?? false,
      );
}

/// Holds the in-flight verification, or null when no signup is awaiting OTP.
/// Lives only in memory — a fresh app launch with no token AND nothing here
/// lands on /login, which is the right behavior (the email is in the user's
/// inbox; a re-launch shouldn't trap them on a verify screen with no way
/// out except retyping their email at register).
final pendingVerificationProvider =
    StateProvider<PendingVerification?>((_) => null);

class AuthController extends StateNotifier<AsyncValue<AuthSnapshot>> {
  AuthController(this._api, this._storage, this._ref) : super(const AsyncValue.loading()) {
    _restore();
  }

  final ApiClient _api;
  final AuthStorage _storage;
  final Ref _ref;

  /// Wipes everything that's user-scoped on this device: encrypted SQLite
  /// (customers / subscriptions / payments / reminders / license cache),
  /// the in-memory + persisted license state, the device-local MPIN, and
  /// bumps the data revision so every tab refetches against the empty DB.
  /// Centralised here so logout / register / login-as-different-user all do
  /// the same thing.
  Future<void> _wipeLocalUserState() async {
    try {
      await _ref.read(licenseControllerProvider.notifier).clear();
    } catch (_) {/* keep going — DB wipe is the more important half. */}
    try {
      await _ref.read(mpinControllerProvider.notifier).clear();
    } catch (_) {/* MPIN reset will be re-triggered on next login. */}
    try {
      await LocalDb.instance.wipeUserData();
    } catch (_) {/* non-fatal; user can re-trigger via logout. */}
    _ref.read(dataRevisionProvider.notifier).state++;
  }

  /// Reset transient navigation state so a fresh login always lands on the
  /// Dashboard — not on whatever tab the previous session left selected
  /// (Settings, after the user tapped Logout there, was the user-visible
  /// symptom). Riverpod StateProviders persist for the lifetime of the
  /// ProviderScope, which spans logout/login on the same app run, so this
  /// reset has to happen explicitly on every auth transition.
  void _resetNavigationState() {
    _ref.read(tabIndexProvider.notifier).state = AppTabs.dashboard;
    _ref.read(pendingIntentProvider.notifier).state = null;
    _ref.read(plansFilterProvider.notifier).state = PlansFilter.none;
  }

  Future<void> _restore() async {
    try {
      final token = await _storage.readToken();
      final email = await _storage.readEmail();
      final name = await _storage.readName();
      final orgId = await _storage.readOrgId();
      state = AsyncValue.data(AuthSnapshot(token: token, email: email, name: name, orgId: orgId));

      // Heal sessions saved before Name was wired through: if we have a
      // valid token but no name on disk, fetch the profile from /me and
      // update the snapshot + storage. Failure is non-fatal — the dashboard
      // falls back to the email-derived greeting until the next login.
      if (token != null && token.isNotEmpty && (name == null || name.isEmpty)) {
        unawaited(_refreshProfile());
      }
    } catch (_) {
      // Storage unreachable (rare — Keystore hiccup, BlueStacks resume, etc.).
      // Fall back to "no session yet" rather than an error state so the router
      // sees a clean signal instead of forcing the user to /login. If we
      // already had a snapshot, keep it — a transient read failure must never
      // wipe an active session.
      if (state is! AsyncData<AuthSnapshot>) {
        state = const AsyncValue.data(AuthSnapshot());
      }
    }
  }

  /// Pulls the current user's profile via /api/auth/me and merges it into
  /// the in-memory snapshot + secure storage. Used by [_restore] to back-fill
  /// the Name field for sessions saved before Name was part of the auth
  /// response. Silently no-ops on any failure — the user keeps their current
  /// state and we'll try again on the next launch.
  Future<void> _refreshProfile() async {
    try {
      final res = await _api.dio.get('/api/auth/me');
      final data = res.data;
      if (data is! Map) return;
      final fetchedName = (data['name'] as String?) ?? '';
      final fetchedEmail = (data['email'] as String?) ?? '';
      final fetchedOrg = (data['organizationId'] as String?) ?? '';
      if (fetchedName.isEmpty) return;

      final current = state.valueOrNull;
      if (current == null || current.token == null) return;
      final mergedEmail = fetchedEmail.isNotEmpty ? fetchedEmail : current.email;
      final mergedOrg = fetchedOrg.isNotEmpty ? fetchedOrg : current.orgId;
      await _storage.save(current.token!, mergedEmail ?? '', mergedOrg ?? '', name: fetchedName);
      state = AsyncValue.data(AuthSnapshot(
        token: current.token,
        email: mergedEmail,
        name: fetchedName,
        orgId: mergedOrg,
      ));
    } catch (_) {
      // Non-fatal — leave the existing snapshot in place.
    }
  }

  Future<void> login(String email, String password) async {
    state = const AsyncValue.loading();
    try {
      // Send the device fingerprint so the server can refuse logins from a
      // device that doesn't match the org's already-bound license. resolve()
      // returns the same value the license activation flow uses, so a single
      // license stays consistently bound.
      final deviceId = await DeviceIdProvider.instance.resolve();
      final res = await _api.dio.post('/api/auth/login', data: {
        'email': email,
        'password': password,
        'deviceId': deviceId,
      });
      final token = res.data['token'] as String;
      final org = res.data['organizationId'] as String;
      final mail = res.data['email'] as String;
      final name = (res.data['name'] as String?) ?? '';
      final licenseKey = (res.data['licenseKey'] as String?)?.trim();

      // Multi-account-on-one-device guard: if the local DB belongs to a
      // different org than the one we just authenticated as, drop the
      // previous user's customers / payments / license cache before we
      // settle the new session. If owner is null (fresh install / prior
      // logout) or matches, leave existing data alone so a same-user
      // re-login doesn't lose work.
      final priorOwner = await LocalDb.instance.readOwnerOrgId();
      if (priorOwner != null && priorOwner != org) {
        await _wipeLocalUserState();
      }
      await LocalDb.instance.writeOwnerOrgId(org);

      await _storage.save(token, mail, org, name: name);
      _resetNavigationState();
      state = AsyncValue.data(AuthSnapshot(token: token, email: mail, name: name, orgId: org));

      // Auto-activate the org's license so a fresh install doesn't dead-end
      // on the License Setup screen. The server already created/owns the
      // license; we just need to bind it to this device. Best-effort —
      // failure leaves the user on their existing license cache.
      if (licenseKey != null && licenseKey.isNotEmpty) {
        unawaited(_ref.read(licenseControllerProvider.notifier).activate(licenseKey));
      }
    } catch (e, st) {
      state = AsyncValue.error(_friendly(e), st);
    }
  }

  Future<void> register({
    required String organizationName,
    required int businessType,
    required String organizationMobile,
    required String adminName,
    required String adminEmail,
    required String adminPassword,
  }) async {
    // Once a license is active on this device, refuse to create another
    // account here. Without this guard a second registration would silently
    // wipe local state below and re-bind the device to a new org, which the
    // license enforcement on the server will then reject anyway — better to
    // surface a clear error before any destructive local work.
    if (_ref.read(licenseControllerProvider).isActive) {
      state = AsyncValue.error(
        'A license is already activated on this device. '
        'Account creation is disabled.',
        StackTrace.current,
      );
      return;
    }

    // Brand-new account being created on this device — wipe any stale
    // state from a prior session BEFORE the API call so even a partial
    // failure leaves a clean slate. Without this, a fresh registration
    // landed on a dashboard pre-populated with the previous user's data
    // and license.
    await _wipeLocalUserState();

    state = const AsyncValue.loading();
    try {
      final res = await _api.dio.post('/api/auth/register', data: {
        'organizationName': organizationName,
        'businessType': businessType,
        'organizationMobile': organizationMobile,
        'adminName': adminName,
        'adminEmail': adminEmail,
        'adminPassword': adminPassword,
      });
      // /register no longer returns a JWT — it returns a pending-verification
      // payload and emails the OTP. Store the pending struct so the verify
      // screen can drive its countdown / resend cooldown / attempts UI, and
      // settle auth state back to "no session" so the router sends the user
      // to /verify-email (which is gated on pendingVerificationProvider).
      final pending = PendingVerification.fromJson(
        Map<String, dynamic>.from(res.data as Map),
      );
      _ref.read(pendingVerificationProvider.notifier).state = pending;
      state = const AsyncValue.data(AuthSnapshot());
    } catch (e, st) {
      state = AsyncValue.error(_friendly(e), st);
    }
  }

  /// Submits the OTP from VerifyEmailScreen. On success we get the same
  /// AuthResponse shape Login returns — JWT, license info, profile — so
  /// this is the moment a signup gains a real session and the dashboard
  /// becomes reachable. Errors are surfaced via state so the screen can
  /// show the message returned by the backend (wrong code, expired, etc).
  Future<void> verifyEmail(String email, String code) async {
    state = const AsyncValue.loading();
    try {
      final deviceId = await DeviceIdProvider.instance.resolve();
      final res = await _api.dio.post('/api/auth/verify-email', data: {
        'email': email,
        'code': code,
        'deviceId': deviceId,
      });
      final token = res.data['token'] as String;
      final org = res.data['organizationId'] as String;
      final mail = res.data['email'] as String;
      final name = (res.data['name'] as String?) ?? '';
      final licenseKey = (res.data['licenseKey'] as String?)?.trim();

      await LocalDb.instance.writeOwnerOrgId(org);
      await _storage.save(token, mail, org, name: name);
      _resetNavigationState();
      // Drop the pending challenge — we're done with it.
      _ref.read(pendingVerificationProvider.notifier).state = null;
      state = AsyncValue.data(
          AuthSnapshot(token: token, email: mail, name: name, orgId: org));

      if (licenseKey != null && licenseKey.isNotEmpty) {
        try {
          await _ref
              .read(licenseControllerProvider.notifier)
              .activate(licenseKey);
        } catch (_) {/* see register() — non-fatal */}
      }
    } catch (e, st) {
      state = AsyncValue.error(_friendly(e), st);
    }
  }

  /// Asks the backend for a fresh OTP. Updates pendingVerificationProvider
  /// with the new expiry / cooldown / attempts so the verify screen's
  /// countdown stays in sync. Errors (cooldown not yet elapsed, no pending
  /// record) are surfaced via state.
  Future<void> resendVerification(String email) async {
    state = const AsyncValue.loading();
    try {
      final res = await _api.dio.post('/api/auth/resend-verification', data: {
        'email': email,
      });
      final pending = PendingVerification.fromJson(
        Map<String, dynamic>.from(res.data as Map),
      );
      _ref.read(pendingVerificationProvider.notifier).state = pending;
      state = const AsyncValue.data(AuthSnapshot());
    } catch (e, st) {
      state = AsyncValue.error(_friendly(e), st);
    }
  }

  /// Drops a pending verification without sending anything. Used by the
  /// "Wrong email? Start over" link on the verify screen — flips the
  /// router back to /login (or /register, the user picks).
  void cancelPendingVerification() {
    _ref.read(pendingVerificationProvider.notifier).state = null;
  }

  Future<void> logout() async {
    // Clear the JWT + email + name + orgId from secure storage so the next
    // launch lands on /login. Also clear the device-local MPIN — keeping it
    // around after an explicit logout would let the next person to open the
    // app gate-check against the previous user's PIN, which is at best
    // confusing and at worst a security hole if the next user is different.
    // Deliberately leave the local SQLite (customers, payments, reminders,
    // license cache) AND the owner_org_id marker intact: the offline-first
    // contract is that a user's own data survives a logout-and-login cycle
    // on the same device. Cross-user contamination is handled in login() —
    // when a different orgId authenticates, the marker comparison there
    // triggers the wipe before the new session settles.
    await _storage.clear();
    try {
      await _ref.read(mpinControllerProvider.notifier).clear();
    } catch (_) {/* non-fatal */}
    _ref.read(pendingVerificationProvider.notifier).state = null;
    _resetNavigationState();
    state = const AsyncValue.data(AuthSnapshot());
  }

  Object _friendly(Object e) {
    if (e is DioException) {
      final status = e.response?.statusCode;
      // Surface the server's `error` message verbatim for any 4xx response
      // that carries one — covers 400 (bad payload), 401 (bad creds), 403
      // (disabled), 409 (duplicate email / mobile on register). Without this
      // a duplicate-on-register surfaces as "Login failed", which reads as
      // an outage when it is really a validation rejection.
      final body = e.response?.data;
      if (status != null && status >= 400 && status < 500 &&
          body is Map && body['error'] is String && (body['error'] as String).isNotEmpty) {
        return body['error'];
      }
      if (status == 401 || status == 400) return 'Invalid email or password';
      if (status == 403) return 'Account is not allowed to sign in';
      if (status != null && status >= 500) return 'Server error. Please try again later.';
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout) {
        return 'Connection timed out. Check your network.';
      }
      if (e.type == DioExceptionType.connectionError) {
        return 'Cannot reach the backend. Check the API URL in Settings.';
      }
    }
    return 'Login failed. Please try again.';
  }
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AsyncValue<AuthSnapshot>>((ref) {
  return AuthController(ref.read(apiClientProvider), ref.read(authStorageProvider), ref);
});
