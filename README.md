# declaration_naissance

Application Flutter de declaration de naissance, avec Firebase et stockage
SQLite local.

## Installation et build Android

```sh
flutter pub get
flutter build apk
```

## Verification des inscriptions

L'inscription utilise Firebase Authentication Email/Password et envoie un lien
de verification avec `sendEmailVerification()`. La connexion e-mail refuse
l'acces tant que Firebase ne confirme pas l'adresse. Aucune API ni code OTP
n'est requis par l'application Flutter.
