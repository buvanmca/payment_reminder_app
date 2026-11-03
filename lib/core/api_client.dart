import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_storage.dart';
import 'config.dart';

class ApiClient {
  ApiClient(this._storage)
      : _dio = Dio(
          BaseOptions(
            baseUrl: AppConfig.apiBaseUrl,
            connectTimeout: const Duration(seconds: 30),
            receiveTimeout: const Duration(seconds: 30),
            sendTimeout: const Duration(seconds: 30),
            headers: {'Content-Type': 'application/json'},
          ),
        ) {
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        // Pick up runtime URL changes (Settings -> Backend URL) on every request.
        if (_dio.options.baseUrl != AppConfig.apiBaseUrl) {
          _dio.options.baseUrl = AppConfig.apiBaseUrl;
        }
        options.baseUrl = AppConfig.apiBaseUrl;
        final token = await _storage.readToken();
        if (token != null && token.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        return handler.next(options);
      },
    ));
  }

  final Dio _dio;
  final AuthStorage _storage;

  Dio get dio => _dio;
}

final authStorageProvider = Provider<AuthStorage>((_) => AuthStorage());
final apiClientProvider = Provider<ApiClient>((ref) => ApiClient(ref.read(authStorageProvider)));
