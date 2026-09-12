#Requires -Version 5.1
<#
.SYNOPSIS
    Moteur ADB Repair — scan adb/scrcpy, telechargement officiel, quarantaine, remplacement SHA-256.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function script:Get-AdbRepairRoot {
    $dir = Join-Path $env:LOCALAPPDATA 'LapwizSetup'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function script:Get-AdbCleanToolsDir {
    $dir = Join-Path (Get-AdbRepairRoot) 'clean-tools'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function script:Get-AdbQuarantineRoot {
    $dir = Join-Path (Get-AdbRepairRoot) 'adb-quarantine'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function script:Get-FileSha256Hex {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $h = Get-FileHash -LiteralPath $Path -Algorithm SHA256
    return $h.Hash.ToLowerInvariant()
}

function script:Write-AdbRepairEngineLog {
    param(
        [string]$Message,
        [scriptblock]$OnLog,
        [ValidateSet('Info', 'Success', 'Warn', 'Error')]
        [string]$Level = 'Info'
    )
    if ($OnLog) { & $OnLog $Message $Level }
    else { Write-Host "[$Level] $Message" }
}

function script:Get-AdbCoreFileNames {
    <# Binaires ADB critiques (PATH / detection rapide). #>
    return @(
        'adb.exe',
        'AdbWinApi.dll',
        'AdbWinUsbApi.dll',
        'fastboot.exe'
    )
}

function script:Get-PlatformToolsFallbackNames {
    <# Pack Google platform-tools complet (appris depuis Desktop\platform-tools). #>
    return @(
        'adb.exe',
        'AdbWinApi.dll',
        'AdbWinUsbApi.dll',
        'etc1tool.exe',
        'fastboot.exe',
        'hprof-conv.exe',
        'libwinpthread-1.dll',
        'make_f2fs.exe',
        'make_f2fs_casefold.exe',
        'mke2fs.conf',
        'mke2fs.exe',
        'NOTICE.txt',
        'source.properties',
        'sqlite3.exe'
    )
}

function script:Test-IsAdbCoreFileName {
    param([string]$Name)
    foreach ($c in (Get-AdbCoreFileNames)) {
        if ($Name -ieq $c) { return $true }
    }
    return $false
}

function script:Get-DefaultPlatformToolsDir {
    $d = Join-Path (Get-AdbCleanToolsDir) 'platform-tools'
    if (Test-Path -LiteralPath (Join-Path $d 'adb.exe')) { return $d }
    return $null
}

function script:Get-DefaultScrcpyDir {
    $d = Join-Path (Get-AdbCleanToolsDir) 'scrcpy'
    if (Test-Path -LiteralPath (Join-Path $d 'scrcpy.exe')) { return $d }
    return $null
}

function script:Get-AdbPackManifestPath {
    param([ValidateSet('platform-tools', 'scrcpy')][string]$Kind)
    return (Join-Path (Get-AdbCleanToolsDir) ("learned-{0}.json" -f $Kind))
}

function script:Save-AdbPackManifest {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][ValidateSet('platform-tools', 'scrcpy')][string]$Kind
    )
    $files = @(Get-ChildItem -LiteralPath $SourceDir -File -Force -ErrorAction SilentlyContinue)
    $entries = foreach ($f in $files) {
        [pscustomobject]@{
            name   = $f.Name
            length = [int64]$f.Length
            sha256 = (Get-FileSha256Hex -Path $f.FullName)
        }
    }
    $obj = [pscustomobject]@{
        kind       = $Kind
        learnedAt  = (Get-Date).ToString('o')
        sourceDir  = $SourceDir
        fileCount  = @($entries).Count
        files      = @($entries)
    }
    $path = Get-AdbPackManifestPath -Kind $Kind
    ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function script:Get-PlatformToolsCleanFileMap {
    param([string]$PlatformToolsDir)
    $map = @{}
    if (-not $PlatformToolsDir -or -not (Test-Path -LiteralPath $PlatformToolsDir)) {
        $PlatformToolsDir = Get-DefaultPlatformToolsDir
    }
    if (-not $PlatformToolsDir -or -not (Test-Path -LiteralPath $PlatformToolsDir)) { return $map }
    Get-ChildItem -LiteralPath $PlatformToolsDir -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $map[$_.Name.ToLowerInvariant()] = $_.FullName
    }
    return $map
}

function script:Test-IsPlatformToolsPackFileName {
    param(
        [string]$Name,
        [string]$PlatformToolsDir = $null
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $clean = Get-PlatformToolsCleanFileMap -PlatformToolsDir $PlatformToolsDir
    if ($clean.Count -gt 0) {
        return $clean.ContainsKey($Name.ToLowerInvariant())
    }
    foreach ($n in (Get-PlatformToolsFallbackNames)) {
        if ($Name -ieq $n) { return $true }
    }
    return $false
}

function script:Test-LooksLikeScrcpyDir {
    <# Dossier scrcpy : scrcpy.exe ou serveur / assets typiques. #>
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir) -or -not (Test-Path -LiteralPath $Dir)) { return $false }
    if (Test-Path -LiteralPath (Join-Path $Dir 'scrcpy.exe')) { return $true }
    $server = @(Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'scrcpy-server*' } |
            Select-Object -First 1)
    if ($server.Count -gt 0) { return $true }
    if ((Test-Path -LiteralPath (Join-Path $Dir 'disconnected.png')) -and
        (Test-Path -LiteralPath (Join-Path $Dir 'SDL3.dll') -or (Test-Path -LiteralPath (Join-Path $Dir 'SDL2.dll')))) {
        return $true
    }
    return $false
}

function script:Test-LooksLikePlatformToolsDir {
    <#
      Dossier ADB style Google platform-tools (pas scrcpy).
      Detecte aussi les dossiers incomplets (seulement AdbWin*.dll) pour sync pack complet.
    #>
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir) -or -not (Test-Path -LiteralPath $Dir)) { return $false }
    if (Test-LooksLikeScrcpyDir -Dir $Dir) { return $false }

    $hasAdbExe = Test-Path -LiteralPath (Join-Path $Dir 'adb.exe')
    $hasAdbApi = Test-Path -LiteralPath (Join-Path $Dir 'AdbWinApi.dll')
    if (-not $hasAdbExe -and -not $hasAdbApi) { return $false }

    $leaf = [IO.Path]::GetFileName($Dir)
    if ($leaf -match '(?i)^platform-tools') { return $true }
    if (Test-Path -LiteralPath (Join-Path $Dir 'source.properties')) { return $true }
    if (Test-Path -LiteralPath (Join-Path $Dir 'NOTICE.txt')) { return $true }
    if (Test-Path -LiteralPath (Join-Path $Dir 'fastboot.exe')) { return $true }
    if (Test-Path -LiteralPath (Join-Path $Dir 'mke2fs.exe')) { return $true }
    if (Test-Path -LiteralPath (Join-Path $Dir 'mke2fs.conf')) { return $true }
    # Dossier adb / outils (Coolray\adb, ATCUpgradeTool, etc.) : sync pack Google entier
    if ($hasAdbExe -or $hasAdbApi) { return $true }
    return $false
}

function script:Test-ScrcpyCompanionName {
    <# Noms / motifs typiques du pack scrcpy (hors ADB Google). #>
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if (Test-IsAdbCoreFileName -Name $Name) { return $false }
    $n = $Name.ToLowerInvariant()
    if ($n -eq 'scrcpy.exe') { return $true }
    if ($n -eq 'scrcpy-server' -or $n -like 'scrcpy-server*') { return $true }
    if ($n -eq 'scrcpy-noconsole.vbs') { return $true }
    if ($n -eq 'license.txt') { return $true }
    # notice.txt = platform-tools (Google), pas scrcpy
    if ($n -eq 'disconnected.png' -or $n -eq 'scrcpy.png' -or $n -eq 'icon.png') { return $true }
    if ($n -like 'sdl*.dll') { return $true }
    if ($n -like 'avcodec*.dll') { return $true }
    if ($n -like 'avformat*.dll') { return $true }
    if ($n -like 'avutil*.dll') { return $true }
    if ($n -like 'swresample*.dll') { return $true }
    if ($n -like 'swscale*.dll') { return $true }
    if ($n -like 'libusb*.dll') { return $true }
    if ($n -eq 'open_a_terminal_here.bat') { return $true }
    return $false
}

function script:Get-ScrcpyCleanFileMap {
    param([string]$ScrcpyDir)
    $map = @{}
    if (-not $ScrcpyDir -or -not (Test-Path -LiteralPath $ScrcpyDir)) {
        $ScrcpyDir = Get-DefaultScrcpyDir
    }
    if (-not $ScrcpyDir -or -not (Test-Path -LiteralPath $ScrcpyDir)) { return $map }
    # Liste exacte du ZIP officiel Genymobile (sauf ADB → source Google)
    Get-ChildItem -LiteralPath $ScrcpyDir -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if (Test-IsAdbCoreFileName -Name $_.Name) { return }
        $map[$_.Name.ToLowerInvariant()] = $_.FullName
    }
    return $map
}

