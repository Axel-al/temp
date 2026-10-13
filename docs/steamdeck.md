# Artemis 0.6.7 : archive portable pour SteamOS

Ce build part du commit officiel `afe2de7f2b24a2f6161f5672e8aa38450fa793ef`, correspondant à `0.6.7-dev.20250831.0017`. Il produit une application Linux **x86_64 native** et son environnement applicatif dans `artemis-steamos-x86_64.tar.gz`. L'installation reste dans le dossier personnel ; aucun `sudo`, changement de partition système ou remplacement de bibliothèque SteamOS n'est nécessaire.

Une exécution GitHub Actions réussie valide la compilation, le contenu et le lancement minimal du package. **Elle ne valide pas une session de streaming sur Steam Deck.** SteamOS 3.8.28 est la version de référence communiquée par l'utilisateur, pas une version à laquelle le programme est lié.

## Base de compatibilité

La cible minimale envisagée est **SteamOS 3.5 sur Steam Deck**, sous réserve des essais matériels décrits plus bas. La barrière ABI du package est **GLIBC ≤ 2.35** pour chaque ELF embarqué. Les bibliothèques GLIBC restent celles du système hôte. Le [dépôt historique SteamOS `core-3.5`](https://steamdeck-packages.steamos.cloud/archlinux-mirror/core-3.5/os/x86_64/) contient GLIBC 2.37 et les bibliothèques GCC 13.1.1 : cela justifie cette base ABI, mais ne démontre pas à lui seul la compatibilité complète du système graphique ou audio.

La compilation utilise Ubuntu 22.04. Compiler directement sur Ubuntu 24.04 pourrait introduire des symboles GLIBC 2.39 et exclure cette base. Les versions récentes de FFmpeg et SDL sont donc construites sur l'environnement plus ancien. Les dépendances copiées et les plugins sont également examinés : vérifier uniquement l'exécutable principal serait insuffisant.

Qt 6.8 prend en charge Ubuntu 22.04 x86_64 et sa documentation indique GLIBC 2.28 pour les binaires Linux x86_64. La remarque Ubuntu 24.04/GLIBC 2.39 de la même page concerne les binaires Linux **ARM**. Les exigences réelles des fichiers Qt 6.8.3 déployés restent contrôlées par le workflow. Voir les [plateformes Qt 6.8](https://doc.qt.io/qt-6.8/supported-platforms.html).

La portabilité repose sur les ABI Linux et les bibliothèques graphiques publiques du système. Elle ne constitue pas une garantie pour toute future mise à jour de SteamOS. Une modification incompatible des pilotes, de Wayland, de Gamescope ou des interfaces audio peut exiger une correction. Conserver une archive connue fonctionnelle et relancer le diagnostic après une mise à jour problématique.

## Dépendances et fonctions

| Composant | Version choisie | Rôle |
| --- | --- | --- |
| Artemis | 0.6.7, base `afe2de7` | Client et protocole de streaming existants |
| Qt | 6.8.3 | Interface, QML, réseau et plugins |
| FFmpeg | 6.1.4 | Décodage vidéo, conversion et interfaces matérielles |
| SDL2 | 2.32.10 | Fenêtres, audio et manettes |
| SDL2_ttf | 2.24.0 | Texte des surimpressions |
| libplacebo | 7.349.0 | Rendu Vulkan, couleurs et HDR |
| Opus et bibliothèques annexes | Versions consignées dans le manifeste | Audio et dépendances transitives |

Le code de référence possède déjà des adaptations aux API FFmpeg 6 et 7. Le passage à FFmpeg 6.1.4 ne nécessite donc pas de désactiver les fonctions de streaming ni de conserver `libavcodec.so.58`. Les bibliothèques FFmpeg de cette archive proviennent de sa propre compilation ; une version FFmpeg installée par SteamOS n'est pas utilisée pour les remplacer.

La chaîne prioritaire sur GPU AMD est **décodage VA-API puis rendu Vulkan/libplacebo**, avec les autres chemins du code conservés. Les vérifications de compilation exigent la présence de VA-API, DRM, EGL, X11, Wayland et libplacebo. L'absence d'une dépendance obligatoire doit faire échouer le build, au lieu de retirer silencieusement le moteur correspondant.

| Fonction | Ce que la compilation peut établir | À confirmer sur le Steam Deck |
| --- | --- | --- |
| H.264 et HEVC | Décodeurs et VA-API disponibles | Décodage matériel effectif, stabilité et latence |
| AV1 | Chemins de décodage présents | Support réel du matériel et du pilote ; ne pas déduire ce support de la présence du codec |
| Vulkan/libplacebo | Moteur compilé et bibliothèque présente | Présentation, import des surfaces VA-API, absence de corruption |
| HDR | Chemins 10 bits, métadonnées et rendu conservés | Écran compatible, hôte, Gamescope/compositeur, couleurs et luminosité |
| Desktop/Gaming Mode | Plugins Qt X11 et Wayland inclus | Lancement, changement de mode, plein écran et reprise |
| Manettes | SDL2 et code de gestion existant | Steam Input, manette intégrée, vibrations, touches et axes |
| Audio | SDL2 et Opus présents | Sortie audio, coupures, synchronisation A/V |
| Apollo/Sunshine | Protocole et code de connexion conservés | Appairage, audio/vidéo, commandes et reconnexion aux deux hôtes |

## Contenu et frontière avec le système hôte

Après extraction :

```text
artemis-steamos-x86_64/
  artemis                 lanceur
  bin/artemis             exécutable ELF
  lib/                    bibliothèques applicatives et transitives
  plugins/                plugins Qt, dont X11/Wayland, TLS et images
  qml/                    modules QML nécessaires à l'interface
  translations/
  share/dependency-manifest.json
  share/licenses/
  install.sh
  uninstall.sh
  diagnose.sh
  README.md
```

Le package inclut notamment Qt, FFmpeg, SDL2, SDL2_ttf, Opus, libplacebo, OpenSSL et les dépendances applicatives nécessaires. Le manifeste fait foi pour la liste exacte, leurs versions et leur origine. La collecte suit les dépendances ELF transitives et traite séparément les plugins Qt chargés à l'exécution.

GLIBC, le chargeur ELF, les pilotes Mesa/RADV/VA-API et les composants graphiques devant suivre ces pilotes restent fournis par SteamOS. Le package n'impose aucun fichier ICD Vulkan, pilote Radeon ni chemin Mesa. Les bibliothèques faisant partie de cette frontière hôte sont consignées dans le manifeste ; un contrôle de liens réussi sur Ubuntu ne prouve pas leur présence sur chaque autre distribution.

Les chemins ELF relatifs à `$ORIGIN` permettent de déplacer le dossier complet. Le lanceur définit les chemins de bibliothèques et de plugins pour son processus, sans les ajouter à la configuration du compte. Utiliser **`./artemis`**, et non `./bin/artemis`, pour bénéficier de cet environnement. Les bibliothèques restent partagées et remplaçables dans le dossier de l'application.

## Télécharger et installer

Dans le fork GitHub, ouvrir **Actions → Steam Deck portable**, choisir une exécution terminée avec succès et télécharger l'artifact `artemis-steamos-x86_64`. Son ZIP contient l'archive binaire, les sources correspondantes et `SHA256SUMS` : en extraire d'abord `artemis-steamos-x86_64.tar.gz`. Aucune GitHub Release n'est créée par ce workflow.

Sur le Steam Deck en Desktop Mode, dans Konsole, depuis le dossier contenant l'archive :

```bash
tar -xzf artemis-steamos-x86_64.tar.gz
cd artemis-steamos-x86_64
./diagnose.sh > artemis-diagnostics.txt 2>&1
./artemis
```

Le lancement direct permet de tester sans installer. Pour créer les raccourcis utilisateur :

```bash
./install.sh
"$HOME/.local/bin/artemis-steamos"
```

L'installateur copie le package dans `~/.local/opt/artemis-steamos`, crée `~/.local/bin/artemis-steamos` et une entrée **Artemis (SteamOS)** dans le menu. Les chemins ne dépendent pas du nom de compte `deck`. Une nouvelle exécution de l'installateur avec une nouvelle archive remplace la version active ; les anciennes copies restent disponibles pour les processus déjà en cours et sont retirées lors de la désinstallation. Les réglages d'Artemis ne sont pas effacés.

Pour Gaming Mode, ajouter le lanceur `~/.local/bin/artemis-steamos` à Steam en tant que jeu non Steam depuis Desktop Mode. Si le sélecteur masque les fichiers cachés, saisir son chemin complet. Laisser désactivée l'option imposant Proton : il s'agit d'un programme Linux natif. Passer ensuite en Gaming Mode et lancer cette entrée.

## Essai matériel recommandé

1. Noter la version SteamOS, le modèle du Deck, les versions Apollo/Sunshine, le mode Desktop/Gaming et le type d'écran.
2. En Desktop Mode, lancer l'application, vérifier l'interface, ajouter l'hôte et effectuer l'appairage habituel.
3. Tester d'abord H.264 en SDR à 1280×800 et 60 images/s, puis HEVC. Dans les réglages, demander le décodage matériel et vérifier le décodeur réellement retenu dans les journaux ou statistiques. Une image fluide ne suffit pas à prouver l'usage de VA-API.
4. Vérifier image, son, synchronisation A/V, commandes de la manette, vibrations, changement de résolution et arrêt/reprise d'une session.
5. Refaire les mêmes essais en Gaming Mode, avec le profil Steam Input attendu. Comparer une session suffisamment longue pour détecter coupures ou dérive A/V.
6. Tester HDR uniquement avec un écran et une chaîne hôte compatibles ; comparer le rendu SDR/HDR et contrôler les niveaux de noir, les hautes lumières et les couleurs. Le LCD interne d'un Deck LCD ne devient pas HDR grâce au logiciel.
7. Tester AV1 si le matériel annonce le décodage correspondant. Un repli logiciel ne valide pas le décodage matériel AV1.
8. Tester Apollo et Sunshine séparément si les deux sont utilisés, puis reconnexion et reprise après veille.

Le chemin Vulkan Video natif est distinct de VA-API avec rendu Vulkan. L'audit du commit de référence a relevé des callbacks de verrouillage de files Vulkan sans effet et une initialisation incomplète des files de décodage dans `plvk.cpp`. Ce sont des limites **préexistantes**, non corrigées par le packaging ; ce chemin n'est pas déclaré validé. Le contournement préprocesseur de `AV_PIX_FMT_P410` du même fichier rend aussi le mode 10 bits 4:4:4 suspect. Aucune correction fonctionnelle de ces points n'est présentée comme éprouvée sans essais GPU.

## Diagnostics et dépannage

Après installation :

```bash
"$HOME/.local/opt/artemis-steamos/diagnose.sh" > "$HOME/artemis-diagnostics.txt" 2>&1
```

Le diagnostic peut être exécuté avant le premier lancement et après une mise à jour SteamOS. La commande ci-dessus écrit le rapport dans `~/artemis-diagnostics.txt`. Il décrit le système, les dépendances visibles, les exigences ABI et les outils GPU disponibles, sans installer de paquet. Un outil absent, tel que `vainfo`, `vulkaninfo` ou `lddtree`, n'autorise pas à conclure que le matériel est incompatible. Transmettre le rapport avec le codec, le mode d'affichage et l'étape précise qui échoue.

Pour obtenir la trace Qt lors d'un problème d'interface :

```bash
QT_DEBUG_PLUGINS=1 "$HOME/.local/bin/artemis-steamos" 2>&1 | tee "$HOME/artemis-launch.log"
```

Pour comparer avec X11 dans une session disposant de XWayland :

```bash
QT_QPA_PLATFORM=xcb "$HOME/.local/bin/artemis-steamos"
```

Ce choix porte sur l'interface Qt ; il ne force ni un pilote GPU ni un codec. Avant de partager des journaux, vérifier les noms de machines, adresses réseau et chemins personnels qu'ils peuvent contenir. Aucun diagnostic ne demande un token GitHub.

Une erreur `GLIBC_... not found` doit être traitée comme une incompatibilité du package ou du système cible. Ne pas remplacer GLIBC sur SteamOS. Une erreur `libavcodec.so.58` en lançant cette nouvelle archive indique vraisemblablement l'utilisation de l'ancien binaire ou d'un autre raccourci : vérifier le chemin lancé.

## Désinstallation

Fermer Artemis, puis exécuter :

```bash
"$HOME/.local/opt/artemis-steamos/uninstall.sh"
```

Le script retire les fichiers installés, les anciennes copies du package et ses raccourcis utilisateur. Les préférences et informations d'appairage sont conservées. Supprimer séparément le raccourci de la bibliothèque Steam si celui-ci a été ajouté manuellement. Le dossier extrait de l'archive peut également être supprimé lorsqu'il n'est plus utilisé.

## Workflow et critères de validation

Le workflow indépendant est `.github/workflows/steamdeck-build.yml`. Il ne remplace pas les pipelines Windows et macOS. Il publie des artifacts, avec des permissions minimales, et possède un déclencheur manuel `workflow_dispatch`. GitHub exige que ce déclencheur soit enregistré sur la branche par défaut pour l'utiliser normalement ; l'intégration de la pull request nécessite l'accord du propriétaire.

Une fois le workflow disponible sur la branche par défaut :

```bash
gh workflow run steamdeck-build.yml --repo Axel-al/temp
gh run list --repo Axel-al/temp --workflow steamdeck-build.yml
gh run watch NUMERO_D_EXECUTION --repo Axel-al/temp
gh run download NUMERO_D_EXECUTION --repo Axel-al/temp
```

Les validations prévues contrôlent : les moteurs sélectionnés par qmake, les codecs FFmpeg, les fichiers requis, l'architecture x86_64, les entrées ELF `NEEDED`, `RPATH`/`RUNPATH`, la limite GLIBC, la résolution des dépendances et les plugins Qt. Le lancement minimal utilise un affichage virtuel et ne contacte aucun hôte de streaming. Il ne remplace pas les essais de connexion, d'accélération, de HDR, d'audio ou de manette. Consulter les rapports de l'exécution précise téléchargée pour ses résultats effectifs.

Les versions applicatives sont fixées. Le manifeste enregistre aussi les versions exactes des paquets Ubuntu copiés, ainsi que les sommes SHA-256 des ELF. La mise à jour des paquets de sécurité du système de compilation peut changer un build ultérieur ; le package n'est donc pas annoncé reproductible bit à bit uniquement parce que ses versions principales sont fixées.

## Licences et sources correspondantes

Artemis est fourni sous GPL v3. Qt comporte des composants LGPL v3/GPL v3 et des notices tierces ; FFmpeg et libplacebo utilisent notamment LGPL 2.1 ou ultérieure ; SDL2 et SDL2_ttf utilisent la licence zlib. Les licences exactes de chaque fichier ou sous-composant et les notices accompagnant le package prévalent sur ce résumé. Voir les [licences Qt](https://doc.qt.io/qt-6.8/licensing.html) et les [conditions de redistribution FFmpeg](https://ffmpeg.org/legal.html).

Les bibliothèques partagées sont conservées, sans activation de composants FFmpeg `nonfree`. Les notices, copyrights et le manifeste sont livrés avec l'archive. Les sources correspondantes et scripts de construction sont livrés dans l'artifact de sources de la même exécution : conserver cet artifact avec le binaire en cas de redistribution, notamment les archives des dépendances, les sources Artemis et de ses sous-modules, les sources Qt correspondantes et les sources des paquets redistribués.

Un simple lien vers la page d'accueil d'une bibliothèque ou une copie de sa licence ne remplace pas la mise à disposition de ses sources correspondantes. Toute modification ultérieure d'une dépendance doit être enregistrée dans les sources et instructions de construction associées. La rétention des artifacts GitHub est limitée ; une redistribution durable nécessite de conserver et rendre accessibles ensemble binaires et sources.
