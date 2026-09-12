#Requires -Version 5.1
<#
.SYNOPSIS
    Detection des dependances (runtime / framework) + toast + telechargement dans dependencies.
#>

function script:Get-LapwizDependenciesDir {
    param([Parameter(Mandatory)][string]$ScriptRoot)
    $preferred = Join-Path $ScriptRoot 'dependencies'
    try {
        if (-not (Test-Path -LiteralPath $preferred)) {
            New-Item -ItemType Directory -Path $preferred -Force | Out-Null
        }
        $probe = Join-Path $preferred '.write-test'
        [System.IO.File]::WriteAllText($probe, 'ok')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $preferred
    }
    catch {
        $fallback = Join-Path $env:LOCALAPPDATA 'LapwizSetup\dependencies'
        if (-not (Test-Path -LiteralPath $fallback)) {
            New-Item -ItemType Directory -Path $fallback -Force | Out-Null
        }
        return $fallback
    }
}

function script:Test-LapwizVcRedist64 {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    )
    foreach ($k in $keys) {
        try {
            if (Test-Path -LiteralPath $k) {
                $v = (Get-ItemProperty -LiteralPath $k -ErrorAction Stop).Installed
                if ([int]$v -eq 1) { return $true }
            }
        }
        catch { }
    }
    # Presence DLL systeme
    $sys = Join-Path $env:SystemRoot 'System32\vcruntime140.dll'
    return (Test-Path -LiteralPath $sys)
}

function script:Test-LapwizDotNet48 {
    try {
        $ndp = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
        if (-not (Test-Path -LiteralPath $ndp)) { return $false }
        $rel = [int](Get-ItemProperty -LiteralPath $ndp -Name Release -ErrorAction Stop).Release
        # 528040 = 4.8 Windows 10 / 528049 4.8
        return ($rel -ge 528040)
    }
    catch {
        return $false
    }
}

function script:Test-LapwizWingetPresent {
    try {
        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        return ($null -ne $cmd)
    }
    catch { return $false }
}

function script:Get-LapwizMissingDependencies {
    <#
    .SYNOPSIS
        Liste les composants manquants (affichage + URL officielle).
    #>
    $missing = New-Object System.Collections.Generic.List[object]

    if (-not (Test-LapwizDotNet48)) {
        [void]$missing.Add([pscustomobject]@{
                Id          = 'dotnet48'
                DisplayName = '.NET Framework 4.8'
                FileName    = 'ndp48-web.exe'
                Url         = 'https://go.microsoft.com/fwlink/?LinkId=2085155'
                Kind        = 'framework'
                Hint        = 'Requis pour WPF / PowerShell UI'
            })
    }

    if (-not (Test-LapwizVcRedist64)) {
        [void]$missing.Add([pscustomobject]@{
                Id          = 'vcredist64'
                DisplayName = 'Visual C++ Redistributable 2015-2022 (x64)'
                FileName    = 'vc_redist.x64.exe'
                Url         = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
                Kind        = 'runtime'
                Hint        = 'DLL natives (outils, scrcpy, etc.)'
            })
    }

    # Assemblies critiques deja charges si l'UI tourne — on verifie quand meme Compression
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    }
    catch {
        [void]$missing.Add([pscustomobject]@{
                Id          = 'compression'
                DisplayName = 'System.IO.Compression.FileSystem'
                FileName    = ''
                Url         = ''
                Kind        = 'assembly'
                Hint        = 'Composant .NET manquant (reparer .NET Framework)'
            })
    }

    if (-not (Test-LapwizWingetPresent)) {
        [void]$missing.Add([pscustomobject]@{
                Id          = 'winget'
                DisplayName = 'winget (App Installer)'
                FileName    = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
                Url         = 'https://aka.ms/getwinget'
                Kind        = 'tool'
                Hint        = 'Necessaire pour le catalogue Store'
            })
    }

    # TLS 1.2 (pas un fichier, mais on le force)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch { }

    return [object[]]@($missing.ToArray())
}

function script:Save-LapwizDependencyFile {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestPath
    )
    $dir = Split-Path -Parent $DestPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = "$DestPath.download"
    try {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'LapwizSetup/1.0')
        $wc.DownloadFile($Url, $tmp)
        if (Test-Path -LiteralPath $DestPath) { Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $tmp -Destination $DestPath -Force
        return $true
    }
    catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
    finally {
        if ($wc) { $wc.Dispose() }
    }
}

function script:Invoke-LapwizDependencyDownloads {
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [object[]]$Items = $null,
        [scriptblock]$OnProgress = $null
    )
    if ($null -eq $Items) {
        $Items = @(Get-LapwizMissingDependencies)
    }
    $dir = Get-LapwizDependenciesDir -ScriptRoot $ScriptRoot
    $ok = 0
    $fail = 0
    foreach ($it in $Items) {
        if ([string]::IsNullOrWhiteSpace([string]$it.Url) -or [string]::IsNullOrWhiteSpace([string]$it.FileName)) {
            if ($OnProgress) { & $OnProgress ("Ignore (pas de fichier) : {0}" -f $it.DisplayName) }
            continue
        }
        $dest = Join-Path $dir ([string]$it.FileName)
        try {
            if ($OnProgress) { & $OnProgress ("Telechargement : {0} ..." -f $it.DisplayName) }
            Save-LapwizDependencyFile -Url ([string]$it.Url) -DestPath $dest
            $ok++
            if ($OnProgress) { & $OnProgress ("OK : $dest") }
        }
        catch {
            $fail++
            if ($OnProgress) { & $OnProgress ("Echec {0} : {1}" -f $it.DisplayName, $_) }
        }
    }
    return [pscustomobject]@{ Ok = $ok; Fail = $fail; Directory = $dir }
}

