#Requires -Version 5.1
<#
.SYNOPSIS
    Controles et corrections defensives inspires de Trend Micro Virus.Win64.EXPIRO.AA.
.NOTES
    N'infecte rien : audit / restauration Startup / services AV / artefacts suspects.
    Source : https://www.trendmicro.com/vinfo/us/threat-encyclopedia/malware/virus.win64.expiro.aa
#>
Set-StrictMode -Version Latest

function script:Get-ExpiroDefaultStartupPath {
    return Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'
}

function script:Get-ExpiroDefaultUserStartupPath {
    return Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
}

function script:Test-ExpiroStartupHijackValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $expanded = [Environment]::ExpandEnvironmentVariables($Value)
    $norm = $expanded.TrimEnd('\')
    $okPaths = @(
        (Get-ExpiroDefaultStartupPath).TrimEnd('\')
        (Get-ExpiroDefaultUserStartupPath).TrimEnd('\')
    )
    foreach ($ok in $okPaths) {
        if ([string]::Equals($norm, $ok, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    # Hijack typique Trend : pointe vers LocalAppData\{aleatoire}
    $local = $env:LOCALAPPDATA
    if ($local -and $norm.StartsWith($local, [StringComparison]::OrdinalIgnoreCase)) {
        if ($norm -notmatch '(?i)\\Microsoft\\Windows\\Start Menu\\Programs\\Start.?up$') {
            return $true
        }
    }
    # Autre valeur non standard (hors Start Menu\...\Startup)
    if ($norm -notmatch '(?i)\\Start Menu\\Programs\\Start.?up$') {
        return $true
    }
    return $false
}

function script:Get-ExpiroStartupAudit {
    $targets = @(
        @{ Hive = 'HKLM'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'; Name = 'Startup' }
        @{ Hive = 'HKLM'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'; Name = 'Startup' }
        @{ Hive = 'HKCU'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'; Name = 'Startup' }
        @{ Hive = 'HKCU'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'; Name = 'Startup' }
    )
    $rows = @()
    foreach ($t in $targets) {
        $regPath = Join-Path ("Registry::$($t.Hive)") $t.Path
        $raw = $null
        $exists = $false
        try {
            if (Test-Path -LiteralPath $regPath) {
                $item = Get-ItemProperty -LiteralPath $regPath -ErrorAction Stop
                if ($null -ne $item.PSObject.Properties[$t.Name]) {
                    $raw = [string]$item.($t.Name)
                    $exists = $true
                }
            }
        }
        catch {
            $raw = "(lecture impossible: $($_.Exception.Message))"
            $exists = $true
        }
        $hijack = $false
        if ($exists -and $raw -and ($raw -notlike '(lecture*')) {
            $hijack = Test-ExpiroStartupHijackValue -Value $raw
        }
        $rows += [pscustomobject]@{
            Hive   = $t.Hive
            Path   = $t.Path
            Name   = $t.Name
            Value  = $(if ($exists) { $raw } else { '(absent)' })
            Hijack = $hijack
        }
    }
    return $rows
}

function script:Repair-ExpiroStartupRegistry {
    $defaultMachine = Get-ExpiroDefaultStartupPath
    $defaultUser = Get-ExpiroDefaultUserStartupPath
    $log = [System.Collections.Generic.List[string]]::new()
    $audit = Get-ExpiroStartupAudit
    foreach ($row in $audit) {
        if (-not $row.Hijack) {
            [void]$log.Add("OK  $($row.Hive)\...\$($row.Name) = $($row.Value)")
            continue
        }
        $regPath = Join-Path ("Registry::$($row.Hive)") $row.Path
        $newVal = if ($row.Hive -eq 'HKLM') { $defaultMachine } else { $defaultUser }
        # User Shell Folders utilise souvent la forme expandee / variable
        if ($row.Path -like '*User Shell Folders*') {
            if ($row.Hive -eq 'HKCU') {
                $newVal = '%USERPROFILE%\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
            }
            else {
                # HKLM User Shell Folders Startup detourne : remettre chemin ProgramData Startup
                $newVal = $defaultMachine
            }
        }
        try {
            if (-not (Test-Path -LiteralPath $regPath)) {
                New-Item -Path $regPath -Force | Out-Null
            }
            Set-ItemProperty -LiteralPath $regPath -Name $row.Name -Value $newVal -Type String -Force
            [void]$log.Add("FIX $($row.Hive)\...\$($row.Name)")
            [void]$log.Add("    avant: $($row.Value)")
            [void]$log.Add("    apres: $newVal")
        }
        catch {
            [void]$log.Add("ERR $($row.Hive)\...\$($row.Name) : $($_.Exception.Message)")
        }
    }
    return $log
}

function script:Get-ExpiroServiceAudit {
    $names = @('wscsvc', 'WinDefend', 'MsMpSvc', 'NisSrv', 'wuauserv', 'gupdate', 'gupdatem')
    $rows = @()
    foreach ($n in $names) {
        try {
            $svc = Get-Service -Name $n -ErrorAction Stop
            $status = ''
            $startType = ''
            try { $status = [string]$svc.Status } catch { $status = '?' }
            try { $startType = [string]$svc.StartType } catch { $startType = '?' }
            $rows += [pscustomobject]@{
                Name        = $svc.Name
                DisplayName = [string]$svc.DisplayName
                Status      = $status
                StartType   = $startType
                Present     = $true
            }
        }
        catch {
            $rows += [pscustomobject]@{
                Name        = $n
                DisplayName = ''
                Status      = 'Absent'
                StartType   = ''
                Present     = $false
            }
        }
    }
    return $rows
}

function script:Repair-ExpiroSecurityServices {
    # Services critiques Trend (Expiro tente de les stopper)
    $critical = @(
        @{ Name = 'wscsvc';    StartType = 'Automatic' }
        @{ Name = 'WinDefend'; StartType = 'Automatic' }
        @{ Name = 'MsMpSvc';  StartType = 'Automatic' }
        @{ Name = 'wuauserv'; StartType = 'Automatic' }
    )
    $log = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $critical) {
        try {
            $svc = Get-Service -Name $c.Name -ErrorAction Stop
            try {
                Set-Service -Name $c.Name -StartupType $c.StartType -ErrorAction Stop
                [void]$log.Add("StartType $($c.Name) -> $($c.StartType)")
            }
            catch {
                [void]$log.Add("WARN StartType $($c.Name) : $($_.Exception.Message)")
            }
            if ($svc.Status -ne 'Running') {
                Start-Service -Name $c.Name -ErrorAction Stop
                [void]$log.Add("START $($c.Name) OK")
            }
            else {
                [void]$log.Add("OK    $($c.Name) deja Running")
            }
        }
        catch {
            [void]$log.Add("ERR  $($c.Name) : $($_.Exception.Message)")
        }
    }
    # NisSrv est souvent dependant de WinDefend — tenter sans forcer
    try {
        $nis = Get-Service -Name 'NisSrv' -ErrorAction Stop
        if ($nis.Status -ne 'Running') {
            Start-Service -Name 'NisSrv' -ErrorAction SilentlyContinue
            [void]$log.Add("START NisSrv tente")
        }
    }
    catch {
        [void]$log.Add('NisSrv absent ou inaccessible')
    }
    return $log
}

function script:Find-ExpiroSuspiciousArtifacts {
    $hits = [System.Collections.Generic.List[object]]::new()
    $local = $env:LOCALAPPDATA
    $progData = $env:ProgramData
    $sysCmd = Join-Path $env:WINDIR 'System32\cmd.exe'

    if ($local -and (Test-Path -LiteralPath $local)) {
        Get-ChildItem -LiteralPath $local -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $dir = $_
            # Dossier court / aleatoire contenant cmd.exe (artefact Trend)
            $cmdCopy = Join-Path $dir.FullName 'cmd.exe'
            if (-not (Test-Path -LiteralPath $cmdCopy)) { return }
            $nameLen = $dir.Name.Length
            $looksRandom = ($nameLen -ge 6 -and $nameLen -le 16 -and $dir.Name -match '^[A-Za-z0-9_-]+$')
            $childCount = @(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue).Count
            if ($looksRandom -or $childCount -le 4) {
                $len = (Get-Item -LiteralPath $cmdCopy).Length
                $sysLen = 0
                if (Test-Path -LiteralPath $sysCmd) { $sysLen = (Get-Item -LiteralPath $sysCmd).Length }
                [void]$hits.Add([pscustomobject]@{
                        Kind    = 'LocalAppData-cmd'
                        Path    = $cmdCopy
                        Detail  = "taille=$len (System32 cmd=$sysLen) dossier=$($dir.Name)"
                        Suggest = 'Delete'
                    })
            }
        }
    }

    if ($progData -and (Test-Path -LiteralPath $progData)) {
        Get-ChildItem -LiteralPath $progData -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension -match '^\.(dat|nls)$' -and
                $_.Name -match '^[A-Za-z0-9_-]{6,20}\.(dat|nls)$' -and
                $_.DirectoryName -eq $progData
            } |
            ForEach-Object {
                [void]$hits.Add([pscustomobject]@{
                        Kind    = 'ProgramData-dat-nls'
                        Path    = $_.FullName
                        Detail  = "taille=$($_.Length) modifie=$($_.LastWriteTime)"
                        Suggest = 'Review'
                    })
            }
    }

    return $hits
}

function script:Remove-ExpiroArtifactPaths {
    param([string[]]$Paths)
    $log = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $Paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (-not (Test-Path -LiteralPath $p)) {
            [void]$log.Add("SKIP absent: $p")
            continue
        }
        try {
            $item = Get-Item -LiteralPath $p -Force
            Remove-Item -LiteralPath $p -Force -ErrorAction Stop
            [void]$log.Add("DEL  $p")
            # Si cmd.exe dans dossier aleatoire quasi vide, tenter de supprimer le dossier parent
            if ($item.Name -eq 'cmd.exe') {
                $parent = $item.Directory
                if ($parent) {
                    $left = @(Get-ChildItem -LiteralPath $parent.FullName -Force -ErrorAction SilentlyContinue)
                    if ($left.Count -eq 0) {
                        Remove-Item -LiteralPath $parent.FullName -Force -ErrorAction SilentlyContinue
                        [void]$log.Add("DEL  dossier vide $($parent.FullName)")
                    }
                }
            }
        }
        catch {
            [void]$log.Add("ERR  $p : $($_.Exception.Message)")
        }
    }
    return $log
}

function script:Invoke-ExpiroTrendFullAudit {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('=== Audit Expiro (Trend Win64.EXPIRO.AA) ===')
    [void]$sb.AppendLine("Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine("Source: trendmicro.com/.../virus.win64.expiro.aa")
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('-- Registre Startup --')
    $startup = Get-ExpiroStartupAudit
    $hijacks = @($startup | Where-Object { $_.Hijack })
    foreach ($r in $startup) {
        $flag = if ($r.Hijack) { 'HIJACK' } else { 'ok' }
        [void]$sb.AppendLine("[$flag] $($r.Hive) $($r.Name) = $($r.Value)")
    }
    [void]$sb.AppendLine("Hijacks detectes: $($hijacks.Count)")
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('-- Services (cibles Expiro) --')
    foreach ($s in Get-ExpiroServiceAudit) {
        if ($s.Present) {
            [void]$sb.AppendLine("$($s.Name): $($s.Status) / $($s.StartType)")
        }
        else {
            [void]$sb.AppendLine("$($s.Name): absent")
        }
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('-- Artefacts suspects --')
    $arts = @(Find-ExpiroSuspiciousArtifacts)
    if ($arts.Count -eq 0) {
        [void]$sb.AppendLine('(aucun motif LocalAppData\*\cmd.exe / ProgramData *.dat|*.nls)')
    }
    else {
        foreach ($a in $arts) {
            [void]$sb.AppendLine("[$($a.Kind)] $($a.Path)")
            [void]$sb.AppendLine("    $($a.Detail)")
        }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Rappel: les EXE infectes doivent etre nettoyes hors Windows (LiveDisk) puis apps reinstallees (winget).')
    return [pscustomobject]@{
        Text     = $sb.ToString()
        Hijacks  = $hijacks.Count
        Artifacts = $arts
    }
}

function script:Get-ExpiroKvrtPath {
    $dir = Join-Path $env:LOCALAPPDATA 'Lapwiz\tools'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return Join-Path $dir 'KVRT.exe'
}

function script:Get-ExpiroKvrtDownloadUrl {
    # Build officiel Kaspersky Labs (latest full) — ~120 Mo
    return 'https://devbuilds.s.kaspersky-labs.com/devbuilds/KVRT/latest/full/KVRT.exe'
}

function script:Install-ExpiroKvrt {
    param(
        [scriptblock]$Progress = $null
    )
    $dest = Get-ExpiroKvrtPath
    $url = Get-ExpiroKvrtDownloadUrl
    if ($Progress) { & $Progress "Telechargement KVRT (~120 Mo)…" }
    $tmp = "$dest.download"
    try {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'LapwizSetup/1.0')
        $wc.DownloadFile($url, $tmp)
        if (-not (Test-Path -LiteralPath $tmp) -or ((Get-Item -LiteralPath $tmp).Length -lt 1MB)) {
            throw 'Fichier KVRT invalide ou trop petit.'
        }
        Move-Item -LiteralPath $tmp -Destination $dest -Force
        if ($Progress) { & $Progress "KVRT pret : $dest" }
        return $dest
    }
    catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function script:Start-ExpiroKvrt {
    $path = Get-ExpiroKvrtPath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "KVRT absent. Telecharge-le d'abord."
    }
    Start-Process -FilePath $path
    return $path
}

function script:Start-ExpiroDefenderFullScan {
    # Prefer cmdlet, fallback to MpCmdRun
    if (Get-Command Start-MpScan -ErrorAction SilentlyContinue) {
        Start-MpScan -ScanType FullScan -ErrorAction Stop
        return 'Start-MpScan -ScanType FullScan lance (arriere-plan Defender).'
    }
    $mp = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
    if (-not (Test-Path -LiteralPath $mp)) {
        $mp = Join-Path ${env:ProgramFiles(x86)} 'Windows Defender\MpCmdRun.exe'
    }
    if (Test-Path -LiteralPath $mp) {
        Start-Process -FilePath $mp -ArgumentList '-Scan','-ScanType','2' -WindowStyle Normal
        return "MpCmdRun FullScan lance : $mp"
    }
    throw 'Microsoft Defender introuvable (Start-MpScan / MpCmdRun).'
}

function script:Find-ExpiroMalwarebytesExe {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Malwarebytes\Anti-Malware\Malwarebytes.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Malwarebytes\Anti-Malware\Malwarebytes.exe')
        (Join-Path $env:ProgramFiles 'Malwarebytes\Malwarebytes.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Malwarebytes\Malwarebytes.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    $cmd = Get-Command 'malwarebytes.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function script:Install-ExpiroMalwarebytesWinget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { throw 'winget introuvable.' }
    $p = Start-Process -FilePath $winget.Source -ArgumentList @(
        'install','-e','--id','Malwarebytes.Malwarebytes',
        '--accept-package-agreements','--accept-source-agreements','--disable-interactivity'
    ) -Wait -PassThru -WindowStyle Normal
    return $p.ExitCode
}

function script:Start-ExpiroMalwarebytes {
    $exe = Find-ExpiroMalwarebytesExe
    if (-not $exe) { throw 'Malwarebytes non installe.' }
    Start-Process -FilePath $exe
    return $exe
}

function script:Start-ExpiroAdwCleanerPage {
    try { Start-Process 'https://www.malwarebytes.com/adwcleaner' | Out-Null } catch {}
}

function script:Start-ExpiroRogueKillerPage {
    try { Start-Process 'https://www.adlice.com/roguekiller/' | Out-Null } catch {}
}

function script:Start-ExpiroFrstPage {
    try { Start-Process 'https://www.bleepingcomputer.com/download/farbar-recovery-scan-tool/' | Out-Null } catch {}
}
