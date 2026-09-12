#Requires -Version 5.1
# Lapwiz — internationalisation FR / EN / AR (JSON UTF-8)
# Dot-source depuis Start-LapwizSetup.ps1

Set-StrictMode -Version Latest

function script:Get-LapwizI18nRoot {
    $here = $PSScriptRoot
    if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
    return (Join-Path $here 'i18n')
}

function script:Get-LapwizLangFile {
    $dir = Join-Path $env:LOCALAPPDATA 'LapwizSetup'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return (Join-Path $dir 'ui-lang.txt')
}

function script:ConvertTo-StringHashtable {
    param($Obj)
    $h = @{}
    if ($null -eq $Obj) { return $h }
    foreach ($p in $Obj.PSObject.Properties) {
        $h[$p.Name] = [string]$p.Value
    }
    return $h
}

function script:Get-UiString {
    <# Acces StrictMode-safe (hashtable / objet). #>
    param(
        $Table,
        [Parameter(Mandatory)][string]$Key,
        [string]$Default = ''
    )
    if ($null -eq $Table) { return $Default }
    try {
        if ($Table -is [hashtable] -or $Table -is [System.Collections.IDictionary]) {
            if ($Table.ContainsKey($Key)) { return [string]$Table[$Key] }
            return $Default
        }
        $prop = $Table.PSObject.Properties[$Key]
        if ($null -ne $prop -and $null -ne $prop.Value) { return [string]$prop.Value }
    }
    catch { }
    return $Default
}

function script:Get-LapwizStrings {
    param([string]$Lang = 'fr')
    $key = $Lang.ToLowerInvariant()
    if ($key -notin @('fr', 'en', 'ar')) { $key = 'fr' }
    $path = Join-Path (Get-LapwizI18nRoot) ($key + '.json')
    if (-not (Test-Path -LiteralPath $path)) {
        $path = Join-Path (Get-LapwizI18nRoot) 'fr.json'
    }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $obj = ConvertFrom-Json -InputObject $raw
    $h = ConvertTo-StringHashtable -Obj $obj
    if (-not $h.ContainsKey('Code')) { $h['Code'] = $key }
    if (-not $h.ContainsKey('Flow')) {
        $h['Flow'] = if ($key -eq 'ar') { 'RightToLeft' } else { 'LeftToRight' }
    }
    return $h
}

function script:Read-LapwizLanguage {
    $file = Get-LapwizLangFile
    if (Test-Path -LiteralPath $file) {
        $v = (Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue).Trim().ToLowerInvariant()
        if ($v -in @('fr', 'en', 'ar')) { return $v }
    }
    return 'fr'
}

function script:Save-LapwizLanguage {
    param([Parameter(Mandatory)][string]$Lang)
    $key = $Lang.ToLowerInvariant()
    if ($key -notin @('fr', 'en', 'ar')) { $key = 'fr' }
    Set-Content -LiteralPath (Get-LapwizLangFile) -Value $key -Encoding UTF8
}

function script:Set-NamedText {
    param($Window, [string]$Name, [string]$Text)
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    if ($null -eq $Text) { $Text = '' }
    try {
        $el = $Window.FindName($Name)
        if ($null -eq $el) { return }
        if ($el -is [System.Windows.Controls.TextBlock]) { $el.Text = $Text; return }
        if ($el -is [System.Windows.Controls.TextBox]) { $el.Text = $Text; return }
        if ($el -is [System.Windows.Controls.CheckBox]) { $el.Content = $Text; return }
        if ($el -is [System.Windows.Controls.ContentControl]) {
            if ($el.Content -is [System.Windows.Controls.Panel]) {
                $texts = @($el.Content.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] })
                if ($texts.Count -gt 0) {
                    $texts[-1].Text = $Text
                    return
                }
            }
            if ($el.Content -is [string] -or $null -eq $el.Content) {
                $el.Content = $Text
                return
            }
        }
    }
    catch { }
}

