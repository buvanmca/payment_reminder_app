import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';

class LicenseValidationResult {
  LicenseValidationResult({
    required this.status,
    this.validUntil,
    this.message,
  });

  final String status;
  /// Null when the backend did not return a validity window — typically
  /// when the license key is invalid or rejected. Callers must NOT default
  /// this to "today" in the UI; treat null as "no date to show".
  final DateTime? validUntil;
  final String? message;

  bool get isActive => status.toLowerCase() == 'active';
}

class LicenseApi {
  LicenseApi(this._api);
  final ApiClient _api;

  Future<LicenseValidationResult> validate({
    required String licenseKey,
    required String deviceId,
  }) async {
    try {
      final res = await _api.dio.post(
        '/api/validate-license',
        data: {'licenseKey': licenseKey, 'deviceId': deviceId},
      );
      final data = res.data as Map<String, dynamic>;
      final validUntilRaw = data['validUntil']?.toString();
      return LicenseValidationResult(
        status: data['status']?.toString() ?? 'unknown',
        validUntil: validUntilRaw == null ? null : DateTime.tryParse(validUntilRaw),
      );
    } on DioException catch (e) {
      final body = e.response?.data;
      String? message;
      if (body is Map && body['error'] != null) {
        message = body['error'].toString();
      }
      // Treat 4xx with a known status code as a structured "not active" result
      // so the UI can surface a clean message without throwing. validUntil is
      // intentionally null — error responses don't carry a real date.
      final code = e.response?.statusCode;
      if (code != null && code >= 400 && code < 500) {
        return LicenseValidationResult(
          status: code == 404 ? 'invalid' : 'rejected',
          message: message ?? e.message,
        );
      }
      rethrow;
    }
  }
}

final licenseApiProvider =
    Provider<LicenseApi>((ref) => LicenseApi(ref.read(apiClientProvider)));