import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';

class CryptoService {
  static const int _iterations = 120000;

  static Future<String> hashPassword(String password) async {
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final derivedKey = await Isolate.run(
      () => _deriveKey(utf8.encode(password), salt, _iterations),
    );
    return 'pbkdf2_sha256\$$_iterations\$${_encodeHex(salt)}\$${_encodeHex(derivedKey)}';
  }

  static Future<bool> verifyPassword(
    String password,
    String encodedHash,
  ) async {
    final parts = encodedHash.split(r'$');
    if (parts.length != 4 || parts[0] != 'pbkdf2_sha256') return false;

    final iterations = int.tryParse(parts[1]);
    final salt = _decodeHex(parts[2]);
    final expectedKey = _decodeHex(parts[3]);
    if (iterations == null ||
        iterations < 1 ||
        iterations > 1000000 ||
        salt == null ||
        expectedKey == null ||
        expectedKey.length != 32) {
      return false;
    }

    final actualKey = await Isolate.run(
      () => _deriveKey(utf8.encode(password), salt, iterations),
    );
    var difference = 0;
    for (var i = 0; i < expectedKey.length; i++) {
      difference |= expectedKey[i] ^ actualKey[i];
    }
    return difference == 0;
  }

  static bool isPasswordHash(String value) {
    final parts = value.split(r'$');
    final iterations = parts.length == 4 ? int.tryParse(parts[1]) : null;
    final salt = parts.length == 4 ? _decodeHex(parts[2]) : null;
    final key = parts.length == 4 ? _decodeHex(parts[3]) : null;
    return parts.length == 4 &&
        parts[0] == 'pbkdf2_sha256' &&
        iterations != null &&
        iterations >= 1 &&
        iterations <= 1000000 &&
        salt?.length == 16 &&
        key?.length == 32;
  }

  static List<int> _deriveKey(
    List<int> password,
    List<int> salt,
    int iterations,
  ) {
    final hmac = Hmac(sha256, password);
    var block = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final derivedKey = List<int>.from(block);

    for (var iteration = 1; iteration < iterations; iteration++) {
      block = hmac.convert(block).bytes;
      for (var i = 0; i < derivedKey.length; i++) {
        derivedKey[i] ^= block[i];
      }
    }
    return derivedKey;
  }

  static String _encodeHex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static List<int>? _decodeHex(String value) {
    if (value.length.isOdd || !RegExp(r'^[0-9a-f]+$').hasMatch(value)) {
      return null;
    }
    return [
      for (var i = 0; i < value.length; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ];
  }
}
