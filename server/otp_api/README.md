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

## Deployer sur Google Cloud Run

Le dossier contient un `Dockerfile` compatible avec Cloud Run. Le service utilise
l'identite runtime Cloud Run pour Firebase Admin; ne fournissez pas de fichier
JSON de compte de service a l'application.

1. Dans la console Google Cloud, selectionnez le projet Firebase et activez
   **Cloud Run**, **Cloud Build**, **Artifact Registry**, **Secret Manager** et
   **Identity Toolkit API**.
2. Dans **IAM et administration > Comptes de service**, creez un compte de
   service dedie a l'API et attribuez-lui le role **Firebase Authentication
   Admin**. Laissez les utilisateurs non authentifies appeler le service Cloud
   Run, car les liens de decision recus par email doivent etre accessibles sans
   connexion.
3. Dans **Secret Manager**, creez les secrets
   `DATABASE_URL`, `APPROVAL_TOKEN_SECRET`, `SMTP_USER` et `SMTP_PASS`. Accordez
   au compte de service runtime le role **Secret Manager Secret Accessor** sur
   ces secrets. `DATABASE_URL` doit utiliser une connexion TLS si le fournisseur
   PostgreSQL la requiert.
4. Publiez le dossier `server/otp_api` sur GitHub, puis ouvrez **Cloud Shell**
   dans la console Google Cloud et clonez votre depot. Ne mettez aucun fichier
   `.env` ni secret dans GitHub. Depuis le dossier `server/otp_api`, lancez :

   ```sh
   gcloud config set project etatcivil-d7daa
   gcloud run deploy registration-approval-api \
     --source . \
     --region europe-west1 \
     --allow-unauthenticated \
     --service-account NOM_DU_COMPTE_RUNTIME \
     --set-env-vars PUBLIC_BASE_URL=https://URL_SERVICE_CLOUD_RUN,EMAIL_FROM=ADRESSE_EXPEDITEUR,SMTP_HOST=HOTE_SMTP,SMTP_PORT=587,SMTP_SECURE=false,REGISTRATION_APPROVAL_TTL_MINUTES=30 \
     --set-secrets DATABASE_URL=DATABASE_URL:latest,APPROVAL_TOKEN_SECRET=APPROVAL_TOKEN_SECRET:latest,SMTP_USER=SMTP_USER:latest,SMTP_PASS=SMTP_PASS:latest
   ```

   Remplacez `NOM_DU_COMPTE_RUNTIME` et les valeurs SMTP. Pour la premiere
   publication, Cloud Run ne connait pas encore son URL. Utilisez temporairement
   `https://example.invalid` comme `PUBLIC_BASE_URL`, deployez, copiez l'URL
   HTTPS affichee par Cloud Run, puis redemarrez le meme deploiement en mettant
   cette URL dans `PUBLIC_BASE_URL`. Gardez la meme region pendant les deux
   deploiements.
5. Testez `https://URL_SERVICE_CLOUD_RUN/health`; une reponse `{"ok":true}`
   confirme que le service repond. Verifiez les journaux Cloud Run si le
   conteneur ne demarre pas.
6. Recompilez Flutter avec l'URL Cloud Run reelle :

   ```sh
   flutter build apk --dart-define=REGISTRATION_APPROVAL_API_URL=https://URL_SERVICE_CLOUD_RUN
   ```

Choisissez une region proche de votre base PostgreSQL. `europe-west1` dans la
commande est un exemple : remplacez-la si votre base est situee ailleurs.
N'envoyez jamais les valeurs secretes dans un message, dans Git ou dans les
arguments `--set-env-vars`; utilisez Secret Manager comme ci-dessus.

## Compiler Flutter

Compilez l'application avec l'URL HTTPS publique de l'API :

```sh
flutter build apk --dart-define=REGISTRATION_APPROVAL_API_URL=https://api.example.com
```

Installez ce nouvel APK. Lors d'une inscription, ouvrez le mail et choisissez
Confirmer ou Refuser; l'application attend la decision et se met a jour
automatiquement. En cas de refus ou d'expiration, le compte Firebase est annule.
