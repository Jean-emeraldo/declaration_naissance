import 'dart:developer' as developer;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../db/database_helper.dart';
import '../services/sync_service.dart';

class EmailVerificationScreen extends StatefulWidget {
  final User user;

  const EmailVerificationScreen({super.key, required this.user});

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  bool _isChecking = false;
  bool _isResending = false;

  Future<void> _checkVerification() async {
    setState(() => _isChecking = true);
    try {
      await widget.user.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;
      if (refreshedUser?.emailVerified != true) {
        _showMessage('Adresse non vérifiée. Consultez votre boîte mail.');
        return;
      }

      final email = refreshedUser!.email;
      if (email == null || email.isEmpty) {
        throw StateError('Le compte Firebase ne possède pas d’adresse email.');
      }

      final database = DatabaseHelper.instance;
      await database.updateUser(email, {
        'firebaseUid': refreshedUser.uid,
        'emailVerified': 1,
        'synced': 0,
      });
      await const FlutterSecureStorage().write(key: 'user_email', value: email);

      try {
        await SyncService().syncAllUnsynced();
      } catch (error, stackTrace) {
        developer.log(
          'Synchronisation différée après vérification email',
          name: 'EmailVerificationScreen',
          error: error,
          stackTrace: stackTrace,
        );
      }

      if (mounted) {
        Navigator.pushNamedAndRemoveUntil(context, '/dashboard', (_) => false);
      }
    } catch (error, stackTrace) {
      developer.log(
        'Impossible de vérifier l’adresse email',
        name: 'EmailVerificationScreen',
        error: error,
        stackTrace: stackTrace,
      );
      _showMessage(
        'Impossible de vérifier maintenant. Vérifiez votre connexion puis réessayez.',
      );
    } finally {
      if (mounted) setState(() => _isChecking = false);
    }
  }

  Future<void> _resendVerification() async {
    setState(() => _isResending = true);
    try {
      await widget.user.sendEmailVerification();
      _showMessage('Lien de vérification envoyé.');
    } catch (error, stackTrace) {
      developer.log(
        'Impossible de renvoyer le lien de vérification',
        name: 'EmailVerificationScreen',
        error: error,
        stackTrace: stackTrace,
      );
      _showMessage(
        'Envoi impossible. Vérifiez votre connexion puis réessayez.',
      );
    } finally {
      if (mounted) setState(() => _isResending = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _cancel() async {
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.pushNamedAndRemoveUntil(context, '/auth', (_) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = widget.user.email ?? '';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vérification de l’adresse'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            onPressed: _isChecking || _isResending ? null : _cancel,
            tooltip: 'Retour à la connexion',
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.mark_email_unread_outlined, size: 72),
                const SizedBox(height: 24),
                const Text(
                  'Vérifiez votre boîte mail',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  'Un lien de confirmation a été envoyé à $email. '
                  'Ouvrez-le avant de continuer.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _isChecking ? null : _checkVerification,
                    icon:
                        _isChecking
                            ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                            : const Icon(Icons.refresh),
                    label: const Text('J’ai vérifié mon adresse'),
                  ),
                ),
                TextButton.icon(
                  onPressed: _isResending ? null : _resendVerification,
                  icon: const Icon(Icons.outgoing_mail),
                  label: Text(
                    _isResending ? 'Envoi en cours...' : 'Renvoyer le lien',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
