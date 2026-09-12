#Requires -Version 5.1
<#
.SYNOPSIS
    Lapwiz Setup - interface graphique d'installation via winget.
.DESCRIPTION
    Lance une fenêtre WPF pour installer WinRAR, 7-Zip, Android Studio, Node.js,
    Java, ADB, Notepad++, Python, .NET, et réparer Windows Installer (msiexec).
    Relancer en administrateur si nécessaire.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) { $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ScriptRoot = $ScriptRoot
$script:LapwizBitmapCache = @{}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Auto-élévation UAC (sauf diagnostic)
if (-not (Test-IsAdministrator) -and $env:LAPWIZ_SKIP_ELEVATION -ne '1') {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.Verb = 'runas'
    try {
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    }
    catch {
        Write-Host "Élévation annulée. Relancez en tant qu'administrateur." -ForegroundColor Yellow
    }
    exit 0
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

# Contexte runspace (requis pour certains callbacks WPF)
$script:LapwizRunspace = [Runspace]::DefaultRunspace

function script:Invoke-LapwizUi {
    param([scriptblock]$Action)
    if ($null -eq $Action) { return }
    if ($null -ne $window -and $window.Dispatcher -and -not $window.Dispatcher.CheckAccess()) {
        # Eviter [Action]{ PS } depuis un autre thread (GetContextFromTLS / crash natif)
        return
    }
    & $Action
}

# Verification integrite release (si RELEASE-SHA256.txt present)
$integrityModule = Join-Path $ScriptRoot 'Guides\Lapwiz-Integrity.ps1'
if (Test-Path -LiteralPath $integrityModule) {
    . $integrityModule
    try {
        $integrity = Test-LapwizIntegrity -ScriptRoot $ScriptRoot
        if (-not $integrity.Skipped -and -not $integrity.Ok) {
            $choice = [System.Windows.MessageBox]::Show(
                ($integrity.Message + "`n`nContinuer quand meme ? (deconseille sur PC suspect)"),
                'Lapwiz Setup — Integrite',
                'YesNo',
                'Warning'
            )
            if ($choice -ne [System.Windows.MessageBoxResult]::Yes) {
                exit 2
            }
        }
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "Verification integrite impossible : $($_.Exception.Message)",
            'Lapwiz Setup',
            'OK',
            'Warning'
        ) | Out-Null
    }
}

. (Join-Path $ScriptRoot 'Install-Engine.ps1')

$catalogMod = Join-Path $ScriptRoot 'Guides\Package-Catalog.ps1'
if (-not (Test-Path -LiteralPath $catalogMod)) {
    throw "Module manquant : Guides\Package-Catalog.ps1"
}
. $catalogMod
$iconsMod = Join-Path $ScriptRoot 'Guides\Package-Icons.ps1'
if (Test-Path -LiteralPath $iconsMod) { . $iconsMod }
$i18nMod = Join-Path $ScriptRoot 'Guides\Lapwiz-I18n.ps1'
if (Test-Path -LiteralPath $i18nMod) { . $i18nMod }

$packagesPath = Join-Path $ScriptRoot 'packages.json'
if (-not (Test-Path -LiteralPath $packagesPath)) {
    throw "Fichier packages.json introuvable : $packagesPath"
}
$script:PackagesPath = $packagesPath
# Ne pas envelopper avec @() : Read-* utilise -NoEnumerate (sinon tableau imbrique PS 5.1)
$script:OfficialPackages = Read-OfficialPackages -PackagesPath $script:PackagesPath
$script:UserPackages = Read-UserPackages
$Packages = Merge-LapwizPackages -Official $script:OfficialPackages -User $script:UserPackages

# Charger XAML : résoudre Source relatif App.xaml via BaseUri
$mainXamlPath = Join-Path $ScriptRoot 'MainWindow.xaml'
$appXamlPath = Join-Path $ScriptRoot 'App.xaml'

function Import-XamlWindow {
    param([string]$WindowPath, [string]$ResourcesPath)

    $context = [System.Windows.Markup.ParserContext]::new()
    try {
        $dummyFull = [IO.Path]::GetFullPath((Join-Path $ScriptRoot 'dummy.xaml'))
        $context.BaseUri = [Uri]::new(('file:///' + ($dummyFull -replace '\\', '/')))
    }
    catch { }

    # Charger d'abord les ressources, puis la fenêtre sans Source externe
    $resStream = [IO.File]::OpenRead($ResourcesPath)
    try {
        $resources = [Windows.Markup.XamlReader]::Load($resStream)
    }
    finally {
        $resStream.Close()
    }

    $xaml = Get-Content -LiteralPath $WindowPath -Raw -Encoding UTF8
    # Retirer MergedDictionaries Source pour injection manuelle (évite problèmes BaseUri)
    $xaml = $xaml -replace '(?s)<Window\.Resources>.*?</Window\.Resources>', ''
    $stringReader = [IO.StringReader]::new($xaml)
    $xmlReader = [Xml.XmlReader]::Create($stringReader)
    try {
        $window = [Windows.Markup.XamlReader]::Load($xmlReader)
    }
    finally {
        $xmlReader.Close()
        $stringReader.Close()
    }

    $window.Resources = [System.Windows.ResourceDictionary]::new()
    if ($resources -is [System.Windows.ResourceDictionary]) {
        [void]$window.Resources.MergedDictionaries.Add($resources)
    }
    return $window
}

$window = Import-XamlWindow -WindowPath $mainXamlPath -ResourcesPath $appXamlPath

function Get-LapwizBitmapFromFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$DecodePixelWidth = 0
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    if (-not $script:LapwizBitmapCache) {
        $script:LapwizBitmapCache = @{}
    }
    $cacheKey = ((Resolve-Path -LiteralPath $Path).Path + '|' + $DecodePixelWidth).ToLowerInvariant()
    if ($script:LapwizBitmapCache.ContainsKey($cacheKey)) {
        return $script:LapwizBitmapCache[$cacheKey]
    }

    try {
        # Norme WPF : OnLoad + Freeze ; ne pas disposer le stream avant Freeze
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 32) { return $null }
        $ms = [System.IO.MemoryStream]::new($bytes)
        try {
            $bi = New-Object System.Windows.Media.Imaging.BitmapImage
            $bi.BeginInit()
            $bi.StreamSource = $ms
            $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bi.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
            if ($DecodePixelWidth -gt 0) {
                $bi.DecodePixelWidth = $DecodePixelWidth
            }
            $bi.EndInit()
            if ($bi.CanFreeze) { $bi.Freeze() }
            $script:LapwizBitmapCache[$cacheKey] = $bi
            return $bi
        }
        finally {
            $ms.Dispose()
        }
    }
    catch {
        try {
            $full = (Resolve-Path -LiteralPath $Path).Path
            $uri = [Uri]::new(('file:///' + ($full -replace '\\', '/')))
            $bi2 = New-Object System.Windows.Media.Imaging.BitmapImage
            $bi2.BeginInit()
            $bi2.UriSource = $uri
            $bi2.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bi2.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
            if ($DecodePixelWidth -gt 0) {
                $bi2.DecodePixelWidth = $DecodePixelWidth
            }
            $bi2.EndInit()
            if ($bi2.CanFreeze) { $bi2.Freeze() }
            $script:LapwizBitmapCache[$cacheKey] = $bi2
            return $bi2
        }
        catch {
            return $null
        }
    }
}