function script:Apply-LapwizLanguage {
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][string]$Lang,
        [switch]$SkipSave
    )
    try {
        $s = Get-LapwizStrings -Lang $Lang
        $script:LapwizUi = $s
        $code = Get-UiString $s 'Code' $Lang
        if (-not $SkipSave) { Save-LapwizLanguage -Lang $code }

        # Ne pas inverser toute la fenetre (casse colonnes / journal a droite).
        # RTL uniquement sur les textes arabes via FlowDirection local si besoin.
        $Window.FlowDirection = [System.Windows.FlowDirection]::LeftToRight

        # Map controle -> cle i18n (TextBlock / Button Content / CheckBox)
        $map = @{
            TxtHeaderSub              = 'HeaderSub'
            TxtLangLabel              = 'LangLabel'
            TxtConsoleTitle           = 'ConsoleTitle'
            TxtLogHint                = 'LogClosed'
            TxtTabStore               = 'TabStore'
            TxtTabInstall             = 'TabInstall'
            TxtTabSynaptic            = 'TabSynaptic'
            TxtTabExpiro              = 'TabExpiro'
            TxtTabScripts             = 'TabScripts'
            TxtTabKvrt                = 'TabKvrt'
            TxtTabAdb                 = 'TabAdb'
            TxtBtnSelectAll           = 'SelectAll'
            TxtBtnSelectNone          = 'SelectNone'
            TxtBtnInstall             = 'Install'
            TxtExpAddApp              = 'AddApp'
            TxtExpAddAppHint          = 'AddAppHint'
            TxtBtnSearchApp           = 'Search'
            TxtBtnAddApp              = 'Add'
            TxtBtnRemoveUserApp       = 'Remove'
            TxtBtnAddLocalApp         = 'LocalFile'
            TxtStatus                 = 'Ready'
            TxtRepairTitle            = 'RepairTitle'
            TxtRepairBody             = 'RepairBody'
            ChkRepairFirst            = 'RepairBefore'
            TxtBtnRepairMsiexec       = 'RepairBtn'
            TxtBtnAdbPath             = 'AdbPath'
            TxtDismHint               = 'DismHint'
            TxtCatalogHintTitle       = 'CatalogHintTitle'
            TxtCatalogHintBody        = 'CatalogHintBody'
            TxtInstallLogHint         = 'InstallLogHint'
            TxtSynapticTitle          = 'SynapticTitle'
            TxtSynapticBody           = 'SynapticBody'
            TxtBtnSynapticAuto        = 'SynapticAuto'
            TxtBtnSynapticInteractive = 'SynapticInteractive'
            TxtBtnSynapticOpenFolder  = 'SynapticOpenFolder'
            TxtBtnSynapticReports     = 'SynapticReports'
            TxtBtnSynapticVerify      = 'SynapticVerify'
            TxtSynapticHint           = 'SynapticHint'
            TxtExpiroTitle            = 'ExpiroTitle'
            TxtExpiroSubtitle         = 'ExpiroSubtitle'
            TxtExpiroFooter           = 'ExpiroFooter'
            BtnExpiroCopyGuide        = 'ExpiroCopy'
            TxtScriptsTitle           = 'ScriptsTitle'
            TxtScriptsSubtitle        = 'ScriptsSubtitle'
            TxtScriptsGroupTrend      = 'ScriptsGroupTrend'
            TxtScriptsGroupTrendDesc  = 'ScriptsGroupTrendDesc'
            TxtScriptsGroupScans      = 'ScriptsGroupScans'
            TxtScriptsGroupScansDesc  = 'ScriptsGroupScansDesc'
            TxtScriptsGroupLinks      = 'ScriptsGroupLinks'
            TxtScriptsGroupLinksDesc  = 'ScriptsGroupLinksDesc'
            BtnAutoAudit              = 'BtnAuditTrend'
            BtnAutoStartup            = 'BtnFixStartup'
            BtnAutoServices           = 'BtnRestartAv'
            BtnAutoArtifacts          = 'BtnRemoveArtifacts'
            BtnAutoKvrtDownload       = 'BtnDlKvrt'
            BtnAutoKvrtRun            = 'BtnRunKvrt'
            BtnAutoKvrtFolder         = 'BtnKvrtFolder'
            BtnAutoMbam               = 'BtnMbam'
            BtnAutoDefender           = 'BtnDefender'
            BtnAutoMbamSite           = 'BtnMbamSite'
            TxtKvrtTitle              = 'KvrtTitle'
            TxtKvrtSubtitle           = 'KvrtSubtitle'
            BtnKvrtHowto              = 'KvrtHowto'
            BtnKvrtOfficial           = 'KvrtOfficial'
            BtnKvrtCopyGuide          = 'KvrtCopy'
            TxtKvrtHint               = 'KvrtHint'
            TxtKvrtLogTitle           = 'KvrtLogTitle'
            TxtAdbStep1Title          = 'AdbStep1Title'
            TxtAdbStep1Desc           = 'AdbStep1Desc'
            BtnAdbLearnPacks          = 'AdbLearn'
            BtnAdbFetchClean          = 'AdbFetch'
            TxtAdbStep2Title          = 'AdbStep2Title'
            TxtAdbStep2Desc           = 'AdbStep2Desc'
            BtnAdbScanFolder          = 'AdbChooseFolder'
            BtnAdbScanCommon          = 'AdbScanQuick'
            BtnAdbScanDrive           = 'AdbScanDrive'
            BtnAdbScanRecent          = 'AdbRescan'
            TxtAdbHistoryLabel        = 'AdbHistory'
            TxtAdbStep3Title          = 'AdbStep3Title'
            TxtAdbStep3Desc           = 'AdbStep3Desc'
            BtnAdbRepairAll           = 'AdbRepairAll'
            TxtAdbStep4Title          = 'AdbStep4Title'
            TxtAdbStep4Desc           = 'AdbStep4Desc'
            BtnAdbPathLapwiz          = 'AdbPathLapwiz'
            BtnAdbOpenQuarantine      = 'AdbQuarantine'
            BtnAdbCheckAll            = 'AdbCheckAll'
            BtnAdbUncheckAll          = 'AdbUncheckAll'
            TxtAdbGuideHeader         = 'AdbGuideHeader'
            TxtAdbGuideHint           = 'AdbGuideHint'
            TxtAdbResults             = 'AdbResults'
            TxtAdbLogTitle            = 'AdbLogTitle'
            BtnClearConsole           = 'ScriptsClearLog'
            TxtDepsToastTitle         = 'DepsTitle'
            TxtDepsToastBody          = 'DepsBody'
            BtnDepsDownload           = 'DepsDownload'
            BtnDepsOpenFolder         = 'DepsFolder'
            BtnDepsDismiss            = 'DepsLater'
            BtnExpiroLightboxClose    = 'LightboxClose'
            TxtLightboxHint           = 'LightboxHint'
        }

        foreach ($name in ($map.Keys | Sort-Object)) {
            Set-NamedText -Window $Window -Name $name -Text (Get-UiString $s $map[$name])
        }

        # Journaux / statuts : ne pas ecraser un contenu dynamique long
        $readyDefaults = @(
            'Pret.', 'Ready.',
            'Pret. Lance un script ci-dessus (admin).',
            'Pret. Lancez un script ci-dessus (admin).',
            'Ready. Run a script above (admin).',
            'Pret. Telecharge puis lance KVRT, ensuite Start scan (voir images).',
            'Pret. Telechargez puis lancez KVRT, ensuite Start scan.',
            'Ready. Download then run KVRT, then Start scan.',
            'Pret. Etape 1 : telechargez les binaires clean, puis scannez.',
            'Pret. Etape 1 : apprenez ou telechargez les packs clean.',
            'Ready. Step 1: learn or download clean packs.',
            'Verification...', 'Checking...',
            'Aucun scan', 'No scan yet'
        )
        foreach ($pair in @(
                @{ Name = 'TxtSynapticStatus'; Key = 'SynapticChecking' },
                @{ Name = 'TxtAdbRepairSummary'; Key = 'AdbNoScan' }
            )) {
            $el = $Window.FindName($pair.Name)
            if (-not $el) { continue }
            $cur = if ($el -is [System.Windows.Controls.TextBox]) { [string]$el.Text } else { [string]$el.Text }
            $looksDefault = [string]::IsNullOrWhiteSpace($cur) -or ($readyDefaults -contains $cur) -or ($cur.Length -lt 90 -and $cur -match '^(Pret|Ready|Verification|Checking|Aucun|No scan)')
            if ($looksDefault) {
                Set-NamedText -Window $Window -Name $pair.Name -Text (Get-UiString $s $pair.Key)
            }
        }

        $phaseFmt = Get-UiString $s 'ExpiroPhaseFmt' 'Phase {0} / {1}'
        $prog = $Window.FindName('ExpiroProgressLabel')
        if ($prog) {
            try { $prog.Text = ($phaseFmt -f 1, 6) } catch { $prog.Text = $phaseFmt }
        }

        $q = $Window.FindName('TxtAddAppQuery')
        if ($q) { $q.ToolTip = (Get-UiString $s 'QueryTip') }
        $localBtn = $Window.FindName('BtnAddLocalApp')
        if ($localBtn) { $localBtn.ToolTip = (Get-UiString $s 'LocalFileTip') }
        $rmBtn = $Window.FindName('BtnRemoveUserApp')
        if ($rmBtn) { $rmBtn.ToolTip = (Get-UiString $s 'RemoveTip') }
        $repBtn = $Window.FindName('BtnRepairMsiexec')
        if ($repBtn) { $repBtn.ToolTip = (Get-UiString $s 'RepairTip') }
        $lbImg = $Window.FindName('ExpiroLightboxImage')
        if ($lbImg) { $lbImg.ToolTip = (Get-UiString $s 'LightboxTip') }

        $cmb = $Window.FindName('CmbAddCategory')
        if ($cmb -and $cmb.Items.Count -ge 5) {
            $cats = @(
                (Get-UiString $s 'CatUtil' 'Utilitaires'),
                (Get-UiString $s 'CatDev' 'Developpement'),
                (Get-UiString $s 'CatMobile' 'Mobile'),
                (Get-UiString $s 'CatDotNet' '.NET'),
                (Get-UiString $s 'CatOther' 'Autres')
            )
            for ($i = 0; $i -lt [math]::Min(5, $cmb.Items.Count); $i++) {
                $item = $cmb.Items[$i]
                if ($item -is [System.Windows.Controls.ComboBoxItem]) {
                    $item.Content = $cats[$i]
                }
            }
        }
    }
    catch {
        throw "Apply-LapwizLanguage($Lang) : $_"
    }
}

function script:Translate-CategoryName {
    param([string]$Category)
    $s = $script:LapwizUi
    if (-not $s) { $s = Get-LapwizStrings -Lang 'fr' }
    if ([string]::IsNullOrWhiteSpace($Category)) { return (Get-UiString $s 'CatOther' 'Autres') }
    switch -Regex ($Category.ToLowerInvariant()) {
        'utilitaire|utilit' { return (Get-UiString $s 'CatUtil' 'Utilitaires') }
        'developp|develop' { return (Get-UiString $s 'CatDev' 'Developpement') }
        'mobile' { return (Get-UiString $s 'CatMobile' 'Mobile') }
        '\.net' { return (Get-UiString $s 'CatDotNet' '.NET') }
        'navigateur|browser' { return (Get-UiString $s 'CatBrowser' 'Navigateurs') }
        'securit|security' { return (Get-UiString $s 'CatSecurity' 'Securite') }
        'autre|other' { return (Get-UiString $s 'CatOther' 'Autres') }
        default { return $Category }
    }
}