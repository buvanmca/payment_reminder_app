import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  /// Compile-time default. Override at build time with:
  ///   flutter run --dart-define=API_BASE_URL=http://<host>:5080
  /// At runtime, the user can override this from Settings; that value
  /// is persisted in SharedPreferences and wins over this default.
  static const String compiledDefault = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://192.168.29.187:5080',
  );

  static const _prefsKey = 'api_base_url_override';

  /// Cached resolved URL (loaded once on app start, kept in memory so the
  /// Dio BaseOptions can read it synchronously).
  static String _current = compiledDefault;
  static String get apiBaseUrl => _current;

  /// Call once during app startup before the first network request.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    if (saved != null && saved.isNotEmpty) {
      _current = saved;
    }
  }

  /// Persist a new backend URL and update the in-memory cache. The next Dio
  /// request will use the new URL (the api_client wires baseUrl from here).
  static Future<void> setApiBaseUrl(String url) async {
    final trimmed = url.trim().replaceAll(RegExp(r'/+$'), '');
    _current = trimmed;
    final prefs = await SharedPreferences.getInstance();
    if (trimmed.isEmpty) {
      await prefs.remove(_prefsKey);
      _current = compiledDefault;
    } else {
      await prefs.setString(_prefsKey, trimmed);
    }
  }

  static Future<void> resetToDefault() => setApiBaseUrl('');
}