function Write-LapwizCrashLog {
    param([string]$Stage, [string]$Detail)
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'LapwizSetup'
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $line = ('[{0}] {1} | {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Stage, $Detail)
        Add-Content -LiteralPath (Join-Path $dir 'crash.log') -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch { }
}

function Set-LapwizAppChrome {
    param($Win)
    try {
        $iconPng = Join-Path $ScriptRoot 'assets\lapwiz-logo.png'
        $iconIco = Join-Path $ScriptRoot 'assets\lapwiz.ico'

        # Norme WPF Window.Icon :
        # - preferer .ico multi-tailles (16/32/48/256) via BitmapFrame Uri
        # - sinon PNG HD en BitmapFrame (pas BitmapImage seul — barre titre / taskbar)
        $iconSet = $false
        if (Test-Path -LiteralPath $iconIco) {
            try {
                $fullIco = (Resolve-Path -LiteralPath $iconIco).Path
                $uri = [Uri]::new(('file:///' + ($fullIco -replace '\\', '/')))
                $frame = [System.Windows.Media.Imaging.BitmapFrame]::Create(
                    $uri,
                    [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
                    [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                )
                if ($frame -and $frame.PixelWidth -gt 0) {
                    $Win.Icon = $frame
                    $iconSet = $true
                }
            }
            catch {
                Write-LapwizCrashLog -Stage 'Set-LapwizAppChrome-ico' -Detail ([string]$_)
            }
        }
        if (-not $iconSet) {
            $bmp = Get-LapwizBitmapFromFile -Path $iconPng -DecodePixelWidth 256
            if ($bmp) {
                try {
                    $Win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($bmp)
                    $iconSet = $true
                }
                catch {
                    try { $Win.Icon = $bmp; $iconSet = $true } catch {}
                }
            }
        }

        $brand = $Win.FindName('BrandLogo')
        if ($brand) {
            # Logo UI : PNG decode a 128 (net HiDPI), jamais l'ICO 16px
            $logo = Get-LapwizBitmapFromFile -Path $iconPng -DecodePixelWidth 128
            if (-not $logo -and (Test-Path -LiteralPath $iconIco)) {
                $logo = Get-LapwizBitmapFromFile -Path $iconIco -DecodePixelWidth 128
            }
            if ($logo) {
                $brand.Source = $logo
                $brand.Stretch = [System.Windows.Media.Stretch]::Uniform
                [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($brand, 'HighQuality')
                $brand.Visibility = [System.Windows.Visibility]::Visible
            }
        }

        $Win.ShowInTaskbar = $true
    }
    catch {
        Write-LapwizCrashLog -Stage 'Set-LapwizAppChrome' -Detail ([string]$_)
    }
}

Set-LapwizAppChrome -Win $window
# Pas de add_Loaded : callback WPF peut planter (GetContextFromTLS) au ShowDialog

$packageList = $window.FindName('PackageList')
$btnSelectAll = $window.FindName('BtnSelectAll')
$btnSelectNone = $window.FindName('BtnSelectNone')
$btnRepairMsiexec = $window.FindName('BtnRepairMsiexec')
$btnAdbPath = $window.FindName('BtnAdbPath')
$btnInstall = $window.FindName('BtnInstall')
$chkRepairFirst = $window.FindName('ChkRepairFirst')
$txtStatus = $window.FindName('TxtStatus')
$txtProgress = $window.FindName('TxtProgress')
$txtStepDetail = $window.FindName('TxtStepDetail')
$progressBar = $window.FindName('ProgressBar')
$txtLog = $window.FindName('TxtLog')
$txtAddAppQuery = $window.FindName('TxtAddAppQuery')
$btnSearchApp = $window.FindName('BtnSearchApp')
$lstWingetHits = $window.FindName('LstWingetHits')
$cmbAddCategory = $window.FindName('CmbAddCategory')
$btnAddApp = $window.FindName('BtnAddApp')
$btnRemoveUserApp = $window.FindName('BtnRemoveUserApp')
$btnAddLocalApp = $window.FindName('BtnAddLocalApp')
$cmbLanguage = $window.FindName('CmbLanguage')
$expInstallLog = $window.FindName('ExpInstallLog')
$expAddApp = $window.FindName('ExpAddApp')
$txtLogHint = $window.FindName('TxtLogHint')
$mainTabs = $window.FindName('MainTabs')
$tabStore = $window.FindName('TabStore')
$script:LapwizUi = $null
if (Get-Command Get-LapwizStrings -ErrorAction SilentlyContinue) {
    $script:LapwizUi = Get-LapwizStrings -Lang (Read-LapwizLanguage)
}

# Onglet SynapticRemover
$txtSynapticPath = $window.FindName('TxtSynapticPath')
$txtSynapticStatus = $window.FindName('TxtSynapticStatus')
$btnSynapticAuto = $window.FindName('BtnSynapticAuto')
$btnSynapticInteractive = $window.FindName('BtnSynapticInteractive')
$btnSynapticOpenFolder = $window.FindName('BtnSynapticOpenFolder')
$btnSynapticReports = $window.FindName('BtnSynapticReports')
$btnSynapticVerify = $window.FindName('BtnSynapticVerify')
$btnClearConsole = $window.FindName('BtnClearConsole')

function Get-SynapticRoot {
    $candidates = @(
        (Join-Path $ScriptRoot 'SynapticRemover'),
        (Join-Path (Split-Path $ScriptRoot -Parent) 'SynapticRemover'),
        'C:\Users\switc\Desktop\SynapticRemover'
    )
    foreach ($c in $candidates) {
        $moteur = Join-Path $c 'tools\Moteur-Nettoyage.ps1'
        if (Test-Path -LiteralPath $moteur) { return $c }
    }
    return $null
}

function Add-SynapticLog {
    param([string]$Line)
    if (Get-Command Add-UiLog -ErrorAction SilentlyContinue) {
        Add-UiLog -Line $Line -Source 'Synaptic'
        return
    }
}

function Test-SynapticRemoverBundle {
    $root = Get-SynapticRoot
    $report = [System.Collections.Generic.List[string]]::new()
    if (-not $root) {
        if ($txtSynapticPath) { $txtSynapticPath.Text = 'Introuvable' }
        if ($txtSynapticStatus) {
            $txtSynapticStatus.Text = 'SynapticRemover manquant'
            $txtSynapticStatus.Foreground = $window.TryFindResource('BrushDanger')
        }
        Add-SynapticLog '[Error] Dossier SynapticRemover introuvable.'
        return $false
    }

    if ($txtSynapticPath) { $txtSynapticPath.Text = $root }
    $required = @(
        'Nettoyage-Automatique.bat',
        'Nettoyage-Interactif.bat',
        'tools\Moteur-Nettoyage.ps1',
        'tools\Interface-UI.ps1',
        'tools\Traductions.ps1',
        'tools\Gestion-Rapports.ps1',
        'tools\Actions-Scan.ps1',
        'tools\messages.json',
        'tools\Selectionner-Langue.bat'
    )
    $ok = $true
    foreach ($rel in $required) {
        $full = Join-Path $root $rel
        if (Test-Path -LiteralPath $full) {
            [void]$report.Add("[OK] $rel")
        }
        else {
            $ok = $false
            [void]$report.Add("[MANQUANT] $rel")
        }
    }

    # Parse moteur
    $moteur = Join-Path $root 'tools\Moteur-Nettoyage.ps1'
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($moteur, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) {
        $ok = $false
        [void]$report.Add('[Error] Moteur-Nettoyage.ps1: erreurs de syntaxe')
        foreach ($e in $errs) { [void]$report.Add('  ' + $e.ToString()) }
    }
    else {
        [void]$report.Add('[OK] Moteur-Nettoyage.ps1 parse')
    }

    Add-SynapticLog '-- Verification SynapticRemover --'
    foreach ($line in $report) { Add-SynapticLog $line }

    if ($ok) {
        if ($txtSynapticStatus) {
            $txtSynapticStatus.Text = 'Pret - bundle inclus et valide'
            $txtSynapticStatus.Foreground = $window.TryFindResource('BrushAccentSoft')
        }
        if ($btnSynapticAuto) { $btnSynapticAuto.IsEnabled = $true }
        if ($btnSynapticInteractive) { $btnSynapticInteractive.IsEnabled = $true }
    }
    else {
        if ($txtSynapticStatus) {
            $txtSynapticStatus.Text = 'Probleme detecte - voir journal'
            $txtSynapticStatus.Foreground = $window.TryFindResource('BrushDanger')
        }
    }
    return $ok
}

function Start-SynapticBat {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Auto', 'Interactive')]
        [string]$Mode
    )
    $root = Get-SynapticRoot
    if (-not $root) {
        [System.Windows.MessageBox]::Show('SynapticRemover introuvable.', 'Lapwiz Setup', 'OK', 'Error') | Out-Null
        return
    }
    $bat = if ($Mode -eq 'Auto') {
        Join-Path $root 'Nettoyage-Automatique.bat'
    }
    else {
        Join-Path $root 'Nettoyage-Interactif.bat'
    }
    if (-not (Test-Path -LiteralPath $bat)) {
        [System.Windows.MessageBox]::Show("Fichier manquant:`n$bat", 'Lapwiz Setup', 'OK', 'Error') | Out-Null
        return
    }
    Add-SynapticLog ("Lancement: " + $bat)
    try {
        Start-Process -FilePath $bat -WorkingDirectory $root -Verb RunAs
        Add-SynapticLog '[OK] Console SynapticRemover lancee (Admin).'
        if ($txtSynapticStatus) {
            $txtSynapticStatus.Text = 'SynapticRemover lance dans une console separee'
        }
    }
    catch {
        Add-SynapticLog ("[Error] " + $_)
        [System.Windows.MessageBox]::Show("Lancement annule ou echoue.`n$_", 'Lapwiz Setup', 'OK', 'Warning') | Out-Null
    }
}

# Verification SynapticRemover (apres Add-UiLog — voir plus bas)

# Liste packages groupee par categorie (pattern WPF GroupStyle/Expander moderne)
$script:PackageChecks = [System.Collections.Generic.List[object]]::new()
$script:SelectedPackageId = $null
$script:SelectedPackageSource = ''
$script:WingetSearchHits = @()

$script:CategoryOrder = @('Utilitaires', 'Navigateurs', 'Securite', 'Developpement', 'Mobile', '.NET', 'Autres')

function Get-CategoryIconGlyph {
    param([string]$Category)
    $c = if ($null -eq $Category) { '' } else { $Category.ToLowerInvariant() }
    if ($c -like '*utilitaire*' -or $c -like '*utilit*') { return [char]0xE74C }
    if ($c -like '*navigateur*' -or $c -like '*browser*') { return [char]0xE774 }
    if ($c -like '*securit*' -or $c -like '*security*') { return [char]0xE72E }
    if ($c -like '*developp*' -or $c -like '*develop*') { return [char]0xE943 }
    if ($c -like '*mobile*') { return [char]0xE8EA }
    if ($c -like '*.net*' -or $c -eq '.net') { return [char]0xE8F1 }
    return [char]0xE8A5
}

function Get-CategorySortKey {
    param([string]$Category)
    for ($i = 0; $i -lt $script:CategoryOrder.Count; $i++) {
        if ($Category -ieq $script:CategoryOrder[$i]) { return $i }
    }
    return 100
}

function Get-PackageIconImage {
    param([object]$Pkg)
    try {
        $file = $null
        if (Get-Command Ensure-PackageIconFile -ErrorAction SilentlyContinue) {
            # Pas de telechargement reseau ici (stable UI)
            $file = Ensure-PackageIconFile -Pkg $Pkg
        }

        if (-not $file) {
            $pathProp = $Pkg.PSObject.Properties['iconPath']
            if ($null -ne $pathProp -and -not [string]::IsNullOrWhiteSpace([string]$pathProp.Value)) {
                $abs = [string]$pathProp.Value
                if (Test-Path -LiteralPath $abs) { $file = $abs }
            }
        }
        if (-not $file) {
            $iconProp = $Pkg.PSObject.Properties['icon']
            if ($null -ne $iconProp -and -not [string]::IsNullOrWhiteSpace([string]$iconProp.Value)) {
                $cand = Join-Path (Join-Path $ScriptRoot 'assets\app-icons') ([string]$iconProp.Value)
                if (Test-Path -LiteralPath $cand) { $file = $cand }
            }
        }

        if (-not $file -or -not (Test-Path -LiteralPath $file)) { return $null }
        return (Get-LapwizBitmapFromFile -Path $file -DecodePixelWidth 128)
    }
    catch {
        return $null
    }
}

function Update-PackageTileChrome {
    param(
        [System.Windows.Controls.Border]$Tile,
        [bool]$Selected
    )
    if ($Selected) {
        $Tile.BorderBrush = $window.TryFindResource('BrushAccent')
        $Tile.BorderThickness = [System.Windows.Thickness]::new(2)
        $Tile.Background = $window.TryFindResource('BrushIconChip')
    }
    else {
        $Tile.BorderBrush = $window.TryFindResource('BrushBorderSubtle')
        $Tile.BorderThickness = [System.Windows.Thickness]::new(1)
        $Tile.Background = $window.TryFindResource('BrushBgElevated')
    }
}

function New-PackageTile {
    param([object]$Pkg)

    # Tuile Store moderne (Fluent : icone + titre, densite lisible)
    $tile = New-Object System.Windows.Controls.Border
    $tile.Width = 128
    $tile.MinHeight = 118
    $tile.Margin = [System.Windows.Thickness]::new(5)
    $tile.Padding = [System.Windows.Thickness]::new(10, 10, 10, 8)
    $tile.CornerRadius = [System.Windows.CornerRadius]::new(12)
    $tile.Cursor = [System.Windows.Input.Cursors]::Hand
    $tile.SnapsToDevicePixels = $true

    $root = New-Object System.Windows.Controls.Grid

    $cb = New-Object System.Windows.Controls.CheckBox
    $isSelected = $false
    if ($Pkg.PSObject.Properties['selected']) { $isSelected = [bool]$Pkg.selected }
    $cb.IsChecked = $isSelected
    $cb.HorizontalAlignment = 'Right'
    $cb.VerticalAlignment = 'Top'
    $cb.Margin = [System.Windows.Thickness]::new(0, -2, -2, 0)
    $cb.Tag = $Pkg
    $cb.ToolTip = 'Selectionner pour installer'
    $cb.Foreground = $window.TryFindResource('BrushTextPrimary')
    [System.Windows.Controls.Panel]::SetZIndex($cb, 2)

    $isUser = $false
    $srcProp = $Pkg.PSObject.Properties['source']
    if ($null -ne $srcProp -and [string]$srcProp.Value -ieq 'user') { $isUser = $true }

    $pkgCategory = 'Autres'
    if ($Pkg.PSObject.Properties['category'] -and -not [string]::IsNullOrWhiteSpace([string]$Pkg.category)) {
        $pkgCategory = [string]$Pkg.category
    }
    $pkgName = if ($Pkg.PSObject.Properties['name']) { [string]$Pkg.name } else { '' }
    $pkgId = if ($Pkg.PSObject.Properties['id']) { [string]$Pkg.id } else { '' }
    if ([string]::IsNullOrWhiteSpace($pkgName)) { $pkgName = $pkgId }
    $tile.ToolTip = ($pkgName + "`n" + $pkgId)

    # Bouton supprimer (coin haut-gauche)
    $btnDel = New-Object System.Windows.Controls.Button
    $btnDel.Content = [string]([char]0xE711)
    $btnDel.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe Fluent Icons, Segoe MDL2 Assets')
    $btnDel.FontSize = 10
    $btnDel.Width = 22
    $btnDel.Height = 22
    $btnDel.Padding = [System.Windows.Thickness]::new(0)
    $btnDel.HorizontalAlignment = 'Left'
    $btnDel.VerticalAlignment = 'Top'
    $btnDel.Margin = [System.Windows.Thickness]::new(-4, -4, 0, 0)
    $btnDel.Cursor = [System.Windows.Input.Cursors]::Hand
    $btnDel.ToolTip = if ($isUser) { 'Retirer de la liste (catalogue perso)' } else { 'Retirer de la liste (masquer)' }
    $btnDel.Background = $window.TryFindResource('BrushBgPanel')
    $btnDel.Foreground = $window.TryFindResource('BrushDanger')
    $btnDel.BorderBrush = $window.TryFindResource('BrushBorderSubtle')
    $btnDel.BorderThickness = [System.Windows.Thickness]::new(1)
    [System.Windows.Controls.Panel]::SetZIndex($btnDel, 3)
    $btnDel.Tag = [pscustomobject]@{
        Id     = $pkgId
        Name   = $pkgName
        IsUser = $isUser
    }
    $btnDel.Add_Click({
        $btn = $args[0]
        $t = $btn.Tag
        if (-not $t) { return }
        $src = if ([bool]$t.IsUser) { 'user' } else { '' }
        if (Get-Command Invoke-RemovePackageFromList -ErrorAction SilentlyContinue) {
            Invoke-RemovePackageFromList -Id ([string]$t.Id) -Name ([string]$t.Name) -Source $src
        }
        else {
            [System.Windows.MessageBox]::Show('Action retirer indisponible (fonction manquante).', 'Lapwiz Setup', 'OK', 'Warning') | Out-Null
        }
    })

    if ($isUser) {
        $badge = New-Object System.Windows.Controls.Border
        $badge.HorizontalAlignment = 'Left'
        $badge.VerticalAlignment = 'Bottom'
        $badge.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $badge.Padding = [System.Windows.Thickness]::new(4, 1, 4, 1)
        $badge.Background = $window.TryFindResource('BrushAccent')
        $badge.Margin = [System.Windows.Thickness]::new(-2, 0, 0, -2)
        $badgeTxt = New-Object System.Windows.Controls.TextBlock
        $badgeTxt.Text = if (Get-Command Get-UiString -ErrorAction SilentlyContinue) {
            Get-UiString -Table $script:LapwizUi -Key 'Perso' -Default 'Perso'
        }
        else { 'Perso' }
        $badgeTxt.FontSize = 8
        $badgeTxt.FontWeight = 'SemiBold'
        $badgeTxt.Foreground = $window.TryFindResource('BrushOnAccent')
        $badge.Child = $badgeTxt
        [System.Windows.Controls.Panel]::SetZIndex($badge, 2)
        [void]$root.Children.Add($badge)
    }

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.HorizontalAlignment = 'Stretch'
    $stack.VerticalAlignment = 'Center'

    $iconChip = New-Object System.Windows.Controls.Border
    $iconChip.Width = 48
    $iconChip.Height = 48
    $iconChip.CornerRadius = [System.Windows.CornerRadius]::new(12)
    $iconChip.Background = $window.TryFindResource('BrushIconChip')
    $iconChip.BorderBrush = $window.TryFindResource('BrushBorderSubtle')
    $iconChip.BorderThickness = [System.Windows.Thickness]::new(1)
    $iconChip.HorizontalAlignment = 'Center'
    $iconChip.ClipToBounds = $true
    $iconChip.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0)

    $pkgBitmap = $null
    try { $pkgBitmap = Get-PackageIconImage -Pkg $Pkg } catch { $pkgBitmap = $null }
    if ($pkgBitmap) {
        $img = New-Object System.Windows.Controls.Image
        $img.Source = $pkgBitmap
        $img.Width = 32
        $img.Height = 32
        $img.Stretch = 'Uniform'
        $img.HorizontalAlignment = 'Center'
        $img.VerticalAlignment = 'Center'
        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')
        $iconChip.Child = $img
    }
    else {
        $iconGlyph = New-Object System.Windows.Controls.TextBlock
        $iconGlyph.Text = [string](Get-CategoryIconGlyph -Category $pkgCategory)
        $iconGlyph.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe Fluent Icons, Segoe MDL2 Assets')
        $iconGlyph.FontSize = 20
        $iconGlyph.Foreground = $window.TryFindResource('BrushAccent')
        $iconGlyph.HorizontalAlignment = 'Center'
        $iconGlyph.VerticalAlignment = 'Center'
        $iconChip.Child = $iconGlyph
    }

    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = $pkgName
    $title.FontSize = 12
    $title.FontWeight = 'SemiBold'
    $title.Foreground = $window.TryFindResource('BrushTextPrimary')
    $title.TextAlignment = 'Center'
    $title.TextWrapping = 'Wrap'
    $title.TextTrimming = 'CharacterEllipsis'
    $title.MaxHeight = 32
    $title.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    $title.ToolTip = $pkgName

    [void]$stack.Children.Add($iconChip)
    [void]$stack.Children.Add($title)

    [void]$root.Children.Add($stack)
    [void]$root.Children.Add($cb)
    [void]$root.Children.Add($btnDel)
    $tile.Child = $root

    Update-PackageTileChrome -Tile $tile -Selected ([bool]$cb.IsChecked)

    # Pas de Checked/Unchecked/MouseEnter/Leave : callbacks WPF sans runspace → GetContextFromTLS (crash au ShowDialog)
    $tile.Add_MouseLeftButtonUp({
        $e = $args[1]
        $walk = $e.OriginalSource
        while ($null -ne $walk) {
            if ($walk -is [System.Windows.Controls.CheckBox]) { return }
            if ($walk -is [System.Windows.Controls.Button]) { return }
            if ($walk -eq $tile) { break }
            if ($walk -is [System.Windows.DependencyObject]) {
                $walk = [System.Windows.Media.VisualTreeHelper]::GetParent($walk)
            }
            else { break }
        }
        $cb.IsChecked = -not [bool]$cb.IsChecked
        Update-PackageTileChrome -Tile $tile -Selected ([bool]$cb.IsChecked)
        $script:SelectedPackageId = $pkgId
        $script:SelectedPackageSource = if ($isUser) { 'user' } else { '' }
        if ($btnRemoveUserApp) { $btnRemoveUserApp.IsEnabled = $true }
        $e.Handled = $true
    }.GetNewClosure())

    # Clic direct sur la case : maj chrome sans event Checked
    $cb.Add_Click({
        Update-PackageTileChrome -Tile $tile -Selected ([bool]$cb.IsChecked)
        $script:SelectedPackageId = $pkgId
        $script:SelectedPackageSource = if ($isUser) { 'user' } else { '' }
        if ($btnRemoveUserApp) { $btnRemoveUserApp.IsEnabled = $true }
    }.GetNewClosure())

    return @{ Row = $tile; CheckBox = $cb }
}

function New-CategorySection {
    param(
        [string]$CategoryName,
        [object[]]$Items
    )

    $section = New-Object System.Windows.Controls.StackPanel
    $section.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)

    $header = New-Object System.Windows.Controls.DockPanel
    $header.LastChildFill = $true
    $header.Margin = [System.Windows.Thickness]::new(6, 4, 6, 8)

    $catIcon = New-Object System.Windows.Controls.Border
    $catIcon.Width = 28
    $catIcon.Height = 28
    $catIcon.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $catIcon.Background = $window.TryFindResource('BrushIconChip')
    $catIcon.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
    $catIcon.VerticalAlignment = 'Center'
    $glyph = New-Object System.Windows.Controls.TextBlock
    $glyph.Text = [string](Get-CategoryIconGlyph -Category $CategoryName)
    $glyph.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe Fluent Icons, Segoe MDL2 Assets')
    $glyph.FontSize = 13
    $glyph.Foreground = $window.TryFindResource('BrushAccent')
    $glyph.HorizontalAlignment = 'Center'
    $glyph.VerticalAlignment = 'Center'
    $catIcon.Child = $glyph

    $titleBlock = New-Object System.Windows.Controls.TextBlock
    $titleBlock.Text = if (Get-Command Translate-CategoryName -ErrorAction SilentlyContinue) {
        Translate-CategoryName -Category $CategoryName
    } else { $CategoryName }
    $titleBlock.FontSize = 15
    $titleBlock.FontWeight = 'SemiBold'
    $titleBlock.VerticalAlignment = 'Center'
    $titleBlock.Foreground = $window.TryFindResource('BrushTextPrimary')

    $countBlock = New-Object System.Windows.Controls.TextBlock
    $countFmt = if (Get-Command Get-UiString -ErrorAction SilentlyContinue) {
        Get-UiString -Table $script:LapwizUi -Key 'AppsCount' -Default '{0} apps'
    }
    else { '{0} apps' }
    $countBlock.Text = ($countFmt -f $Items.Count)
    $countBlock.FontSize = 12
    $countBlock.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
    $countBlock.VerticalAlignment = 'Center'
    $countBlock.Foreground = $window.TryFindResource('BrushTextMuted')

    $titleRow = New-Object System.Windows.Controls.StackPanel
    $titleRow.Orientation = 'Horizontal'
    [void]$titleRow.Children.Add($titleBlock)
    [void]$titleRow.Children.Add($countBlock)

    [System.Windows.Controls.DockPanel]::SetDock($catIcon, 'Left')
    [void]$header.Children.Add($catIcon)
    [void]$header.Children.Add($titleRow)

    # Grille Store (WrapPanel) — densite type Microsoft Store / Fluent
    $grid = New-Object System.Windows.Controls.WrapPanel
    $grid.Orientation = 'Horizontal'
    $grid.ItemWidth = 138
    $grid.ItemHeight = 130

    foreach ($pkg in ($Items | Sort-Object name)) {
        $built = New-PackageTile -Pkg $pkg
        [void]$grid.Children.Add($built.Row)
        $script:PackageChecks.Add($built.CheckBox)
    }

    [void]$section.Children.Add($header)
    [void]$section.Children.Add($grid)
    return $section
}

function Get-SelectedPackageStates {
    $map = @{}
    foreach ($c in $script:PackageChecks) {
        if ($null -eq $c.Tag) { continue }
        $id = [string]$c.Tag.id
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $map[$id] = [bool]$c.IsChecked
        }
    }
    return $map
}

