import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';

class ReminderSendResult {
  ReminderSendResult({
    required this.status,
    this.messageId,
    this.error,
    this.networkError = false,
  });
  final String status;
  final String? messageId;
  final String? error;
  /// True when the failure was a connection-level problem (server unreachable,
  /// timeout, DNS, etc.) rather than the server explicitly responding with an
  /// error status. Callers can use this to enqueue the request for later retry.
  final bool networkError;

  bool get sent => status.toLowerCase() == 'sent';
}

class ReminderDispatchApi {
  ReminderDispatchApi(this._api);
  final ApiClient _api;

  Future<ReminderSendResult> sendWhatsApp({
    required String licenseKey,
    required String phone,
    required String customerName,
    required double amount,
    required DateTime dueDate,
    String? templateName,
  }) async {
    return _post('/api/send-whatsapp-reminder', {
      'licenseKey': licenseKey,
      'phone': phone,
      'customerName': customerName,
      'amount': amount,
      'dueDate': dueDate.toIso8601String(),
      if (templateName != null) 'templateName': templateName,
    });
  }

  Future<ReminderSendResult> sendEmail({
    required String licenseKey,
    required String email,
    required String customerName,
    required double amount,
    required DateTime dueDate,
    String? templateName,
    String? subject,
    String? body,
  }) async {
    return _post('/api/send-email-reminder', {
      'licenseKey': licenseKey,
      'email': email,
      'customerName': customerName,
      'amount': amount,
      'dueDate': dueDate.toIso8601String(),
      if (templateName != null) 'templateName': templateName,
      if (subject != null) 'subject': subject,
      // Client-rendered body from the user's custom template; the backend sends
      // it verbatim and only falls back to its own template when this is absent.
      if (body != null) 'body': body,
    });
  }

  Future<ReminderSendResult> _post(String path, Map<String, Object?> body) async {
    try {
      final res = await _api.dio.post(path, data: body);
      final data = res.data as Map<String, dynamic>;
      return ReminderSendResult(
        status: data['status']?.toString() ?? 'unknown',
        messageId: data['messageId']?.toString(),
        error: data['error']?.toString(),
      );
    } on DioException catch (e) {
      final body = e.response?.data;
      String? error;
      if (body is Map && body['error'] != null) {
        error = body['error'].toString();
      }
      // No response = connection-level failure (server down, timeout, DNS).
      // The caller can enqueue these for later retry.
      final isNetwork = e.response == null ||
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.unknown;
      return ReminderSendResult(
        status: 'failed',
        error: error ?? e.message,
        networkError: isNetwork,
      );
    }
  }
}

final reminderDispatchApiProvider = Provider<ReminderDispatchApi>(
    (ref) => ReminderDispatchApi(ref.read(apiClientProvider)));