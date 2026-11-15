import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:local_auth/local_auth.dart';

import '../db/database_helper.dart';
import '../services/crypto_service.dart';
import '../services/sync_service.dart';
import '../widgets/email_verification_dialog.dart';

class AuthScreen extends StatefulWidget {
  static const String routeName = '/auth';

  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isEmailLoading = false;
  bool _isGoogleLoading = false;
  bool _isFaceLoading = false;
  bool _obscurePassword = true;
  final _storage = const FlutterSecureStorage();
  final LocalAuthentication _localAuth = LocalAuthentication();
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeIn),
    );
    _scaleAnimation = Tween<double>(begin: 0.8, end: 1).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.fastOutSlowIn,
      ),
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _isGoogleLoading = true);
    try {
      final googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) return;
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      final userCredential = await FirebaseAuth.instance.signInWithCredential(
        credential,
      );
      final user = userCredential.user;
      if (user == null) throw Exception('Erreur lors de la connexion Google');
      if (!user.emailVerified) {
        await user.sendEmailVerification();
        _showSnackBar(
          'Veuillez vérifier votre email Google pour terminer la connexion',
          Colors.orange,
        );
        await FirebaseAuth.instance.signOut();
        return;
      }
      await _storage.write(key: 'user_email', value: user.email);
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/dashboard');
    } catch (e) {
      _showSnackBar('Erreur lors de la connexion Google : $e', Colors.red);
    } finally {
      if (mounted) setState(() => _isGoogleLoading = false);
    }
  }

  Future<void> _loginWithFace() async {
    setState(() => _isFaceLoading = true);
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isSupported = await _localAuth.isDeviceSupported();
      final availableBiometrics = await _localAuth.getAvailableBiometrics();
      if (!canCheck ||
          !isSupported ||
          !availableBiometrics.contains(BiometricType.face)) {
        _showSnackBar(
          'La reconnaissance faciale n’est pas disponible sur cet appareil. Veuillez utiliser votre email et mot de passe.',
          Colors.orange,
        );
        return;
      }

      final authenticated = await _localAuth.authenticate(
        localizedReason:
            'Confirmez votre identité avec la reconnaissance faciale',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
      if (!authenticated) {
        _showSnackBar(
          'Reconnaissance faciale annulée ou échouée. Vous pouvez utiliser votre email et mot de passe.',
          Colors.orange,
        );
        return;
      }

      final email = await _storage.read(key: 'user_email');
      if (email == null || email.isEmpty) {
        _showSnackBar(
          'Connectez-vous une première fois avec votre email et votre mot de passe sur cet appareil.',
          Colors.orange,
        );
        return;
      }
      final localUser = await DatabaseHelper.instance.getUserByEmail(email);
      if (localUser == null ||
          (localUser['firebaseUid'] as String?)?.isNotEmpty != true) {
        _showSnackBar(
          'Aucun compte synchronisé n’est disponible pour cette connexion biométrique.',
          Colors.orange,
        );
        return;
      }

      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/dashboard');
    } catch (e) {
      developer.log(
        'Erreur lors de la vérification biométrique',
        name: 'AuthScreen',
        error: e,
      );
      _showSnackBar(
        'La reconnaissance faciale a échoué. Utilisez votre email et mot de passe.',
        Colors.red,
      );
    } finally {
      if (mounted) setState(() => _isFaceLoading = false);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isEmailLoading = true);
    final email = _emailController.text.trim().toLowerCase();
    final password = _passwordController.text;
    Map<String, dynamic>? localUser;
    try {
      final database = DatabaseHelper.instance;
      localUser = await database.getUserByEmail(email);
      if (localUser != null) {
        final passwordHash = localUser['password'] as String? ?? '';
        if (!await CryptoService.verifyPassword(password, passwordHash)) {
          _showSnackBar('Mot de passe incorrect.', Colors.red);
          return;
        }
      }

      if (!await database.isOnline) {
        if (localUser == null) {
          _showSnackBar(
            'Aucun compte local ne correspond à cet email. Connectez-vous une première fois avec Internet.',
            Colors.orange,
          );
          return;
        }
        if (localUser['emailVerified'] == 0) {
          _showSnackBar(
            'Vérifiez votre adresse e-mail avec Internet avant de vous connecter.',
            Colors.orange,
          );
          return;
        }
        if ((localUser['firebaseUid'] as String?)?.isNotEmpty != true) {
          _showSnackBar(
            'Ce compte local n’est pas encore synchronisé avec Firebase. Connectez-vous avec Internet.',
            Colors.orange,
          );
          return;
        }
        await _storage.write(key: 'user_email', value: email);
        if (!mounted) return;
        Navigator.pushReplacementNamed(context, '/dashboard');
        return;
      }

      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        throw StateError('Firebase n’a pas retourné le compte connecté.');
      }

      if (!user.emailVerified) {
        if (!mounted) return;
        final verified = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => EmailVerificationDialog(user: user),
        );
        if (verified != true || !mounted) {
          await FirebaseAuth.instance.signOut();
          return;
        }
        await user.reload();
        if (!mounted) {
          await FirebaseAuth.instance.signOut();
          return;
        }
        if (FirebaseAuth.instance.currentUser?.emailVerified != true) {
          await FirebaseAuth.instance.signOut();
          _showSnackBar(
            'Votre adresse email n’est pas encore vérifiée. Ouvrez le lien reçu puis réessayez.',
            Colors.orange,
          );
          return;
        }
      }

      Map<String, dynamic> cachedUser;
      if (localUser == null) {
        Map<String, dynamic> profile = {};
        try {
          final snapshot =
              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(user.uid)
                  .get();
          profile = snapshot.data() ?? {};
        } catch (error, stackTrace) {
          developer.log(
            'Profil distant indisponible pendant la connexion',
            name: 'AuthScreen',
            error: error,
            stackTrace: stackTrace,
          );
        }
        cachedUser = {
          'email': email,
          'password': await CryptoService.hashPassword(password),
          'firstName': profile['firstName'] ?? '',
          'lastName': profile['lastName'] ?? '',
          'profilePicture': profile['profilePicture'],
          'firebaseUid': user.uid,
          'emailVerified': 1,
          'synced': profile.isEmpty ? 0 : 1,
        };
        await database.insertUser(cachedUser);
      } else {
        cachedUser = {
          ...localUser,
          'firebaseUid': user.uid,
          'emailVerified': 1,
        };
        await database.updateUser(email, {
          'firebaseUid': user.uid,
          'emailVerified': 1,
        });
      }

      if (cachedUser['synced'] != 1) {
        try {
          await SyncService().syncUser(cachedUser);
        } catch (error, stackTrace) {
          developer.log(
            'Échec de synchronisation du profil pendant la connexion',
            name: 'AuthScreen',
            error: error,
            stackTrace: stackTrace,
          );
          _showSnackBar(
            'Connexion réussie. La synchronisation du profil sera réessayée plus tard.',
            Colors.orange,
          );
        }
      }

      await _storage.write(key: 'user_email', value: user.email);
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/dashboard');
    } on FirebaseAuthException catch (e) {
      final message = switch (e.code) {
        'user-not-found' || 'invalid-credential' =>
          'Aucun compte Firebase ne correspond à cet email ou au mot de passe.',
        'wrong-password' => 'Mot de passe incorrect.',
        'invalid-email' => 'Adresse email invalide.',
        'network-request-failed' =>
          'Connexion Internet indisponible. Réessayez ou utilisez un compte déjà synchronisé.',
        _ => e.message ?? 'Erreur lors de la connexion Firebase.',
      };
      if (e.code == 'network-request-failed' &&
          localUser != null &&
          (localUser['firebaseUid'] as String?)?.isNotEmpty == true) {
        await _storage.write(key: 'user_email', value: email);
        if (mounted) Navigator.pushReplacementNamed(context, '/dashboard');
        return;
      }
      _showSnackBar(message, Colors.red);
    } catch (e) {
      developer.log(
        'Erreur pendant la connexion email/mot de passe',
        name: 'AuthScreen',
        error: e,
      );
      _showSnackBar(
        'Impossible de terminer la connexion. Vérifiez votre connexion et réessayez.',
        Colors.red,
      );
    } finally {
      if (mounted) setState(() => _isEmailLoading = false);
    }
  }

  Widget _buildStartFaceRecognitionButton() {
    return ElevatedButton.icon(
      icon: const Icon(Icons.face, size: 20),
      label:
          _isFaceLoading
              ? const SizedBox(
                height: 22,
                width: 22,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              )
              : const Text(
                'Connexion par visage',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF1ABC9C),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      onPressed: _isFaceLoading ? null : _loginWithFace,
    );
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FadeTransition(
        opacity: _fadeAnimation,
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: Container(
            width: double.infinity,
            height: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF1ABC9C), Color(0xFF3498DB)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            child: Center(
              child: SingleChildScrollView(
                child: Card(
                  elevation: 12,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(48),
                          child: Image.asset(
                            'assets/images/bb.png',
                            width: 80,
                            height: 80,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _buildStartFaceRecognitionButton(),
                        const SizedBox(height: 24),
                        Form(
                          key: _formKey,
                          child: Column(
                            children: [
                              TextFormField(
                                controller: _emailController,
                                decoration: InputDecoration(
                                  labelText: 'Email',
                                  prefixIcon: const Icon(
                                    Icons.email,
                                    color: Color(0xFF3498DB),
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(20),
                                    borderSide: const BorderSide(
                                      color: Color(0xFF1ABC9C),
                                      width: 2,
                                    ),
                                  ),
                                ),
                                keyboardType: TextInputType.emailAddress,
                                validator: (value) {
                                  if (value == null || value.isEmpty) {
                                    return 'Veuillez entrer un email valide';
                                  }
                                  if (!RegExp(
                                    r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                                  ).hasMatch(value)) {
                                    return 'Veuillez entrer un email valide';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 18),
                              TextFormField(
                                controller: _passwordController,
                                decoration: InputDecoration(
                                  labelText: 'Mot de passe',
                                  prefixIcon: const Icon(
                                    Icons.lock,
                                    color: Color(0xFF3498DB),
                                  ),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscurePassword
                                          ? Icons.visibility
                                          : Icons.visibility_off,
                                      color: const Color(0xFF1ABC9C),
                                    ),
                                    onPressed:
                                        () => setState(
                                          () =>
                                              _obscurePassword =
                                                  !_obscurePassword,
                                        ),
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(20),
                                    borderSide: const BorderSide(
                                      color: Color(0xFF1ABC9C),
                                      width: 2,
                                    ),
                                  ),
                                ),
                                obscureText: _obscurePassword,
                                validator:
                                    (value) =>
                                        (value?.length ?? 0) < 6
                                            ? 'Minimum 6 caractères'
                                            : null,
                              ),
                              const SizedBox(height: 26),
                              ElevatedButton(
                                onPressed: _isEmailLoading ? null : _submit,
                                style: ElevatedButton.styleFrom(
                                  minimumSize: const Size(double.infinity, 50),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  backgroundColor: const Color(0xFF1ABC9C),
                                  elevation: 8,
                                  shadowColor: const Color(0xFF16A085),
                                ),
                                child:
                                    _isEmailLoading
                                        ? const SizedBox(
                                          height: 24,
                                          width: 24,
                                          child: CircularProgressIndicator(
                                            color: Colors.white,
                                            strokeWidth: 3,
                                          ),
                                        )
                                        : const Text(
                                          'CONNEXION',
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Divider(color: Colors.grey),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                child: Text(
                                  'OU',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ),
                              const Expanded(
                                child: Divider(color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ElevatedButton.icon(
                            icon: Image.asset(
                              'assets/images/google_logo.png',
                              height: 28,
                            ),
                            label:
                                _isGoogleLoading
                                    ? const SizedBox(
                                      height: 24,
                                      width: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                    : const Text(
                                      'Se connecter avec Google',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1ABC9C),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                              elevation: 8,
                              shadowColor: const Color(0xFFB33628),
                            ),
                            onPressed:
                                _isGoogleLoading ? null : _signInWithGoogle,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed:
                              () => Navigator.pushNamed(context, '/register'),
                          child: const Text(
                            "Créer un compte",
                            style: TextStyle(
                              fontSize: 14,
                              color: Color(0xFF3498DB),
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
