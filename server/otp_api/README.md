# API de confirmation d'inscription

Firebase Authentication n'envoie pas de demande avec les boutons confirmer et
refuser. Cette API de confiance envoie ces deux liens, enregistre leur etat dans
PostgreSQL et marque le compte Firebase verifie apres confirmation. Un refus ou
une expiration supprime le compte Firebase. Les jetons des liens ne sont stockes
qu'en HMAC; les liens utilisent un formulaire POST afin qu'un scanner d'emails
qui ouvre simplement les liens ne puisse pas confirmer ou refuser a la place de
l'utilisateur.

## Prerequis

- Node.js 22 ou plus recent.
- Une base PostgreSQL.
- Un compte SMTP et une adresse d'expedition autorisee par ce fournisseur.
- Un compte de service Firebase avec les droits d'administration Firebase
  Authentication. Ne placez jamais sa cle dans Flutter ni dans le depot.

## Lancer le service

1. Copiez `.env.example` en `.env`.
2. Renseignez `DATABASE_URL`, `PUBLIC_BASE_URL` (URL HTTPS publique de cette
   API, sans chemin), `APPROVAL_TOKEN_SECRET`, les parametres SMTP et
   `EMAIL_FROM`. Generez le secret d'approbation avec
   `openssl rand -hex 32`. Le TTL est de 30 minutes par defaut.
3. Configurez les identifiants Firebase Admin :
   - en local, definissez `GOOGLE_APPLICATION_CREDENTIALS` vers le fichier JSON
     du compte de service, stocke hors du depot;
   - sur Cloud Run, utilisez une identite de service avec les permissions
     Firebase Authentication necessaires.
4. Dans la console Firebase, activez **Authentication > Sign-in method >
   Email/Password**.
5. Installez et demarrez l'API :

   ```sh
   npm install
   npm start
   ```

Les tables et index PostgreSQL sont crees au demarrage. En production, exposez
le service uniquement derriere HTTPS et gardez les variables secretes dans le
gestionnaire de secrets de l'hebergeur. Les anciennes routes OTP ne sont plus
utilisees par l'application.

## Compiler Flutter

Compilez l'application avec l'URL HTTPS publique de l'API :

```sh
flutter build apk --dart-define=REGISTRATION_APPROVAL_API_URL=https://api.example.com
```

Installez ce nouvel APK. Lors d'une inscription, ouvrez le mail et choisissez
Confirmer ou Refuser; l'application attend la decision et se met a jour
automatiquement. En cas de refus ou d'expiration, le compte Firebase est annule.