function script:Invoke-RemovePackageFromList {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Name = '',
        [string]$Source = ''
    )
    if ([string]::IsNullOrWhiteSpace($Id)) { return }
    $label = if ($Name) { $Name } else { $Id }
    $isUser = ($Source -ieq 'user')
    $msg = if ($isUser) {
        "Retirer « $label » du catalogue personnel ?"
    }
    else {
        "Retirer « $label » de la liste ?`n(L'app officielle sera masquee ; packages.json n'est pas modifie.)"
    }
    $confirm = [System.Windows.MessageBox]::Show($msg, 'Lapwiz Setup', 'YesNo', 'Question')
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    try {
        if (Remove-PackageFromList -Id $Id -Source $Source) {
            if (Get-Command Add-UiLog -ErrorAction SilentlyContinue) {
                Add-UiLog ("Retire de la liste : $label ($Id)")
            }
            Rebuild-PackageGrid
            if ($txtStatus) { $txtStatus.Text = "Retire : $label" }
        }
        else {
            [System.Windows.MessageBox]::Show("Impossible de retirer « $label ».", 'Lapwiz Setup', 'OK', 'Warning') | Out-Null
        }
    }
    catch {
        if (Get-Command Add-UiLog -ErrorAction SilentlyContinue) {
            Add-UiLog ("[Error] Retrait : $_") 'Error'
        }
        [System.Windows.MessageBox]::Show("Erreur retrait.`n$_", 'Lapwiz Setup', 'OK', 'Warning') | Out-Null
    }
}

