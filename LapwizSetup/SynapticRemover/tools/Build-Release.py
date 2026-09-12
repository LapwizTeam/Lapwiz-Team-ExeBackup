# -*- coding: utf-8 -*-
"""Build release: un dossier autonome par script de lancement."""
from __future__ import annotations

import shutil
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
RELEASE = ROOT / "release"
STAMP = datetime.now().strftime("%Y%m%d_%H%M%S")
OUT = RELEASE / f"SynapticRemover-{STAMP}"

SHARED_FILES = [
    "Moteur-Nettoyage.ps1",
    "Actions-Scan.ps1",
    "Gestion-Rapports.ps1",
    "Traductions.ps1",
    "Interface-UI.ps1",
    "Choix-Langue.ps1",
    "Journal-Arabe.ps1",
    "Selectionner-Langue.bat",
    "messages.json",
]

PACKS = [
    {
        "folder": "01-Nettoyage-Automatique",
        "bat": "Nettoyage-Automatique.bat",
        "title_fr": "Nettoyage automatique (tous volumes, sans redémarrage)",
        "title_en": "Automatic cleanup (all volumes, no reboot)",
        "title_ar": "تنظيف تلقائي (جميع الأقراص، بدون إعادة تشغيل)",
    },
    {
        "folder": "02-Nettoyage-Interactif",
        "bat": "Nettoyage-Interactif.bat",
        "title_fr": "Mode interactif (choix scan / redémarrage)",
        "title_en": "Interactive mode (scan / reboot choices)",
        "title_ar": "الوضع التفاعلي (اختيار الفحص / إعادة التشغيل)",
    },
]


def copy_tools(dest_tools: Path) -> None:
    dest_tools.mkdir(parents=True, exist_ok=True)
    for name in SHARED_FILES:
        src = TOOLS / name
        if src.exists():
            shutil.copy2(src, dest_tools / name)
        else:
            print(f"  WARN missing: {name}")

    recover = TOOLS / "synaptics-recover"
    if recover.exists():
        dst = dest_tools / "synaptics-recover"
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(
            recover,
            dst,
            ignore=shutil.ignore_patterns("*.md", ".git"),
        )


def write_readme(pack_dir: Path, pack: dict) -> None:
    bat = pack["bat"]
    text = f"""================================================================================
SynapticRemover - README / LIRE-MOI / اقرأني
================================================================================

--- Français ---
{pack['title_fr']}

Utilisation
1. Clic droit sur {bat}
2. Exécuter en tant qu'administrateur
3. Choisir la langue (FR / EN / AR)
4. Attendre la fin du nettoyage

Contenu
- {bat}   : lanceur
- tools\\  : moteur, traductions, synaptics-recover
- reports\\: rapports (max 5 conservés)

Notes
- Nécessite Windows 10/11
- Pour l'arabe, une fenêtre journal s'affiche (Segoe UI)
- Ne pas déplacer le .bat hors de ce dossier

--- English ---
{pack['title_en']}

How to use
1. Right-click {bat}
2. Run as administrator
3. Choose language (FR / EN / AR)
4. Wait until cleanup finishes

Contents
- {bat}   : launcher
- tools\\  : engine, translations, synaptics-recover
- reports\\: reports (max 5 kept)

Notes
- Requires Windows 10/11
- For Arabic, a journal window is shown (Segoe UI)
- Do not move the .bat file out of this folder

--- العربية ---
{pack['title_ar']}

طريقة الاستخدام
1. انقر بزر الماوس الأيمن على {bat}
2. تشغيل كمسؤول
3. اختر اللغة (FR / EN / AR)
4. انتظر حتى ينتهي التنظيف

المحتويات
- {bat}   : المشغّل
- tools\\  : المحرك، الترجمات، synaptics-recover
- reports\\: التقارير (حد أقصى 5)

ملاحظات
- يتطلب Windows 10/11
- للعربية تظهر نافذة سجل (Segoe UI)
- لا تنقل ملف .bat خارج هذا المجلد
"""
    (pack_dir / "LIRE-MOI.txt").write_text(text, encoding="utf-8-sig")


def ensure_synaptics_recover() -> None:
    exe64 = TOOLS / "synaptics-recover" / "x86_64" / "synaptics-recover.exe"
    exe86 = TOOLS / "synaptics-recover" / "x86" / "synaptics-recover.exe"
    if exe64.exists() or exe86.exists():
        print("synaptics-recover: OK")
        return

    import tempfile
    import urllib.request
    import zipfile

    url = "https://github.com/SineStriker/synaptics-recover/releases/download/0.0.1.6/synaptics-recover-0.0.1.6.zip"
    print("Downloading synaptics-recover...")
    dest = TOOLS / "synaptics-recover"
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)

    with tempfile.TemporaryDirectory() as tmp:
        zpath = Path(tmp) / "sr.zip"
        urllib.request.urlretrieve(url, zpath)
        with zipfile.ZipFile(zpath, "r") as zf:
            zf.extractall(dest)
    print("synaptics-recover: downloaded")


def main() -> None:
    ensure_synaptics_recover()
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)

    print(f"Building: {OUT}")

    for pack in PACKS:
        pack_dir = OUT / pack["folder"]
        pack_dir.mkdir(parents=True)
        print(f" - {pack['folder']}")

        src_bat = ROOT / pack["bat"]
        if not src_bat.exists():
            raise SystemExit(f"Missing launcher: {src_bat}")
        shutil.copy2(src_bat, pack_dir / pack["bat"])

        copy_tools(pack_dir / "tools")
        (pack_dir / "reports").mkdir(exist_ok=True)
        (pack_dir / "reports" / ".gitkeep").write_text("", encoding="utf-8")
        write_readme(pack_dir, pack)

    index = """================================================================================
SynapticRemover - README / LIRE-MOI / اقرأني
================================================================================

--- Français ---
Dossiers
--------
01-Nettoyage-Automatique
    Nettoyage complet automatique (recommandé)

02-Nettoyage-Interactif
    Mode manuel (choix des options)

Chaque dossier est autonome : copiez uniquement celui dont vous avez besoin.
Exécutez toujours le .bat en tant qu'Administrateur.

--- English ---
Folders
-------
01-Nettoyage-Automatique
    Full automatic cleanup (recommended)

02-Nettoyage-Interactif
    Manual mode (choose options)

Each folder is standalone: copy only the one you need.
Always run the .bat as Administrator.

--- العربية ---
المجلدات
--------
01-Nettoyage-Automatique
    تنظيف كامل تلقائي (موصى به)

02-Nettoyage-Interactif
    الوضع اليدوي (اختيار الخيارات)

كل مجلد مستقل: انسخ فقط المجلد الذي تحتاجه.
شغّل ملف .bat دائماً كمسؤول.
"""
    (OUT / "LIRE-MOI.txt").write_text(index, encoding="utf-8-sig")

    latest = RELEASE / "SynapticRemover-latest"
    if latest.exists():
        shutil.rmtree(latest)
    shutil.copytree(OUT, latest)

    zip_base = RELEASE / f"SynapticRemover-{STAMP}"
    zip_path = shutil.make_archive(str(zip_base), "zip", root_dir=OUT)
    print(f"ZIP: {zip_path}")
    print(f"DIR: {OUT}")
    print(f"LATEST: {latest}")


if __name__ == "__main__":
    main()
