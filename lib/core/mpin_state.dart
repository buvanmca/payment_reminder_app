import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mpin_storage.dart';

/// Lockout policy: every 5 wrong attempts adds another 60s to the next
/// window, capped at 10 minutes. After 8 wrong attempts the unlock screen
/// also surfaces a "Forgot MPIN" path that logs the user out and clears the
/// PIN — see [MpinUnlockScreen].
const int kMpinAttemptLimit = 5;
const int kMpinLockoutSeconds = 60;
const int kMpinMaxLockoutSeconds = 600;

class MpinState {
  const MpinState({
    required this.isSet,
    required this.isUnlocked,
    required this.failedAttempts,
    this.lockUntil,
    this.bootstrapped = false,
  });

  /// True once MpinController.bootstrap() has read secure storage at least
  /// once. The router treats an un-bootstrapped state as "don't redirect
  /// yet" so a fresh launch doesn't briefly bounce through /mpin/setup
  /// before the storage read settles.
  final bool bootstrapped;

  /// True once the user has saved a MPIN on this device.
  final bool isSet;

  /// True for the lifetime of the current foreground session after the user
  /// has either set the MPIN (setup flow) or successfully entered it on the
  /// unlock screen. Logout / different-org login flips this back to false.
  final bool isUnlocked;

  /// Wrong attempts accumulated since the last successful unlock or setup.
  final int failedAttempts;

  /// When non-null and in the future, the unlock screen blocks input until
  /// this time and shows a countdown.
  final DateTime? lockUntil;

  bool get isLockedNow =>
      lockUntil != null && lockUntil!.isAfter(DateTime.now());

  MpinState copyWith({
    bool? isSet,
    bool? isUnlocked,
    int? failedAttempts,
    DateTime? lockUntil,
    bool? bootstrapped,
    bool clearLock = false,
  }) {
    return MpinState(
      isSet: isSet ?? this.isSet,
      isUnlocked: isUnlocked ?? this.isUnlocked,
      failedAttempts: failedAttempts ?? this.failedAttempts,
      lockUntil: clearLock ? null : (lockUntil ?? this.lockUntil),
      bootstrapped: bootstrapped ?? this.bootstrapped,
    );
  }

  static const initial =
      MpinState(isSet: false, isUnlocked: false, failedAttempts: 0);
}

class MpinController extends StateNotifier<MpinState> {
  MpinController(this._storage) : super(MpinState.initial) {
    // Kick off the storage read as soon as the provider is materialised so
    // the router redirect has a hydrated state by the time the first frame
    // resolves. main.dart also awaits bootstrap() in a postFrameCallback as
    // a belt-and-braces — it's idempotent.
    bootstrap();
  }

  final MpinStorage _storage;

  /// Hydrate from secure storage. Called on app start (before routing) and
  /// after auth transitions so the router can decide between /mpin/setup,
  /// /mpin/unlock and /. Re-reading from storage rather than trusting in-
  /// memory state keeps a fresh app launch from inheriting an [isUnlocked]
  /// flag set in a prior session.
  Future<void> bootstrap() async {
    final isSet = await _storage.isSet();
    final attempts = await _storage.readAttempts();
    final lockUntil = await _storage.readLockUntil();
    state = MpinState(
      isSet: isSet,
      isUnlocked: false,
      failedAttempts: attempts,
      lockUntil: lockUntil,
      bootstrapped: true,
    );
  }

  /// Mark the current session unlocked without verifying — used by the setup
  /// flow once the user has just saved a fresh PIN, since making them
  /// re-enter it on the next screen would be redundant.
  void markUnlocked() {
    state = state.copyWith(isUnlocked: true);
  }

  /// Read-only equality check against the stored hash. Unlike [verify], this
  /// never touches the failed-attempt counter or the lockout window — it's
  /// for the "Change MPIN" flow, where we need to reject a candidate that
  /// matches the existing PIN without penalising the user for picking it.
  Future<bool> matchesCurrent(String pin) => _storage.verify(pin);

  Future<void> setPin(String pin, {required String orgId}) async {
    _assertValidPin(pin);
    await _storage.save(pin, orgId: orgId);
    state = const MpinState(
      isSet: true,
      isUnlocked: true,
      failedAttempts: 0,
      lockUntil: null,
      bootstrapped: true,
    );
  }

  /// Returns true on success. On failure, increments the attempt counter
  /// and — once [kMpinAttemptLimit] is reached — sets a lockout window
  /// that grows by [kMpinLockoutSeconds] for each subsequent batch of
  /// failures, capped at [kMpinMaxLockoutSeconds].
  Future<bool> verify(String pin) async {
    if (state.isLockedNow) return false;

    final ok = await _storage.verify(pin);
    if (ok) {
      await _storage.writeAttempts(0);
      await _storage.writeLockUntil(null);
      state = state.copyWith(
        isUnlocked: true,
        failedAttempts: 0,
        clearLock: true,
      );
      return true;
    }

    final attempts = state.failedAttempts + 1;
    await _storage.writeAttempts(attempts);

    DateTime? lockUntil;
    if (attempts % kMpinAttemptLimit == 0) {
      final batches = attempts ~/ kMpinAttemptLimit;
      final seconds =
          (kMpinLockoutSeconds * batches).clamp(0, kMpinMaxLockoutSeconds);
      lockUntil = DateTime.now().add(Duration(seconds: seconds));
      await _storage.writeLockUntil(lockUntil);
    }

    state = state.copyWith(
      failedAttempts: attempts,
      lockUntil: lockUntil ?? state.lockUntil,
    );
    return false;
  }

  /// Drops the stored PIN entirely. Call on full logout, on different-org
  /// login, and on the "Forgot MPIN" recovery path.
  Future<void> clear() async {
    await _storage.clear();
    state = const MpinState(
      isSet: false,
      isUnlocked: false,
      failedAttempts: 0,
      bootstrapped: true,
    );
  }

  void _assertValidPin(String pin) {
    if (pin.length != 4 || int.tryParse(pin) == null) {
      throw ArgumentError('MPIN must be exactly 4 digits.');
    }
  }
}

final mpinStorageProvider = Provider<MpinStorage>((_) => MpinStorage());

final mpinControllerProvider =
    StateNotifierProvider<MpinController, MpinState>((ref) {
  return MpinController(ref.read(mpinStorageProvider));
});