function Rebuild-PackageGrid {
    param([hashtable]$PreserveSelection = $null)

    if (-not $packageList) { return }

    if ($null -eq $PreserveSelection) {
        $PreserveSelection = Get-SelectedPackageStates
    }

    # Recharger le catalogue officiel depuis le disque (evite tableaux imbriqués / etat stale)
    # Sans @() autour de Read-*/Merge-* (NoEnumerate)
    $script:OfficialPackages = Read-OfficialPackages -PackagesPath $script:PackagesPath
    $script:UserPackages = Read-UserPackages
    $script:Packages = Merge-LapwizPackages -Official $script:OfficialPackages -User $script:UserPackages
    $Packages = $script:Packages

    foreach ($pkg in $Packages) {
        $id = [string]$pkg.id
        if ($PreserveSelection.ContainsKey($id)) {
            $pkg.selected = [bool]$PreserveSelection[$id]
        }
    }

    # S'assurer que chaque app a une icone en cache (ne disparait plus apres rebuild / langue)
    if (Get-Command Ensure-PackageIconFile -ErrorAction SilentlyContinue) {
        foreach ($pkg in $Packages) {
            try {
                $iconFile = Ensure-PackageIconFile -Pkg $pkg
                if ($iconFile) {
                    $isUser = $false
                    $srcProp = $pkg.PSObject.Properties['source']
                    if ($null -ne $srcProp -and [string]$srcProp.Value -ieq 'user') { $isUser = $true }
                    if ($isUser -and (Get-Command Update-UserPackageIconMeta -ErrorAction SilentlyContinue)) {
                        $hasIcon = $pkg.PSObject.Properties['icon'] -and -not [string]::IsNullOrWhiteSpace([string]$pkg.icon)
                        $hasPath = $pkg.PSObject.Properties['iconPath'] -and -not [string]::IsNullOrWhiteSpace([string]$pkg.iconPath)
                        if (-not $hasIcon -or -not $hasPath) {
                            $null = Update-UserPackageIconMeta -Id ([string]$pkg.id) -IconPath $iconFile `
                                -Icon (Get-SafeIconFileName -Id ([string]$pkg.id))
                        }
                    }
                }
            }
            catch { }
        }
    }

    $packageList.Children.Clear()
    $script:PackageChecks.Clear()
    $script:SelectedPackageId = $null
    $script:SelectedPackageSource = ''
    if ($btnRemoveUserApp) { $btnRemoveUserApp.IsEnabled = $false }

    if (@($Packages).Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = 'Aucune application dans le catalogue.'
        $empty.FontSize = 14
        $empty.Margin = [System.Windows.Thickness]::new(12)
        $empty.Foreground = $window.TryFindResource('BrushTextMuted')
        [void]$packageList.Children.Add($empty)
        return
    }

    $grouped = $Packages | Group-Object -Property {
        if ($_.PSObject.Properties['category'] -and $_.category) { [string]$_.category } else { 'Autres' }
    }

    $orderedGroups = $grouped | Sort-Object {
        Get-CategorySortKey -Category $_.Name
    }, Name

    foreach ($grp in $orderedGroups) {
        $section = New-CategorySection -CategoryName $grp.Name -Items @($grp.Group)
        [void]$packageList.Children.Add($section)
    }
}

# Langue UI (FR / EN / AR) — avant construction de la grille
if ((Get-Command Apply-LapwizLanguage -ErrorAction SilentlyContinue) -and $cmbLanguage) {
    $lang = Read-LapwizLanguage
    foreach ($item in $cmbLanguage.Items) {
        if ($item -is [System.Windows.Controls.ComboBoxItem] -and [string]$item.Tag -ieq $lang) {
            $cmbLanguage.SelectedItem = $item
            break
        }
    }
    Apply-LapwizLanguage -Window $window -Lang $lang -SkipSave
    # Handler sans GetNewClosure ; erreurs langue ne doivent plus tuer ShowDialog
    $cmbLanguage.Add_DropDownClosed({
        try {
            $item = $cmbLanguage.SelectedItem
            if ($item -isnot [System.Windows.Controls.ComboBoxItem]) { return }
            $code = [string]$item.Tag
            if ([string]::IsNullOrWhiteSpace($code)) { return }
            if ($script:LapwizLastLang -ieq $code) { return }
            $script:LapwizLastLang = $code

            if (Get-Command Apply-LapwizLanguage -ErrorAction SilentlyContinue) {
                Apply-LapwizLanguage -Window $window -Lang $code
            }
            if (Get-Command Rebuild-PackageGrid -ErrorAction SilentlyContinue) {
                Rebuild-PackageGrid
            }
            if (Get-Command Set-LapwizAppChrome -ErrorAction SilentlyContinue) {
                Set-LapwizAppChrome -Win $window
            }
            if (Get-Command Add-UiLog -ErrorAction SilentlyContinue) {
                Add-UiLog ("Langue : $code")
            }
        }
        catch {
            Write-LapwizCrashLog -Stage 'Lang-DropDownClosed' -Detail ([string]$_)
            try {
                [System.Windows.MessageBox]::Show("Changement de langue : $_", 'Lapwiz Setup', 'OK', 'Warning') | Out-Null
            }
            catch { }
        }
    })
    $script:LapwizLastLang = $lang
}

try {
    Rebuild-PackageGrid -PreserveSelection @{}
}
catch {
    Write-LapwizCrashLog -Stage 'Rebuild-PackageGrid' -Detail ([string]$_)
    [System.Windows.MessageBox]::Show("Catalogue Store indisponible : $_", 'Lapwiz Setup', 'OK', 'Warning') | Out-Null
}

function Show-InstallLogPanel {
    param([string]$Hint = 'en cours...')
    if ($txtLogHint) {
        $txtLogHint.Text = $Hint
    }
}

function Get-LapwizUiText {
    param([string]$Key, [string]$Default = '')
    if (Get-Command Get-UiString -ErrorAction SilentlyContinue) {
        return (Get-UiString -Table $script:LapwizUi -Key $Key -Default $Default)
    }
    return $Default
}

function Resolve-UiLogLevel {
    param([string]$Line, [string]$Level = 'Info')
    $detected = if ([string]::IsNullOrWhiteSpace($Level)) { 'Info' } else { $Level }
    if ($Line -match '(?i)\[(Error|Warn|Warning|Success|OK|Info|Critical)\]') {
        $t = $Matches[1]
        if ($t -match '(?i)^OK$') { $detected = 'Success' }
        elseif ($t -match '(?i)^Warning$') { $detected = 'Warn' }
        else { $detected = $t }
    }
    elseif ($Line -match '(?i)1601|0x80070424|msiserver\s+INTROUVABLE|service.*n.?existe\s+pas|CRITICAL|FATAL') {
        $detected = 'Critical'
    }
    elseif ($Line -match '(?i)\[Error\]|\berror\b|a echoue|échoué|echoue|failed|impossible|introuvable|exception') {
        $detected = 'Error'
    }
    elseif ($Line -match '(?i)\[Warn\]|\bwarn(ing)?\b|attention|incomplete|deconseille|skip') {
        $detected = 'Warn'
    }
    elseif ($Line -match '(?i)\[Success\]|\[OK\]|\bok\b|succes|succès|termine|terminé|valide|pret -|ready') {
        $detected = 'Success'
    }
    return $detected
}

function Get-UiLogBrushKey {
    param([string]$Level)
    switch -Regex ($Level) {
        '^(?i)Critical$' { return 'BrushLogCritical' }
        '^(?i)Error$'    { return 'BrushLogError' }
        '^(?i)Warn$'     { return 'BrushLogWarn' }
        '^(?i)Success$'  { return 'BrushLogSuccess' }
        '^(?i)Info$'     { return 'BrushLogInfo' }
        default          { return 'BrushLogText' }
    }
}

function Get-UiLogBadge {
    param([string]$Level)
    switch -Regex ($Level) {
        '^(?i)Critical$' { return 'CRIT' }
        '^(?i)Error$'    { return 'ERR ' }
        '^(?i)Warn$'     { return 'WARN' }
        '^(?i)Success$'  { return 'OK  ' }
        default          { return 'INF ' }
    }
}

function Split-UiLogSegments {
    <# Decoupe une ligne pour colorer codes hex / MSI / exit / SHA. #>
    param([string]$Text, [string]$BodyBrushKey)
    $list = [System.Collections.Generic.List[hashtable]]::new()
    if ([string]::IsNullOrEmpty($Text)) { return $list }
    $rx = [regex]::new('(?i)(0x[0-9A-F]{4,8}|\b(?:1601|1603|1618|1619|1638|3010)\b|\bexit(?:\s*code)?\s*[=:]?\s*\d+|\bcode\s*[=:]?\s*\d+|SHA-?256|[A-F0-9]{8,}(?:\.\.\.)?)')
    $idx = 0
    foreach ($m in $rx.Matches($Text)) {
        if ($m.Index -gt $idx) {
            [void]$list.Add(@{ T = $Text.Substring($idx, $m.Index - $idx); K = $BodyBrushKey; B = $false })
        }
        $codeKey = 'BrushLogCode'
        if ($m.Value -match '(?i)1601|0x80070424|0x8') { $codeKey = 'BrushLogCritical' }
        [void]$list.Add(@{ T = $m.Value; K = $codeKey; B = $true })
        $idx = $m.Index + $m.Length
    }
    if ($idx -lt $Text.Length) {
        [void]$list.Add(@{ T = $Text.Substring($idx); K = $BodyBrushKey; B = $false })
    }
    if ($list.Count -eq 0) {
        [void]$list.Add(@{ T = $Text; K = $BodyBrushKey; B = $false })
    }
    return $list
}

function Add-UiLog {
    param(
        [string]$Line,
        [string]$Level = 'Info',
        [string]$Source = ''
    )
    if ($null -eq $Line) { return }
    if (Get-Command Repair-MojibakeText -ErrorAction SilentlyContinue) {
        $Line = Repair-MojibakeText -Text $Line
    }
    $Line = $Line.TrimEnd()
    if ([string]::IsNullOrWhiteSpace($Line)) { return }

    # Extraire source [ADB]/[Scripts 12:00:00] etc.
    $body = $Line
    $tag = $Source
    if ($body -match '^\[(Synaptic|ADB|Scripts|KVRT|Expiro|Store|Install|PATH|Deps)[^\]]*\]\s*(.*)$') {
        if ([string]::IsNullOrWhiteSpace($tag)) { $tag = $Matches[1] }
        $body = $Matches[2]
    }
    # Retirer horodatage deja present dans le body
    if ($body -match '^\[?(\d{1,2}:\d{2}:\d{2})\]?\s*(.*)$') {
        $body = $Matches[2]
    }
    # Retirer prefixe ADB stamp "ADB HH:mm:ss"
    if ($body -match '^(?:ADB|Scripts)\s+\d{1,2}:\d{2}:\d{2}\s+(.*)$') {
        $body = $Matches[1]
    }

    $detected = Resolve-UiLogLevel -Line $Line -Level $Level
    if ($detected -eq 'Info') {
        $detected = Resolve-UiLogLevel -Line $body -Level $detected
    }
    $levelBrush = Get-UiLogBrushKey -Level $detected
    $badge = Get-UiLogBadge -Level $detected
    $stamp = Get-Date -Format 'HH:mm:ss'

    $segments = [System.Collections.Generic.List[hashtable]]::new()
    [void]$segments.Add(@{ T = $stamp; K = 'BrushLogMuted'; B = $false })
    [void]$segments.Add(@{ T = '  '; K = 'BrushLogMuted'; B = $false })
    [void]$segments.Add(@{ T = $badge; K = $levelBrush; B = $true })
    [void]$segments.Add(@{ T = '  '; K = 'BrushLogMuted'; B = $false })
    if (-not [string]::IsNullOrWhiteSpace($tag)) {
        [void]$segments.Add(@{ T = ('[' + $tag.ToUpperInvariant() + ']'); K = 'BrushLogTag'; B = $true })
        [void]$segments.Add(@{ T = ' '; K = 'BrushLogMuted'; B = $false })
    }
    $bodyBrush = if ($detected -in @('Error', 'Critical', 'Warn', 'Success')) { $levelBrush } else { 'BrushLogText' }
    foreach ($seg in (Split-UiLogSegments -Text $body -BodyBrushKey $bodyBrush)) {
        [void]$segments.Add($seg)
    }

    # Copie locale pour le scriptblock UI
    $segs = @($segments)

    Invoke-LapwizUi -Action {
        if (-not $txtLog) { return }
        $para = New-Object System.Windows.Documents.Paragraph
        $para.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1)
        foreach ($s in $segs) {
            $run = New-Object System.Windows.Documents.Run
            $run.Text = [string]$s.T
            $br = $txtLog.TryFindResource([string]$s.K)
            if (-not $br) { $br = $txtLog.TryFindResource('BrushLogText') }
            if ($br) { $run.Foreground = $br }
            if ($s.B) { $run.FontWeight = [System.Windows.FontWeights]::SemiBold }
            [void]$para.Inlines.Add($run)
        }
        [void]$txtLog.Document.Blocks.Add($para)
        $txtLog.ScrollToEnd()

        if ($txtLogHint) {
            $hintBrush = $txtLog.TryFindResource($levelBrush)
            if ($hintBrush) { $txtLogHint.Foreground = $hintBrush }
            $txtLogHint.Text = $badge.Trim().ToLowerInvariant()
        }
    }
}

function Clear-UiLog {
    Invoke-LapwizUi -Action {
        if (-not $txtLog) { return }
        $txtLog.Document.Blocks.Clear()
        if ($txtLogHint) {
            $txtLogHint.Text = 'live'
            $muted = $txtLog.TryFindResource('BrushLogMuted')
            if ($muted) { $txtLogHint.Foreground = $muted }
        }
    }
}

if ($btnClearConsole) {
    $btnClearConsole.Add_Click({ Clear-UiLog })
}

function Update-UiProgress {
    param($Prog)
    if ($null -eq $Prog) { return }

    # Support hashtable / PSCustomObject
    $name = $null; $detail = $null; $pct = $null; $indet = $false; $step = $null; $total = $null
    $sizeTotal = $null; $sizeDone = $null; $sizeRemain = $null; $dlPct = $null
    if ($Prog -is [hashtable]) {
        if ($Prog.ContainsKey('Name')) { $name = [string]$Prog.Name }
        if ($Prog.ContainsKey('Detail')) { $detail = [string]$Prog.Detail }
        if ($Prog.ContainsKey('Percent')) { $pct = [double]$Prog.Percent }
        if ($Prog.ContainsKey('Indeterminate')) { $indet = [bool]$Prog.Indeterminate }
        if ($Prog.ContainsKey('Step')) { $step = [int]$Prog.Step }
        if ($Prog.ContainsKey('Total')) { $total = [int]$Prog.Total }
        if ($Prog.ContainsKey('SizeTotalBytes')) { $sizeTotal = [long]$Prog.SizeTotalBytes }
        if ($Prog.ContainsKey('SizeDoneBytes')) { $sizeDone = [long]$Prog.SizeDoneBytes }
        if ($Prog.ContainsKey('SizeRemainBytes')) { $sizeRemain = [long]$Prog.SizeRemainBytes }
        if ($Prog.ContainsKey('DownloadPercent')) { $dlPct = [int]$Prog.DownloadPercent }
    }
    else {
        $p = $Prog.PSObject.Properties
        if ($p['Name']) { $name = [string]$Prog.Name }
        if ($p['Detail']) { $detail = [string]$Prog.Detail }
        if ($p['Percent']) { $pct = [double]$Prog.Percent }
        if ($p['Indeterminate']) { $indet = [bool]$Prog.Indeterminate }
        if ($p['Step']) { $step = [int]$Prog.Step }
        if ($p['Total']) { $total = [int]$Prog.Total }
        if ($p['SizeTotalBytes']) { $sizeTotal = [long]$Prog.SizeTotalBytes }
        if ($p['SizeDoneBytes']) { $sizeDone = [long]$Prog.SizeDoneBytes }
        if ($p['SizeRemainBytes']) { $sizeRemain = [long]$Prog.SizeRemainBytes }
        if ($p['DownloadPercent']) { $dlPct = [int]$Prog.DownloadPercent }
    }

    if ($null -eq $pct -and $null -ne $step -and $null -ne $total -and $total -gt 0) {
        $pct = [math]::Round(100.0 * $step / $total)
    }

    $progressBar.IsIndeterminate = $indet
    if (-not $indet -and $null -ne $pct) {
        $progressBar.Value = [math]::Max(0, [math]::Min(100, $pct))
        if ($null -ne $dlPct) {
            $txtProgress.Text = ('{0} %' -f $dlPct)
        }
        else {
            $txtProgress.Text = ('{0} %' -f [int]$pct)
        }
    }
    elseif ($indet) {
        $txtProgress.Text = '...'
    }

    if ($name) {
        if ($null -ne $sizeTotal -and $null -ne $sizeRemain -and (Get-Command Format-ByteSize -ErrorAction SilentlyContinue)) {
            $txtStatus.Text = ('{0} — taille {1} | restant {2}' -f $name, (Format-ByteSize $sizeTotal), (Format-ByteSize $sizeRemain))
        }
        elseif ($detail) {
            $txtStatus.Text = "$name - $detail"
        }
        else {
            $txtStatus.Text = "Installation : $name"
        }
    }
    if ($txtStepDetail) {
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $step -and $null -ne $total -and $total -gt 0) {
            [void]$parts.Add("Etape $step / $total")
        }
        if ($null -ne $sizeTotal -and (Get-Command Format-ByteSize -ErrorAction SilentlyContinue)) {
            [void]$parts.Add(('Taille {0}' -f (Format-ByteSize $sizeTotal)))
            if ($null -ne $sizeDone) {
                [void]$parts.Add(('Telecharge {0}' -f (Format-ByteSize $sizeDone)))
            }
            if ($null -ne $sizeRemain) {
                [void]$parts.Add(('Restant {0}' -f (Format-ByteSize $sizeRemain)))
            }
        }
        elseif ($detail) {
            [void]$parts.Add($detail)
        }
        $txtStepDetail.Text = ($parts -join ' | ')
    }
}

function Set-UiBusy {
    param([bool]$Busy)
    Invoke-LapwizUi -Action {
        if ($btnInstall) { $btnInstall.IsEnabled = -not $Busy }
        if ($btnRepairMsiexec) { $btnRepairMsiexec.IsEnabled = -not $Busy }
        if ($btnAdbPath) { $btnAdbPath.IsEnabled = -not $Busy }
        if ($btnSelectAll) { $btnSelectAll.IsEnabled = -not $Busy }
        if ($btnSelectNone) { $btnSelectNone.IsEnabled = -not $Busy }
        if ($chkRepairFirst) { $chkRepairFirst.IsEnabled = -not $Busy }
        if ($btnSearchApp) { $btnSearchApp.IsEnabled = -not $Busy }
        if ($btnAddLocalApp) { $btnAddLocalApp.IsEnabled = -not $Busy }
        if ($cmbLanguage) { $cmbLanguage.IsEnabled = -not $Busy }
        if ($btnAddApp) {
            $btnAddApp.IsEnabled = ((-not $Busy) -and ($null -ne $lstWingetHits.SelectedItem))
        }
        if ($btnRemoveUserApp) {
            $btnRemoveUserApp.IsEnabled = ((-not $Busy) -and -not [string]::IsNullOrWhiteSpace($script:SelectedPackageId))
        }
        if ($txtAddAppQuery) { $txtAddAppQuery.IsEnabled = -not $Busy }
        if ($cmbAddCategory) { $cmbAddCategory.IsEnabled = -not $Busy }
        if ($lstWingetHits) { $lstWingetHits.IsEnabled = -not $Busy }
        if ($script:PackageChecks) {
            foreach ($chk in $script:PackageChecks) { $chk.IsEnabled = -not $Busy }
        }
    }
}

function Get-SelectedAddCategory {
    if (-not $cmbAddCategory) { return 'Autres' }
    $item = $cmbAddCategory.SelectedItem
    if ($item -is [System.Windows.Controls.ComboBoxItem]) {
        $c = [string]$item.Content
        if (-not [string]::IsNullOrWhiteSpace($c)) { return $c }
    }
    return 'Autres'
}

function Update-WingetHitsList {
    param([object[]]$Hits)
    $script:WingetSearchHits = @($Hits)
    $lstWingetHits.Items.Clear()
    foreach ($h in $script:WingetSearchHits) {
        [void]$lstWingetHits.Items.Add($h)
    }
    if ($script:WingetSearchHits.Count -gt 0) {
        $lstWingetHits.Visibility = [System.Windows.Visibility]::Visible
        $lstWingetHits.SelectedIndex = 0
        $btnAddApp.IsEnabled = $true
    }
    else {
        $lstWingetHits.Visibility = [System.Windows.Visibility]::Collapsed
        $btnAddApp.IsEnabled = $false
    }
}

function Start-WingetCatalogSearch {
    $q = if ($txtAddAppQuery) { [string]$txtAddAppQuery.Text } else { '' }
    $q = $q.Trim()
    if ([string]::IsNullOrWhiteSpace($q)) {
        [System.Windows.MessageBox]::Show(
            'Entrez un nom d''application ou un ID winget.',
            'Lapwiz Setup',
            'OK',
            'Information'
        ) | Out-Null
        return
    }

    if ($expAddApp) { $expAddApp.IsExpanded = $true }
    Show-InstallLogPanel -Hint 'recherche winget...'

    Set-UiBusy $true
    $txtStatus.Text = "Recherche winget : $q ..."
    Add-UiLog "-- Recherche winget : $q --"

    $catalogPath = Join-Path $ScriptRoot 'Guides\Package-Catalog.ps1'
    $resultBox = [hashtable]::Synchronized(@{ Done = $false; Hits = @(); Error = $null })

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript({
        param($CatalogPath, $Query, $ResultBox)
        try {
            . $CatalogPath
            $ResultBox.Hits = @(Search-WingetPackages -Query $Query -MaxResults 15)
        }
        catch {
            $ResultBox.Error = "$_"
        }
        finally {
            $ResultBox.Done = $true
        }
    }).AddArgument($catalogPath).AddArgument($q).AddArgument($resultBox)

    $handle = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        if (-not $resultBox.Done) { return }
        $timer.Stop()
        try { $null = $ps.EndInvoke($handle) } catch {}
        $ps.Dispose()
        $runspace.Close()

        Set-UiBusy $false
        if ($resultBox.Error) {
            Add-UiLog ("[Error] Recherche : " + $resultBox.Error) 'Error'
            $txtStatus.Text = 'Recherche echouee'
            [System.Windows.MessageBox]::Show(
                ("Recherche winget echouee.`n" + $resultBox.Error),
                'Lapwiz Setup',
                'OK',
                'Warning'
            ) | Out-Null
            return
        }

        $hits = @($resultBox.Hits)
        Update-WingetHitsList -Hits $hits
        if ($hits.Count -eq 0) {
            Add-UiLog 'Aucun resultat winget.'
            $txtStatus.Text = 'Aucun resultat'
        }
        else {
            Add-UiLog ("Resultats : " + $hits.Count)
            $txtStatus.Text = ("{0} resultat(s) — choisissez puis Ajouter" -f $hits.Count)
        }
    }.GetNewClosure())
    $timer.Start()
}

if ($btnSelectAll) {
    $btnSelectAll.Add_Click({
        foreach ($c in $script:PackageChecks) {
            $c.IsChecked = $true
            $parent = $c.Parent
            if ($parent -and $parent.Parent -is [System.Windows.Controls.Border]) {
                Update-PackageTileChrome -Tile $parent.Parent -Selected $true
            }
        }
    })
}

if ($btnSelectNone) {
    $btnSelectNone.Add_Click({
        foreach ($c in $script:PackageChecks) {
            $c.IsChecked = $false
            $parent = $c.Parent
            if ($parent -and $parent.Parent -is [System.Windows.Controls.Border]) {
                Update-PackageTileChrome -Tile $parent.Parent -Selected $false
            }
        }
    })
}

function Invoke-AddSelectedWingetHit {
    $sel = $lstWingetHits.SelectedItem
    if ($null -eq $sel) {
        [System.Windows.MessageBox]::Show(
            'Selectionnez un resultat dans la liste (ou lancez une recherche).',
            'Lapwiz Setup',
            'OK',
            'Information'
        ) | Out-Null
        return
    }
    $id = [string]$sel.Id
    $name = [string]$sel.Name
    $cat = Get-SelectedAddCategory
    try {
        $officialIds = @($script:OfficialPackages | ForEach-Object { [string]$_.id })
        if ($officialIds -contains $id) {
            [System.Windows.MessageBox]::Show(
                ("« $name » est deja dans le catalogue officiel Lapwiz."),
                'Lapwiz Setup',
                'OK',
                'Information'
            ) | Out-Null
            return
        }

        $iconPath = $null
        if (Get-Command Save-PackageIconForId -ErrorAction SilentlyContinue) {
            $homePageUrl = $null
            if (Get-Command Resolve-WingetHomepage -ErrorAction SilentlyContinue) {
                $homePageUrl = Resolve-WingetHomepage -PackageId $id
            }
            $iconPath = Save-PackageIconForId -Id $id -Homepage $homePageUrl
        }

        $iconName = ''
        if ($iconPath -and (Get-Command Get-SafeIconFileName -ErrorAction SilentlyContinue)) {
            $iconName = Get-SafeIconFileName -Id $id
        }

        $null = Add-UserPackage -Id $id -Name $name -Category $cat -Notes 'Ajoute manuellement (winget)' -Selected $true `
            -Icon $iconName -IconPath $(if ($iconPath) { $iconPath } else { '' })
        Add-UiLog ("Ajoute au catalogue perso : $name ($id) [$cat]" + $(if ($iconPath) { ' + icone' } else { '' }))
        Rebuild-PackageGrid
        Update-WingetHitsList -Hits @()
        if ($txtAddAppQuery) { $txtAddAppQuery.Text = '' }
        $added = if (Get-Command Get-UiString -ErrorAction SilentlyContinue) { Get-UiString $script:LapwizUi 'AddedOk' 'Ajoute' } else { 'Ajoute' }
        $txtStatus.Text = "$added : $name"
    }
    catch {
        Add-UiLog ("[Error] Ajout : $_") 'Error'
        [System.Windows.MessageBox]::Show("Impossible d'ajouter.`n$_", 'Lapwiz Setup', 'OK', 'Warning') | Out-Null
    }
}

function Invoke-AddLocalInstaller {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Installateurs (*.exe;*.msi)|*.exe;*.msi|Tous les fichiers (*.*)|*.*'
    $dlg.Title = if (Get-Command Get-UiString -ErrorAction SilentlyContinue) { Get-UiString $script:LapwizUi 'PickLocal' 'Selectionnez un installateur' } else { 'Selectionnez un installateur' }
    $dlg.CheckFileExists = $true
    if (-not $dlg.ShowDialog()) { return }

    $path = [string]$dlg.FileName
    $base = [IO.Path]::GetFileNameWithoutExtension($path)
    $id = 'Local.' + ($base -replace '[^A-Za-z0-9]', '')
    if ($id.Length -lt 8) { $id = 'Local.App' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    $name = $base
    $cat = Get-SelectedAddCategory

    try {
        $iconPath = $null
        if (Get-Command Save-PackageIconForId -ErrorAction SilentlyContinue) {
            $iconPath = Save-PackageIconForId -Id $id -LocalExePath $path
        }
        $iconName = ''
        if ($iconPath -and (Get-Command Get-SafeIconFileName -ErrorAction SilentlyContinue)) {
            $iconName = Get-SafeIconFileName -Id $id
        }
        $null = Add-UserPackage -Id $id -Name $name -Category $cat `
            -Notes ('Installateur local : ' + $path) -Selected $true `
            -Icon $iconName -IconPath $(if ($iconPath) { $iconPath } else { '' }) `
            -InstallMode 'local' -LocalPath $path
        Add-UiLog ("Ajoute local : $name ($path)" + $(if ($iconPath) { ' + icone' } else { '' }))
        Rebuild-PackageGrid
        if ($expAddApp) { $expAddApp.IsExpanded = $true }
        $added = if (Get-Command Get-UiString -ErrorAction SilentlyContinue) { Get-UiString $script:LapwizUi 'AddedOk' 'Ajoute' } else { 'Ajoute' }
        $txtStatus.Text = "$added : $name"
    }
    catch {
        Add-UiLog ("[Error] Ajout local : $_") 'Error'
        [System.Windows.MessageBox]::Show("Impossible d'ajouter le fichier local.`n$_", 'Lapwiz Setup', 'OK', 'Warning') | Out-Null
    }
}

if ($btnSearchApp) {
    $btnSearchApp.Add_Click({ Start-WingetCatalogSearch })
}
if ($btnAddLocalApp) {
    $btnAddLocalApp.Add_Click({ Invoke-AddLocalInstaller })
}
if ($txtAddAppQuery) {
    $txtAddAppQuery.Add_KeyDown({
        $e = $args[1]
        if ($e.Key -eq [System.Windows.Input.Key]::Return) {
            Start-WingetCatalogSearch
            $e.Handled = $true
        }
    })
}
if ($lstWingetHits) {
    $lstWingetHits.Add_SelectionChanged({
        $btnAddApp.IsEnabled = ($null -ne $lstWingetHits.SelectedItem)
    })
    $lstWingetHits.Add_MouseDoubleClick({
        if ($null -ne $lstWingetHits.SelectedItem) {
            Invoke-AddSelectedWingetHit
        }
    })
}
if ($btnAddApp) {
    $btnAddApp.Add_Click({ Invoke-AddSelectedWingetHit })
}
if ($btnRemoveUserApp) {
    $btnRemoveUserApp.Add_Click({
        $id = $script:SelectedPackageId
        if ([string]::IsNullOrWhiteSpace($id)) {
            [System.Windows.MessageBox]::Show(
                'Cliquez d''abord une tuile a retirer (ou utilisez le bouton X sur la tuile).',
                'Lapwiz Setup',
                'OK',
                'Information'
            ) | Out-Null
            return
        }
        Invoke-RemovePackageFromList -Id $id -Source $script:SelectedPackageSource
    })
}

if ($btnRepairMsiexec) {
$btnRepairMsiexec.Add_Click({
    $confirm = [System.Windows.MessageBox]::Show(
        "Cette reparation va :`n" +
        "1. Recreer / demarrer msiserver (local)`n" +
        "2. DISM RestoreHealth depuis Windows Update (serveurs Microsoft)`n" +
        "3. sfc /scannow`n`n" +
        "Duree typique : 10 a 40 minutes. Internet requis.`n" +
        "Ne fermez pas Lapwiz pendant l'operation.`n`nContinuer ?",
        'Lapwiz — msiexec + DISM',
        'YesNo',
        'Warning'
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    if ($mainTabs -and $tabStore) { $mainTabs.SelectedItem = $tabStore }
    Show-InstallLogPanel -Hint 'DISM RestoreHealth...'
    Set-UiBusy $true
    $txtStatus.Text = 'Réparation msiexec + DISM...'
    $progressBar.IsIndeterminate = $true
    $txtProgress.Text = '...'
    if ($txtStepDetail) { $txtStepDetail.Text = 'msiserver → DISM → SFC' }
    Add-UiLog '-- Reparation msiexec + DISM RestoreHealth --'

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

    $enginePath = Join-Path $ScriptRoot 'Install-Engine.ps1'
    $logQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

    [void]$ps.AddScript({
        param($EnginePath, $LogQueue)
        . $EnginePath
        $onLog = {
            param($line, $level)
            [void]$LogQueue.Enqueue($line)
        }
        Repair-WindowsInstaller -OnLog $onLog -RunDism
    }).AddArgument($enginePath).AddArgument($logQueue)

    $handle = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        $line = $null
        while ($logQueue.TryDequeue([ref]$line)) { Add-UiLog $line }
        if ($handle.IsCompleted) {
            $timer.Stop()
            try { $null = $ps.EndInvoke($handle) } catch { Add-UiLog "[Error] $_" 'Error' }
            $ps.Dispose()
            $runspace.Close()
            $progressBar.IsIndeterminate = $false
            Set-UiBusy $false
            $txtStatus.Text = 'Réparation msiexec + DISM terminée.'
            $progressBar.Value = 100
            $txtProgress.Text = '100 %'
            if ($txtStepDetail) { $txtStepDetail.Text = '' }
            if ($txtLogHint) { $txtLogHint.Text = 'reparation terminee' }
        }
    }.GetNewClosure())
    $timer.Start()
}.GetNewClosure())
}


if ($btnAdbPath) {
$btnAdbPath.Add_Click({
    Show-InstallLogPanel -Hint 'PATH ADB...'
    Set-UiBusy $true
    $txtStatus.Text = 'Configuration PATH ADB...'
    $progressBar.IsIndeterminate = $true
    $txtProgress.Text = '...'
    if ($txtStepDetail) { $txtStepDetail.Text = 'PATH ADB automatique' }
    Add-UiLog '-- PATH ADB auto --'

    $enginePath = Join-Path $ScriptRoot 'Install-Engine.ps1'
    $logQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $progressQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

    [void]$ps.AddScript({
        param($EnginePath, $LogQueue, $ProgressQueue)
        . $EnginePath
        $onLog = { param($line, $level) [void]$LogQueue.Enqueue($line) }
        $onProgress = { param($Info) [void]$ProgressQueue.Enqueue($Info) }
        Set-AdbPath -OnLog $onLog -OnProgress $onProgress
    }).AddArgument($enginePath).AddArgument($logQueue).AddArgument($progressQueue)

    $handle = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        $line = $null
        while ($logQueue.TryDequeue([ref]$line)) { Add-UiLog $line }
        $prog = $null
        while ($progressQueue.TryDequeue([ref]$prog)) { Update-UiProgress $prog }
        if ($handle.IsCompleted) {
            $timer.Stop()
            $ok = $false
            try {
                $raw = $ps.EndInvoke($handle)
                if ($raw -is [System.Collections.IList] -and $raw.Count -ge 1) { $ok = [bool]$raw[0] }
                else { $ok = [bool]$raw }
            }
            catch { Add-UiLog "[Error] $_" 'Error' }
            $ps.Dispose(); $runspace.Close()
            while ($logQueue.TryDequeue([ref]$line)) { Add-UiLog $line }
            Set-UiBusy $false
            $progressBar.IsIndeterminate = $false
            $progressBar.Value = 100
            $txtProgress.Text = '100 %'
            $txtStatus.Text = if ($ok) { 'PATH ADB configure automatiquement.' } else { 'Echec config PATH ADB.' }
            Add-UiLog '-- Fin PATH ADB --'
        }
    }.GetNewClosure())
    $timer.Start()
})
}

