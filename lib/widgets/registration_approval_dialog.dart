import 'dart:async';
import 'dart:developer' as developer;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/registration_approval_service.dart';

class RegistrationApprovalDialog extends StatefulWidget {
  final User user;

  const RegistrationApprovalDialog({super.key, required this.user});

  @override
  State<RegistrationApprovalDialog> createState() =>
      _RegistrationApprovalDialogState();
}

class _RegistrationApprovalDialogState extends State<RegistrationApprovalDialog>
    with WidgetsBindingObserver {
  Timer? _pollTimer;
  bool _isChecking = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkStatus(),
    );
    unawaited(_checkStatus());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_checkStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkStatus() async {
    if (_isChecking) return;
    _isChecking = true;
    var didPop = false;
    try {
      final status = await RegistrationApprovalService().getStatus(widget.user);
      if (!mounted) return;
      if (status == RegistrationApprovalStatus.approved ||
          status == RegistrationApprovalStatus.rejected ||
          status == RegistrationApprovalStatus.expired) {
        Navigator.of(context).pop(status);
        didPop = true;
      } else if (status == RegistrationApprovalStatus.notRequested) {
        setState(() {
          _errorMessage =
              'La demande est introuvable. Recommencez l’inscription.';
        });
      } else if (_errorMessage != null) {
        setState(() => _errorMessage = null);
      }
    } on RegistrationApprovalException catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
    } catch (error, stackTrace) {
      developer.log(
        'Erreur lors de la vérification de la demande',
        name: 'RegistrationApprovalDialog',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _errorMessage = 'Impossible de vérifier la réponse. Réessayez.';
        });
      }
    } finally {
      _isChecking = false;
      if (mounted && !didPop) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        icon: const Icon(Icons.mark_email_unread_outlined, size: 40),
        title: const Text('Confirmez votre inscription'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Un e-mail avec les choix Confirmer et Refuser a été envoyé à '
              '${widget.user.email ?? 'votre adresse'}. La réponse sera vérifiée automatiquement.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            if (_isChecking)
              const CircularProgressIndicator()
            else
              const Icon(Icons.hourglass_top, size: 30),
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: _isChecking ? null : _checkStatus,
            child: const Text('Vérifier maintenant'),
          ),
        ],
      ),
    );
  }
}
