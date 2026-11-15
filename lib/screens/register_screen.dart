import 'dart:io';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../db/database_helper.dart';
import '../services/crypto_service.dart';
import '../services/registration_approval_service.dart';
import '../utils/translate.dart';
import '../widgets/registration_approval_dialog.dart';
import '../widgets/email_verification_screen.dart';

class RegisterScreen extends StatefulWidget {
  static const String routeName = '/register';
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen>
    with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{
    'email': TextEditingController(),
    'password': TextEditingController(),
    'firstName': TextEditingController(),
    'lastName': TextEditingController(),
  };
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _profilePicturePath;
  late AnimationController _mainController;
  late AnimationController _formController;
  late AnimationController _buttonController;
  late AnimationController _floatController;
  late Animation<double> _scaleAnim;
  late Animation<double> _floatAnim;
  late List<Animation<Offset>> _fieldSlideAnims;

  @override
  void initState() {
    super.initState();
    _mainController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _formController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _buttonController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );
    _scaleAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _mainController,
        curve: const Interval(0.0, 0.6, curve: Curves.elasticOut),
      ),
    );
    _floatAnim = Tween<double>(begin: -10, end: 10).animate(
      CurvedAnimation(parent: _floatController, curve: Curves.easeInOut),
    );
    final slideIntervals = [
      [0.0, 0.3],
      [0.1, 0.4],
      [0.2, 0.5],
      [0.3, 0.6],
    ];
    _fieldSlideAnims = List.generate(4, (i) {
      final start = i % 2 == 0 ? -1.5 : 1.5;
      return Tween<Offset>(begin: Offset(start, 0), end: Offset.zero).animate(
        CurvedAnimation(
          parent: _formController,
          curve: Interval(
            slideIntervals[i][0],
            slideIntervals[i][1],
            curve: Curves.elasticOut,
          ),
        ),
      );
    });
    _mainController.forward();
    Future.delayed(
      const Duration(milliseconds: 400),
      () => _formController.forward(),
    );
    _floatController.repeat(reverse: true);
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _mainController.dispose();
    _formController.dispose();
    _buttonController.dispose();
    _floatController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      _buttonController.forward().then((_) => _buttonController.reverse());
      return;
    }
    setState(() => _isLoading = true);
    final email = _controllers['email']!.text.trim().toLowerCase();
    final password = _controllers['password']!.text;
    var firebaseAccountCreated = false;
    var createdThisAttempt = false;
    var localProfileSaved = false;
    User? firebaseUser;
    try {
      final database = DatabaseHelper.instance;
      final localUser = await database.getUserByEmail(email);
      final localProfile = <String, dynamic>{
        'email': email,
        'password': await CryptoService.hashPassword(password),
        'firstName': _controllers['firstName']!.text.trim(),
        'lastName': _controllers['lastName']!.text.trim(),
        'profilePicture': _profilePicturePath,
        'firebaseUid': null,
        'emailVerified': 0,
        'synced': 0,
      };
      if (localUser != null) {
        if ((localUser['firebaseUid'] as String?)?.isNotEmpty == true ||
            !await CryptoService.verifyPassword(
              password,
              localUser['password'] as String? ?? '',
            )) {
          _snackBar(
            'Un compte existe déjà avec cette adresse email.',
            Colors.red.shade400,
          );
          return;
        }
        await database.updateUser(email, localProfile);
      } else {
        await database.insertUser(localProfile);
      }
      localProfileSaved = true;

      if (!await database.isOnline) {
        _snackBar(
          'Profil enregistré sur cet appareil. Reconnectez-vous à Internet puis renvoyez le formulaire pour créer le compte.',
          Colors.orange,
        );
        return;
      }

      UserCredential credential;
      try {
        credential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
        createdThisAttempt = true;
      } on FirebaseAuthException catch (error) {
        if (error.code != 'email-already-in-use') rethrow;
        credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
      }

      final user = credential.user;
      if (user == null) {
        throw StateError('Firebase n’a pas retourné le compte créé.');
      }
      firebaseUser = user;
      firebaseAccountCreated = true;

      if (!user.emailVerified) {
        await user.sendEmailVerification();
      }

      final approvalStatus = await RegistrationApprovalService()
          .requestApproval(user);
      RegistrationApprovalStatus? finalApprovalStatus = approvalStatus;
      if (approvalStatus == RegistrationApprovalStatus.pending) {
        if (!mounted) {
          await _signOutAfterFailure();
          firebaseAccountCreated = false;
          return;
        }
        finalApprovalStatus = await showDialog<RegistrationApprovalStatus>(
          context: context,
          barrierDismissible: false,
          builder: (context) => RegistrationApprovalDialog(user: user),
        );
      }

      if (finalApprovalStatus != RegistrationApprovalStatus.approved ||
          !mounted) {
        await _signOutAfterFailure();
        firebaseAccountCreated = false;
        if (mounted &&
            (finalApprovalStatus == RegistrationApprovalStatus.rejected ||
                finalApprovalStatus == RegistrationApprovalStatus.expired)) {
          _snackBar(
            finalApprovalStatus == RegistrationApprovalStatus.rejected
                ? 'La demande a été refusée. Le compte a été annulé.'
                : 'La demande a expiré. Recommencez l’inscription.',
            Colors.orange,
          );
        }
        return;
      }

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => EmailVerificationScreen(user: user),
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (firebaseAccountCreated) {
        await _signOutAfterFailure();
      }
      final message = switch (e.code) {
        'email-already-in-use' =>
          'Un compte existe déjà avec cette adresse email.',
        'invalid-email' => 'Adresse email invalide.',
        'weak-password' =>
          'Le mot de passe doit contenir au moins 6 caractères.',
        'invalid-credential' || 'wrong-password' =>
          'Cette adresse possède déjà un compte. Vérifiez le mot de passe ou connectez-vous.',
        'network-request-failed' =>
          'Connexion Internet indisponible. Le profil reste enregistré localement; réessayez lorsque le réseau sera revenu.',
        _ => e.message ?? 'Erreur Firebase pendant la création du compte.',
      };
      _snackBar(
        firebaseAccountCreated && !localProfileSaved
            ? 'Compte Firebase créé, mais le profil local n’a pas pu être enregistré. Connectez-vous avec Internet pour le récupérer.'
            : message,
        Colors.red.shade400,
      );
    } on RegistrationApprovalException catch (error) {
      if (firebaseAccountCreated) {
        if (createdThisAttempt && firebaseUser != null) {
          try {
            await firebaseUser.delete();
          } catch (deleteError, stackTrace) {
            developer.log(
              'Impossible d’annuler le compte après une erreur de confirmation',
              name: 'RegisterScreen',
              error: deleteError,
              stackTrace: stackTrace,
            );
          }
        }
        await _signOutAfterFailure();
      }
      _snackBar(error.message, Colors.red.shade400);
    } catch (e) {
      if (firebaseAccountCreated) {
        await _signOutAfterFailure();
      }
      developer.log(
        'Erreur pendant la création du compte',
        name: 'RegisterScreen',
        error: e,
      );
      _snackBar(
        firebaseAccountCreated && !localProfileSaved
            ? 'Compte Firebase créé, mais le profil local n’a pas pu être enregistré. Connectez-vous avec Internet pour le récupérer.'
            : 'Impossible de créer le compte. Réessayez.',
        Colors.red.shade400,
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _signOutAfterFailure() async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (error, stackTrace) {
      developer.log(
        'Impossible de fermer la session Firebase après une erreur',
        name: 'RegisterScreen',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _snackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _buildHeader() {
    return ScaleTransition(
      scale: _scaleAnim,
      child: Column(
        children: const [
          SizedBox(height: 20),
          Text(
            'Créer un compte',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 28,
              color: Colors.white,
              shadows: [
                Shadow(
                  offset: Offset(0, 2),
                  blurRadius: 4,
                  color: Colors.black26,
                ),
              ],
            ),
          ),
          SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildFormFields() {
    final labels = [
      tr(context, 'first_name'),
      tr(context, 'name'),
      tr(context, 'email'),
      tr(context, 'password'),
    ];
    final icons = [Icons.person_outline, Icons.person, Icons.email, Icons.lock];
    final fields = [
      _controllers['firstName']!,
      _controllers['lastName']!,
      _controllers['email']!,
      _controllers['password']!,
    ];
    final validators = [
      (String? val) =>
          val?.trim().isEmpty ?? true ? 'Veuillez entrer votre prénom' : null,
      (String? val) =>
          val?.trim().isEmpty ?? true ? 'Veuillez entrer votre nom' : null,
      (String? val) {
        if (val == null || val.isEmpty) {
          return 'Veuillez entrer un email valide';
        }
        if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(val)) {
          return 'Veuillez entrer un email valide';
        }
        return null;
      },
      (String? val) => (val?.length ?? 0) < 6 ? 'Minimum 6 caractères' : null,
    ];
    final obs = [false, false, false, _obscurePassword];
    return Column(
      children: List.generate(4, (i) {
        return Padding(
          padding: EdgeInsets.only(bottom: i == 3 ? 0 : 20),
          child: SlideTransition(
            position: _fieldSlideAnims[i],
            child: FadeTransition(
              opacity: _formController,
              child:
                  i < 3
                      ? _buildTextField(
                        fields[i],
                        labels[i],
                        icons[i],
                        validators[i],
                        obs[i],
                      )
                      : _buildPasswordField(
                        fields[i],
                        labels[i],
                        obs[i],
                        () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                        validators[i],
                      ),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String label,
    IconData icon,
    String? Function(String?) validator,
    bool obscure,
  ) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        style: const TextStyle(color: Colors.white, fontSize: 16),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontWeight: FontWeight.w500,
          ),
          prefixIcon: Icon(icon, color: Colors.white.withValues(alpha: 0.8)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Colors.white, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: Colors.red.shade300, width: 2),
          ),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.15),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 16,
          ),
        ),
        validator: validator,
        keyboardType:
            label == 'Email' ? TextInputType.emailAddress : TextInputType.text,
      ),
    );
  }

  Widget _buildPasswordField(
    TextEditingController controller,
    String label,
    bool obscure,
    VoidCallback onToggle,
    String? Function(String?) validator,
  ) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        style: const TextStyle(color: Colors.white, fontSize: 16),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontWeight: FontWeight.w500,
          ),
          prefixIcon: const Icon(Icons.lock, color: Colors.white70),
          suffixIcon: IconButton(
            icon: Icon(
              obscure ? Icons.visibility : Icons.visibility_off,
              color: Colors.white70,
            ),
            onPressed: onToggle,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Colors.white, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: Colors.red.shade300, width: 2),
          ),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.15),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 16,
          ),
        ),
        validator: validator,
      ),
    );
  }

  Widget _buildRegisterButton() {
    final scaleAnim = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _buttonController, curve: Curves.easeInOut),
    );
    final rotateAnim = Tween<double>(begin: 0.0, end: 0.02).animate(
      CurvedAnimation(parent: _buttonController, curve: Curves.easeInOut),
    );
    return AnimatedBuilder(
      animation: _buttonController,
      builder:
          (context, child) => Transform.scale(
            scale: scaleAnim.value,
            child: Transform.rotate(
              angle: rotateAnim.value,
              child: Container(
                width: double.infinity,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 15,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1ABC9C),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child:
                      _isLoading
                          ? const SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 3,
                            ),
                          )
                          : const Text(
                            'CRÉER MON COMPTE',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                ),
              ),
            ),
          ),
    );
  }

  Widget _buildLoginLink() {
    return AnimatedBuilder(
      animation: _floatAnim,
      builder:
          (context, child) => Transform.translate(
            offset: Offset(_floatAnim.value * 0.1, 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(25),
                color: Colors.white.withValues(alpha: 0.1),
                border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
              ),
              child: TextButton(
                onPressed:
                    () => Navigator.pushReplacementNamed(context, '/auth'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.zero,
                ),
                child: const Text(
                  'Déjà un compte ? Se connecter',
                  style: TextStyle(fontWeight: FontWeight.w500, fontSize: 15),
                ),
              ),
            ),
          ),
    );
  }

  Widget _buildProfilePicture() {
    return GestureDetector(
      onTap: () async {
        try {
          final pickedFile = await ImagePicker().pickImage(
            source: ImageSource.gallery,
          );
          if (pickedFile != null && mounted) {
            setState(() => _profilePicturePath = pickedFile.path);
          }
        } catch (error, stackTrace) {
          developer.log(
            'Erreur lors du choix de la photo de profil',
            name: 'RegisterScreen',
            error: error,
            stackTrace: stackTrace,
          );
          if (mounted) {
            _snackBar(
              'Impossible de sélectionner cette photo.',
              Colors.red.shade400,
            );
          }
        }
      },
      child: CircleAvatar(
        radius: 50,
        backgroundColor: Colors.white,
        backgroundImage:
            _profilePicturePath != null
                ? FileImage(File(_profilePicturePath!))
                : null,
        child:
            _profilePicturePath == null
                ? const Icon(Icons.camera_alt, size: 40, color: Colors.grey)
                : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text(
          'Inscription',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF1ABC9C), Color(0xFF3498DB)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildProfilePicture(),
                const SizedBox(height: 16),
                _buildHeader(),
                const SizedBox(height: 32),
                Form(key: _formKey, child: _buildFormFields()),
                const SizedBox(height: 20),
                _buildRegisterButton(),
                const SizedBox(height: 20),
                _buildLoginLink(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