if ($btnInstall) {
$btnInstall.Add_Click({
    $selected = @()
    foreach ($c in $script:PackageChecks) {
        if ($c.IsChecked) { $selected += $c.Tag }
    }
    if ($selected.Count -eq 0) {
        $msg = if (Get-Command Get-UiString -ErrorAction SilentlyContinue) { Get-UiString $script:LapwizUi 'NoSelection' 'Selectionnez au moins un package.' } else { 'Selectionnez au moins un package.' }
        [System.Windows.MessageBox]::Show(
            $msg,
            'Lapwiz Setup',
            'OK',
            'Information'
        ) | Out-Null
        return
    }

    $txtStatus.Text = 'Detection des logiciels deja installes...'
    Add-UiLog '-- Detection des packages deja presents --'
    $already = @()
    try {
        $wingetOnly = @($selected | Where-Object { (Get-PackageInstallMode -Pkg $_) -eq 'winget' })
        if ($wingetOnly.Count -gt 0) {
            $already = @(Get-WingetInstalledPackageIds -Packages $wingetOnly)
        }
    }
    catch {
        Add-UiLog "[Warn] Detection incomplete : $_" 'Warn'
    }

    $forceIds = [System.Collections.Generic.List[string]]::new()
    if ($already.Count -gt 0) {
        $list = ($already | ForEach-Object { ' - ' + $_.Name }) -join "`n"
        Add-UiLog ("Deja presents : " + (($already | ForEach-Object { $_.Name }) -join ', '))
        $choice = [System.Windows.MessageBox]::Show(
            ("Logiciels deja detectes sur ce PC :`n`n$list`n`n" +
             "Apres Expiro, reinstaller est souvent recommande (EXE potentiellement corrompus).`n`n" +
             "Oui = reinstaller TOUS ceux-la`n" +
             "Non = les ignorer (ne pas reinstaller)`n" +
             "Annuler = choisir un par un"),
            'Lapwiz Setup — Deja installes',
            'YesNoCancel',
            'Question'
        )

        if ($choice -eq [System.Windows.MessageBoxResult]::Yes) {
            foreach ($a in $already) { [void]$forceIds.Add([string]$a.Id) }
            Add-UiLog 'Choix : reinstaller tous les deja presents (force).'
        }
        elseif ($choice -eq [System.Windows.MessageBoxResult]::No) {
            Add-UiLog 'Choix : ignorer tous les deja presents.'
        }
        else {
            Add-UiLog 'Choix : confirmation une par une.'
            foreach ($a in $already) {
                $one = [System.Windows.MessageBox]::Show(
                    ("« $($a.Name) » est deja installe.`n`nReinstaller ?`n(Recommande apres infection Expiro)"),
                    'Lapwiz Setup — Reinstaller ?',
                    'YesNo',
                    'Question'
                )
                if ($one -eq [System.Windows.MessageBoxResult]::Yes) {
                    [void]$forceIds.Add([string]$a.Id)
                    Add-UiLog ("Reinstall : " + $a.Name)
                }
                else {
                    Add-UiLog ("Ignore : " + $a.Name)
                }
            }
        }
    }
    else {
        Add-UiLog 'Aucun package selectionne deja detecte comme installe.'
    }

    Set-UiBusy $true
    $progressBar.IsIndeterminate = $false
    $progressBar.Value = 0
    $txtProgress.Text = '0 %'
    if ($txtStepDetail) { $txtStepDetail.Text = '' }
    $txtStatus.Text = 'Installation en cours...'
    Show-InstallLogPanel -Hint 'installation en cours...'
    Add-UiLog '-- Debut de l''installation --'

    $repairFirst = [bool]$chkRepairFirst.IsChecked
    $enginePath = Join-Path $ScriptRoot 'Install-Engine.ps1'
    $pkgsJson = ConvertTo-Json -InputObject @($selected) -Depth 6 -Compress
    $forceJson = ConvertTo-Json -InputObject @($forceIds.ToArray()) -Compress
    $logQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $progressQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

    [void]$ps.AddScript({
        param($EnginePath, $PkgsJson, $ForceJson, $RepairFirst, $LogQueue, $ProgressQueue)
        . $EnginePath
        $parsed = $PkgsJson | ConvertFrom-Json
        $pkgs = @($parsed)
        $forceIdsLocal = @()
        if (-not [string]::IsNullOrWhiteSpace($ForceJson) -and $ForceJson -ne 'null') {
            $forceParsed = $ForceJson | ConvertFrom-Json
            if ($null -ne $forceParsed) { $forceIdsLocal = @($forceParsed) }
        }
        $onLog = {
            param($line, $level)
            [void]$LogQueue.Enqueue($line)
        }
        $onProgress = {
            param($Info)
            [void]$ProgressQueue.Enqueue($Info)
        }
        Invoke-LapwizInstall -Packages $pkgs -OnLog $onLog -OnProgress $onProgress -RepairMsiexecFirst:$RepairFirst -ForcePackageIds $forceIdsLocal
    }).AddArgument($enginePath).AddArgument($pkgsJson).AddArgument($forceJson).AddArgument($repairFirst).AddArgument($logQueue).AddArgument($progressQueue)

    $handle = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        $line = $null
        while ($logQueue.TryDequeue([ref]$line)) { Add-UiLog $line }

        $prog = $null
        while ($progressQueue.TryDequeue([ref]$prog)) {
            Update-UiProgress $prog
        }

        if ($handle.IsCompleted) {
            $timer.Stop()
            $result = $null
            try {
                $raw = $ps.EndInvoke($handle)
                if ($raw -is [System.Collections.IList] -and $raw.Count -ge 1) {
                    $result = $raw[0]
                }
                else {
                    $result = $raw
                }
            }
            catch {
                Add-UiLog "[Error] $_" 'Error'
            }
            $ps.Dispose()
            $runspace.Close()

            while ($logQueue.TryDequeue([ref]$line)) { Add-UiLog $line }

            Set-UiBusy $false
            $progressBar.Value = 100
            $txtProgress.Text = '100 %'
            $msg = if ($result -and $result.Message) { [string]$result.Message } else { 'termine' }
            $txtStatus.Text = "Termine - $msg"
            Add-UiLog '-- Fin --'

            $ok = $false
            if ($result -and ($result.Ok -eq $true)) { $ok = $true }
            $icon = if ($ok) { 'Information' } else { 'Warning' }
            [System.Windows.MessageBox]::Show(
                "Installation terminee.`n$msg",
                'Lapwiz Setup',
                'OK',
                $icon
            ) | Out-Null
        }
    }.GetNewClosure())
    $timer.Start()
})
}

