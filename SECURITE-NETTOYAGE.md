# zerOS — sécurité du nettoyage (version 1.0)

Inventaire de **tout ce que zerOS peut supprimer**, comment, et ce qui le protège. Vérifié par l'autotest `--selftest securite`
(`SelfTestCleanup.swift`) : la règle sur les vrais résultats d'analyse (lecture seule) et de vraies suppressions, mises à la Corbeille et
vidages de corbeille sur une **image disque temporaire** (`/tmp/zerOS-test-securite-…`, montée comme un disque externe) ; rien d'autre n'est touché.

## La règle 1.0

1. **Suppression définitive uniquement pour les caches et fichiers que macOS ou les apps recréent seuls** (groupes marqués « régénérables »
   dans le code : `CleanGroup.regenerable`).
2. **Tout fichier de l'utilisateur va à la Corbeille**, récupérable : doublons, gros et anciens fichiers, téléchargements, installateurs,
   photos similaires, pièces jointes, apps désinstallées et leurs restes, services, réglages abîmés… Un fichier système (dans `/Library`)
   va aussi à la Corbeille, avec le mot de passe administrateur (`mv -n` vers `~/.Trash`, jamais `rm`).
3. **Rien n'est présélectionné hors caches régénérables.**
4. **Confirmation avant toute action**, avec le nombre, la taille, la façon (Corbeille ou définitif) et la liste des éléments.

La règle est **appliquée au centre**, pas seulement dans chaque analyse : `CleanGroup.protected()` (avant affichage) et
`ScanSession.itemsToRun` (avant nettoyage) passent chaque élément par `CleanGroup.policy`. Hors groupe régénérable, une suppression définitive
devient une mise à la Corbeille (fichier, dossier, élément système), une action définitive sans équivalent (vider un cache Adobe) devient
« analyse seule », et la présélection est retirée. Même un bouton qui imposerait « supprimer » est ramené à la Corbeille.

## Protections communes (toutes les suppressions)

