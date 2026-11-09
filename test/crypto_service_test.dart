import 'package:flutter_test/flutter_test.dart';
import 'package:declaration_naissance/services/crypto_service.dart';

void main() {
  test(
    'password hashes are salted and verified without storing plaintext',
    () async {
      const password = 'correct horse battery staple';
      final firstHash = await CryptoService.hashPassword(password);
      final secondHash = await CryptoService.hashPassword(password);

      expect(firstHash, isNot(contains(password)));
      expect(firstHash, isNot(secondHash));
      expect(CryptoService.isPasswordHash(firstHash), isTrue);
      expect(await CryptoService.verifyPassword(password, firstHash), isTrue);
      expect(
        await CryptoService.verifyPassword('incorrect password', firstHash),
        isFalse,
      );
    },
  );
}