# Check winget au demarrage
Add-UiLog 'Lapwiz Setup demarre (session administrateur).'
if ($txtStatus) {
    if (Test-WingetAvailable -OnLog { param($l,$lv) Add-UiLog $l }) {
        $txtStatus.Text = 'Pret - selectionnez les packages puis Installez.'
    }
    else {
        $txtStatus.Text = 'winget manquant - installez App Installer (Store).'
    }
}

# Onglet SynapticRemover - handlers
if ($btnSynapticAuto) { $btnSynapticAuto.Add_Click({ Start-SynapticBat -Mode Auto }) }
if ($btnSynapticInteractive) { $btnSynapticInteractive.Add_Click({ Start-SynapticBat -Mode Interactive }) }
if ($btnSynapticVerify) {
    $btnSynapticVerify.Add_Click({
        Add-SynapticLog '-- Re-verification --'
        $null = Test-SynapticRemoverBundle
    })
}
if ($btnSynapticOpenFolder) {
    $btnSynapticOpenFolder.Add_Click({
        $root = Get-SynapticRoot
        if ($root) { Start-Process explorer.exe $root }
        else { [System.Windows.MessageBox]::Show('Dossier introuvable.', 'Lapwiz Setup', 'OK', 'Warning') | Out-Null }
    })
}
if ($btnSynapticReports) {
    $btnSynapticReports.Add_Click({
        $root = Get-SynapticRoot
        if (-not $root) {
            [System.Windows.MessageBox]::Show('SynapticRemover introuvable.', 'Lapwiz Setup', 'OK', 'Warning') | Out-Null
            return
        }
        $reports = @(
            (Join-Path $root 'reports'),
            (Join-Path $ScriptRoot '..\..\SynapticRemover\reports'),
            'C:\Users\switc\Desktop\SynapticRemover\reports'
        ) | ForEach-Object { [IO.Path]::GetFullPath($_) } | Select-Object -Unique
        $found = $reports | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($found) {
            Start-Process explorer.exe $found
            Add-SynapticLog ("Rapports: " + $found)
        }
        else {
            New-Item -ItemType Directory -Path (Join-Path $root 'reports') -Force | Out-Null
            Start-Process explorer.exe (Join-Path $root 'reports')
            Add-SynapticLog 'Dossier reports cree (vide pour l instant).'
        }
    })
}

