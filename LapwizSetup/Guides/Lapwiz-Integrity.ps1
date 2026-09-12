#Requires -Version 5.1
<#
.SYNOPSIS
    Integrite Lapwiz Setup — manifeste SHA256 (detection tampering / infection fichier).
.NOTES
    Expiro cible surtout les .EXE PE (ESET, Seqrite/Quick Heal, Trend).
    Lapwiz = .ps1/.xaml/.cmd : surface plus faible, MAIS un PC infecte peut
    toujours corrompre des EXE telecharges (winget) apres coup.
    Ce module detecte la modification des fichiers du package Lapwiz.
#>
Set-StrictMode -Version Latest

function script:Get-LapwizIntegrityRoots {
    param([string]$ScriptRoot)
    $roots = @(
        'Start-LapwizSetup.ps1'
        'Install-Engine.ps1'
        'MainWindow.xaml'
        'App.xaml'
        'packages.json'
        'Lancer-LapwizSetup.cmd'
        'Guides\Expiro-Trend-Remediation.ps1'
        'Guides\Expiro-Guide-UI.ps1'
        'Guides\Scripts-Auto-UI.ps1'
        'Guides\Kvrt-Guide-UI.ps1'
        'Guides\Adb-Repair-UI.ps1'
        'Guides\Adb-Repair-Engine.ps1'
        'Guides\Adb-Repair-Guide.txt'
        'Guides\Lapwiz-Dependencies.ps1'
        'Guides\Package-Catalog.ps1'
        'Guides\Package-Icons.ps1'
        'Guides\Lapwiz-I18n.ps1'
        'Guides\i18n\fr.json'
        'Guides\i18n\en.json'
        'Guides\i18n\ar.json'
        'Guides\Expiro-WinTips.txt'
        'Guides\Kvrt-Guide.txt'
        'Guides\expiro-images.json'
        'Guides\kvrt-images.json'
        'Guides\expiro-phases.json'
    )
    return $roots
}

function script:New-LapwizIntegrityManifest {
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [string]$OutFile = ''
    )
    if (-not $OutFile) {
        $OutFile = Join-Path $ScriptRoot 'RELEASE-SHA256.txt'
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add('# Lapwiz Setup integrity manifest (SHA256)')
    [void]$lines.Add("# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$lines.Add('# Format: HASH  relative/path')
    [void]$lines.Add('')

    $seen = @{}
    foreach ($rel in Get-LapwizIntegrityRoots -ScriptRoot $ScriptRoot) {
        $full = Join-Path $ScriptRoot $rel
        if (-not (Test-Path -LiteralPath $full)) {
            Write-Warning "Manifest: fichier manquant $rel"
            continue
        }
        $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
        $norm = $rel -replace '\\', '/'
        [void]$lines.Add("$hash  $norm")
        $seen[$norm.ToLowerInvariant()] = $true
    }

    # Images + scripts + exe/dll du package (synaptics-recover, etc.)
    $extraExt = @('.png', '.jpg', '.jpeg', '.webp', '.ico', '.exe', '.dll', '.cmd', '.bat', '.ps1', '.xaml', '.json', '.txt')
    $rootFull = [IO.Path]::GetFullPath($ScriptRoot).TrimEnd('\')
    Get-ChildItem -LiteralPath $ScriptRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -eq 'RELEASE-SHA256.txt') { return }
        if ($_.Name -eq 'LIRE-MOI-RELEASE.txt') { return }
        if ($extraExt -notcontains $_.Extension.ToLowerInvariant()) { return }
        # Ignorer uniquement un sous-dossier relatif "release\" (pas le chemin parent ...\release\LapwizSetup-xxx)
        $full = [IO.Path]::GetFullPath($_.FullName)
        $rel = $full.Substring($rootFull.Length).TrimStart('\')
        if ($rel -like 'release\*') { return }
        if ($rel -match '(?i)\\reports\\') { return }
        $norm = $rel -replace '\\', '/'
        $key = $norm.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return }
        $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
        [void]$lines.Add("$hash  $norm")
        $seen[$key] = $true
    }

    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllLines($OutFile, $lines.ToArray(), $utf8Bom)
    return $OutFile
}

function script:Test-LapwizIntegrity {
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [string]$ManifestPath = '',
        [switch]$ThrowOnFail
    )
    if (-not $ManifestPath) {
        $ManifestPath = Join-Path $ScriptRoot 'RELEASE-SHA256.txt'
    }
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return [pscustomobject]@{
            Ok       = $true
            Skipped  = $true
            Message  = 'Pas de RELEASE-SHA256.txt (mode dev) — verification ignoree.'
            Failures = @()
        }
    }

    $failures = [System.Collections.Generic.List[string]]::new()
    $checked = 0
    Get-Content -LiteralPath $ManifestPath -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { return }
        if ($line -notmatch '^([A-Fa-f0-9]{64})\s+(.+)$') { return }
        $expected = $Matches[1].ToUpperInvariant()
        $rel = ($Matches[2].Trim() -replace '/', '\')
        $full = Join-Path $ScriptRoot $rel
        $checked++
        if (-not (Test-Path -LiteralPath $full)) {
            [void]$failures.Add("MANQUANT: $rel")
            return
        }
        $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -ne $expected) {
            [void]$failures.Add("MODIFIE: $rel")
        }
    }

    $ok = ($failures.Count -eq 0)
    $msg = if ($ok) {
        "Integrite OK ($checked fichiers verifies)."
    }
    else {
        "ALERTE integrite : $($failures.Count) probleme(s). Package potentiellement altere (tampering / Expiro / copie incomplete).`n" + ($failures -join "`n")
    }

    if (-not $ok -and $ThrowOnFail) {
        throw $msg
    }

    return [pscustomobject]@{
        Ok       = $ok
        Skipped  = $false
        Message  = $msg
        Failures = @($failures)
        Checked  = $checked
    }
}
