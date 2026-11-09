# zerOS

[Français](#français) · [English](#english)

---

## Français

**Un assistant discret pour garder votre Mac propre, léger et en bonne santé.**
App macOS native, en français, gratuite et open source.

zerOS affiche des chiffres et des états (vert, orange, rouge), propose au plus trois actions utiles, et ne supprime jamais rien sans vous montrer d'abord la liste et la taille.

**[Télécharger la dernière version](https://github.com/zeropablo/zerOS/releases/latest)**

### Ce que fait zerOS

- **Aujourd'hui** : l'état du Mac en un coup d'œil (disque interne, mémoire, disques externes, dernier nettoyage, espace récupérable) et au plus trois actions proposées.
- **Stockage** : nettoyage des caches et fichiers inutiles, carte du disque par catégorie, « Données système » expliquées, gros fichiers, doublons, photos similaires, Téléchargements, fichiers cloud à libérer. **Déplacer** donne la marche à suivre pour ranger les données lourdes d'apps (bibliothèques de sons, jeux…) sur un disque externe ; zerOS ne déplace rien lui-même.
- **Apps** : désinstallation propre (avec les services d'arrière-plan liés), restes d'apps supprimées, installateurs, mises à jour, démarrage et arrière-plan.
- **Santé** : mémoire, disques (SMART et température quand ils sont lisibles), audio, batterie, réparations manuelles.
- **Journal** : tout ce que zerOS a fait, avec la date et la taille.
- **Barre des menus** : états clés et raccourcis. Notifications macOS seulement pour le critique (disque plein).

### Sécurité du nettoyage

- **Suppression définitive uniquement pour les caches et fichiers que macOS ou les apps recréent seuls.**
- **Tout fichier à vous va à la Corbeille**, donc récupérable : doublons, gros fichiers, téléchargements, installateurs, photos, apps désinstallées et leurs restes.
- **Rien n'est coché d'office**, sauf les caches régénérables.
- **Confirmation avant toute action**, avec la liste, le nombre et la taille.
- **Jamais touchés** : vos projets (Logic, Ableton, After Effects, Premiere, Photoshop, Final Cut…) et les dossiers qui en contiennent, Musique, Films, les dossiers et disques que vous mettez en lecture seule, vos e-mails, l'historique et les mots de passe des navigateurs, les conversations des apps d'IA.
- **Vider la Corbeille** est une action à part, jamais cochée, avec confirmation.

Le détail de chaque catégorie est dans [SECURITE-NETTOYAGE.md](SECURITE-NETTOYAGE.md).

### Installation

1. Mac **Apple Silicon** (M1 et suivants), **macOS 15 Sequoia** ou plus récent.
2. Ouvrez `zerOS-1.0.0.dmg` et glissez **zerOS** sur **Applications**.
3. zerOS n'est pas notarisé par Apple. Au premier lancement, cliquez sur **Terminé**, puis allez dans Réglages Système > Confidentialité et sécurité > **Ouvrir quand même** (une seule fois).
4. Recommandé : Réglages Système > Confidentialité et sécurité > **Accès complet au disque** > activez zerOS. Sans cet accès, Mail, Safari et la Corbeille ne sont pas analysés.

Un assistant de premier lancement vous guide. Rien n'est enregistré avant « Terminer ».

### Légèreté

Fenêtre fermée, zerOS ne fait presque rien (≈ 0 % de processeur, mémoire rendue). Les analyses ne se lancent qu'à votre demande.

### Confidentialité

zerOS fonctionne entièrement sur votre Mac : pas de compte, pas de publicité, pas de statistiques, rien n'est envoyé. Seule exception : la vérification des mises à jour de vos apps interroge leurs propres serveurs (et l'App Store), à votre demande.

### Compiler soi-même

Prérequis : les Command Line Tools d'Apple (`xcode-select --install`).

```
./build.sh       # construit dist/zerOS.app
./make_dmg.sh    # fabrique le .dmg dans dist/
```

Par défaut l'app est signée ad hoc. Pour la signer avec votre identité : `SIGN_IDENTITY="Votre identité" ./build.sh`.

### Signaler un problème

Onglet [Issues](https://github.com/zeropablo/zerOS/issues) : décrivez ce qui s'est passé, votre modèle de Mac et votre version de macOS.

### À propos

zerOS est un projet personnel développé en *vibe coding* : je décris ce que je veux, une IA écrit le code, je teste et je tranche.

© 2026 zeropablo — GPL-3.0, voir [LICENSE](LICENSE).

---

## English

**A quiet assistant that keeps your Mac clean, light and healthy.**
Native macOS app, free and open source. **The interface is in French only.**

zerOS shows numbers and states (green, orange, red), suggests at most three useful actions, and never deletes anything without first showing you the list and the size.

**[Download the latest version](https://github.com/zeropablo/zerOS/releases/latest)**

### What zerOS does

- **Today**: your Mac's state at a glance (internal disk, memory, external disks, last cleanup, reclaimable space) and at most three suggested actions.
- **Storage**: cleans caches and junk files, disk map by category, "System Data" explained, large files, duplicates, similar photos, Downloads, cloud files to free up. **Move** explains how to put heavy app data (sound libraries, games…) on an external disk; zerOS never moves anything itself.
- **Apps**: clean uninstall (including related background services), leftovers from deleted apps, installers, updates, login and background items.
- **Health**: memory, disks (SMART and temperature when readable), audio, battery, manual repairs.
- **Log**: everything zerOS has done, with date and size.
- **Menu bar**: key states and shortcuts. macOS notifications only for critical issues (disk full).

### Cleanup safety

- **Permanent deletion only for caches and files that macOS or apps rebuild on their own.**
- **Anything that is yours goes to the Trash**, so it can be recovered: duplicates, large files, downloads, installers, photos, uninstalled apps and their leftovers.
- **Nothing is pre-selected**, except rebuildable caches.
- **Confirmation before every action**, with the list, count and size.
- **Never touched**: your projects (Logic, Ableton, After Effects, Premiere, Photoshop, Final Cut…) and any folder containing them, Music, Movies, folders and disks you set as read-only, your emails, browser history and passwords, AI app conversations.
- **Empty Trash** is a separate action, never pre-selected, always confirmed.

Details for each category (in French): [SECURITE-NETTOYAGE.md](SECURITE-NETTOYAGE.md).

### Installation

1. **Apple Silicon** Mac (M1 or later), **macOS 15 Sequoia** or later.
2. Open `zerOS-1.0.0.dmg` and drag **zerOS** onto **Applications**.
3. zerOS is not notarized by Apple. On first launch, click **Done**, then go to System Settings > Privacy & Security > **Open Anyway** (only once).
4. Recommended: System Settings > Privacy & Security > **Full Disk Access** > turn on zerOS. Without it, Mail, Safari and the Trash are not scanned.

A first-launch assistant guides you. Nothing is saved until you click "Terminer" (Finish).

### Lightweight

With its window closed, zerOS does almost nothing (≈ 0% CPU, memory released). Scans only run when you ask.

### Privacy

zerOS runs entirely on your Mac: no account, no ads, no analytics, nothing is sent. One exception: checking for app updates contacts those apps' own servers (and the App Store), when you ask.

### Build from source

Requirements: Apple's Command Line Tools (`xcode-select --install`).

```
./build.sh       # builds dist/zerOS.app
./make_dmg.sh    # builds the .dmg in dist/
```

The app is ad-hoc signed by default. To sign with your own identity: `SIGN_IDENTITY="Your identity" ./build.sh`.

### Report a problem

[Issues](https://github.com/zeropablo/zerOS/issues) tab: describe what happened, your Mac model and your macOS version.

### About

zerOS is a personal project built through *vibe coding*: I describe what I want, an AI writes the code, I test and make the calls.

© 2026 zeropablo — GPL-3.0, see [LICENSE](LICENSE).