function script:Test-IsScrcpyRepairFileName {
    param(
        [string]$Name,
        [string]$ScrcpyDir = $null
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if (Test-IsAdbCoreFileName -Name $Name) { return $false }
    $clean = Get-ScrcpyCleanFileMap -ScrcpyDir $ScrcpyDir
    if ($clean.Count -gt 0) {
        if ($clean.ContainsKey($Name.ToLowerInvariant())) { return $true }
        if ($Name -like 'scrcpy-server*') {
            foreach ($k in $clean.Keys) {
                if ($k -like 'scrcpy-server*') { return $true }
            }
        }
        return $false
    }
    return (Test-ScrcpyCompanionName -Name $Name)
}

function script:Test-IsAllowedRepairFileName {
    <#
      Liste blanche stricte : pack platform-tools appris + pack scrcpy appris.
      Jamais les autres fichiers/dossiers a cote.
    #>
    param(
        [string]$Name,
        [string]$ScrcpyDir = $null,
        [string]$PlatformToolsDir = $null
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if (Test-IsPlatformToolsPackFileName -Name $Name -PlatformToolsDir $PlatformToolsDir) { return $true }
    if (Test-IsAdbCoreFileName -Name $Name) { return $true }
    return (Test-IsScrcpyRepairFileName -Name $Name -ScrcpyDir $ScrcpyDir)
}

function script:Test-AdbFolderPackConsistency {
    <#
      Verifie qu'un dossier aligne le pack appris :
      - tous les fichiers du pack presents + SHA-256 identiques
      - pas de fichier obsolete du pack (autre version)
      - les fichiers hors pack (metier) sont ignores (Kept)
    #>
    param(
        [Parameter(Mandatory)][string]$TargetDir,
        [Parameter(Mandatory)][ValidateSet('platform-tools', 'scrcpy')][string]$Kind,
        [Parameter(Mandatory)][string]$PlatformToolsDir,
        [string]$ScrcpyDir = $null,
        [scriptblock]$OnLog
    )
    $issues = [System.Collections.Generic.List[object]]::new()
    $kept = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        [void]$issues.Add([pscustomobject]@{
                Severity = 'FAIL'
                Code     = 'DIR_MISSING'
                Name     = ''
                Path     = $TargetDir
                Detail   = 'Dossier introuvable apres reparation'
            })
        return [pscustomobject]@{ Ok = $false; Issues = @($issues); KeptExtra = @() }
    }

    $existing = @(Get-ChildItem -LiteralPath $TargetDir -File -Force -ErrorAction SilentlyContinue)

    if ($Kind -eq 'platform-tools') {
        $cleanMap = Get-PlatformToolsCleanFileMap -PlatformToolsDir $PlatformToolsDir
        foreach ($key in @($cleanMap.Keys)) {
            $src = [string]$cleanMap[$key]
            $name = [IO.Path]::GetFileName($src)
            $dest = Join-Path $TargetDir $name
            if (-not (Test-Path -LiteralPath $dest)) {
                [void]$issues.Add([pscustomobject]@{
                        Severity = 'FAIL'
                        Code     = 'MISSING'
                        Name     = $name
                        Path     = $dest
                        Detail   = 'Fichier pack Google absent'
                    })
                continue
            }
            $hLive = Get-FileSha256Hex -Path $dest
            $hClean = Get-FileSha256Hex -Path $src
            if (-not $hLive -or -not $hClean -or ($hLive -ine $hClean)) {
                [void]$issues.Add([pscustomobject]@{
                        Severity = 'FAIL'
                        Code     = 'HASH'
                        Name     = $name
                        Path     = $dest
                        Detail   = 'SHA-256 different du pack Google'
                    })
            }
        }
        foreach ($f in $existing) {
            $key = $f.Name.ToLowerInvariant()
            if ($cleanMap.ContainsKey($key)) { continue }
            if (Test-IsPlatformToolsPackFileName -Name $f.Name -PlatformToolsDir $PlatformToolsDir) {
                [void]$issues.Add([pscustomobject]@{
                        Severity = 'WARN'
                        Code     = 'OBSOLETE'
                        Name     = $f.Name
                        Path     = $f.FullName
                        Detail   = 'Fichier style platform-tools hors pack appris'
                    })
            }
            else {
                [void]$kept.Add($f.Name)
            }
        }
    }
    else {
        $cleanMap = Get-ScrcpyCleanFileMap -ScrcpyDir $ScrcpyDir
        foreach ($key in @($cleanMap.Keys)) {
            $src = [string]$cleanMap[$key]
            $name = [IO.Path]::GetFileName($src)
            $dest = Join-Path $TargetDir $name
            if (-not (Test-Path -LiteralPath $dest)) {
                [void]$issues.Add([pscustomobject]@{
                        Severity = 'FAIL'
                        Code     = 'MISSING'
                        Name     = $name
                        Path     = $dest
                        Detail   = 'Fichier pack scrcpy absent'
                    })
                continue
            }
            $hLive = Get-FileSha256Hex -Path $dest
            $hClean = Get-FileSha256Hex -Path $src
            if (-not $hLive -or -not $hClean -or ($hLive -ine $hClean)) {
                [void]$issues.Add([pscustomobject]@{
                        Severity = 'FAIL'
                        Code     = 'HASH'
                        Name     = $name
                        Path     = $dest
                        Detail   = 'SHA-256 different du pack scrcpy'
                    })
            }
        }
        # Trio ADB Google obligatoire a cote de scrcpy
        foreach ($adbName in @('adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll')) {
            $src = Join-Path $PlatformToolsDir $adbName
            $dest = Join-Path $TargetDir $adbName
            if (-not (Test-Path -LiteralPath $src)) { continue }
            if (-not (Test-Path -LiteralPath $dest)) {
                [void]$issues.Add([pscustomobject]@{
                        Severity = 'FAIL'
                        Code     = 'MISSING_ADB'
                        Name     = $adbName
                        Path     = $dest
                        Detail   = 'ADB Google manquant a cote de scrcpy'
                    })
                continue
            }
            $hLive = Get-FileSha256Hex -Path $dest
            $hClean = Get-FileSha256Hex -Path $src
            if (-not $hLive -or -not $hClean -or ($hLive -ine $hClean)) {
                [void]$issues.Add([pscustomobject]@{
                        Severity = 'FAIL'
                        Code     = 'HASH_ADB'
                        Name     = $adbName
                        Path     = $dest
                        Detail   = 'ADB different du pack Google (attendu)'
                    })
            }
        }
        foreach ($f in $existing) {
            $key = $f.Name.ToLowerInvariant()
            if (Test-IsAdbCoreFileName -Name $f.Name) { continue }
            if ($cleanMap.ContainsKey($key)) { continue }
            if (Test-ScrcpyCompanionName -Name $f.Name) {
                [void]$issues.Add([pscustomobject]@{
                        Severity = 'WARN'
                        Code     = 'OBSOLETE'
                        Name     = $f.Name
                        Path     = $f.FullName
                        Detail   = 'Ancien compagnon scrcpy hors pack appris'
                    })
            }
            else {
                [void]$kept.Add($f.Name)
            }
        }
    }

    $failCount = @($issues | Where-Object { $_.Severity -eq 'FAIL' }).Count
    $ok = ($failCount -eq 0)
    if ($ok) {
        Write-AdbRepairEngineLog -Message (
            ("Verification OK ($Kind) : $TargetDir — extras conserves={0}" -f $kept.Count)
        ) -OnLog $OnLog -Level Success
    }
    else {
        Write-AdbRepairEngineLog -Message (
            ("Verification INCOHERENTE ($Kind) : $TargetDir — {0} probleme(s)" -f $issues.Count)
        ) -OnLog $OnLog -Level Warn
        foreach ($i in $issues) {
            Write-AdbRepairEngineLog -Message (
                ("  [{0}] {1} {2} — {3}" -f $i.Severity, $i.Code, $i.Name, $i.Detail)
            ) -OnLog $OnLog -Level Warn
        }
    }
    return [pscustomobject]@{
        Ok        = $ok
        Kind      = $Kind
        Directory = $TargetDir
        Issues    = @($issues)
        KeptExtra = @($kept)
    }
}

function script:Import-AdbReferencePack {
    <#
      Copie un dossier de reference (Desktop) vers clean-tools et enregistre le manifeste appris.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][ValidateSet('platform-tools', 'scrcpy')][string]$Kind,
        [scriptblock]$OnLog
    )
    if (-not (Test-Path -LiteralPath $SourceDir)) {
        throw "Dossier reference introuvable : $SourceDir"
    }
    $destName = if ($Kind -eq 'platform-tools') { 'platform-tools' } else { 'scrcpy' }
    $dest = Join-Path (Get-AdbCleanToolsDir) $destName
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $copied = 0
    Get-ChildItem -LiteralPath $SourceDir -File -Force -ErrorAction Stop | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $dest $_.Name) -Force
        $copied++
    }
    $manifest = Save-AdbPackManifest -SourceDir $dest -Kind $Kind
    Write-AdbRepairEngineLog -Message ("Pack $Kind appris : $copied fichier(s) → $dest") -OnLog $OnLog -Level Success
    Write-AdbRepairEngineLog -Message ("Manifeste : $manifest") -OnLog $OnLog -Level Info
    return [pscustomobject]@{
        Kind         = $Kind
        SourceDir    = $SourceDir
        DestDir      = $dest
        FileCount    = $copied
        ManifestPath = $manifest
    }
}

