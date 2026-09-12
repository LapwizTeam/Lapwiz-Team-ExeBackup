# Lapwiz Setup - moteur d'installation (winget, msiexec, PATH ADB)
# Dot-source depuis Start-LapwizSetup.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Repair-MojibakeText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    # UTF-8 lu comme Windows-1252 / Latin-1 (ex. dÔÇÖ → d')
    if ($Text -notmatch '[Ô├┬ÃÂÅ]') { return $Text }
    try {
        $latin1 = [System.Text.Encoding]::GetEncoding(28591)
        $bytes = $latin1.GetBytes($Text)
        $fixed = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ($fixed -match '\uFFFD' -or $fixed.Length -eq 0) { return $Text }
        return $fixed
    }
    catch {
        return $Text
    }
}

function Invoke-NativeCommandLines {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    $r = Invoke-NativeCommandStreaming -FileName $FileName -ArgumentList $ArgumentList
    return [pscustomobject]@{ ExitCode = $r.ExitCode; Lines = @($r.Lines) }
}

function Invoke-NativeCommandStreaming {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [scriptblock]$OnLine
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    $psi.Arguments = ($ArgumentList | ForEach-Object {
            if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $allLines = [System.Collections.Generic.List[string]]::new()

    # Handler C# pur : un scriptblock PS sur OutputDataReceived crash (GetContextFromTLS)
    if (-not ('LapwizNativeLines' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Collections.Concurrent;
public static class LapwizNativeLines {
  public static DataReceivedEventHandler CreateHandler(ConcurrentQueue<string> queue) {
    return (sender, e) => {
      if (e == null || e.Data == null) return;
      string[] parts = e.Data.Split(new char[] { '\r' }, StringSplitOptions.None);
      for (int i = 0; i < parts.Length; i++) {
        string p = parts[i];
        if (string.IsNullOrWhiteSpace(p)) continue;
        queue.Enqueue(p.TrimEnd());
      }
    };
  }
}
'@
    }
    $handler = [LapwizNativeLines]::CreateHandler($queue)
    $proc.add_OutputDataReceived($handler)
    $proc.add_ErrorDataReceived($handler)

    [void]$proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    $processLine = {
        param([string]$raw)
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $clean = Repair-MojibakeText -Text $raw
        if ([string]::IsNullOrWhiteSpace($clean)) { return }
        [void]$allLines.Add($clean)
        if ($OnLine) { & $OnLine $clean }
    }

    while (-not $proc.HasExited) {
        $raw = $null
        while ($queue.TryDequeue([ref]$raw)) {
            & $processLine $raw
        }
        Start-Sleep -Milliseconds 80
    }
    Start-Sleep -Milliseconds 120
    $raw = $null
    while ($queue.TryDequeue([ref]$raw)) {
        & $processLine $raw
    }

    $code = $proc.ExitCode
    try { $proc.remove_OutputDataReceived($handler) } catch { }
    try { $proc.remove_ErrorDataReceived($handler) } catch { }
    try { $proc.CancelOutputRead() } catch { }
    try { $proc.CancelErrorRead() } catch { }
    $proc.Dispose()
    return [pscustomobject]@{ ExitCode = $code; Lines = @($allLines) }
}

function ConvertTo-ByteCount {
    param(
        [double]$Value,
        [string]$Unit
    )
    $u = $Unit.Trim().ToUpperInvariant()
    switch -Regex ($u) {
        '^(B|O)$' { return [long][math]::Round($Value) }
        '^(KB|KO)$' { return [long][math]::Round($Value * 1KB) }
        '^(MB|MO)$' { return [long][math]::Round($Value * 1MB) }
        '^(GB|GO)$' { return [long][math]::Round($Value * 1GB) }
        '^(TB|TO)$' { return [long][math]::Round($Value * 1TB) }
        '^(PB|PO)$' { return [long][math]::Round($Value * 1PB) }
        default { return [long][math]::Round($Value) }
    }
}

function Format-ByteSize {
    param([long]$Bytes)
    if ($Bytes -lt 0) { $Bytes = 0 }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Get-WingetDownloadProgressFromText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    # Ex. "269 MB / 305 MB" ou "269,5 Mo / 305 Mo" (FR)
    $m = [regex]::Match($Text, '(?i)(\d+(?:[.,]\d+)?)\s*(B|KB|MB|GB|TB|PB|O|Ko|Mo|Go|To|Po)\s*/\s*(\d+(?:[.,]\d+)?)\s*(B|KB|MB|GB|TB|PB|O|Ko|Mo|Go|To|Po)')
    if (-not $m.Success) { return $null }

    $doneVal = [double](($m.Groups[1].Value -replace ',', '.'))
    $totalVal = [double](($m.Groups[3].Value -replace ',', '.'))
    $doneBytes = ConvertTo-ByteCount -Value $doneVal -Unit $m.Groups[2].Value
    $totalBytes = ConvertTo-ByteCount -Value $totalVal -Unit $m.Groups[4].Value
    if ($totalBytes -le 0) { return $null }
    $remain = [math]::Max(0L, $totalBytes - $doneBytes)
    $pct = [math]::Min(100, [math]::Round(100.0 * $doneBytes / $totalBytes))
    return [pscustomobject]@{
        DownloadedBytes = $doneBytes
        TotalBytes      = $totalBytes
        RemainingBytes  = $remain
        Percent         = $pct
        Label           = ('Taille {0} | Telecharge {1} | Restant {2}' -f (Format-ByteSize $totalBytes), (Format-ByteSize $doneBytes), (Format-ByteSize $remain))
    }
}

function Resolve-WingetExe {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return [string]$cmd.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'),
        (Join-Path $env:ProgramFiles 'WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe')
    )
    foreach ($c in $candidates) {
        if ($c -like '*\*') {
            $hit = Get-Item $c -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
        elseif (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Write-EngineLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warn', 'Error')]
        [string]$Level = 'Info',
        [scriptblock]$OnLog
    )
    $stamp = Get-Date -Format 'HH:mm:ss'
    $msg = Repair-MojibakeText -Text $Message
    $line = '[' + $stamp + '] [' + $Level + '] ' + $msg
    if ($OnLog) { & $OnLog $line $Level }
    else { Write-Host $line }
}

function Get-InstallFailureHint {
    param([int]$ExitCode, [string]$CombinedOutput = '')
    $hints = [System.Collections.Generic.List[string]]::new()
    if ($ExitCode -eq 1601 -or $CombinedOutput -match '1601|0x80070424') {
        [void]$hints.Add('Cause: service Windows Installer (msiserver) inaccessible ou INTROUVABLE (MSI 1601 / 0x80070424). Souvent apres Expiro. Cliquez « Reparer msiexec », puis reessayez.')
    }
    if ($CombinedOutput -match '0x80070424|service specifie n.existe pas|service spécifié n.existe pas') {
        [void]$hints.Add('Detail: erreur 0x80070424 = le service msiserver n''existe plus dans le SCM Windows.')
    }
    # winget INSTALL_FAILED typical HRESULT
    if ($ExitCode -eq -1978334968 -or $ExitCode -eq 0x8A150006) {
        [void]$hints.Add('winget INSTALL_FAILED (-1978334968) : l''installeur MSI/EXE a echoue (voir code MSI ci-dessus).')
    }
    if ($ExitCode -eq 1618) {
        [void]$hints.Add('MSI 1618 : une autre installation est en cours. Attendez ou tuez msiexec orphelins.')
    }
    if ($ExitCode -eq 1603) {
        [void]$hints.Add('MSI 1603 : echec fatal installateur (droits, fichier verrouille, antivirus).')
    }
    return @($hints)
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WingetAvailable {
    param([scriptblock]$OnLog)
    $exe = Resolve-WingetExe
    if (-not $exe) {
        Write-EngineLog -Message "winget introuvable. Installez App Installer depuis le Microsoft Store." -Level Error -OnLog $OnLog
        return $false
    }
    try {
        $r = Invoke-NativeCommandLines -FileName $exe -ArgumentList @('--version')
        $ver = if ($r.Lines.Count) { $r.Lines[0] } else { '?' }
        Write-EngineLog -Message ("winget detecte : " + $ver) -Level Success -OnLog $OnLog
        return $true
    }
    catch {
        Write-EngineLog -Message ("winget present mais non utilisable : " + $_) -Level Error -OnLog $OnLog
        return $false
    }
}

function Test-MsiServerExists {
    try {
        $null = Get-Service -Name 'msiserver' -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Register-WindowsInstallerService {
    param([scriptblock]$OnLog)
    $msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    if (-not (Test-Path -LiteralPath $msiexec)) {
        Write-EngineLog -Message ("msiexec.exe introuvable : " + $msiexec) -Level Error -OnLog $OnLog
        return $false
    }

    Write-EngineLog -Message 'Reenregistrement Windows Installer (msiexec /regserver)...' -Level Warn -OnLog $OnLog
    try {
        Start-Process -FilePath $msiexec -ArgumentList '/unregister' -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
    }
    catch {}
    try {
        $p = Start-Process -FilePath $msiexec -ArgumentList '/regserver' -Wait -PassThru -WindowStyle Hidden
        Write-EngineLog -Message ("msiexec /regserver termine (code {0})" -f $p.ExitCode) -Level Info -OnLog $OnLog
    }
    catch {
        Write-EngineLog -Message ("msiexec /regserver echoue : " + $_) -Level Error -OnLog $OnLog
    }

    Start-Sleep -Milliseconds 800
    if (Test-MsiServerExists) { return $true }

    Write-EngineLog -Message 'Creation manuelle du service msiserver...' -Level Warn -OnLog $OnLog
    $bin = "`"$msiexec`" /V"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & sc.exe create msiserver binPath= $bin start= demand DisplayName= "Windows Installer" type= own 2>&1 | Out-String
        Write-EngineLog -Message ("sc create : " + ($out.Trim())) -Level Info -OnLog $OnLog
        & sc.exe description msiserver "Installe, répare et supprime les programmes selon les instructions des fichiers de package Windows Installer (*.msi)." 2>&1 | Out-Null
    }
    finally {
        $ErrorActionPreference = $prev
    }

    Start-Sleep -Milliseconds 500
    return (Test-MsiServerExists)
}

function Repair-WindowsInstaller {
    param(
        [scriptblock]$OnLog,
        [switch]$RunSfc,
        [switch]$RunDism
    )

    Write-EngineLog -Message 'Verification du service Windows Installer (msiserver)...' -Level Info -OnLog $OnLog

    if (-not (Test-MsiServerExists)) {
        Write-EngineLog -Message 'ALERTE: service msiserver INTROUVABLE (erreur 1060 / 0x80070424). Les MSI (7-Zip, Notepad++, etc.) echouent avec code 1601.' -Level Error -OnLog $OnLog
        if (-not (Register-WindowsInstallerService -OnLog $OnLog)) {
            Write-EngineLog -Message 'Impossible de recreer msiserver. Lancement DISM/SFC recommande (serveurs Microsoft).' -Level Error -OnLog $OnLog
            # Continuer vers DISM si demande — ne pas abandonner trop tot
            if (-not $RunDism) { return $false }
        }
        else {
            Write-EngineLog -Message 'Service msiserver recree avec succes.' -Level Success -OnLog $OnLog
        }
    }

    if (Test-MsiServerExists) {
        try {
            $svc = Get-Service -Name 'msiserver' -ErrorAction Stop
            if ($svc.StartType -eq 'Disabled') {
                Write-EngineLog -Message 'Service msiserver desactive - reactivation...' -Level Warn -OnLog $OnLog
                Set-Service -Name 'msiserver' -StartupType Manual -ErrorAction Stop
            }
            if ($svc.Status -ne 'Running') {
                Write-EngineLog -Message 'Demarrage du service msiserver...' -Level Info -OnLog $OnLog
                Start-Service -Name 'msiserver' -ErrorAction Stop
                Start-Sleep -Seconds 1
            }
            $svc = Get-Service -Name 'msiserver'
            Write-EngineLog -Message ("msiserver : {0} (demarrage={1})" -f $svc.Status, $svc.StartType) -Level Success -OnLog $OnLog
        }
        catch {
            Write-EngineLog -Message ("Impossible de gerer msiserver : " + $_) -Level Error -OnLog $OnLog
            if (-not $RunDism) { return $false }
        }
    }

    try {
        $msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        if (-not (Test-Path -LiteralPath $msiexec)) {
            Write-EngineLog -Message ("msiexec.exe introuvable : " + $msiexec) -Level Error -OnLog $OnLog
            if (-not $RunDism) { return $false }
        }
        else {
            $p = Start-Process -FilePath $msiexec -ArgumentList '/?' -Wait -PassThru -WindowStyle Hidden
            Write-EngineLog -Message ("Test msiexec - code retour {0}" -f $p.ExitCode) -Level Success -OnLog $OnLog
        }
    }
    catch {
        Write-EngineLog -Message ("Echec du test msiexec : " + $_) -Level Error -OnLog $OnLog
        if (-not $RunDism) { return $false }
    }

    # Restauration composants Windows depuis Windows Update (serveurs Microsoft)
    if ($RunDism) {
        Write-EngineLog -Message 'DISM RestoreHealth — telechargement / reparation depuis Windows Update (10-40 min possibles)...' -Level Warn -OnLog $OnLog
        Write-EngineLog -Message 'Ne fermez pas Lapwiz pendant DISM. Connexion Internet requise.' -Level Info -OnLog $OnLog
        $dismOk = $false
        try {
            # Preferer le cmdlet PowerShell si dispo, sinon dism.exe
            $cmdlet = Get-Command Repair-WindowsImage -ErrorAction SilentlyContinue
            if ($cmdlet) {
                $prev = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    $result = Repair-WindowsImage -Online -RestoreHealth -ErrorAction Continue
                    if ($result) {
                        Write-EngineLog -Message ("DISM ImageHealthState : " + $result.ImageHealthState) -Level Info -OnLog $OnLog
                        $dismOk = ($result.ImageHealthState -match '(?i)Healthy|Repairable') -or ($null -eq $result.ImageHealthState)
                    }
                    else {
                        $dismOk = $true
                    }
                }
                finally {
                    $ErrorActionPreference = $prev
                }
            }
            else {
                $dismExe = Join-Path $env:SystemRoot 'System32\Dism.exe'
                $r = Invoke-NativeCommandLines -FileName $dismExe -ArgumentList @(
                    '/Online', '/Cleanup-Image', '/RestoreHealth'
                )
                foreach ($line in $r.Lines) {
                    if ($line -match '\d{1,3}\s*%|Error|Erreur|corrupt|healthy|reussi|succ') {
                        Write-EngineLog -Message $line -Level Info -OnLog $OnLog
                    }
                }
                $dismOk = ($r.ExitCode -eq 0)
                Write-EngineLog -Message ("DISM exit code : " + $r.ExitCode) -Level $(if ($dismOk) { 'Success' } else { 'Error' }) -OnLog $OnLog
            }
            if ($dismOk) {
                Write-EngineLog -Message 'DISM RestoreHealth termine.' -Level Success -OnLog $OnLog
            }
            else {
                Write-EngineLog -Message 'DISM a signale un probleme — poursuivez avec SFC ou une repair install Windows.' -Level Warn -OnLog $OnLog
            }
        }
        catch {
            Write-EngineLog -Message ("DISM RestoreHealth echoue : " + $_) -Level Error -OnLog $OnLog
            $dismOk = $false
        }

        # Apres DISM, SFC est recommande par Microsoft
        $RunSfc = $true
    }

    if ($RunSfc) {
        Write-EngineLog -Message 'Lancement de sfc /scannow (peut prendre plusieurs minutes)...' -Level Warn -OnLog $OnLog
        try {
            $sfc = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\sfc.exe') -ArgumentList '/scannow' -Wait -PassThru -NoNewWindow
            Write-EngineLog -Message ("sfc /scannow termine - code {0}" -f $sfc.ExitCode) -Level Info -OnLog $OnLog
        }
        catch {
            Write-EngineLog -Message ("sfc non bloquant a echoue : " + $_) -Level Warn -OnLog $OnLog
        }
    }

    # Re-tester le service apres DISM/SFC
    if (-not (Test-MsiServerExists)) {
        Write-EngineLog -Message 'msiserver toujours absent apres DISM — nouvelle tentative de recreation...' -Level Warn -OnLog $OnLog
        $null = Register-WindowsInstallerService -OnLog $OnLog
    }

    $finalOk = (Test-MsiServerExists)
    if ($finalOk) {
        Write-EngineLog -Message 'Windows Installer operationnel.' -Level Success -OnLog $OnLog
    }
    else {
        Write-EngineLog -Message 'Windows Installer toujours HS. Envisager une mise a niveau sur place de Windows.' -Level Error -OnLog $OnLog
    }
    return $finalOk
}

function Test-WingetPackageInstalled {
    param([Parameter(Mandatory)][string]$PackageId)
    $exe = Resolve-WingetExe
    if (-not $exe) { return $false }
    try {
        $r = Invoke-NativeCommandLines -FileName $exe -ArgumentList @(
            'list', '--id', $PackageId, '-e', '--accept-source-agreements', '--disable-interactivity'
        )
        $output = ($r.Lines -join "`n")
        if ($r.ExitCode -ne 0) { return $false }
        if ($output -match '(?i)No installed package found|Aucun package') { return $false }
        return ($output -match [regex]::Escape($PackageId))
    }
    catch {
        return $false
    }
}

function Get-WingetInstalledPackageIds {
    param([Parameter(Mandatory)][object[]]$Packages)
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($pkg in $Packages) {
        $id = [string]$pkg.id
        $name = [string]$pkg.name
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if (Test-WingetPackageInstalled -PackageId $id) {
            [void]$found.Add([pscustomobject]@{ Id = $id; Name = $name })
        }
    }
    return @($found)
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$DisplayName,
        [scriptblock]$OnLog,
        [scriptblock]$OnProgress,
        [int]$Step = 0,
        [int]$Total = 1,
        [switch]$Force
    )

    $already = Test-WingetPackageInstalled -PackageId $PackageId
    if ($already -and -not $Force) {
        Write-EngineLog -Message ($DisplayName + ' (' + $PackageId + ') deja installe - ignore (pas de reinstall).') -Level Warn -OnLog $OnLog
        if ($OnProgress -and $Total -gt 0) {
            $pct = [math]::Round(100.0 * $Step / $Total)
            & $OnProgress @{ Step = $Step; Total = $Total; Name = $DisplayName; Percent = $pct; Indeterminate = $false; Detail = 'Deja installe (ignore)' }
        }
        return 'Skipped'
    }

    if ($already -and $Force) {
        Write-EngineLog -Message ($DisplayName + ' deja present - reinstallation forcee (recommande apres Expiro).') -Level Warn -OnLog $OnLog
    }

    if (-not (Test-MsiServerExists)) {
        Write-EngineLog -Message 'msiserver manquant avant install — tentative de reparation automatique...' -Level Warn -OnLog $OnLog
        $null = Repair-WindowsInstaller -OnLog $OnLog
    }

    $actionLabel = if ($Force -and $already) { 'Reinstallation' } else { 'Installation' }
    Write-EngineLog -Message ($actionLabel + ' de ' + $DisplayName + ' (' + $PackageId + ')...') -Level Info -OnLog $OnLog
    if ($OnProgress) {
        $basePct = if ($Total -gt 0) { [math]::Round(100.0 * ([math]::Max(0, $Step - 1)) / $Total) } else { 0 }
        $detail = if ($Force -and $already) { 'Reinstall forcee...' } else { 'Telechargement...' }
        & $OnProgress @{ Step = $Step; Total = $Total; Name = $DisplayName; Percent = $basePct; Indeterminate = $true; Detail = $detail }
    }

    $exe = Resolve-WingetExe
    if (-not $exe) {
        Write-EngineLog -Message 'winget introuvable.' -Level Error -OnLog $OnLog
        return 'Failed'
    }

    $wingetArgs = @(
        'install', '--id', $PackageId, '-e',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
    )
    if ($Force) { $wingetArgs += '--force' }

    $logState = @{ LastSizeTick = 0 }
    $onLine = {
        param([string]$text)
        $level = 'Info'
        if ($text -match '(?i)succ[eè]s|successfully|v[eé]rifi[eé].*succ') { $level = 'Success' }
        elseif ($text -match '(?i)echec|échec|error|failed|1601|1603|1618|0x80070424') { $level = 'Error' }
        elseif ($text -match '(?i)avertissement|warning|attention') { $level = 'Warn' }

        $dl = Get-WingetDownloadProgressFromText -Text $text
        if ($dl) {
            $now = [Environment]::TickCount
            if ((($now - [int]$logState.LastSizeTick) -gt 1500) -or ($dl.Percent -ge 99)) {
                $logState.LastSizeTick = $now
                Write-EngineLog -Message ($DisplayName + ' — ' + $dl.Label) -Level Info -OnLog $OnLog
            }
            if ($OnProgress -and $Total -gt 0) {
                $overall = [math]::Round((100.0 * ($Step - 1) / $Total) + ($dl.Percent / $Total))
                & $OnProgress @{
                    Step            = $Step
                    Total           = $Total
                    Name            = $DisplayName
                    Percent         = $overall
                    Indeterminate   = $false
                    Detail          = $dl.Label
                    SizeTotalBytes  = $dl.TotalBytes
                    SizeDoneBytes   = $dl.DownloadedBytes
                    SizeRemainBytes = $dl.RemainingBytes
                    DownloadPercent = $dl.Percent
                }
            }
            return
        }

        # Lignes utiles hors barre de progression (spinners / barres vides)
        if ($text -match '^[█▉▊▋▌▍▎▏▒▓\s\-\\|/]+$' ) { return }
        if ($text -match '(?i)^\s*\d{1,3}\s*%\s*$') {
            if ($OnProgress -and $text -match '(\d{1,3})\s*%') {
                $localPct = [int]$Matches[1]
                if ($localPct -ge 0 -and $localPct -le 100 -and $Total -gt 0) {
                    $overall = [math]::Round((100.0 * ($Step - 1) / $Total) + ($localPct / $Total))
                    & $OnProgress @{ Step = $Step; Total = $Total; Name = $DisplayName; Percent = $overall; Indeterminate = $false; Detail = "$localPct % winget" }
                }
            }
            return
        }

        Write-EngineLog -Message $text -Level $level -OnLog $OnLog
        if ($OnProgress -and $text -match '(\d{1,3})\s*%') {
            $localPct = [int]$Matches[1]
            if ($localPct -ge 0 -and $localPct -le 100 -and $Total -gt 0) {
                $overall = [math]::Round((100.0 * ($Step - 1) / $Total) + ($localPct / $Total))
                & $OnProgress @{ Step = $Step; Total = $Total; Name = $DisplayName; Percent = $overall; Indeterminate = $false; Detail = "$localPct % winget" }
            }
        }
    }.GetNewClosure()

    $r = Invoke-NativeCommandStreaming -FileName $exe -ArgumentList $wingetArgs -OnLine $onLine
    $combined = ($r.Lines -join "`n")

    $msiCode = $null
    if ($combined -match '(?i)code de sortie\s*:?\s*(\d+)') {
        $msiCode = [int]$Matches[1]
    }
    elseif ($combined -match '(?i)exit\s*code\s*:?\s*(\d+)') {
        $msiCode = [int]$Matches[1]
    }

    $code = [int]$r.ExitCode
    if ($code -eq 0 -or $code -eq -1978335189) {
        Write-EngineLog -Message ($DisplayName + ' installe avec succes.') -Level Success -OnLog $OnLog
        if ($OnProgress -and $Total -gt 0) {
            $pct = [math]::Round(100.0 * $Step / $Total)
            & $OnProgress @{ Step = $Step; Total = $Total; Name = $DisplayName; Percent = $pct; Indeterminate = $false; Detail = 'OK' }
        }
        return 'Success'
    }

    Write-EngineLog -Message ($DisplayName + ' a echoue (code winget ' + $code + ').') -Level Error -OnLog $OnLog
    if ($null -ne $msiCode) {
        Write-EngineLog -Message ("Code MSI detecte : $msiCode") -Level Error -OnLog $OnLog
    }
    $hintCode = if ($null -ne $msiCode) { $msiCode } else { $code }
    foreach ($h in (Get-InstallFailureHint -ExitCode $hintCode -CombinedOutput $combined)) {
        Write-EngineLog -Message $h -Level Warn -OnLog $OnLog
    }
    if ($OnProgress -and $Total -gt 0) {
        $pct = [math]::Round(100.0 * $Step / $Total)
        & $OnProgress @{ Step = $Step; Total = $Total; Name = $DisplayName; Percent = $pct; Indeterminate = $false; Detail = 'Echec' }
    }
    return 'Failed'
}
function Find-AdbDirectory {
    $candidates = [System.Collections.Generic.List[string]]::new()

    $wingetRoots = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
        (Join-Path $env:ProgramFiles 'WinGet\Packages')
    )
    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf86) { $wingetRoots += (Join-Path $pf86 'WinGet\Packages') }

    foreach ($wingetRoot in ($wingetRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
        Get-ChildItem -LiteralPath $wingetRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Google.PlatformTools*' } |
            ForEach-Object {
                $pt = Join-Path $_.FullName 'platform-tools'
                if (Test-Path -LiteralPath (Join-Path $pt 'adb.exe')) { [void]$candidates.Add($pt) }
                Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter 'adb.exe' -ErrorAction SilentlyContinue |
                    Select-Object -First 8 |
                    ForEach-Object { [void]$candidates.Add($_.Directory.FullName) }
            }
    }

    foreach ($p in @(
            (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools'),
            (Join-Path $env:USERPROFILE 'AppData\Local\Android\Sdk\platform-tools'),
            (Join-Path $env:LOCALAPPDATA 'Lapwiz\platform-tools'),
            'C:\Android\platform-tools',
            'C:\platform-tools'
        )) {
        if (Test-Path -LiteralPath (Join-Path $p 'adb.exe')) { [void]$candidates.Add($p) }
    }

    foreach ($var in @('ANDROID_HOME', 'ANDROID_SDK_ROOT')) {
        $root = [Environment]::GetEnvironmentVariable($var, 'User')
        if (-not $root) { $root = [Environment]::GetEnvironmentVariable($var, 'Machine') }
        if (-not $root) { $root = [Environment]::GetEnvironmentVariable($var, 'Process') }
        if ($root) {
            $pt = Join-Path $root 'platform-tools'
            if (Test-Path -LiteralPath (Join-Path $pt 'adb.exe')) { [void]$candidates.Add($pt) }
        }
    }

    return ($candidates | Select-Object -Unique | Select-Object -First 1)
}

function Wait-AdbDirectory {
    param([int]$TimeoutSeconds = 90, [scriptblock]$OnLog)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $attempt = 0
    while ((Get-Date) -lt $deadline) {
        $attempt++
        $dir = Find-AdbDirectory
        if ($dir) { return $dir }
        if ($OnLog -and ($attempt % 3 -eq 1)) {
            Write-EngineLog -Message ("Attente platform-tools (essai $attempt)...") -Level Info -OnLog $OnLog
        }
        Start-Sleep -Seconds 2
    }
    return $null
}

function Publish-EnvironmentChange {
    try {
        if (-not ('LapwizEnvBroadcast' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LapwizEnvBroadcast {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
  public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
  public static void Broadcast() {
    UIntPtr result = UIntPtr.Zero;
    SendMessageTimeout((IntPtr)0xffff, 0x001A, UIntPtr.Zero, "Environment", 2, 5000, out result);
  }
}
'@ -Language CSharp -ErrorAction Stop
        }
        [LapwizEnvBroadcast]::Broadcast()
        return $true
    }
    catch {
        return $false
    }
}

function Install-StableAdbCopy {
    param([Parameter(Mandatory)][string]$SourceDir, [scriptblock]$OnLog)
    $stableRoot = Join-Path $env:LOCALAPPDATA 'Lapwiz\platform-tools'
    try {
        $parent = Split-Path $stableRoot -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $stableRoot)) {
            New-Item -ItemType Directory -Path $stableRoot -Force | Out-Null
        }
        Write-EngineLog -Message ("Copie stable ADB vers " + $stableRoot + " ...") -Level Info -OnLog $OnLog
        Copy-Item -Path (Join-Path $SourceDir '*') -Destination $stableRoot -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath (Join-Path $stableRoot 'adb.exe')) {
            return $stableRoot
        }
    }
    catch {
        Write-EngineLog -Message ("Copie stable ADB impossible, chemin d origine : " + $_) -Level Warn -OnLog $OnLog
    }
    return $SourceDir
}

function Add-PathEntry {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [ValidateSet('User', 'Machine')]
        [string]$Scope = 'User'
    )

    $target = if ($Scope -eq 'Machine') {
        [EnvironmentVariableTarget]::Machine
    }
    else {
        [EnvironmentVariableTarget]::User
    }

    $current = [Environment]::GetEnvironmentVariable('Path', $target)
    if ([string]::IsNullOrWhiteSpace($current)) { $current = '' }

    $resolved = Resolve-Path -LiteralPath $Directory -ErrorAction SilentlyContinue
    if ($resolved) { $Directory = $resolved.Path }
    $normalized = $Directory.TrimEnd('\')

    $parts = $current -split ';' | Where-Object { $_ -and $_.Trim() }
    $exists = $parts | Where-Object { $_.TrimEnd('\') -ieq $normalized }
    if ($exists) { return $false }

    $newPath = if ($current.TrimEnd(';')) { ($current.TrimEnd(';') + ';' + $Directory) } else { $Directory }
    [Environment]::SetEnvironmentVariable('Path', $newPath, $target)

    if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $normalized })) {
        $env:Path = $env:Path + ';' + $Directory
    }
    return $true
}

function Set-AndroidHomeIfNeeded {
    param([Parameter(Mandatory)][string]$PlatformToolsDir, [scriptblock]$OnLog)
    $sdkRoot = Split-Path -Parent $PlatformToolsDir
    $leaf = Split-Path -Leaf $sdkRoot
    if ($leaf -ine 'Sdk' -and $leaf -ine 'Android') { return }

    foreach ($scope in @('User', 'Machine')) {
        if ($scope -eq 'Machine' -and -not (Test-IsAdministrator)) { continue }
        $target = [Enum]::Parse([EnvironmentVariableTarget], $scope)
        $existing = [Environment]::GetEnvironmentVariable('ANDROID_HOME', $target)
        if (-not $existing) {
            [Environment]::SetEnvironmentVariable('ANDROID_HOME', $sdkRoot, $target)
            [Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', $sdkRoot, $target)
            Write-EngineLog -Message ("ANDROID_HOME ($scope) = " + $sdkRoot) -Level Success -OnLog $OnLog
        }
    }
    $env:ANDROID_HOME = $sdkRoot
    $env:ANDROID_SDK_ROOT = $sdkRoot
}

function Set-AdbPath {
    param(
        [scriptblock]$OnLog,
        [scriptblock]$OnProgress,
        [switch]$WaitForInstall
    )

    if ($OnProgress) {
        & $OnProgress @{ Name = 'PATH ADB'; Phase = 'adb'; Indeterminate = $true; Detail = 'Recherche adb...' }
    }

    Write-EngineLog -Message 'Configuration automatique du PATH ADB (sans action manuelle)...' -Level Info -OnLog $OnLog

    $dir = if ($WaitForInstall) {
        Wait-AdbDirectory -TimeoutSeconds 90 -OnLog $OnLog
    }
    else {
        Find-AdbDirectory
    }

    if (-not $dir) {
        Write-EngineLog -Message 'platform-tools introuvable. Installez Google.PlatformTools puis cliquez PATH ADB auto.' -Level Error -OnLog $OnLog
        return $false
    }

    Write-EngineLog -Message ('adb source : ' + $dir) -Level Success -OnLog $OnLog
    $stable = Install-StableAdbCopy -SourceDir $dir -OnLog $OnLog

    if (Add-PathEntry -Directory $stable -Scope User) {
        Write-EngineLog -Message ('PATH utilisateur : ajoute ' + $stable) -Level Success -OnLog $OnLog
    }
    else {
        Write-EngineLog -Message 'PATH utilisateur : deja present.' -Level Warn -OnLog $OnLog
    }

    if (Test-IsAdministrator) {
        if (Add-PathEntry -Directory $stable -Scope Machine) {
            Write-EngineLog -Message ('PATH machine : ajoute ' + $stable) -Level Success -OnLog $OnLog
        }
        else {
            Write-EngineLog -Message 'PATH machine : deja present.' -Level Warn -OnLog $OnLog
        }
    }

    Set-AndroidHomeIfNeeded -PlatformToolsDir $stable -OnLog $OnLog

    if (Publish-EnvironmentChange) {
        Write-EngineLog -Message 'Notification Windows (Explorer) envoyee pour le PATH.' -Level Success -OnLog $OnLog
    }
    else {
        Write-EngineLog -Message 'Broadcast PATH non critique echoue.' -Level Warn -OnLog $OnLog
    }

    $adb = Join-Path $stable 'adb.exe'
    try {
        $ver = & $adb version 2>&1 | Select-Object -First 1
        Write-EngineLog -Message ('Verification auto : ' + $ver) -Level Success -OnLog $OnLog
        Write-EngineLog -Message 'PATH ADB configure automatiquement.' -Level Success -OnLog $OnLog
    }
    catch {
        Write-EngineLog -Message ('adb trouve mais non executable : ' + $_) -Level Warn -OnLog $OnLog
    }

    if ($OnProgress) {
        & $OnProgress @{ Name = 'PATH ADB'; Phase = 'adb'; Indeterminate = $false; Percent = 100; Detail = 'PATH ADB OK' }
    }
    return $true
}

function Get-DotNetStatus {
    param([scriptblock]$OnLog)
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        Write-EngineLog -Message 'dotnet non trouve dans le PATH (normal avant installation).' -Level Warn -OnLog $OnLog
        return
    }
    try {
        Write-EngineLog -Message 'Runtimes .NET :' -Level Info -OnLog $OnLog
        & dotnet --list-runtimes 2>&1 | ForEach-Object { Write-EngineLog -Message ("  " + $_) -Level Info -OnLog $OnLog }
        Write-EngineLog -Message 'SDKs .NET :' -Level Info -OnLog $OnLog
        & dotnet --list-sdks 2>&1 | ForEach-Object { Write-EngineLog -Message ("  " + $_) -Level Info -OnLog $OnLog }
    }
    catch {
        Write-EngineLog -Message ("Impossible de lister .NET : " + $_) -Level Warn -OnLog $OnLog
    }
}

function Install-UrlPackage {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Url,
        [string]$PackageId = '',
        [switch]$RunAfterDownload,
        [scriptblock]$OnLog,
        [scriptblock]$OnProgress,
        [int]$Step = 0,
        [int]$Total = 1
    )

    Write-EngineLog -Message ("Telechargement de {0}..." -f $DisplayName) -Level Info -OnLog $OnLog
    if ($OnProgress) {
        $basePct = if ($Total -gt 0) { [math]::Round(100.0 * ([math]::Max(0, $Step - 1)) / $Total) } else { 0 }
        & $OnProgress @{ Step = $Step; Total = $Total; Name = $DisplayName; Percent = $basePct; Indeterminate = $true; Detail = 'Telechargement URL...' }
    }

    $tools = Join-Path $env:LOCALAPPDATA 'Lapwiz\tools'
    if (-not (Test-Path -LiteralPath $tools)) {
        New-Item -ItemType Directory -Path $tools -Force | Out-Null
    }
    $leaf = [IO.Path]::GetFileName(([Uri]$Url).AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        $leaf = if ($PackageId) { ($PackageId -replace '[^A-Za-z0-9._-]', '_') + '.exe' } else { 'download.exe' }
    }
    $dest = Join-Path $tools $leaf

    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers['User-Agent'] = 'LapwizSetup/1.0'
        try {
            $wc.DownloadFile($Url, $dest)
        }
        finally { $wc.Dispose() }

        if (-not (Test-Path -LiteralPath $dest) -or ((Get-Item -LiteralPath $dest).Length -lt 1024)) {
            throw 'Fichier telecharge invalide ou trop petit.'
        }
        $size = (Get-Item -LiteralPath $dest).Length
        Write-EngineLog -Message ("Telecharge : {0} ({1})" -f $dest, (Format-ByteSize $size)) -Level Success -OnLog $OnLog

        if ($RunAfterDownload) {
            Write-EngineLog -Message ("Lancement de {0}..." -f $DisplayName) -Level Info -OnLog $OnLog
            Start-Process -FilePath $dest -WorkingDirectory (Split-Path -Parent $dest)
        }

        if ($OnProgress -and $Total -gt 0) {
            $pct = [math]::Round(100.0 * $Step / $Total)
            & $OnProgress @{ Step = $Step; Total = $Total; Name = $DisplayName; Percent = $pct; Indeterminate = $false; Detail = 'OK'; SizeTotalBytes = $size; SizeDoneBytes = $size; SizeRemainBytes = 0 }
        }
        return 'Success'
    }
    catch {
        Write-EngineLog -Message ("Echec telechargement {0} : {1}" -f $DisplayName, $_) -Level Error -OnLog $OnLog
        if ($OnProgress -and $Total -gt 0) {
            $pct = [math]::Round(100.0 * $Step / $Total)
            & $OnProgress @{ Step = $Step; Total = $Total; Name = $DisplayName; Percent = $pct; Indeterminate = $false; Detail = 'Echec' }
        }
        return 'Failed'
    }
}

