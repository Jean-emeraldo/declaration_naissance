# declaration_naissance

Application Flutter de declaration de naissance, avec Firebase et stockage
SQLite local.

## Installation et build Android

```sh
flutter pub get
flutter build apk
```

## Confirmation des inscriptions

Apres la creation du compte avec Firebase Authentication Email/Password,
l'application appelle le service existant dans `server/otp_api`. Ce service
envoie un e-mail avec les choix **Confirmer** et **Refuser**. Une confirmation
marque l'adresse Firebase comme verifiee; un refus annule le compte. Les routes
OTP ne sont pas utilisees par l'application.

Le service doit etre deploye en HTTPS avec PostgreSQL, SMTP et Firebase Admin.
Consultez [son guide de configuration](server/otp_api/README.md), puis
recompilez l'application avec l'URL HTTPS de ce service :

```sh
flutter build apk --dart-define=REGISTRATION_APPROVAL_API_URL=https://VOTRE-URL-HTTPS
```

Sans cette URL, l'application ne peut pas envoyer ni verifier les decisions de
confirmation. L'adresse e-mail standard de Firebase ne fournit pas les boutons
Confirmer/Refuser.