function script:Import-AdbReferencePacks {
    param(
        [string]$PlatformToolsSource = '',
        [string]$ScrcpySource = '',
        [scriptblock]$OnLog
    )
    if ([string]::IsNullOrWhiteSpace($PlatformToolsSource)) {
        $PlatformToolsSource = Join-Path ([Environment]::GetFolderPath('Desktop')) 'platform-tools'
    }
    if ([string]::IsNullOrWhiteSpace($ScrcpySource)) {
        $desk = [Environment]::GetFolderPath('Desktop')
        $cand = @(
            (Join-Path $desk 'scrcpy-win64-v4.1'),
            (Join-Path $desk 'scrcpy'),
            (Join-Path $desk 'scrcpy-win64')
        )
        foreach ($c in $cand) {
            if (Test-Path -LiteralPath (Join-Path $c 'scrcpy.exe')) {
                $ScrcpySource = $c
                break
            }
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    if ($PlatformToolsSource -and (Test-Path -LiteralPath $PlatformToolsSource)) {
        [void]$results.Add((Import-AdbReferencePack -SourceDir $PlatformToolsSource -Kind 'platform-tools' -OnLog $OnLog))
    }
    else {
        Write-AdbRepairEngineLog -Message ("platform-tools reference absente : $PlatformToolsSource") -OnLog $OnLog -Level Warn
    }
    if ($ScrcpySource -and (Test-Path -LiteralPath $ScrcpySource)) {
        [void]$results.Add((Import-AdbReferencePack -SourceDir $ScrcpySource -Kind 'scrcpy' -OnLog $OnLog))
    }
    else {
        Write-AdbRepairEngineLog -Message ("scrcpy reference absente : $ScrcpySource") -OnLog $OnLog -Level Warn
    }

    $pt = Get-DefaultPlatformToolsDir
    $sc = Get-DefaultScrcpyDir
    if (-not $pt -or -not $sc) {
        throw 'Apprentissage incomplet : platform-tools et/ou scrcpy manquants.'
    }
    return [pscustomobject]@{
        PlatformToolsDir = $pt
        ScrcpyDir        = $sc
        Learned          = @($results)
    }
}

function script:Test-AdbRepairExcludedPath {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return $true }
    $p = $FullPath.ToLowerInvariant()
    $blocked = @(
        '\windows\winsxs\',
        '\windows\servicing\',
        '\windows\installer\',
        '\system volume information',
        '\$recycle.bin\',
        '\windows\system32\driverstore\',
        '\programdata\microsoft\windows defender\',
        '\lapwizsetup\clean-tools\',
        '\lapwizsetup\adb-quarantine\'
    )
    foreach ($b in $blocked) {
        if ($p.Contains($b)) { return $true }
    }
    return $false
}

function script:Get-AdbCommonScanRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    $add = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        try {
            if (Test-Path -LiteralPath $Path) {
                $full = [IO.Path]::GetFullPath($Path)
                if (-not ($roots | Where-Object { $_ -ieq $full })) {
                    [void]$roots.Add($full)
                }
            }
        }
        catch { }
    }

    & $add (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools')
    & $add (Join-Path $env:LOCALAPPDATA 'Lapwiz\platform-tools')
    if ($env:ANDROID_HOME) { & $add (Join-Path $env:ANDROID_HOME 'platform-tools') }
    if ($env:ANDROID_SDK_ROOT) { & $add (Join-Path $env:ANDROID_SDK_ROOT 'platform-tools') }

    $wingetRoots = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
        (Join-Path $env:ProgramFiles 'WinGet\Packages'),
        (Join-Path ${env:ProgramFiles(x86)} 'WinGet\Packages')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($wr in $wingetRoots) {
        Get-ChildItem -LiteralPath $wr -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'PlatformTools|Android|scrcpy|Genymobile' } |
            ForEach-Object { & $add $_.FullName }
    }

    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $pf) { continue }
        Get-ChildItem -LiteralPath $pf -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'scrcpy|android|platform-tools' } |
            ForEach-Object { & $add $_.FullName }
    }

    & $add ([Environment]::GetFolderPath('Desktop'))
    & $add (Join-Path $env:USERPROFILE 'Downloads')
    & $add (Join-Path $env:USERPROFILE 'Documents')

    try {
        $whereOut = & where.exe adb.exe 2>$null
        foreach ($line in @($whereOut)) {
            if ($line -and (Test-Path -LiteralPath $line)) {
                & $add (Split-Path -Parent $line)
            }
        }
    }
    catch { }

    return @($roots)
}

function script:New-AdbHitObject {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Kind = 'adb',
        [hashtable]$CleanHashMap = $null
    )
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $hash = Get-FileSha256Hex -Path $item.FullName
    $nameKey = $item.Name.ToLowerInvariant()
    $status = 'Unknown'
    $cleanHash = $null
    if ($CleanHashMap -and $CleanHashMap.ContainsKey($nameKey)) {
        $cleanHash = [string]$CleanHashMap[$nameKey]
        if ($hash -and $cleanHash -and ($hash -ieq $cleanHash)) { $status = 'Match' }
        else { $status = 'Differ' }
    }
    elseif ($item.Extension -ieq '.exe') {
        $status = 'Differ'
    }

    return [pscustomobject]@{
        Path       = $item.FullName
        Name       = $item.Name
        Directory  = $item.DirectoryName
        Length     = [long]$item.Length
        Hash       = $hash
        CleanHash  = $cleanHash
        Kind       = $Kind
        Status     = $status
        Selected   = ($status -ne 'Match')
    }
}

function script:Write-AdbRepairProgress {
    param(
        [hashtable]$ProgressBox,
        [string]$Phase = 'work',
        [int]$Current = 0,
        [int]$Total = 0,
        [int]$FilesSeen = 0,
        [string]$Message = ''
    )
    if (-not $ProgressBox) { return }
    try {
        $ProgressBox['Phase'] = $Phase
        $ProgressBox['Current'] = [int]$Current
        $ProgressBox['Total'] = [int]$Total
        $ProgressBox['FilesSeen'] = [int]$FilesSeen
        $ProgressBox['Message'] = [string]$Message
        $ProgressBox['Tick'] = [DateTime]::UtcNow.Ticks
        if (-not $ProgressBox.ContainsKey('StartedUtc') -or -not $ProgressBox['StartedUtc']) {
            $ProgressBox['StartedUtc'] = [DateTime]::UtcNow
        }
    }
    catch { }
}