function Install-LocalPackage {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$LocalPath,
        [scriptblock]$OnLog,
        [scriptblock]$OnProgress,
        [int]$Step = 0,
        [int]$Total = 1
    )

    if (-not (Test-Path -LiteralPath $LocalPath)) {
        Write-EngineLog -Message ("Fichier local introuvable : {0}" -f $LocalPath) -Level Error -OnLog $OnLog
        return 'Failed'
    }

    Write-EngineLog -Message ("Lancement installateur local : {0}" -f $LocalPath) -Level Info -OnLog $OnLog
    if ($OnProgress) {
        $basePct = if ($Total -gt 0) { [math]::Round(100.0 * ([math]::Max(0, $Step - 1)) / $Total) } else { 0 }
        & $OnProgress @{ Step = $Step; Total = $Total; Name = $DisplayName; Percent = $basePct; Indeterminate = $true; Detail = 'Installateur local...' }
    }

    try {
        $ext = [IO.Path]::GetExtension($LocalPath).ToLowerInvariant()
        if ($ext -eq '.msi') {
            $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$LocalPath`"", '/passive') -Wait -PassThru
            $code = $p.ExitCode
        }
        else {
            $p = Start-Process -FilePath $LocalPath -Wait -PassThru
            $code = $p.ExitCode
        }
        if ($null -eq $code -or $code -eq 0) {
            Write-EngineLog -Message ($DisplayName + ' : installateur local termine.') -Level Success -OnLog $OnLog
            if ($OnProgress -and $Total -gt 0) {
                $pct = [math]::Round(100.0 * $Step / $Total)
                & $OnProgress @{ Step = $Step; Total = $Total; Name = $DisplayName; Percent = $pct; Indeterminate = $false; Detail = 'OK' }
            }
            return 'Success'
        }
        Write-EngineLog -Message ("{0} : code sortie {1}" -f $DisplayName, $code) -Level Error -OnLog $OnLog
        return 'Failed'
    }
    catch {
        Write-EngineLog -Message ("Echec install local {0} : {1}" -f $DisplayName, $_) -Level Error -OnLog $OnLog
        return 'Failed'
    }
}

function Get-PackageInstallMode {
    param([object]$Pkg)
    $prop = $Pkg.PSObject.Properties['installMode']
    if ($null -ne $prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
        return ([string]$prop.Value).Trim().ToLowerInvariant()
    }
    $urlProp = $Pkg.PSObject.Properties['installUrl']
    if ($null -ne $urlProp -and -not [string]::IsNullOrWhiteSpace([string]$urlProp.Value)) { return 'url' }
    $localProp = $Pkg.PSObject.Properties['localPath']
    if ($null -ne $localProp -and -not [string]::IsNullOrWhiteSpace([string]$localProp.Value)) { return 'local' }
    return 'winget'
}

function Invoke-LapwizInstall {
    param(
        [Parameter(Mandatory)]
        [object[]]$Packages,
        [scriptblock]$OnLog,
        [scriptblock]$OnProgress,
        [switch]$RepairMsiexecFirst,
        [switch]$RunSfc,
        [string[]]$ForcePackageIds = @()
    )

    $results = [System.Collections.Generic.List[object]]::new()

    $needAdbPath = $false
    $needsWinget = $false
    foreach ($pkg in $Packages) {
        $postProp = $pkg.PSObject.Properties['postAction']
        if ($null -ne $postProp -and $postProp.Value -eq 'adbPath') {
            $needAdbPath = $true
        }
        if ((Get-PackageInstallMode -Pkg $pkg) -eq 'winget') {
            $needsWinget = $true
        }
    }

    $total = $Packages.Count
    if ($RepairMsiexecFirst) { $total++ }
    if ($needAdbPath) { $total++ }
    $step = 0

    if ($needsWinget -and -not (Test-WingetAvailable -OnLog $OnLog)) {
        return @{ Ok = $false; Results = @(); Message = 'winget indisponible' }
    }

    if ($RepairMsiexecFirst) {
        $step++
        if ($OnProgress) {
            & $OnProgress @{ Step = $step; Total = $total; Name = 'msiexec'; Percent = ([math]::Round(100.0 * $step / $total)); Indeterminate = $true; Detail = 'Reparation msiexec' }
        }
        $ok = Repair-WindowsInstaller -OnLog $OnLog -RunSfc:$RunSfc
        $results.Add([pscustomobject]@{ Name = 'Windows Installer (msiexec)'; Status = $(if ($ok) { 'Success' } else { 'Failed' }) })
        if ($OnProgress) {
            & $OnProgress @{ Step = $step; Total = $total; Name = 'msiexec'; Percent = ([math]::Round(100.0 * $step / $total)); Indeterminate = $false; Detail = 'msiexec OK' }
        }
    }

    $forceSet = @{}
    foreach ($fid in @($ForcePackageIds)) {
        if (-not [string]::IsNullOrWhiteSpace($fid)) { $forceSet[$fid] = $true }
    }

    foreach ($pkg in $Packages) {
        $step++
        $name = [string]$pkg.name
        $id = [string]$pkg.id
        $mode = Get-PackageInstallMode -Pkg $pkg
        $doForce = $forceSet.ContainsKey($id)

        if ($mode -eq 'url') {
            $url = [string]$pkg.installUrl
            $run = $false
            $runProp = $pkg.PSObject.Properties['runAfterDownload']
            if ($null -ne $runProp) { $run = [bool]$runProp.Value }
            $status = Install-UrlPackage -DisplayName $name -Url $url -PackageId $id -RunAfterDownload:$run -OnLog $OnLog -OnProgress $OnProgress -Step $step -Total $total
        }
        elseif ($mode -eq 'local') {
            $status = Install-LocalPackage -DisplayName $name -LocalPath ([string]$pkg.localPath) -OnLog $OnLog -OnProgress $OnProgress -Step $step -Total $total
        }
        else {
            $status = Install-WingetPackage -PackageId $id -DisplayName $name -OnLog $OnLog -OnProgress $OnProgress -Step $step -Total $total -Force:$doForce
        }
        $results.Add([pscustomobject]@{ Name = $name; Id = $id; Status = $status })
    }

    if ($needAdbPath) {
        $step++
        Write-EngineLog -Message 'Etape automatique : configuration PATH ADB...' -Level Info -OnLog $OnLog
        if ($OnProgress) {
            & $OnProgress @{ Step = $step; Total = $total; Name = 'PATH ADB'; Percent = ([math]::Round(100.0 * ($step - 1) / $total)); Indeterminate = $true; Detail = 'Config PATH ADB...' }
        }
        $adbOk = Set-AdbPath -OnLog $OnLog -OnProgress $OnProgress -WaitForInstall
        $results.Add([pscustomobject]@{ Name = 'PATH ADB (auto)'; Status = $(if ($adbOk) { 'Success' } else { 'Failed' }) })
        if ($OnProgress) {
            $detail = if ($adbOk) { 'PATH ADB OK' } else { 'PATH ADB echec' }
            & $OnProgress @{ Step = $step; Total = $total; Name = 'PATH ADB'; Percent = ([math]::Round(100.0 * $step / $total)); Indeterminate = $false; Detail = $detail }
        }
    }

    $dotNetPkgs = @($Packages | Where-Object { $_.id -like 'Microsoft.DotNet.*' })
    if ($dotNetPkgs.Count -gt 0) {
        Get-DotNetStatus -OnLog $OnLog
    }

    $failed = @($results | Where-Object { $_.Status -eq 'Failed' })
    $okCount = @($results | Where-Object { $_.Status -eq 'Success' }).Count
    $skipCount = @($results | Where-Object { $_.Status -eq 'Skipped' }).Count

    Write-EngineLog -Message ("Termine - OK: {0}, ignores: {1}, echecs: {2}" -f $okCount, $skipCount, $failed.Count) -Level $(if ($failed.Count) { 'Warn' } else { 'Success' }) -OnLog $OnLog

    if ($OnProgress) {
        & $OnProgress @{ Step = $total; Total = $total; Name = 'Termine'; Percent = 100; Indeterminate = $false; Detail = 'Termine' }
    }

    return @{
        Ok      = ($failed.Count -eq 0)
        Results = $results
        Message = "OK=$okCount Skip=$skipCount Fail=$($failed.Count)"
    }
}