- **`FS.remove` / `FS.trash` / `FS.emptyDirectory`** sont les seuls chemins de suppression de fichiers ; tous refusent ce que
  `Ignore.removalBlocker` refuse :
  - **bloqué** (`~/.claude`, `~/.ssh`, trousseaux, dossiers système, exclusions de l'utilisateur) : jamais lu, jamais affiché ;
  - **lecture seule** (`~/Music`, `~/Movies`, disque de données, dossiers ajoutés, fichiers de projet partout : Logic, Ableton, After Effects,
    Premiere, Photoshop, TouchDesigner, Final Cut, Photos…) : affiché 🔒, jamais coché ni sélectionnable ;
  - **dossier qui contient un élément protégé** (projet, dossier en lecture seule ou bloqué), regardé à l'intérieur avant suppression
    (5 s / 300 000 entrées au plus ; au-delà, refusé par prudence) ;
  - **dossier cloud jamais téléchargé** (le supprimer le retirerait du cloud) : refusé.
- **`FS.emptyDirectory` vérifie aussi chaque élément contenu** : dans un dossier de caches (dont le contenu n'est pas inspecté d'avance),
  un projet ou un dossier en lecture seule rangé dedans est laissé en place et signalé.
- **Commandes administrateur** (`Shell.admin`) : chaque élément passe d'abord par `Ignore.removalBlocker` ; refusés jamais transmis.
- **Apps ouvertes** : leurs caches sont décochés ; elles sont fermées avant désinstallation ou mise à jour.
- **Doublons** : une copie de chaque série est toujours gardée (`keepOne`), même tout coché.
- Tout est noté au **Journal** (date, nombre, taille).

## Tableau

Légende : **Corbeille** = récupérable · **définitif** = supprimé pour de bon · **admin** = mot de passe administrateur demandé.

| Section > catégorie | Ce qui est supprimé | Comment | Coché d'office | Protections propres |
|---|---|---|---|---|
| **Nettoyage > Caches des apps** | contenu de `~/Library/Caches/<app>`, caches d'outils de développement | définitif (dossier vidé, gardé) | oui, sauf app ouverte | caches dont macOS a besoin exclus (iCloud, Localiser, trousseau…) ; caches ignorés (Réglages) ; chaque élément vérifié |
| Nettoyage > Caches du système | contenu de `/Library/Caches/<x>` | définitif, admin | oui, sauf caches Apple | dossier vérifié avant ; caches Apple décochés |
| Nettoyage > Journaux des apps | `~/Library/Logs/*` (rapports de plantage compris) | définitif | oui | — |
| Nettoyage > Journaux du système | `/Library/Logs/*`, anciens journaux archivés de `/private/var/log` (`.gz`, `.bz2`, `.N`) | définitif, admin | oui | journaux en cours jamais touchés |
| Nettoyage > Caches des navigateurs | caches de pages et d'images (Safari, Chrome, Firefox, Edge, Brave, Arc…) | définitif | oui, sauf navigateur ouvert | historique, cookies, mots de passe jamais touchés |
| Nettoyage > Caches de montage | Premiere, After Effects | **analyse seule** | — | — |
| Nettoyage > Caches Adobe (préférences) | contenu des dossiers de cache choisis dans After Effects / Premiere | définitif (recalculé par Adobe) | **jamais** | seulement apps Adobe fermées, contenu vérifié, chemin relu dans les préférences ; seule exception à la lecture seule (chemin explicite `CacheScan.emptyPrefsCache`) |
| Nettoyage > IA — caches, journaux | caches et journaux techniques de ChatGPT, Claude, Cursor… | définitif | oui, sauf app ouverte | conversations et réglages jamais touchés |
| Nettoyage > IA — modèles locaux | modèles téléchargés | Corbeille | non | — |
| Nettoyage > Déchets Xcode | DerivedData, caches des simulateurs, journaux des appareils, cache Xcode ; prise en charge iOS | définitif (recréés ou retéléchargés) | oui ; prise en charge iOS : non | — |
| Nettoyage > Déchets Xcode > Archives d'apps | vos versions publiées (`Xcode/Archives`) | **Corbeille** | non | jamais recréées : jamais définitif |
| Nettoyage > Éléments de démarrage cassés | lanceurs (`LaunchAgents` / `LaunchDaemons`) vers une app disparue | Corbeille (système : Corbeille, admin) | non | service arrêté avant |
| Nettoyage > Réglages abîmés | fichiers `.plist` illisibles de `~/Library/Preferences` | Corbeille | non | — |
| Nettoyage > Comptes supprimés | dossiers de `/Users/Deleted Users` | Corbeille, admin | non | — |
| Nettoyage > Versions de documents | anciennes versions gardées par macOS | **analyse seule** (une version supprimée ne passe pas par la Corbeille) | — | — |
| Nettoyage > Sauvegardes iPhone / iPad | copies d'appareils (`MobileSync/Backup`) | Corbeille | non | — |
| Nettoyage > Langues inutilisées, Code Intel | parties des apps | **analyse seule** (les retirer casse la signature) | — | — |
| Nettoyage > Pièces jointes Mail | `Attachments` de Mail, « Mail Downloads » | **Corbeille** (une boîte « Sur mon Mac » peut ne pas avoir d'autre copie) | non | e-mails jamais touchés |
| **Nettoyage > Vider la Corbeille** | contenu de `~/.Trash` et de la corbeille de l'utilisateur sur chaque disque externe (`.Trashes/<uid>`, à son nom), **détaillées séparément** | définitif (c'est la Corbeille) | **action à part** : jamais cochée, jamais dans « Nettoyer » | confirmation : nombre, taille, éléments mis par zerOS depuis 24 h, « irréversible » ; élément verrouillé (ou qui en contient un) ou en cours d'utilisation laissé et signalé ; **jamais de mot de passe administrateur ni de Finder pour forcer** ; `Ignore.removalBlocker` par élément ; refusé sur un dossier qui n'est pas une corbeille |
| Mon désordre > Gros et anciens fichiers | fichiers de votre dossier personnel | Corbeille | non | lecture seule et projets 🔒 |
| Mon désordre > Doublons | copies identiques | Corbeille | non | une copie toujours gardée |
| Mon désordre > Photos similaires | photos d'une même série | Corbeille | non | — |
| Mon désordre > Téléchargements | contenu de `~/Downloads` | Corbeille | non | — |
| Cloud > Libérer l'espace | copie locale d'un fichier iCloud / Drive / Dropbox | retiré du Mac, **gardé dans le cloud** (`evict`) | non | services qui ne répondent pas signalés, jamais attendus |
| Cloud > Supprimer partout | fichier du cloud | Corbeille (le service le retire aussi en ligne) | non | — |
| **Apps > Désinstallation** | l'app, ses fichiers liés (`~/Library`, `/Library`), ses services d'arrière-plan | Corbeille (fichiers système : Corbeille, admin) | l'app choisie ; fichiers liés : **seulement caches et états** (`Caches`, `Saved Application State`, `Logs`, `HTTPStorages`, `WebKit`) | app fermée, services arrêtés avant ; apps protégées refusées ; confirmation avec apps, tailles, fichiers cochés |
| Apps > Réinitialiser | fichiers liés cochés (l'app reste) | Corbeille | idem | — |
| Apps > Restes d'apps | restes d'apps qui ne sont plus installées | Corbeille | non | éditeur encore présent signalé « à vérifier » |
| Apps > Installateurs | `.dmg` / `.pkg` déjà utilisés | Corbeille | non | — |
| Apps > Mises à jour | ancienne version de l'app (Sparkle) | Corbeille (admin si besoin) | — | même développeur exigé (Team ID), sinon refusé ; app protégée refusée |
| Apps > Arrière-plan > « Mettre ce lanceur à la Corbeille… » | fichier `.plist` d'un service | Corbeille (système : Corbeille, admin) | — | confirmation ; service désactivé avant |
| Santé > Instantanés Time Machine | copies locales temporaires (`tmutil deletelocalsnapshots`) | définitif, admin (macOS les gère et en recrée) | non | confirmation avec les dates ; sauvegardes Time Machine sur disque jamais touchées |
| Santé > Réparations | cache DNS, index Spotlight, autorisations | rien de vos fichiers n'est supprimé | — | manuelles seulement, admin |
| Barre des menus > « Vider la corbeille… » | — | ouvre « Vider la Corbeille » de Nettoyage (plus de vidage direct sans confirmation) | — | — |

## Confirmation (texte affiché)

Toute action de Nettoyage, Mon désordre, Cloud et Restes d'apps affiche avant de commencer, par exemple :

> **Nettoyer ?**
> À la Corbeille (récupérable) : 3 éléments, 1,2 Go
> Supprimés définitivement (caches et fichiers recréés seuls) : 41 éléments, 2,1 Go
> Mot de passe administrateur demandé pour les éléments système.
> · Caches de Google Chrome — 812 Mo
> · …

## Ce que zerOS ne supprime jamais

Vos documents, photos, musique, vidéos et projets sans votre choix explicite, et alors toujours à la Corbeille ; tout ce qui est en lecture
seule ou bloqué ; le disque de données ; un dossier qui contient un projet ; un dossier cloud jamais téléchargé ; les e-mails ; l'historique,
les cookies et mots de passe des navigateurs ; les conversations des apps d'IA ; les versions de documents ; les parties des apps (langues,
code Intel).

## Autotest `--selftest securite` (résultat du 9 novembre 2026, MacBook)

21 contrôles, 0 échec : règle sur groupes synthétiques ; 31 groupes réels / 683 éléments analysés : 0 suppression définitive hors
régénérables, 0 présélection hors régénérables ; « Corbeilles » hors du nettoyage ; versions de documents en analyse seule ; Mail, réglages
abîmés, lanceurs, comptes : Corbeille non cochés ; désinstallation d'une vraie app (lecture seule) : tout à la Corbeille, seuls caches et
états cochés ; commande administrateur = `mv -n` vers `~/.Trash`. Sur l'image disque : dossier contenant un projet refusé en bloc ; dossier de
caches vidé élément par élément (projet et dossier en lecture seule laissés) ; fichier mis dans la Corbeille du disque et retrouvé ;
« supprimer » imposé ramené à la Corbeille ; confirmation avec nombre, taille, façon, éléments ; projet et lecture seule refusés ;
corbeille du disque listée à part avec les éléments mis par zerOS depuis 24 h ; vidage : verrouillé et dossier contenant un verrouillé
laissés et signalés ; vidage refusé hors corbeille.
