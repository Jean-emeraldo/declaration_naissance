import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:declaration_naissance/screens/register_screen.dart';

void main() {
  testWidgets('registration fields remain available without removed sections', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: const RegisterScreen(),
        routes: {
          RegisterScreen.routeName: (_) => const RegisterScreen(),
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Commencer la reconnaissance faciale'), findsNothing);
    expect(find.text('Confirmer le mot de passe'), findsNothing);
    expect(find.byType(TextFormField), findsNWidgets(4));
    expect(find.text('Déjà un compte ? Se connecter'), findsOneWidget);
  });
}
