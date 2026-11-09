# declaration_naissance

Application Flutter de declaration de naissance, avec Firebase et stockage
SQLite local.

## Installation et build Android

```sh
flutter pub get
flutter build apk
```

## Confirmation des nouvelles inscriptions

L'inscription envoie un email avec les choix **Confirmer** et **Refuser**.
Le profil local n'est sauvegarde qu'apres confirmation; un refus ou l'expiration
de la demande supprime le compte Firebase. Ce parcours requiert l'API
d'approbation, PostgreSQL, SMTP et Firebase Admin. Consultez
[le guide de configuration](server/otp_api/README.md).

Apres le deploiement de l'API HTTPS, reconstruisez l'application avec son URL :

```sh
flutter build apk --dart-define=REGISTRATION_APPROVAL_API_URL=https://api.example.com
```

Sans URL de service dans l'APK, les inscriptions email echouent explicitement.
La connexion email en ligne consulte aussi cette API pour ne pas laisser passer
une demande d'inscription en attente ou refusee; la connexion hors ligne d'un
compte deja enregistre localement reste disponible.
