# Lapwiz Setup

Installateur graphique PowerShell + **winget** pour réinstaller rapidement tes outils après un nettoyage système (ex. infection `Win64/Expiro`).

## Prérequis anti-Expiro (obligatoire)

Expiro infecte les fichiers **`.exe`** (append PE, casse souvent la signature Authenticode — voir analyses [ESET](https://www.welivesecurity.com/2013/07/30/versatile-and-infectious-win64expiro-is-a-cross-platform-file-infector/), [Seqrite/Quick Heal](https://www.seqrite.com/blog/expiro-old-virus-resurfaces-to-cast-new-challenge/), [Trend EXPIRO.AA](https://www.trendmicro.com/vinfo/us/threat-encyclopedia/malware/virus.win64.expiro.aa)).

1. Nettoie hors Windows si besoin (LiveDisk) + onglets Guide Expiro / Scripts / KVRT.
2. Scan Defender / MBAM / KVRT sur **tous** les disques et USB.
3. Si le virus revient : **réinstalle Windows** (média créé sur PC sain) — ne restaure **aucun** ancien `.exe`.
4. Ensuite seulement : Lapwiz Setup → winget.

### Est-ce que Lapwiz est « protégé » contre Expiro ?

| Point | Réalité |
|---|---|
| Pas d’`.exe` custom Lapwiz | **Oui** — surface Expiro plus faible (scripts `.ps1` / `.xaml` / `.cmd`) |
| Manifeste `RELEASE-SHA256.txt` | **Oui** — détecte si le package release a été modifié |
| Signature Authenticode | **Non** sans certificat code-signing OEM |
| Protection des apps winget sur PC encore infecté | **Non** — les nouveaux `.exe` peuvent être réinfectés |

Conclusion : Lapwiz **détecte le tampering de son propre package** ; il **ne remplace pas** un OS propre ni un antivirus. Rebuild depuis une machine saine.

## Prérequis techniques

- Windows 10 (1809+) ou Windows 11
- PowerShell 5.1+
- [winget](https://aka.ms/getwinget) (App Installer)
- Droits administrateur (UAC auto)

## Lancement

Double-clic **`Lancer-LapwizSetup.cmd`**, accepter l’UAC.

Build release :

```text
Build-LapwizRelease.cmd
```

Sortie : `release\LapwizSetup-YYYYMMDD_HHMMSS\` + `.zip` + `RELEASE-SHA256.txt`.

## Onglets

| Onglet | Rôle |
|---|---|
| Installateur | winget, msiexec, PATH ADB |
| SynapticRemover | nettoyage inclus |
| Guide Expiro | parcours WinTips + Trend |
| Scripts | automatisations (audit, KVRT, MBAM, Defender…) |
| KVRT | guide + captures officielles Kaspersky |

## Packages

Voir `packages.json` (catalogue officiel : WinRAR, 7-Zip, Notepad++, Node, Python, JDK, Android Studio, ADB, .NET 8…).

### Ajouter des apps (catalogue perso)

Dans l’onglet **Installateur**, barre **Ajouter une application** :
1. Taper un nom (ex. `Cursor`) ou un ID winget (ex. `Anysphere.Cursor`)
2. **Rechercher** → choisir un résultat
3. Choisir la catégorie → **Ajouter**

Persistance : `%LOCALAPPDATA%\LapwizSetup\packages.user.json` (hors package — ne casse pas l’intégrité SHA256).

- Badge **Perso** sur les tuiles ajoutées
- **Retirer** : cliquer la tuile perso puis le bouton Retirer
- Reset : supprimer `packages.user.json`

## Fichiers clés

| Fichier | Rôle |
|---|---|
| `Start-LapwizSetup.ps1` | Entrée + UI |
| `Install-Engine.ps1` | winget / msiexec / ADB |
| `Guides\Lapwiz-Integrity.ps1` | SHA256 |
| `Build-LapwizRelease.ps1` | Build release |
| `RELEASE-SHA256.txt` | Présent dans les builds release |
