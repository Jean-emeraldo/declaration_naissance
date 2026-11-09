import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../config/email_config.dart';

enum RegistrationApprovalStatus {
  pending,
  approved,
  rejected,
  expired,
  notRequested,
}

class RegistrationApprovalException implements Exception {
  final String message;

  const RegistrationApprovalException(this.message);

  @override
  String toString() => message;
}

class RegistrationApprovalService {
  static final RegistrationApprovalService _instance =
      RegistrationApprovalService._internal();

  factory RegistrationApprovalService() => _instance;

  RegistrationApprovalService._internal();

  Future<RegistrationApprovalStatus> requestApproval(User user) async {
    final response = await _send(
      user,
      'POST',
      '/registration-approvals/request',
      body: {'email': user.email ?? ''},
      forceRefresh: true,
    );
    return _parseStatus(response);
  }

  Future<RegistrationApprovalStatus> getStatus(User user) async {
    final response = await _send(user, 'GET', '/registration-approvals/status');
    return _parseStatus(response);
  }

  Future<http.Response> _send(
    User user,
    String method,
    String path, {
    Map<String, String>? body,
    bool forceRefresh = false,
  }) async {
    final baseUrl = EmailConfig.registrationApprovalApiBaseUrl
        .trim()
        .replaceFirst(RegExp(r'/+$'), '');
    if (baseUrl.isEmpty) {
      throw const RegistrationApprovalException(
        'Le service de confirmation des inscriptions n’est pas configuré.',
      );
    }

    try {
      final uri = Uri.parse('$baseUrl$path');
      if (uri.scheme != 'https' || uri.host.isEmpty) {
        throw const RegistrationApprovalException(
          'Le service de confirmation doit utiliser une adresse HTTPS.',
        );
      }

      final idToken = await user.getIdToken(forceRefresh);
      if (idToken == null || idToken.isEmpty) {
        throw const RegistrationApprovalException(
          'La session Firebase a expiré. Recommencez la connexion.',
        );
      }

      final headers = {
        'Authorization': 'Bearer $idToken',
        if (body != null) 'Content-Type': 'application/json',
      };
      final response =
          method == 'POST'
              ? await http
                  .post(uri, headers: headers, body: jsonEncode(body))
                  .timeout(const Duration(seconds: 15))
              : await http
                  .get(uri, headers: headers)
                  .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) return response;
      if (response.statusCode == 409) {
        throw const RegistrationApprovalException(
          'Un compte existe déjà avec cette adresse. Connectez-vous plutôt.',
        );
      }
      if (response.statusCode == 429) {
        throw const RegistrationApprovalException(
          'Trop de demandes. Patientez avant de réessayer.',
        );
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const RegistrationApprovalException(
          'La session Firebase n’est plus valide. Recommencez la connexion.',
        );
      }
      throw const RegistrationApprovalException(
        'Le service de confirmation est indisponible. Réessayez plus tard.',
      );
    } on RegistrationApprovalException {
      rethrow;
    } catch (_) {
      throw const RegistrationApprovalException(
        'Connexion impossible au service de confirmation. Vérifiez votre Internet.',
      );
    }
  }

  RegistrationApprovalStatus _parseStatus(http.Response response) {
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return switch (body['status']) {
        'pending' => RegistrationApprovalStatus.pending,
        'approved' => RegistrationApprovalStatus.approved,
        'rejected' => RegistrationApprovalStatus.rejected,
        'expired' => RegistrationApprovalStatus.expired,
        'not_requested' => RegistrationApprovalStatus.notRequested,
        _ =>
          throw const RegistrationApprovalException(
            'Réponse invalide du service de confirmation.',
          ),
      };
    } on FormatException {
      throw const RegistrationApprovalException(
        'Réponse invalide du service de confirmation.',
      );
    } on TypeError {
      throw const RegistrationApprovalException(
        'Réponse invalide du service de confirmation.',
      );
    }
  }
}
