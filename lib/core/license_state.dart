import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/license_api.dart';
import '../local/device_id.dart';
import '../local/license_cache_dao.dart';

enum LicenseGate { unknown, active, expired, invalid, deviceConflict, networkError }

class LicenseState {
  const LicenseState({
    required this.gate,
    this.licenseKey,
    this.deviceId,
    this.validUntil,
    this.message,
  });

  factory LicenseState.unknown() => const LicenseState(gate: LicenseGate.unknown);

  final LicenseGate gate;
  final String? licenseKey;
  final String? deviceId;
  final DateTime? validUntil;
  final String? message;

  bool get isActive => gate == LicenseGate.active;

  LicenseState copyWith({
    LicenseGate? gate,
    String? licenseKey,
    String? deviceId,
    DateTime? validUntil,
    String? message,
  }) =>
      LicenseState(
        gate: gate ?? this.gate,
        licenseKey: licenseKey ?? this.licenseKey,
        deviceId: deviceId ?? this.deviceId,
        validUntil: validUntil ?? this.validUntil,
        message: message ?? this.message,
      );
}

class LicenseController extends StateNotifier<LicenseState> {
  LicenseController(this._api, this._cache) : super(LicenseState.unknown());

  static const _storageKey = 'paybell_license_key_v1';
  static const _storage = FlutterSecureStorage();

  final LicenseApi _api;
  final LicenseCacheDao _cache;

  Future<void> bootstrap() async {
    final cached = await _cache.read();
    if (cached != null) {
      state = LicenseState(
        gate: cached.isActive ? LicenseGate.active : LicenseGate.expired,
        licenseKey: cached.licenseKey,
        deviceId: cached.deviceId,
        validUntil: cached.validUntil,
      );
    }
    final stored = await _storage.read(key: _storageKey);
    if (stored != null && stored.isNotEmpty) {
      // Best-effort online refresh; if offline, keep cached state.
      await refresh(stored);
    }
  }

  Future<LicenseState> activate(String licenseKey) async {
    await _storage.write(key: _storageKey, value: licenseKey.trim());
    return refresh(licenseKey);
  }

  Future<LicenseState> refresh(String licenseKey) async {
    try {
      final deviceId = await DeviceIdProvider.instance.resolve();
      final result = await _api.validate(
        licenseKey: licenseKey.trim(),
        deviceId: deviceId,
      );
      final gate = switch (result.status.toLowerCase()) {
        'active' => LicenseGate.active,
        'expired' => LicenseGate.expired,
        'invalid' => LicenseGate.invalid,
        'rejected' => LicenseGate.deviceConflict,
        _ => LicenseGate.expired,
      };
      state = LicenseState(
        gate: gate,
        licenseKey: licenseKey.trim(),
        deviceId: deviceId,
        validUntil: result.validUntil,
        message: result.message,
      );
      // Only persist a cache row when we actually got a date back. For
      // invalid/rejected/network-error responses, validUntil is null and we
      // must not write a placeholder (otherwise the UI shows misleading "today"
      // dates and the cached row gets confused with a real license).
      if ((gate == LicenseGate.active || gate == LicenseGate.expired) &&
          result.validUntil != null) {
        await _cache.save(CachedLicense(
          licenseKey: licenseKey.trim(),
          deviceId: deviceId,
          status: result.status,
          validUntil: result.validUntil!,
          lastValidatedAt: DateTime.now(),
        ));
      }
      return state;
    } catch (e) {
      state = state.copyWith(
        gate: state.gate == LicenseGate.unknown ? LicenseGate.networkError : state.gate,
        message: 'Could not reach server: $e',
      );
      return state;
    }
  }

  Future<void> clear() async {
    await _storage.delete(key: _storageKey);
    await _cache.clear();
    state = LicenseState.unknown();
  }
}

final licenseCacheDaoProvider = Provider<LicenseCacheDao>((_) => LicenseCacheDao());

final licenseControllerProvider =
    StateNotifierProvider<LicenseController, LicenseState>((ref) {
  final api = ref.read(licenseApiProvider);
  final cache = ref.read(licenseCacheDaoProvider);
  return LicenseController(api, cache);
});