import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';

/// Resolves a stable per-install device id and stores it in secure storage.
/// Falls back to platform identifiers (Android ID / iOS identifierForVendor)
/// when available, otherwise generates a UUID-like random id on first use.
class DeviceIdProvider {
  DeviceIdProvider._();
  static final DeviceIdProvider instance = DeviceIdProvider._();

  static const _storageKey = 'paybell_device_id_v1';
  String? _cached;

  Future<String> resolve() async {
    if (_cached != null) return _cached!;
    const storage = FlutterSecureStorage();
    final stored = await storage.read(key: _storageKey);
    if (stored != null && stored.isNotEmpty) {
      _cached = stored;
      return stored;
    }
    final id = await _detect();
    await storage.write(key: _storageKey, value: id);
    _cached = id;
    return id;
  }

  Future<String> _detect() async {
    try {
      final info = DeviceInfoPlugin();
      if (kIsWeb) {
        final web = await info.webBrowserInfo;
        return 'web-${web.userAgent?.hashCode ?? DateTime.now().microsecondsSinceEpoch}';
      }
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        return 'android-${a.id}-${a.model}';
      }
      if (Platform.isIOS) {
        final i = await info.iosInfo;
        return 'ios-${i.identifierForVendor ?? DateTime.now().microsecondsSinceEpoch}';
      }
      if (Platform.isWindows) {
        final w = await info.windowsInfo;
        return 'win-${w.deviceId}';
      }
      if (Platform.isMacOS) {
        final m = await info.macOsInfo;
        return 'mac-${m.systemGUID ?? DateTime.now().microsecondsSinceEpoch}';
      }
      if (Platform.isLinux) {
        final l = await info.linuxInfo;
        return 'linux-${l.machineId ?? DateTime.now().microsecondsSinceEpoch}';
      }
    } catch (_) {
      // fall through
    }
    return 'dev-${DateTime.now().microsecondsSinceEpoch}';
  }
}