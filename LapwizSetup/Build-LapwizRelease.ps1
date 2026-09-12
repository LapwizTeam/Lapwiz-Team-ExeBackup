#Requires -Version 5.1
<#
.SYNOPSIS
    Build release Lapwiz Setup : copie propre + manifeste SHA256.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Here = $PSScriptRoot
if (-not $Here) { $Here = Split-Path -Parent $MyInvocation.MyCommand.Path }

$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$OutRoot = Join-Path $Here 'release'
$Out = Join-Path $OutRoot "LapwizSetup-$Stamp"

Write-Host "=== Build Lapwiz Setup Release ===" -ForegroundColor Cyan
Write-Host "Source : $Here"
Write-Host "Sortie : $Out"

New-Item -ItemType Directory -Path $Out -Force | Out-Null

$excludeDirNames = @('release', '.git', '.vs', '__pycache__')
function Copy-LapwizTree {
    param([string]$Src, [string]$Dst)
    New-Item -ItemType Directory -Path $Dst -Force | Out-Null
    Get-ChildItem -LiteralPath $Src -Force | ForEach-Object {
        if ($_.PSIsContainer) {
            if ($excludeDirNames -contains $_.Name) { return }
            Copy-LapwizTree -Src $_.FullName -Dst (Join-Path $Dst $_.Name)
        }
        else {
            # Pas de reports runtime Synaptic dans la release
            if ($_.FullName -match '\\reports\\') { return }
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Dst $_.Name) -Force
        }
    }
}

Copy-LapwizTree -Src $Here -Dst $Out

# Integrite
$integrityPs1 = Join-Path $Out 'Guides\Lapwiz-Integrity.ps1'
if (-not (Test-Path -LiteralPath $integrityPs1)) {
    throw "Lapwiz-Integrity.ps1 manquant dans la copie."
}
. $integrityPs1
$manifest = New-LapwizIntegrityManifest -ScriptRoot $Out
Write-Host "Manifeste : $manifest"

# Verif immediate
$check = Test-LapwizIntegrity -ScriptRoot $Out -ManifestPath $manifest
if (-not $check.Ok) { throw $check.Message }
Write-Host $check.Message -ForegroundColor Green

# README release
$readme = @"
================================================================================
Lapwiz Setup — Release $Stamp
================================================================================

Lancement
  1. Sur un PC SAIN (ou apres LiveDisk / nettoyage Expiro)
  2. Double-clic Lancer-LapwizSetup.cmd → accepter UAC
  3. Au demarrage : verification SHA256 automatique (RELEASE-SHA256.txt)

Protection / limites (Expiro & file infectors)
  - Lapwiz est surtout des scripts (.ps1 / .xaml / .cmd), PAS un .exe custom.
  - Expiro infecte typiquement les PE .exe (append section, casse la signature).
    Sources : ESET Win64/Expiro, Seqrite/Quick Heal, Trend Virus.Win64.EXPIRO.AA
  - SHA256 detecte si CE package Lapwiz a ete modifie apres le build.
  - SHA256 NE protege PAS les EXE installes ensuite par winget sur un PC encore
    infecte : nettoie d'abord, sinon reinfection.
  - Pas de signature Authenticode sans certificat code-signing OEM.

Onglets
  Store | ADB Repair | Installateur | SynapticRemover | Guide Expiro | Scripts | KVRT

Fichier d'integrite
  RELEASE-SHA256.txt

================================================================================
"@
$utf8Bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText((Join-Path $Out 'LIRE-MOI-RELEASE.txt'), $readme, $utf8Bom)

# Zip
$zip = Join-Path $OutRoot "LapwizSetup-$Stamp.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($Out, $zip)
Write-Host "ZIP : $zip" -ForegroundColor Green

# Resume
$exeCount = @(Get-ChildItem -LiteralPath $Out -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue).Count
Write-Host ""
Write-Host "EXE dans la release : $exeCount (0 = ideal contre Expiro file-infector)" -ForegroundColor $(if ($exeCount -eq 0) { 'Green' } else { 'Yellow' })
Write-Host "DONE"
Write-Host $Out
Write-Host $zip