# Module remediation Expiro/KVRT/MBAM (scope script — requis par les handlers WPF)
$expiroRemediationPath = Join-Path $ScriptRoot 'Guides\Expiro-Trend-Remediation.ps1'
if (Test-Path -LiteralPath $expiroRemediationPath) {
    try { . $expiroRemediationPath }
    catch { Write-LapwizCrashLog -Stage 'Expiro-Trend-Remediation' -Detail ([string]$_) }
}
else {
    [System.Windows.MessageBox]::Show("Module manquant : Guides\Expiro-Trend-Remediation.ps1", 'Lapwiz Setup', 'OK', 'Error') | Out-Null
}
# Onglet Guide Expiro — wizard (docs + images)
$expiroUiPath = Join-Path $ScriptRoot 'Guides\Expiro-Guide-UI.ps1'
if (-not (Test-Path -LiteralPath $expiroUiPath)) {
    [System.Windows.MessageBox]::Show("Module guide manquant : Guides\Expiro-Guide-UI.ps1", 'Lapwiz Setup', 'OK', 'Error') | Out-Null
}
else {
    try {
        . $expiroUiPath
        Initialize-ExpiroGuideUi -Window $window -ScriptRoot $ScriptRoot
    }
    catch {
        Write-LapwizCrashLog -Stage 'Initialize-ExpiroGuideUi' -Detail ([string]$_)
        [System.Windows.MessageBox]::Show("Guide Expiro indisponible : $_", 'Lapwiz Setup', 'OK', 'Warning') | Out-Null
    }
}

