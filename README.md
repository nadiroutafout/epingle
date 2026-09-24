<p align="center"><img src="Resources/AppIcon.png" width="160" alt="Icône Épingle"></p>

<h1 align="center">Épingle</h1>

<p align="center">Mettez n'importe quelle fenêtre au premier plan et épinglez-la au-dessus de toutes les autres sur macOS.</p>

## Fonctionnalités

- **Recherche rapide (⌃⌥Espace)** : tapez quelques lettres pour trouver une fenêtre. ↩ la met au premier plan, ⌘↩ l'épingle ou la désépingle.
- **Épingler la fenêtre active (⌃⌥P)** : même raccourci pour la désépingler.
- **Menu 📌** : les fenêtres visibles, avec leurs actions. Les fenêtres réduites, masquées ou sur un autre bureau ne sont pas proposées.
- **Sur une fenêtre épinglée** :
  - clic : travailler dans la vraie fenêtre ; glisser : déplacer ;
  - glisser un coin (sauf en haut à droite) : redimensionner, pour garder une miniature dans un coin de l'écran ;
  - ⌥ + molette : régler l'opacité ;
  - clic sur la punaise 📌 : désépingler ;
  - clic droit : mode fantôme (les clics traversent la fenêtre), opacité, recadrage, taille réelle.
- **Recadrage** : n'épinglez qu'une partie d'une fenêtre, par exemple le lecteur vidéo d'une page web.
- **Mémoire** : les épingles sont restaurées après une relance d'Épingle, d'une app ou du Mac.
- **Réglages** : raccourcis personnalisables, fluidité (30 ou 60 images/s), punaise visible ou non, ouverture à la connexion.

## Comment ça marche

macOS n'autorise pas une app à modifier le niveau des fenêtres d'une autre app. Épingle affiche donc une **copie en direct** de la fenêtre (via ScreenCaptureKit) dans un panneau flottant, visible sur tous les bureaux.

Quand vous travaillez dans la fenêtre épinglée, la copie disparaît et la capture s'arrête. Dès que vous passez à une autre fenêtre, même dans la même app, la copie reprend sa place au premier plan.

La capture reste locale : rien n'est enregistré ni envoyé. L'indicateur violet d'enregistrement d'écran de macOS s'affiche tant qu'une copie est visible.

## Installation

### Télécharger

Chaque version est publiée sur la page [Releases](../../releases) (Apple Silicon et Intel, macOS 14 ou plus). Ouvrez le `.dmg` et glissez Épingle dans Applications.

Sans signature Developer ID, macOS bloque la première ouverture : lancez l'app une fois, puis cliquez sur **Ouvrir quand même** dans Réglages Système → Confidentialité et sécurité.

### Compiler

Nécessite les Command Line Tools (`xcode-select --install`).

```sh
./build.sh                 # compile et installe dans /Applications
UNIVERSAL=1 ./build.sh     # binaire universel Apple Silicon + Intel
./make-dmg.sh              # crée build/Epingle-<version>.dmg à partager
```

L'icône est générée par `swift Tools/make-icon.swift`.

### Autorisations

Au premier lancement, autorisez Épingle dans **Réglages Système → Confidentialité et sécurité** :

- **Accessibilité** : pour mettre les fenêtres au premier plan, les déplacer et savoir laquelle a le focus.
- **Enregistrement de l'écran** : pour afficher la copie des fenêtres épinglées.

## Publier une version

Poussez un tag : GitHub Actions compile le binaire universel et crée la version.

```sh
git tag v2.0 && git push origin v2.0
```

### Signature et notarisation (optionnel)

Avec un compte Apple Developer (99 $/an), l'app s'ouvre sans avertissement et macOS ne redemande plus les autorisations à chaque mise à jour. Ajoutez ces secrets au dépôt (Settings → Secrets and variables → Actions) :

| Secret | Contenu |
| --- | --- |
| `MACOS_CERTIFICATE` | Certificat « Developer ID Application » exporté en .p12, encodé en base64 (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PASSWORD` | Mot de passe du .p12 |
| `SIGN_IDENTITY` | Nom du certificat, ex. `Developer ID Application: Nom Prénom (TEAMID)` |
| `APPLE_ID` | Adresse de votre compte Apple Developer |
| `APPLE_TEAM_ID` | Identifiant d'équipe (10 caractères) |
| `APPLE_APP_PASSWORD` | Mot de passe pour app, créé sur [account.apple.com](https://account.apple.com) |

Sans ces secrets, l'app est signée localement (« ad hoc ») et fonctionne quand même.
