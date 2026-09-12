# Lapwiz-Team-ExeBackup

Outils Lapwiz pour **nettoyer** un PC (Expiro / malwares) puis **réinstaller** et **réparer** (winget, ADB/scrcpy).

## Démarrage rapide

1. Télécharger la [dernière release](https://github.com/LapwizTeam/Lapwiz-Team-ExeBackup/releases/latest)
2. Extraire le ZIP → double-clic **`Lancer-LapwizSetup.cmd`** (accepter UAC)
3. Suivre le **[Guide utilisateur complet (avec images)](docs/GUIDE-UTILISATEUR.md)**

## Contenu du dépôt

| Dossier / fichier | Rôle |
|---|---|
| [`LapwizSetup/`](LapwizSetup/) | Application PowerShell + WPF (Store, ADB Repair, Expiro, Scripts, KVRT, Synaptic) |
| [`docs/GUIDE-UTILISATEUR.md`](docs/GUIDE-UTILISATEUR.md) | Parcours illustré de A à Z |
| [`LICENSE`](LICENSE) | AGPL-3.0 |

## Ordre recommandé après infection

```text
1. LiveDisk / Safe Mode / KVRT / MBAM   (nettoyer)
2. Guide Expiro + Scripts               (audit, Startup, services)
3. ADB Repair                           (remplacer adb/scrcpy corrompus)
4. Store / Installateur                 (winget — apps propres)
```

## Build local

```text
cd LapwizSetup
Build-LapwizRelease.cmd
```

Sortie : `LapwizSetup/release/LapwizSetup-YYYYMMDD_HHMMSS.zip` + `RELEASE-SHA256.txt`.

## Licence

AGPL-3.0 — voir [`LICENSE`](LICENSE).