function script:Set-LapwizTabOrder {
    param([Parameter(Mandatory)]$Window)
    $tabs = $Window.FindName('MainTabs')
    if (-not $tabs) { return }
    $desired = @(
        'TabStore',
        'TabAdbRepair',
        'TabInstall',
        'TabExpiro',
        'TabScripts',
        'TabKvrt',
        'TabSynaptic'
    )
    $byName = @{}
    foreach ($it in @($tabs.Items)) {
        if ($it -and $it.Name) { $byName[[string]$it.Name] = $it }
    }
    $tabs.Items.Clear()
    foreach ($n in $desired) {
        if ($byName.ContainsKey($n)) {
            [void]$tabs.Items.Add($byName[$n])
        }
    }
    # Ajouter tout onglet non liste (avenir)
    foreach ($kv in $byName.GetEnumerator()) {
        if ($desired -notcontains $kv.Key) {
            [void]$tabs.Items.Add($kv.Value)
        }
    }
    if ($tabs.Items.Count -gt 0) {
        $tabs.SelectedIndex = 0
    }
}

function script:Initialize-LapwizDependenciesUi {
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][string]$ScriptRoot
    )

    try { Set-LapwizTabOrder -Window $Window } catch { }

    $toast = $Window.FindName('DepsToast')
    $title = $Window.FindName('TxtDepsToastTitle')
    $body = $Window.FindName('TxtDepsToastBody')
    $btnDl = $Window.FindName('BtnDepsDownload')
    $btnOpen = $Window.FindName('BtnDepsOpenFolder')
    $btnDismiss = $Window.FindName('BtnDepsDismiss')

    $script:LapwizDepsWindow = $Window
    $script:LapwizDepsRoot = $ScriptRoot
    $script:LapwizMissingDeps = @(Get-LapwizMissingDependencies)

    if ($script:LapwizMissingDeps.Count -eq 0) {
        if ($toast) { $toast.Visibility = [System.Windows.Visibility]::Collapsed }
        return
    }

    $names = ($script:LapwizMissingDeps | ForEach-Object { $_.DisplayName }) -join ', '
    $dir = Get-LapwizDependenciesDir -ScriptRoot $ScriptRoot
    if ($title) { $title.Text = ("Dependances manquantes ({0})" -f $script:LapwizMissingDeps.Count) }
    if ($body) {
        $body.Text = "Sur ce PC : $names.`nTelechargement vers : $dir (installez ensuite les .exe telecharges)."
    }
    if ($toast) { $toast.Visibility = [System.Windows.Visibility]::Visible }

    if ($btnDismiss) {
        $btnDismiss.Add_Click({
            $t = $script:LapwizDepsWindow.FindName('DepsToast')
            if ($t) { $t.Visibility = [System.Windows.Visibility]::Collapsed }
        })
    }

    if ($btnOpen) {
        $btnOpen.Add_Click({
            $d = Get-LapwizDependenciesDir -ScriptRoot $script:LapwizDepsRoot
            if (-not (Test-Path -LiteralPath $d)) {
                New-Item -ItemType Directory -Path $d -Force | Out-Null
            }
            Start-Process explorer.exe -ArgumentList $d
        })
    }

    if ($btnDl) {
        $btnDl.Add_Click({
            $btn = $script:LapwizDepsWindow.FindName('BtnDepsDownload')
            $bodyCtrl = $script:LapwizDepsWindow.FindName('TxtDepsToastBody')
            if ($btn) { $btn.IsEnabled = $false }
            try {
                if ($bodyCtrl) { $bodyCtrl.Text = 'Telechargement en cours...' }
                $result = Invoke-LapwizDependencyDownloads -ScriptRoot $script:LapwizDepsRoot `
                    -Items $script:LapwizMissingDeps `
                    -OnProgress {
                        param($msg)
                        $b = $script:LapwizDepsWindow.FindName('TxtDepsToastBody')
                        if ($b) { $b.Text = [string]$msg }
                    }
                if ($bodyCtrl) {
                    $bodyCtrl.Text = ("Termine : {0} OK, {1} echec.`nDossier : {2}`nLancez les installateurs telecharges, puis relancez Lapwiz." -f `
                            $result.Ok, $result.Fail, $result.Directory)
                }
            }
            catch {
                if ($bodyCtrl) { $bodyCtrl.Text = "Erreur telechargement : $_" }
            }
            finally {
                if ($btn) { $btn.IsEnabled = $true }
            }
        })
    }
}