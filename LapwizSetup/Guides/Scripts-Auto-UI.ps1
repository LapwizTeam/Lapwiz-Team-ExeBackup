#Requires -Version 5.1
<#
.SYNOPSIS
    Onglet Scripts — toutes les automatisations (Trend, KVRT, MBAM, Defender, liens).
.NOTES
    Tous les handlers sont try/catch : ErrorAction Stop ne doit pas tuer la fenetre WPF.
#>

function Initialize-ScriptsAutoUi {
    param(
        [Parameter(Mandatory)] $Window,
        [Parameter(Mandatory)][string]$ScriptRoot
    )

    $remPath = Join-Path $ScriptRoot 'Guides\Expiro-Trend-Remediation.ps1'
    if (Test-Path -LiteralPath $remPath) {
        . $remPath
    }

    $script:AutoLastArtifacts = @()

    function script:Write-AutoLog {
        param([string]$Text, [switch]$Append)
        try {
            if (Get-Command Add-UiLog -ErrorAction SilentlyContinue) {
                Add-UiLog -Line $Text -Source 'Scripts'
                return
            }
        }
        catch {
            # Ne jamais faire planter l'UI pour un log
        }
    }

    function script:Start-AutoUrl {
        param([string]$Url)
        try {
            if ([string]::IsNullOrWhiteSpace($Url)) { return }
            Start-Process $Url | Out-Null
            Write-AutoLog "Ouvert : $Url" -Append
        }
        catch {
            try {
                Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'start', '', $Url -WindowStyle Hidden | Out-Null
                Write-AutoLog "Ouvert (fallback) : $Url" -Append
            }
            catch {
                Write-AutoLog "Impossible d'ouvrir : $Url — $($_.Exception.Message)" -Append
                [System.Windows.MessageBox]::Show("Impossible d'ouvrir le lien :`n$Url", 'Lapwiz — Scripts', 'OK', 'Warning') | Out-Null
            }
        }
    }

    function script:Invoke-AutoSafe {
        param([scriptblock]$Action, [string]$Label = 'Action')
        try {
            & $Action
        }
        catch {
            Write-AutoLog "$Label : $($_.Exception.Message)" -Append
            try {
                [System.Windows.MessageBox]::Show("$Label`n$($_.Exception.Message)", 'Lapwiz — Scripts', 'OK', 'Warning') | Out-Null
            }
            catch {}
        }
        finally {
            try { [System.Windows.Input.Mouse]::OverrideCursor = $null } catch {}
        }
    }

    # Clear journal : bouton global a droite (BtnClearConsole)

    $handlers = @{
        BtnAutoAudit = {
            Invoke-AutoSafe -Label 'Audit' -Action {
                Write-AutoLog 'Audit Trend en cours…'
                [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
                if (-not (Get-Command Invoke-ExpiroTrendFullAudit -ErrorAction SilentlyContinue)) {
                    throw 'Module remediation non charge (Invoke-ExpiroTrendFullAudit).'
                }
                $result = Invoke-ExpiroTrendFullAudit
                $script:AutoLastArtifacts = @($result.Artifacts)
                Write-AutoLog $result.Text
            }
        }
        BtnAutoStartup = {
            Invoke-AutoSafe -Label 'Startup' -Action {
                $c = [System.Windows.MessageBox]::Show('Corriger les valeurs Startup detournees ?', 'Lapwiz — Scripts', 'YesNo', 'Question')
                if ($c -ne [System.Windows.MessageBoxResult]::Yes) { return }
                $lines = Repair-ExpiroStartupRegistry
                Write-AutoLog ("=== Startup ===`r`n" + ($lines -join "`r`n")) -Append
            }
        }
        BtnAutoServices = {
            Invoke-AutoSafe -Label 'Services' -Action {
                $c = [System.Windows.MessageBox]::Show('Relancer WinDefend / MsMpSvc / wscsvc / wuauserv ?', 'Lapwiz — Scripts', 'YesNo', 'Question')
                if ($c -ne [System.Windows.MessageBoxResult]::Yes) { return }
                $lines = Repair-ExpiroSecurityServices
                Write-AutoLog ("=== Services ===`r`n" + ($lines -join "`r`n")) -Append
            }
        }
        BtnAutoArtifacts = {
            Invoke-AutoSafe -Label 'Artefacts' -Action {
                $arts = @(Find-ExpiroSuspiciousArtifacts)
                $script:AutoLastArtifacts = $arts
                if ($arts.Count -eq 0) {
                    Write-AutoLog 'Aucun artefact suspect (motifs Trend).' -Append
                    return
                }
                $list = ($arts | ForEach-Object { $_.Path }) -join "`n"
                $c = [System.Windows.MessageBox]::Show("Supprimer $($arts.Count) fichier(s) ?`n`n$list", 'Lapwiz — Scripts', 'YesNo', 'Warning')
                if ($c -ne [System.Windows.MessageBoxResult]::Yes) { return }
                $lines = Remove-ExpiroArtifactPaths -Paths @($arts | ForEach-Object { $_.Path })
                Write-AutoLog ("=== Artefacts ===`r`n" + ($lines -join "`r`n")) -Append
            }
        }
        BtnAutoKvrtDownload = {
            Invoke-AutoSafe -Label 'KVRT DL' -Action {
                Write-AutoLog 'Telechargement KVRT (~120 Mo)…'
                [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
                $path = Install-ExpiroKvrt -Progress { param($m) Write-AutoLog $m -Append }
                Write-AutoLog "OK KVRT : $path" -Append
                [System.Windows.MessageBox]::Show("KVRT pret.`n$path", 'Lapwiz — Scripts', 'OK', 'Information') | Out-Null
            }
        }
        BtnAutoKvrtRun = {
            Invoke-AutoSafe -Label 'KVRT' -Action {
                $path = Get-ExpiroKvrtPath
                if (-not (Test-Path -LiteralPath $path)) {
                    $c = [System.Windows.MessageBox]::Show('KVRT absent. Telecharger maintenant ?', 'Lapwiz — Scripts', 'YesNo', 'Question')
                    if ($c -ne [System.Windows.MessageBoxResult]::Yes) { return }
                    Write-AutoLog 'Telechargement KVRT…'
                    [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
                    $path = Install-ExpiroKvrt
                }
                Start-ExpiroKvrt | Out-Null
                Write-AutoLog "KVRT lance : $path" -Append
            }
        }
        BtnAutoKvrtFolder = {
            Invoke-AutoSafe -Label 'Dossier KVRT' -Action {
                $dir = Split-Path -Parent (Get-ExpiroKvrtPath)
                if (-not (Test-Path -LiteralPath $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                }
                Start-Process explorer.exe $dir | Out-Null
                Write-AutoLog "Dossier : $dir" -Append
            }
        }
        BtnAutoMbam = {
            Invoke-AutoSafe -Label 'MBAM' -Action {
                $existing = Find-ExpiroMalwarebytesExe
                if ($existing) {
                    Start-ExpiroMalwarebytes | Out-Null
                    Write-AutoLog "Malwarebytes lance : $existing" -Append
                    return
                }
                $c = [System.Windows.MessageBox]::Show('Installer Malwarebytes via winget ?', 'Lapwiz — Scripts', 'YesNo', 'Question')
                if ($c -ne [System.Windows.MessageBoxResult]::Yes) {
                    Start-AutoUrl 'https://www.malwarebytes.com/'
                    return
                }
                Write-AutoLog 'winget install Malwarebytes…'
                $code = Install-ExpiroMalwarebytesWinget
                Write-AutoLog "winget exit=$code" -Append
                $exe = Find-ExpiroMalwarebytesExe
                if ($exe) {
                    Start-ExpiroMalwarebytes | Out-Null
                    Write-AutoLog "Lance : $exe" -Append
                }
            }
        }
        BtnAutoDefender = {
            Invoke-AutoSafe -Label 'Defender' -Action {
                $c = [System.Windows.MessageBox]::Show('Lancer un scan complet Microsoft Defender ?', 'Lapwiz — Scripts', 'YesNo', 'Question')
                if ($c -ne [System.Windows.MessageBoxResult]::Yes) { return }
                $msg = Start-ExpiroDefenderFullScan
                Write-AutoLog $msg -Append
            }
        }
        # Liens : toujours via Start-AutoUrl (try/catch) — jamais d'appel nu qui peut crasher sous ErrorAction Stop
        BtnAutoDrWeb       = { Start-AutoUrl 'https://free.drweb.com/livedisk/' }
        BtnAutoRogueKiller = { Start-AutoUrl 'https://www.adlice.com/roguekiller/' }
        BtnAutoAdw         = { Start-AutoUrl 'https://www.malwarebytes.com/adwcleaner' }
        BtnAutoFrst        = { Start-AutoUrl 'https://www.bleepingcomputer.com/download/farbar-recovery-scan-tool/' }
        BtnAutoMbamSite    = { Start-AutoUrl 'https://www.malwarebytes.com/' }
        BtnAutoKvrtHowto   = { Start-AutoUrl 'https://support.kaspersky.com/kvrt2020/howto/15674' }
        BtnAutoWinTips     = { Start-AutoUrl 'https://www.wintips.org/remove-win32-expiro-virus/' }
        BtnAutoTrend       = { Start-AutoUrl 'https://www.trendmicro.com/vinfo/us/threat-encyclopedia/malware/virus.win64.expiro.aa' }
    }

    function script:Register-AutoClick {
        param(
            $Button,
            [scriptblock]$Action
        )
        if (-not $Button -or -not $Action) { return }
        # Copie locale dans la portee de cette fonction = closure stable par bouton
        $sb = $Action
        $Button.Add_Click({
            param($sender, $e)
            try {
                & $sb
            }
            catch {
                Write-AutoLog "Erreur : $($_.Exception.Message)" -Append
            }
        }.GetNewClosure())
    }

    foreach ($name in @($handlers.Keys)) {
        Register-AutoClick -Button $Window.FindName($name) -Action $handlers[$name]
    }

    try {
        if (Get-Command Get-ExpiroKvrtPath -ErrorAction SilentlyContinue) {
            $p = Get-ExpiroKvrtPath
            if (Test-Path -LiteralPath $p) {
                $len = [math]::Round((Get-Item -LiteralPath $p).Length / 1MB, 1)
                Write-AutoLog "KVRT present ($len Mo) : $p"
            }
            else {
                Write-AutoLog 'Pret. Aucun KVRT local — utilise Telecharger KVRT si besoin.'
            }
        }
        else {
            Write-AutoLog 'Pret. (Module remediation a recharger si commandes manquent.)'
        }
    }
    catch {
        Write-AutoLog 'Pret.'
    }
}