function script:Find-AdbScrcpyInDirectory {
    param(
        [Parameter(Mandatory)][string]$Root,
        [hashtable]$CleanHashMap = $null,
        [scriptblock]$OnLog,
        [scriptblock]$OnHit,
        [hashtable]$ProgressBox = $null,
        [switch]$Recurse,
        [string]$PlatformToolsDir = $null,
        [string]$ScrcpyDir = $null
    )
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    if (Test-AdbRepairExcludedPath -FullPath $Root) { return @() }

    $hits = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $filesSeen = 0

    try {
        Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'enum' -Current 0 -Total 0 -FilesSeen 0 -Message ("Enumeration : $Root")
        $option = if ($Recurse) {
            [System.IO.SearchOption]::AllDirectories
        }
        else {
            [System.IO.SearchOption]::TopDirectoryOnly
        }
        $enum = $null
        try {
            $enum = [System.IO.Directory]::EnumerateFiles($Root, '*', $option)
        }
        catch {
            # Fallback Get-ChildItem si EnumerateFiles refuse
            if ($Recurse) {
                $enum = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            }
            else {
                $enum = @(Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            }
        }

        foreach ($path in $enum) {
            $filesSeen++
            if (($filesSeen % 250) -eq 0) {
                Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'enum' -Current $filesSeen -Total 0 `
                    -FilesSeen $filesSeen -Message $path
            }
            try {
                if (Test-AdbRepairExcludedPath -FullPath $path) { continue }
                $fi = New-Object System.IO.FileInfo $path
                if ($fi.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { continue }
                [void]$files.Add($fi)
            }
            catch { }
        }
    }
    catch {
        Write-AdbRepairEngineLog -Message ("Scan erreur $Root : $_") -OnLog $OnLog -Level Warn
        return @()
    }

    Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'analyze' -Current 0 -Total $files.Count `
        -FilesSeen $filesSeen -Message ("Analyse de {0} fichier(s)…" -f $files.Count)

    $scrcpyDirs = @{}
    $ptDirs = @{}
    $i = 0
    foreach ($f in $files) {
        $i++
        if (($i % 400) -eq 0 -or $i -eq $files.Count) {
            Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'analyze' -Current $i -Total $files.Count `
                -FilesSeen $filesSeen -Message $f.DirectoryName
        }
        if ($f.Name -ieq 'scrcpy.exe') {
            $scrcpyDirs[$f.DirectoryName] = $true
        }
    }
    $dirsToProbe = @($files | ForEach-Object { $_.DirectoryName } | Select-Object -Unique)
    foreach ($d in $dirsToProbe) {
        if ($scrcpyDirs.ContainsKey($d)) { continue }
        if (Test-LooksLikePlatformToolsDir -Dir $d) {
            $ptDirs[$d] = $true
        }
    }

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $files) {
        $full = $f.FullName
        if ($seen.ContainsKey($full.ToLowerInvariant())) { continue }

        $kind = $null
        if ($ptDirs.ContainsKey($f.DirectoryName) -and (Test-IsPlatformToolsPackFileName -Name $f.Name -PlatformToolsDir $PlatformToolsDir)) {
            $kind = if ($f.Extension -ieq '.dll') { 'dll' } else { 'adb' }
        }
        elseif (Test-IsAdbCoreFileName -Name $f.Name) {
            $kind = if ($f.Extension -ieq '.dll') { 'dll' } else { 'adb' }
        }
        elseif ($scrcpyDirs.ContainsKey($f.DirectoryName) -and (
                (Test-ScrcpyCompanionName -Name $f.Name) -or
                (Test-IsScrcpyRepairFileName -Name $f.Name -ScrcpyDir $ScrcpyDir)
            )) {
            $kind = if ($f.Name -ieq 'scrcpy.exe') { 'scrcpy' } elseif ($f.Extension -ieq '.dll') { 'dll' } else { 'scrcpy' }
        }
        elseif ($f.Name -ieq 'scrcpy.exe' -or ($f.Name -like 'scrcpy-server*')) {
            $kind = 'scrcpy'
        }

        if (-not $kind) { continue }
        $seen[$full.ToLowerInvariant()] = $true
        [void]$candidates.Add([pscustomobject]@{ Path = $full; Kind = $kind; Name = $f.Name })
    }

    $hashTotal = $candidates.Count
    $hashIdx = 0
    foreach ($c in $candidates) {
        $hashIdx++
        Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'hash' -Current $hashIdx -Total $hashTotal `
            -FilesSeen $filesSeen -Message $c.Path
        try {
            $hit = New-AdbHitObject -Path $c.Path -Kind $c.Kind -CleanHashMap $CleanHashMap
            [void]$hits.Add($hit)
            if ($OnHit) { & $OnHit $hit }
        }
        catch {
            Write-AdbRepairEngineLog -Message ("Ignore $($c.Path) : $_") -OnLog $OnLog -Level Warn
        }
    }

    Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'hash' -Current $hashTotal -Total ([Math]::Max(1, $hashTotal)) `
        -FilesSeen $filesSeen -Message ("Scan termine ({0} hits)" -f $hits.Count)
    return @($hits)
}

function script:Scan-AdbScrcpyRoots {
    param(
        [Parameter(Mandatory)][string[]]$Roots,
        [hashtable]$CleanHashMap = $null,
        [scriptblock]$OnLog,
        [scriptblock]$OnHit,
        [hashtable]$ProgressBox = $null,
        [switch]$Recurse,
        [string]$PlatformToolsDir = $null,
        [string]$ScrcpyDir = $null
    )
    $all = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $rootList = @($Roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $ri = 0
    foreach ($root in $rootList) {
        $ri++
        Write-AdbRepairEngineLog -Message ("Scan : $root") -OnLog $OnLog -Level Info
        Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'root' -Current $ri -Total $rootList.Count `
            -Message ("Dossier $ri / $($rootList.Count) : $root")
        $batch = Find-AdbScrcpyInDirectory -Root $root -CleanHashMap $CleanHashMap -OnLog $OnLog -OnHit $OnHit `
            -ProgressBox $ProgressBox -Recurse:$Recurse -PlatformToolsDir $PlatformToolsDir -ScrcpyDir $ScrcpyDir
        foreach ($h in $batch) {
            $k = [string]$h.Path
            if ($seen.ContainsKey($k.ToLowerInvariant())) { continue }
            $seen[$k.ToLowerInvariant()] = $true
            [void]$all.Add($h)
        }
    }
    Write-AdbRepairEngineLog -Message ("Terminé : {0} fichier(s) trouvé(s)." -f $all.Count) -OnLog $OnLog -Level Success
    Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'done' -Current 1 -Total 1 -Message 'Scan termine'
    return @($all)
}

function script:Download-FileHttp {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutPath,
        [scriptblock]$OnLog
    )
    $dir = Split-Path -Parent $OutPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Write-AdbRepairEngineLog -Message ("Telechargement : $Url") -OnLog $OnLog -Level Info
    # WebClient synchrone — pas de callback PS async (GetContextFromTLS)
    $wc = New-Object System.Net.WebClient
    try {
        $wc.Headers.Add('User-Agent', 'LapwizSetup-AdbRepair/1.0')
        $wc.DownloadFile($Url, $OutPath)
    }
    finally {
        $wc.Dispose()
    }
    if (-not (Test-Path -LiteralPath $OutPath)) {
        throw "Telechargement invalide : $OutPath"
    }
    $min = if ($OutPath -match '(?i)SHA256SUMS') { 32 } else { 1024 }
    if ((Get-Item -LiteralPath $OutPath).Length -lt $min) {
        throw "Telechargement invalide (trop petit) : $OutPath"
    }
    Write-AdbRepairEngineLog -Message ("OK : $OutPath ({0:N0} octets)" -f (Get-Item -LiteralPath $OutPath).Length) -OnLog $OnLog -Level Success
}

function script:Expand-ZipToDir {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$DestDir
    )
    if (Test-Path -LiteralPath $DestDir) {
        Remove-Item -LiteralPath $DestDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $DestDir)
}

function script:Find-ExtractedPlatformToolsDir {
    param([string]$ExtractRoot)
    $direct = Join-Path $ExtractRoot 'platform-tools'
    if (Test-Path -LiteralPath (Join-Path $direct 'adb.exe')) { return $direct }
    $found = Get-ChildItem -LiteralPath $ExtractRoot -Recurse -Filter 'adb.exe' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { return $found.DirectoryName }
    return $null
}

function script:Find-ExtractedScrcpyDir {
    param([string]$ExtractRoot)
    $found = Get-ChildItem -LiteralPath $ExtractRoot -Recurse -Filter 'scrcpy.exe' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { return $found.DirectoryName }
    return $null
}

function script:Get-ScrcpyLatestWin64Url {
    param([scriptblock]$OnLog)
    $api = 'https://api.github.com/repos/Genymobile/scrcpy/releases/latest'
    Write-AdbRepairEngineLog -Message 'GitHub API : scrcpy releases/latest' -OnLog $OnLog -Level Info
    $wc = New-Object System.Net.WebClient
    try {
        $wc.Headers.Add('User-Agent', 'LapwizSetup-AdbRepair/1.0')
        $wc.Headers.Add('Accept', 'application/vnd.github+json')
        $json = $wc.DownloadString($api)
    }
    finally {
        $wc.Dispose()
    }
    $rel = $json | ConvertFrom-Json
    $asset = @($rel.assets) | Where-Object { $_.name -match '^scrcpy-win64-.*\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw 'Asset scrcpy-win64 introuvable sur GitHub.' }
    $sums = @($rel.assets) | Where-Object { $_.name -ieq 'SHA256SUMS.txt' } | Select-Object -First 1
    return [pscustomobject]@{
        Tag     = [string]$rel.tag_name
        ZipUrl  = [string]$asset.browser_download_url
        ZipName = [string]$asset.name
        SumsUrl = if ($sums) { [string]$sums.browser_download_url } else { $null }
    }
}

function script:Ensure-AdbCleanPackages {
    param(
        [scriptblock]$OnLog,
        [switch]$ForceRefresh
    )
    $root = Get-AdbCleanToolsDir
    $ptZip = Join-Path $root 'platform-tools-latest-windows.zip'
    $ptExtract = Join-Path $root 'platform-tools-extract'
    $ptDir = Join-Path $root 'platform-tools'
    $scZip = Join-Path $root 'scrcpy-win64.zip'
    $scExtract = Join-Path $root 'scrcpy-extract'
    $scDir = Join-Path $root 'scrcpy'

    if ($ForceRefresh) {
        foreach ($p in @($ptZip, $ptExtract, $ptDir, $scZip, $scExtract, $scDir)) {
            if (Test-Path -LiteralPath $p) {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($ForceRefresh -or -not (Test-Path -LiteralPath (Join-Path $ptDir 'adb.exe'))) {
        Download-FileHttp -Url 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutPath $ptZip -OnLog $OnLog
        Expand-ZipToDir -ZipPath $ptZip -DestDir $ptExtract
        $found = Find-ExtractedPlatformToolsDir -ExtractRoot $ptExtract
        if (-not $found) { throw 'platform-tools/adb.exe introuvable dans le ZIP Google.' }
        if (Test-Path -LiteralPath $ptDir) { Remove-Item -LiteralPath $ptDir -Recurse -Force }
        Copy-Item -LiteralPath $found -Destination $ptDir -Recurse -Force
        Write-AdbRepairEngineLog -Message ("platform-tools pret : $ptDir") -OnLog $OnLog -Level Success
    }
    else {
        Write-AdbRepairEngineLog -Message 'Cache platform-tools OK.' -OnLog $OnLog -Level Info
    }

    if ($ForceRefresh -or -not (Test-Path -LiteralPath (Join-Path $scDir 'scrcpy.exe'))) {
        $meta = Get-ScrcpyLatestWin64Url -OnLog $OnLog
        Download-FileHttp -Url $meta.ZipUrl -OutPath $scZip -OnLog $OnLog
        if ($meta.SumsUrl) {
            $sumsPath = Join-Path $root 'SHA256SUMS.txt'
            try {
                Download-FileHttp -Url $meta.SumsUrl -OutPath $sumsPath -OnLog $OnLog
                $expected = $null
                Get-Content -LiteralPath $sumsPath -Encoding UTF8 | ForEach-Object {
                    if ($_ -match '(?i)^([a-f0-9]{64})\s+(\S+)\s*$') {
                        if ($Matches[2] -ieq $meta.ZipName) {
                            $expected = $Matches[1].ToLowerInvariant()
                        }
                    }
                }
                if ($expected) {
                    $got = Get-FileSha256Hex -Path $scZip
                    if ($got -ne $expected) {
                        throw "SHA256 scrcpy ZIP invalide (attendu $expected, obtenu $got)."
                    }
                    Write-AdbRepairEngineLog -Message 'SHA256 scrcpy ZIP verifie.' -OnLog $OnLog -Level Success
                }
            }
            catch {
                Write-AdbRepairEngineLog -Message ("Verification SHA256SUMS ignoree : $_") -OnLog $OnLog -Level Warn
            }
        }
        Expand-ZipToDir -ZipPath $scZip -DestDir $scExtract
        $foundSc = Find-ExtractedScrcpyDir -ExtractRoot $scExtract
        if (-not $foundSc) { throw 'scrcpy.exe introuvable dans le ZIP GitHub.' }
        if (Test-Path -LiteralPath $scDir) { Remove-Item -LiteralPath $scDir -Recurse -Force }
        Copy-Item -LiteralPath $foundSc -Destination $scDir -Recurse -Force
        Write-AdbRepairEngineLog -Message ("scrcpy pret ({0}) : $scDir" -f $meta.Tag) -OnLog $OnLog -Level Success
    }
    else {
        Write-AdbRepairEngineLog -Message 'Cache scrcpy OK.' -OnLog $OnLog -Level Info
    }

    try { $null = Save-AdbPackManifest -SourceDir $ptDir -Kind 'platform-tools' } catch { }
    try { $null = Save-AdbPackManifest -SourceDir $scDir -Kind 'scrcpy' } catch { }
    Write-AdbRepairEngineLog -Message (
        'Packs appris : {0} fichiers platform-tools, {1} fichiers scrcpy (hors ADB Google).' -f `
            (Get-PlatformToolsCleanFileMap -PlatformToolsDir $ptDir).Count, `
            (Get-ScrcpyCleanFileMap -ScrcpyDir $scDir).Count
    ) -OnLog $OnLog -Level Success

    return [pscustomobject]@{
        PlatformToolsDir = $ptDir
        ScrcpyDir        = $scDir
        Root             = $root
    }
}

function script:Build-AdbCleanHashMap {
    param(
        [Parameter(Mandatory)][string]$PlatformToolsDir,
        [Parameter(Mandatory)][string]$ScrcpyDir
    )
    $map = @{}
    $ptMap = Get-PlatformToolsCleanFileMap -PlatformToolsDir $PlatformToolsDir
    foreach ($key in @($ptMap.Keys)) {
        $map[$key] = Get-FileSha256Hex -Path ([string]$ptMap[$key])
    }
    if (Test-Path -LiteralPath $ScrcpyDir) {
        Get-ChildItem -LiteralPath $ScrcpyDir -File -ErrorAction SilentlyContinue | ForEach-Object {
            $key = $_.Name.ToLowerInvariant()
            if (Test-IsAdbCoreFileName -Name $_.Name) { return }
            # Ne pas ecraser un hash platform-tools (ex. NOTICE.txt homonyme)
            if ($map.ContainsKey($key)) { return }
            $map[$key] = Get-FileSha256Hex -Path $_.FullName
        }
    }
    return $map
}

function script:Resolve-CleanSourceFile {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$PlatformToolsDir,
        [Parameter(Mandatory)][string]$ScrcpyDir
    )
    $pt = Join-Path $PlatformToolsDir $FileName
    if (Test-Path -LiteralPath $pt) { return $pt }

    $ptMap = Get-PlatformToolsCleanFileMap -PlatformToolsDir $PlatformToolsDir
    $key = $FileName.ToLowerInvariant()
    if ($ptMap.ContainsKey($key)) { return [string]$ptMap[$key] }

    $sc = Join-Path $ScrcpyDir $FileName
    if (Test-Path -LiteralPath $sc) { return $sc }
    if ($FileName -like 'scrcpy-server*') {
        $cand = Get-ChildItem -LiteralPath $ScrcpyDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'scrcpy-server*' } | Select-Object -First 1
        if ($cand) { return $cand.FullName }
    }
    return $null
}

function script:Stop-AdbScrcpyProcesses {
    param([scriptblock]$OnLog)
    foreach ($name in @('adb', 'adbd', 'scrcpy')) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Write-AdbRepairEngineLog -Message ("Arret processus : {0} (PID {1})" -f $_.ProcessName, $_.Id) -OnLog $OnLog -Level Warn
                $_.Kill()
            }
            catch {
                Write-AdbRepairEngineLog -Message ("Impossible d'arreter {0} : $_" -f $name) -OnLog $OnLog -Level Warn
            }
        }
    }
    Start-Sleep -Milliseconds 500
}

function script:Remove-WhitelistedRepairFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$OnLog,
        [string]$ScrcpyDir = $null,
        [string]$PlatformToolsDir = $null
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        Write-AdbRepairEngineLog -Message ("Refuse suppression dossier : $Path") -OnLog $OnLog -Level Warn
        return $false
    }
    if (-not (Test-IsAllowedRepairFileName -Name $item.Name -ScrcpyDir $ScrcpyDir -PlatformToolsDir $PlatformToolsDir)) {
        if (-not (Test-ScrcpyCompanionName -Name $item.Name) -and -not (Test-IsPlatformToolsPackFileName -Name $item.Name -PlatformToolsDir $PlatformToolsDir)) {
            Write-AdbRepairEngineLog -Message ("Refuse suppression (hors liste ADB/scrcpy) : $Path") -OnLog $OnLog -Level Warn
            return $false
        }
    }
    for ($i = 1; $i -le 5; $i++) {
        try {
            [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal)
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $Path)) {
                Write-AdbRepairEngineLog -Message ("Supprime : $Path") -OnLog $OnLog -Level Warn
                return $true
            }
        }
        catch {
            Write-AdbRepairEngineLog -Message ("Suppression tentative $i : $_") -OnLog $OnLog -Level Warn
            Start-Sleep -Milliseconds (200 * $i)
            Stop-AdbScrcpyProcesses -OnLog $OnLog
        }
    }
    return -not (Test-Path -LiteralPath $Path)
}

function script:Backup-AndReplaceFileStrict {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$QuarantineRoot,
        [scriptblock]$OnLog,
        [string]$ScrcpyDir = $null,
        [string]$PlatformToolsDir = $null,
        [System.Collections.IList]$ActionLog = $null,
        [string]$PackHint = ''
    )
    $name = [IO.Path]::GetFileName($TargetPath)
    if (-not (Test-IsAllowedRepairFileName -Name $name -ScrcpyDir $ScrcpyDir -PlatformToolsDir $PlatformToolsDir) `
            -and -not (Test-ScrcpyCompanionName -Name $name) `
            -and -not (Test-IsPlatformToolsPackFileName -Name $name -PlatformToolsDir $PlatformToolsDir) `
            -and -not (Test-IsAdbCoreFileName -Name $name)) {
        throw "Fichier hors liste blanche : $TargetPath"
    }
    $rel = $TargetPath -replace '^[A-Za-z]:\\', ''
    $qDest = Join-Path $QuarantineRoot $rel
    $qParent = Split-Path -Parent $qDest
    if (-not (Test-Path -LiteralPath $qParent)) {
        New-Item -ItemType Directory -Path $qParent -Force | Out-Null
    }
    $hadBackup = $false
    if (Test-Path -LiteralPath $TargetPath) {
        Copy-Item -LiteralPath $TargetPath -Destination $qDest -Force -ErrorAction Stop
        Write-AdbRepairEngineLog -Message ("Backup : $qDest") -OnLog $OnLog -Level Info
        $hadBackup = $true
        if (-not (Remove-WhitelistedRepairFile -Path $TargetPath -OnLog $OnLog -ScrcpyDir $ScrcpyDir -PlatformToolsDir $PlatformToolsDir)) {
            throw "Impossible de supprimer l'ancien : $TargetPath"
        }
    }
    $destDir = Split-Path -Parent $TargetPath
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $SourcePath -Destination $TargetPath -Force -ErrorAction Stop
    $newHash = Get-FileSha256Hex -Path $TargetPath
    $expect = Get-FileSha256Hex -Path $SourcePath
    $hashOk = ($newHash -and $expect -and ($newHash -ieq $expect))
    if ($hashOk) {
        Write-AdbRepairEngineLog -Message ("OK nouveau : $TargetPath") -OnLog $OnLog -Level Success
    }
    else {
        Write-AdbRepairEngineLog -Message ("Copie hash inattendu : $TargetPath") -OnLog $OnLog -Level Warn
    }

    $pack = $PackHint
    if ([string]::IsNullOrWhiteSpace($pack)) {
        $srcDir = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($SourcePath))
        if ($srcDir -match '(?i)platform-tools') { $pack = 'platform-tools' }
        elseif ($srcDir -match '(?i)scrcpy') { $pack = 'scrcpy' }
        elseif (Test-IsAdbCoreFileName -Name $name) { $pack = 'platform-tools' }
        else { $pack = 'clean' }
    }

    if ($null -ne $ActionLog) {
        [void]$ActionLog.Add([pscustomobject]@{
                Status     = $(if ($hashOk) { 'OK' } else { 'WARN' })
                Action     = $(if ($hadBackup) { 'Remplace' } else { 'Installe' })
                Name       = $name
                Path       = $TargetPath
                Source     = $SourcePath
                Pack       = $pack
                Quarantine = $(if ($hadBackup) { $qDest } else { '' })
                Hash       = $(if ($newHash) { $newHash.ToUpperInvariant() } else { '' })
            })
    }
}

function script:Sync-PlatformToolsFolderStrict {
    <#
      Sync complet d'un dossier platform-tools :
      - Connait TOUS les fichiers du pack clean appris
      - Supprime (apres backup) chaque fichier du pack present / obsolete
      - Remplace / installe chaque fichier du pack clean
      - Ne touche pas aux fichiers hors pack
    #>
    param(
        [Parameter(Mandatory)][string]$TargetDir,
        [Parameter(Mandatory)][string]$PlatformToolsDir,
        [Parameter(Mandatory)][string]$QuarantineRoot,
        [scriptblock]$OnLog,
        [System.Collections.IList]$ActionLog = $null
    )
    if (-not (Test-Path -LiteralPath $TargetDir)) { return [pscustomobject]@{ Ok = 0; Fail = 0; Skip = 0 } }
    Write-AdbRepairEngineLog -Message ("=== platform-tools strict dossier : $TargetDir ===") -OnLog $OnLog -Level Info

    $cleanMap = Get-PlatformToolsCleanFileMap -PlatformToolsDir $PlatformToolsDir
    if ($cleanMap.Count -eq 0) {
        Write-AdbRepairEngineLog -Message 'Pack platform-tools clean vide — ignore sync.' -OnLog $OnLog -Level Warn
        return [pscustomobject]@{ Ok = 0; Fail = 0; Skip = 0 }
    }

    $ok = 0; $fail = 0; $skip = 0
    $existing = @(Get-ChildItem -LiteralPath $TargetDir -File -Force -ErrorAction SilentlyContinue)

    # 1) Purger fichiers du pack PT absents du clean (vieilles versions)
    foreach ($f in $existing) {
        if (-not (Test-IsPlatformToolsPackFileName -Name $f.Name -PlatformToolsDir $PlatformToolsDir)) { continue }
        $key = $f.Name.ToLowerInvariant()
        if ($cleanMap.ContainsKey($key)) { continue }
        try {
            $rel = $f.FullName -replace '^[A-Za-z]:\\', ''
            $qDest = Join-Path $QuarantineRoot $rel
            $qParent = Split-Path -Parent $qDest
            if (-not (Test-Path -LiteralPath $qParent)) {
                New-Item -ItemType Directory -Path $qParent -Force | Out-Null
            }
            Copy-Item -LiteralPath $f.FullName -Destination $qDest -Force
            if (Remove-WhitelistedRepairFile -Path $f.FullName -OnLog $OnLog -PlatformToolsDir $PlatformToolsDir) {
                Write-AdbRepairEngineLog -Message ("Ancien platform-tools obsolete : $($f.Name)") -OnLog $OnLog -Level Warn
                if ($null -ne $ActionLog) {
                    [void]$ActionLog.Add([pscustomobject]@{
                            Status     = 'OK'
                            Action     = 'Supprime'
                            Name       = $f.Name
                            Path       = $f.FullName
                            Source     = ''
                            Pack       = 'platform-tools'
                            Quarantine = $qDest
                            Hash       = ''
                        })
                }
                $ok++
            }
            else { $fail++ }
        }
        catch {
            Write-AdbRepairEngineLog -Message ("Echec purge $($f.Name) : $_") -OnLog $OnLog -Level Error
            $fail++
        }
    }

    # 2) Remplacer / installer TOUT le pack appris
    foreach ($key in @($cleanMap.Keys)) {
        $src = [string]$cleanMap[$key]
        $destName = [IO.Path]::GetFileName($src)
        $dest = Join-Path $TargetDir $destName
        try {
            Backup-AndReplaceFileStrict -TargetPath $dest -SourcePath $src -QuarantineRoot $QuarantineRoot `
                -OnLog $OnLog -PlatformToolsDir $PlatformToolsDir -ActionLog $ActionLog -PackHint 'platform-tools'
            $ok++
        }
        catch {
            Write-AdbRepairEngineLog -Message ("Echec PT $destName : $_") -OnLog $OnLog -Level Error
            if ($null -ne $ActionLog) {
                [void]$ActionLog.Add([pscustomobject]@{
                        Status     = 'FAIL'
                        Action     = 'Echec'
                        Name       = $destName
                        Path       = $dest
                        Source     = $src
                        Pack       = 'platform-tools'
                        Quarantine = ''
                        Hash       = ''
                    })
            }
            $fail++
        }
    }

    Write-AdbRepairEngineLog -Message ("platform-tools dossier termine OK=$ok Fail=$fail") -OnLog $OnLog -Level Success
    return [pscustomobject]@{ Ok = $ok; Fail = $fail; Skip = $skip }
}

function script:Sync-ScrcpyFolderStrict {
    <#
      Pour un dossier contenant scrcpy : meme regle stricte qu'ADB.
      - Ne touche que les fichiers scrcpy (liste pack officiel + anciens compagnons motifs)
      - Ne supprime aucun autre fichier/sous-dossier
      - Flux : backup → delete → copy pour chaque fichier du pack clean
      - Supprime les vieux DLL scrcpy (autre version) absents du pack neuf
    #>
    param(
        [Parameter(Mandatory)][string]$TargetDir,
        [Parameter(Mandatory)][string]$ScrcpyDir,
        [Parameter(Mandatory)][string]$PlatformToolsDir,
        [Parameter(Mandatory)][string]$QuarantineRoot,
        [scriptblock]$OnLog,
        [System.Collections.IList]$ActionLog = $null
    )
    if (-not (Test-Path -LiteralPath $TargetDir)) { return [pscustomobject]@{ Ok = 0; Fail = 0; Skip = 0 } }
    Write-AdbRepairEngineLog -Message ("=== scrcpy strict dossier : $TargetDir ===") -OnLog $OnLog -Level Info

    $cleanMap = Get-ScrcpyCleanFileMap -ScrcpyDir $ScrcpyDir
    if ($cleanMap.Count -eq 0) {
        Write-AdbRepairEngineLog -Message 'Pack scrcpy clean vide — ignore sync dossier.' -OnLog $OnLog -Level Warn
        return [pscustomobject]@{ Ok = 0; Fail = 0; Skip = 0 }
    }

    $ok = 0; $fail = 0; $skip = 0

    # 1) Supprimer anciens compagnons scrcpy (motifs) absents du pack neuf — fichier seul
    $existing = @(Get-ChildItem -LiteralPath $TargetDir -File -Force -ErrorAction SilentlyContinue)
    foreach ($f in $existing) {
        if (Test-IsAdbCoreFileName -Name $f.Name) { continue }
        $key = $f.Name.ToLowerInvariant()
        $isCompanion = Test-ScrcpyCompanionName -Name $f.Name
        $inClean = $cleanMap.ContainsKey($key)
        if (-not $isCompanion) { continue }
        if ($inClean) { continue } # sera remplace a l'etape 2
        try {
            $rel = $f.FullName -replace '^[A-Za-z]:\\', ''
            $qDest = Join-Path $QuarantineRoot $rel
            $qParent = Split-Path -Parent $qDest
            if (-not (Test-Path -LiteralPath $qParent)) {
                New-Item -ItemType Directory -Path $qParent -Force | Out-Null
            }
            Copy-Item -LiteralPath $f.FullName -Destination $qDest -Force
            if (Remove-WhitelistedRepairFile -Path $f.FullName -OnLog $OnLog -ScrcpyDir $ScrcpyDir -PlatformToolsDir $PlatformToolsDir) {
                Write-AdbRepairEngineLog -Message ("Ancien scrcpy obsolete supprime : $($f.Name)") -OnLog $OnLog -Level Warn
                if ($null -ne $ActionLog) {
                    [void]$ActionLog.Add([pscustomobject]@{
                            Status     = 'OK'
                            Action     = 'Supprime'
                            Name       = $f.Name
                            Path       = $f.FullName
                            Source     = ''
                            Pack       = 'scrcpy'
                            Quarantine = $qDest
                            Hash       = ''
                        })
                }
                $ok++
            }
            else { $fail++ }
        }
        catch {
            Write-AdbRepairEngineLog -Message ("Echec purge $($f.Name) : $_") -OnLog $OnLog -Level Error
            $fail++
        }
    }

    # 2) Installer / remplacer chaque fichier du pack officiel scrcpy
    foreach ($key in @($cleanMap.Keys)) {
        $src = [string]$cleanMap[$key]
        $destName = [IO.Path]::GetFileName($src)
        $dest = Join-Path $TargetDir $destName
        try {
            Backup-AndReplaceFileStrict -TargetPath $dest -SourcePath $src -QuarantineRoot $QuarantineRoot `
                -OnLog $OnLog -ScrcpyDir $ScrcpyDir -PlatformToolsDir $PlatformToolsDir `
                -ActionLog $ActionLog -PackHint 'scrcpy'
            $ok++
        }
        catch {
            Write-AdbRepairEngineLog -Message ("Echec scrcpy $destName : $_") -OnLog $OnLog -Level Error
            if ($null -ne $ActionLog) {
                [void]$ActionLog.Add([pscustomobject]@{
                        Status     = 'FAIL'
                        Action     = 'Echec'
                        Name       = $destName
                        Path       = $dest
                        Source     = $src
                        Pack       = 'scrcpy'
                        Quarantine = ''
                        Hash       = ''
                    })
            }
            $fail++
        }
    }

    # 3) ADB Google a cote de scrcpy : toujours poser le trio (adb.exe + AdbWin*.dll), meme si absent
    foreach ($adbName in @('adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll')) {
        $dest = Join-Path $TargetDir $adbName
        $src = Join-Path $PlatformToolsDir $adbName
        if (-not (Test-Path -LiteralPath $src)) { continue }
        try {
            Backup-AndReplaceFileStrict -TargetPath $dest -SourcePath $src -QuarantineRoot $QuarantineRoot `
                -OnLog $OnLog -ScrcpyDir $ScrcpyDir -PlatformToolsDir $PlatformToolsDir `
                -ActionLog $ActionLog -PackHint 'platform-tools'
            $ok++
        }
        catch {
            Write-AdbRepairEngineLog -Message ("Echec ADB dans scrcpy ($adbName) : $_") -OnLog $OnLog -Level Error
            if ($null -ne $ActionLog) {
                [void]$ActionLog.Add([pscustomobject]@{
                        Status     = 'FAIL'
                        Action     = 'Echec'
                        Name       = $adbName
                        Path       = $dest
                        Source     = $src
                        Pack       = 'platform-tools'
                        Quarantine = ''
                        Hash       = ''
                    })
            }
            $fail++
        }
    }

    Write-AdbRepairEngineLog -Message ("scrcpy dossier termine OK=$ok Fail=$fail (autres fichiers intacts)") -OnLog $OnLog -Level Success
    return [pscustomobject]@{ Ok = $ok; Fail = $fail; Skip = $skip }
}

function script:Repair-AdbScrcpyHits {
    param(
        [Parameter(Mandatory)][object[]]$Hits,
        [Parameter(Mandatory)][string]$PlatformToolsDir,
        [Parameter(Mandatory)][string]$ScrcpyDir,
        [scriptblock]$OnLog,
        [hashtable]$ProgressBox = $null,
        [switch]$OnlySelected
    )
    $toFix = @($Hits | Where-Object {
            if (-not (Test-IsAllowedRepairFileName -Name ([string]$_.Name) -ScrcpyDir $ScrcpyDir -PlatformToolsDir $PlatformToolsDir) -and
                -not (Test-ScrcpyCompanionName -Name ([string]$_.Name)) -and
                -not (Test-IsPlatformToolsPackFileName -Name ([string]$_.Name) -PlatformToolsDir $PlatformToolsDir) -and
                -not (Test-IsAdbCoreFileName -Name ([string]$_.Name))) {
                $false
            }
            elseif ($OnlySelected) {
                [bool]$_.Selected
            }
            else {
                $_.Status -ne 'Match'
            }
        })
    if ($toFix.Count -eq 0) {
        Write-AdbRepairEngineLog -Message 'Aucun fichier ADB/scrcpy a reparer (liste blanche uniquement).' -OnLog $OnLog -Level Info
        Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'done' -Current 1 -Total 1 -Message 'Rien a reparer'
        return [pscustomobject]@{
            Ok                   = 0
            Fail                 = 0
            Skip                 = 0
            Quarantine           = ''
            Actions              = @()
            ScrcpyFolders        = @()
            PlatformToolsFolders = @()
            ReportPath           = ''
            EndedAt              = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
    }

    Write-AdbRepairEngineLog -Message (
        'Mode strict packs appris : backup → SUPPRESSION → copie. platform-tools et scrcpy synchronises en bloc.'
    ) -OnLog $OnLog -Level Info

    Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'repair' -Current 0 -Total 1 -Message 'Arret processus ADB/scrcpy…'
    Stop-AdbScrcpyProcesses -OnLog $OnLog
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $qRoot = Join-Path (Get-AdbQuarantineRoot) $stamp
    New-Item -ItemType Directory -Path $qRoot -Force | Out-Null
    $actionLog = [System.Collections.Generic.List[object]]::new()
    $startedAt = Get-Date

    $ok = 0; $fail = 0; $skip = 0

    $scrcpyFolders = @{}
    $ptFolders = @{}
    foreach ($hit in $toFix) {
        $n = [string]$hit.Name
        $k = [string]$hit.Kind
        $dir = [string]$hit.Directory
        if (-not $dir) { continue }

        # Priorite scrcpy : hit compagnon OU dossier contenant scrcpy (meme si seul AdbWin* est infecte)
        $isScrcpyHit = ($n -ieq 'scrcpy.exe') -or ($k -ieq 'scrcpy') -or (Test-ScrcpyCompanionName -Name $n)
        if ($isScrcpyHit -or (Test-LooksLikeScrcpyDir -Dir $dir)) {
            $scrcpyFolders[$dir] = $true
            continue
        }

        # Sinon : dossier ADB → sync pack Google platform-tools complet (pas fichier par fichier)
        if ((Test-IsAdbCoreFileName -Name $n) -or
            (Test-IsPlatformToolsPackFileName -Name $n -PlatformToolsDir $PlatformToolsDir) -or
            (Test-LooksLikePlatformToolsDir -Dir $dir)) {
            $ptFolders[$dir] = $true
        }
    }

    # Un dossier ne peut pas etre dans les deux listes
    foreach ($d in @($scrcpyFolders.Keys)) {
        if ($ptFolders.ContainsKey($d)) { $ptFolders.Remove($d) }
    }

    $soloHits = @($toFix | Where-Object {
            $d = [string]$_.Directory
            -not $scrcpyFolders.ContainsKey($d) -and -not $ptFolders.ContainsKey($d)
        })
    if ($soloHits.Count -gt 0) {
        Write-AdbRepairEngineLog -Message (
            ("Fichiers hors sync dossier (solo) : {0}" -f $soloHits.Count)
        ) -OnLog $OnLog -Level Info
    }
    if ($scrcpyFolders.Count -gt 0) {
        Write-AdbRepairEngineLog -Message (
            ("Sync scrcpy + ADB Google sur {0} dossier(s)" -f $scrcpyFolders.Count)
        ) -OnLog $OnLog -Level Info
    }
    if ($ptFolders.Count -gt 0) {
        Write-AdbRepairEngineLog -Message (
            ("Sync platform-tools Google complet sur {0} dossier(s)" -f $ptFolders.Count)
        ) -OnLog $OnLog -Level Info
    }
    $ptKeys = @($ptFolders.Keys)
    $scKeys = @($scrcpyFolders.Keys)
    $totalSteps = $soloHits.Count + $ptKeys.Count + $scKeys.Count
    if ($totalSteps -lt 1) { $totalSteps = 1 }
    $step = 0

    foreach ($hit in $soloHits) {
        $step++
        $path = [string]$hit.Path
        $name = [string]$hit.Name
        Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'repair' -Current $step -Total $totalSteps -Message $path

        if (-not (Test-IsAllowedRepairFileName -Name $name -ScrcpyDir $ScrcpyDir -PlatformToolsDir $PlatformToolsDir)) {
            $skip++
            continue
        }

        $src = Resolve-CleanSourceFile -FileName $name -PlatformToolsDir $PlatformToolsDir -ScrcpyDir $ScrcpyDir
        if (-not $src) {
            Write-AdbRepairEngineLog -Message ("Pas de source clean pour $name — ignore") -OnLog $OnLog -Level Warn
            $skip++
            continue
        }
        try {
            Backup-AndReplaceFileStrict -TargetPath $path -SourcePath $src -QuarantineRoot $qRoot `
                -OnLog $OnLog -ScrcpyDir $ScrcpyDir -PlatformToolsDir $PlatformToolsDir -ActionLog $actionLog
            $ok++
        }
        catch {
            Write-AdbRepairEngineLog -Message ("Echec $path : $_") -OnLog $OnLog -Level Error
            [void]$actionLog.Add([pscustomobject]@{
                    Status     = 'FAIL'
                    Action     = 'Echec'
                    Name       = $name
                    Path       = $path
                    Source     = $(if ($src) { $src } else { '' })
                    Pack       = ''
                    Quarantine = ''
                    Hash       = ''
                })
            $fail++
            try {
                $rel = $path -replace '^[A-Za-z]:\\', ''
                $qDest = Join-Path $qRoot $rel
                if ((Test-Path -LiteralPath $qDest) -and -not (Test-Path -LiteralPath $path)) {
                    Copy-Item -LiteralPath $qDest -Destination $path -Force -ErrorAction SilentlyContinue
                }
            }
            catch { }
        }
    }

    foreach ($folder in $ptKeys) {
        $step++
        Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'repair' -Current $step -Total $totalSteps `
            -Message ("Sync platform-tools : $folder")
        try {
            $r = Sync-PlatformToolsFolderStrict -TargetDir $folder -PlatformToolsDir $PlatformToolsDir `
                -QuarantineRoot $qRoot -OnLog $OnLog -ActionLog $actionLog
            $ok += [int]$r.Ok
            $fail += [int]$r.Fail
            $skip += [int]$r.Skip
        }
        catch {
            Write-AdbRepairEngineLog -Message ("Echec sync platform-tools $folder : $_") -OnLog $OnLog -Level Error
            $fail++
        }
    }

    foreach ($folder in $scKeys) {
        $step++
        Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'repair' -Current $step -Total $totalSteps `
            -Message ("Sync scrcpy : $folder")
        try {
            $r = Sync-ScrcpyFolderStrict -TargetDir $folder -ScrcpyDir $ScrcpyDir `
                -PlatformToolsDir $PlatformToolsDir -QuarantineRoot $qRoot -OnLog $OnLog -ActionLog $actionLog
            $ok += [int]$r.Ok
            $fail += [int]$r.Fail
            $skip += [int]$r.Skip
        }
        catch {
            Write-AdbRepairEngineLog -Message ("Echec sync scrcpy $folder : $_") -OnLog $OnLog -Level Error
            $fail++
        }
    }

    # Verification d'incoherence (pack Google / scrcpy vs live, hors fichiers metier)
    Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'repair' -Current $totalSteps -Total $totalSteps `
        -Message 'Verification incoherences…'
    Write-AdbRepairEngineLog -Message '=== Verification post-reparation (SHA-256 pack) ===' -OnLog $OnLog -Level Info
    $verifyResults = [System.Collections.Generic.List[object]]::new()
    $allIssues = [System.Collections.Generic.List[object]]::new()
    foreach ($folder in $ptKeys) {
        $vr = Test-AdbFolderPackConsistency -TargetDir $folder -Kind 'platform-tools' `
            -PlatformToolsDir $PlatformToolsDir -OnLog $OnLog
        [void]$verifyResults.Add($vr)
        foreach ($i in @($vr.Issues)) { [void]$allIssues.Add($i) }
    }
    foreach ($folder in $scKeys) {
        $vr = Test-AdbFolderPackConsistency -TargetDir $folder -Kind 'scrcpy' `
            -PlatformToolsDir $PlatformToolsDir -ScrcpyDir $ScrcpyDir -OnLog $OnLog
        [void]$verifyResults.Add($vr)
        foreach ($i in @($vr.Issues)) { [void]$allIssues.Add($i) }
    }
    # Solo : verifier chaque fichier remplace contre le clean
    foreach ($hit in $soloHits) {
        $path = [string]$hit.Path
        $name = [string]$hit.Name
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        $src = Resolve-CleanSourceFile -FileName $name -PlatformToolsDir $PlatformToolsDir -ScrcpyDir $ScrcpyDir
        if (-not $src) { continue }
        $hLive = Get-FileSha256Hex -Path $path
        $hClean = Get-FileSha256Hex -Path $src
        if (-not $hLive -or -not $hClean -or ($hLive -ine $hClean)) {
            $iss = [pscustomobject]@{
                Severity = 'FAIL'
                Code     = 'HASH'
                Name     = $name
                Path     = $path
                Detail   = 'SHA-256 different apres repair solo'
            }
            [void]$allIssues.Add($iss)
            [void]$verifyResults.Add([pscustomobject]@{
                    Ok        = $false
                    Kind      = 'solo'
                    Directory = [string]$hit.Directory
                    Issues    = @($iss)
                    KeptExtra = @()
                })
        }
    }
    $verifyFail = @($allIssues | Where-Object { $_.Severity -eq 'FAIL' }).Count
    $verifyWarn = @($allIssues | Where-Object { $_.Severity -eq 'WARN' }).Count
    if ($verifyFail -eq 0 -and $verifyWarn -eq 0) {
        Write-AdbRepairEngineLog -Message 'Verification : aucune incoherence detectee.' -OnLog $OnLog -Level Success
    }
    else {
        Write-AdbRepairEngineLog -Message (
            ("Verification : {0} echec(s), {1} avertissement(s)" -f $verifyFail, $verifyWarn)
        ) -OnLog $OnLog -Level Warn
    }

    $endedAt = Get-Date
    $actions = @($actionLog)
    $reportPath = Join-Path $qRoot 'repair-report.txt'
    try {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('Lapwiz ADB Repair — rapport detaille')
        [void]$sb.AppendLine(('Debut : {0}' -f $startedAt.ToString('yyyy-MM-dd HH:mm:ss')))
        [void]$sb.AppendLine(('Fin   : {0}' -f $endedAt.ToString('yyyy-MM-dd HH:mm:ss')))
        [void]$sb.AppendLine(("Bilan : OK=$ok  Fail=$fail  Skip=$skip  Actions=$($actions.Count)"))
        [void]$sb.AppendLine(("Verification : FAIL=$verifyFail  WARN=$verifyWarn"))
        [void]$sb.AppendLine(("Quarantaine : $qRoot"))
        [void]$sb.AppendLine(("Packs : PT=$PlatformToolsDir"))
        [void]$sb.AppendLine(("        SC=$ScrcpyDir"))
        if ($ptKeys.Count -gt 0) {
            [void]$sb.AppendLine('Dossiers platform-tools (sync complet pack Google) :')
            foreach ($f in $ptKeys) { [void]$sb.AppendLine("  - $f") }
        }
        if ($scKeys.Count -gt 0) {
            [void]$sb.AppendLine('Dossiers scrcpy (sync complet + ADB Google) :')
            foreach ($f in $scKeys) { [void]$sb.AppendLine("  - $f") }
        }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('--- Detail actions ---')
        foreach ($a in $actions) {
            $hashShort = ''
            if ($a.Hash -and $a.Hash.Length -ge 12) { $hashShort = $a.Hash.Substring(0, 12) }
            [void]$sb.AppendLine(('[{0}] {1} | {2} | pack={3} | {4}' -f $a.Status, $a.Action, $a.Name, $a.Pack, $a.Path))
            if ($a.Source) { [void]$sb.AppendLine(("         source : {0}" -f $a.Source)) }
            if ($a.Quarantine) { [void]$sb.AppendLine(("         backup  : {0}" -f $a.Quarantine)) }
            if ($hashShort) { [void]$sb.AppendLine(("         sha256  : {0}…" -f $hashShort)) }
        }
        if ($allIssues.Count -gt 0) {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('--- Incoherences ---')
            foreach ($i in $allIssues) {
                [void]$sb.AppendLine(('[{0}] {1} | {2} | {3} | {4}' -f $i.Severity, $i.Code, $i.Name, $i.Path, $i.Detail))
            }
        }
        else {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('--- Incoherences ---')
            [void]$sb.AppendLine('(aucune)')
        }
        foreach ($vr in $verifyResults) {
            if ($vr.KeptExtra -and @($vr.KeptExtra).Count -gt 0) {
                [void]$sb.AppendLine('')
                [void]$sb.AppendLine(("Extras conserves (hors pack) dans {0} :" -f $vr.Directory))
                foreach ($ex in @($vr.KeptExtra)) { [void]$sb.AppendLine("  + $ex") }
            }
        }
        [IO.File]::WriteAllText($reportPath, $sb.ToString(), [Text.UTF8Encoding]::new($false))
    }
    catch {
        Write-AdbRepairEngineLog -Message ("Rapport fichier ignore : $_") -OnLog $OnLog -Level Warn
        $reportPath = ''
    }

    Write-AdbRepairEngineLog -Message ("Quarantaine : $qRoot") -OnLog $OnLog -Level Info
    Write-AdbRepairEngineLog -Message ("Bilan : OK=$ok Fail=$fail Skip=$skip (packs platform-tools + scrcpy)") -OnLog $OnLog -Level Info
    Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'done' -Current $totalSteps -Total $totalSteps -Message 'Reparation terminee'
    return [pscustomobject]@{
        Ok                   = $ok
        Fail                 = $fail
        Skip                 = $skip
        Quarantine           = $qRoot
        Actions              = $actions
        ScrcpyFolders        = @($scKeys)
        PlatformToolsFolders = @($ptKeys)
        ReportPath           = $reportPath
        StartedAt            = $startedAt.ToString('yyyy-MM-dd HH:mm:ss')
        EndedAt              = $endedAt.ToString('yyyy-MM-dd HH:mm:ss')
        Issues               = @($allIssues)
        VerifyFail           = $verifyFail
        VerifyWarn           = $verifyWarn
        VerifyResults        = @($verifyResults)
    }
}