# Onglet Scripts automatises
$scriptsUiPath = Join-Path $ScriptRoot 'Guides\Scripts-Auto-UI.ps1'
if (-not (Test-Path -LiteralPath $scriptsUiPath)) {
    [System.Windows.MessageBox]::Show("Module scripts manquant : Guides\Scripts-Auto-UI.ps1", 'Lapwiz Setup', 'OK', 'Error') | Out-Null
}
else {
    try {
        . $scriptsUiPath
        Initialize-ScriptsAutoUi -Window $window -ScriptRoot $ScriptRoot
    }
    catch {
        Write-LapwizCrashLog -Stage 'Initialize-ScriptsAutoUi' -Detail ([string]$_)
        [System.Windows.MessageBox]::Show("Scripts auto indisponibles : $_", 'Lapwiz Setup', 'OK', 'Warning') | Out-Null
    }
}

# Onglet KVRT independant (guide + images)
$kvrtUiPath = Join-Path $ScriptRoot 'Guides\Kvrt-Guide-UI.ps1'
if (-not (Test-Path -LiteralPath $kvrtUiPath)) {
    [System.Windows.MessageBox]::Show("Module KVRT manquant : Guides\Kvrt-Guide-UI.ps1", 'Lapwiz Setup', 'OK', 'Error') | Out-Null
}
else {
    try {
        . $kvrtUiPath
        Initialize-KvrtGuideUi -Window $window -ScriptRoot $ScriptRoot
    }
    catch {
        Write-LapwizCrashLog -Stage 'Initialize-KvrtGuideUi' -Detail ([string]$_)
        [System.Windows.MessageBox]::Show("Guide KVRT indisponible : $_", 'Lapwiz Setup', 'OK', 'Warning') | Out-Null
    }
}

# Onglet ADB Repair (scan + remplacement officiel)
$adbRepairUiPath = Join-Path $ScriptRoot 'Guides\Adb-Repair-UI.ps1'
if (-not (Test-Path -LiteralPath $adbRepairUiPath)) {
    [System.Windows.MessageBox]::Show("Module ADB Repair manquant : Guides\Adb-Repair-UI.ps1", 'Lapwiz Setup', 'OK', 'Error') | Out-Null
}
else {
    try {
        . $adbRepairUiPath
        Initialize-AdbRepairUi -Window $window -ScriptRoot $ScriptRoot
    }
    catch {
        Write-LapwizCrashLog -Stage 'Initialize-AdbRepairUi' -Detail ([string]$_)
        [System.Windows.MessageBox]::Show("ADB Repair indisponible : $_", 'Lapwiz Setup', 'OK', 'Warning') | Out-Null
    }
}

# Onglets reordonnes + toast dependances (premier PC / runtime manquant)
$depsModPath = Join-Path $ScriptRoot 'Guides\Lapwiz-Dependencies.ps1'
if (Test-Path -LiteralPath $depsModPath) {
    try {
        . $depsModPath
        Initialize-LapwizDependenciesUi -Window $window -ScriptRoot $ScriptRoot
    }
    catch {
        Write-LapwizCrashLog -Stage 'Initialize-LapwizDependenciesUi' -Detail ([string]$_)
    }
}

Write-LapwizCrashLog -Stage 'UI-ready' -Detail 'Avant ShowDialog'
try {
    # Re-appliquer chrome juste avant affichage (icone barre titre / logo)
    Set-LapwizAppChrome -Win $window
    # Mode plein ecran (maximisé — barre titre conservée pour fermer)
    $window.WindowState = [System.Windows.WindowState]::Maximized
    [void]$window.ShowDialog()
    Write-LapwizCrashLog -Stage 'UI-closed' -Detail 'ShowDialog termine normalement'
}
catch {
    Write-LapwizCrashLog -Stage 'ShowDialog' -Detail ([string]$_)
    try {
        [System.Windows.MessageBox]::Show("Fermeture anormale : $_", 'Lapwiz Setup', 'OK', 'Error') | Out-Null
    }
    catch {}
}
finally {
    $global:LASTEXITCODE = 0
}
