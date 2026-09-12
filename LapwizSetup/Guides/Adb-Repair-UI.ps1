#Requires -Version 5.1
<#
.SYNOPSIS
    Onglet ADB Repair — scan / download clean / remplacement adb+scrcpy.
.NOTES
    Handlers Add_Click uniquement. Travail long via runspace + ConcurrentQueue (pas de closure serializee).
#>

function Initialize-AdbRepairUi {
    param(
        [Parameter(Mandatory)] $Window,
        [Parameter(Mandatory)][string]$ScriptRoot
    )

    $enginePath = Join-Path $ScriptRoot 'Guides\Adb-Repair-Engine.ps1'
    if (-not (Test-Path -LiteralPath $enginePath)) {
        [System.Windows.MessageBox]::Show('Module manquant : Guides\Adb-Repair-Engine.ps1', 'Lapwiz — ADB Repair', 'OK', 'Error') | Out-Null
        return
    }
    . $enginePath
    # script: obligatoire — Start-AdbRepairJob est en scope script (hors locals de Initialize)
    $script:AdbRepairEnginePath = $enginePath
    $script:AdbRepairScriptRoot = $ScriptRoot

    try { Add-Type -AssemblyName System.Windows.Forms } catch { }

    $script:AdbRepairWindow = $Window
    $script:AdbRepairList = $Window.FindName('LstAdbRepairHits')
    $script:AdbRepairSummary = $Window.FindName('TxtAdbRepairSummary')
    $script:AdbProgressPanel = $Window.FindName('AdbProgressPanel')
    $script:AdbProgressBar = $Window.FindName('AdbProgressBar')
    $script:AdbProgressLabel = $Window.FindName('TxtAdbProgressLabel')
    $script:AdbProgressDetail = $Window.FindName('TxtAdbProgressDetail')
    $script:AdbProgressPct = $Window.FindName('TxtAdbProgressPct')
    $script:AdbProgressEta = $Window.FindName('TxtAdbProgressEta')
    $script:AdbRepairHits = @()
    $script:AdbCleanPackages = $null
    $script:AdbCleanHashMap = $null
    $script:AdbRepairBusy = $false
    $script:AdbProgressStarted = $null
    $script:AdbPendingRepairReport = $null
    $script:AdbOpenRepairReport = $false
    $script:AdbScanHistoryCombo = $Window.FindName('CmbAdbScanHistory')
    $script:AdbScanHistoryMax = 10

    function script:Get-AdbScanHistoryPath {
        $dir = Join-Path $env:LOCALAPPDATA 'LapwizSetup'
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        return (Join-Path $dir 'adb-scan-history.json')
    }

    function script:Read-AdbScanHistory {
        $path = Get-AdbScanHistoryPath
        $norm = [System.Collections.Generic.List[string]]::new()
        try {
            if (-not (Test-Path -LiteralPath $path)) { return @() }
            $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
            $obj = $raw | ConvertFrom-Json
            foreach ($p in @($obj)) {
                $t = [string]$p
                if ([string]::IsNullOrWhiteSpace($t)) { continue }
                $t = $t.Trim()
                if ($t -match '^[A-Za-z]:\\?$') { $t = $t.Substring(0, 1) + ':\' }
                else { $t = $t.TrimEnd('\') }
                $exists = $false
                foreach ($e in $norm) { if ($e -ieq $t) { $exists = $true; break } }
                if (-not $exists) { [void]$norm.Add($t) }
            }
        }
        catch { }
        return @($norm)
    }

    function script:Save-AdbScanHistory {
        param([string[]]$Paths)
        try {
            $path = Get-AdbScanHistoryPath
            $arr = @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($arr.Count -eq 0) {
                [IO.File]::WriteAllText($path, '[]', [Text.UTF8Encoding]::new($true))
                return
            }
            # Toujours un tableau JSON
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.Append('[')
            for ($i = 0; $i -lt $arr.Count; $i++) {
                if ($i -gt 0) { [void]$sb.Append(',') }
                $esc = ($arr[$i] -replace '\\', '\\' -replace '"', '\"')
                [void]$sb.Append(('"{0}"' -f $esc))
            }
            [void]$sb.Append(']')
            [IO.File]::WriteAllText($path, $sb.ToString(), [Text.UTF8Encoding]::new($true))
        }
        catch { }
    }

    function script:Add-AdbScanHistory {
        param([Parameter(Mandatory)][string]$Root)
        if ([string]::IsNullOrWhiteSpace($Root)) { return }
        $root = $Root.Trim()
        if ($root -match '^[A-Za-z]:\\?$') { $root = $root.Substring(0, 1) + ':\' }
        else { $root = $root.TrimEnd('\') }

        $cur = [System.Collections.Generic.List[string]]::new()
        [void]$cur.Add($root)
        foreach ($p in @(Read-AdbScanHistory)) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $n = $p.Trim()
            if ($n -match '^[A-Za-z]:\\?$') { $n = $n.Substring(0, 1) + ':\' }
            else { $n = $n.TrimEnd('\') }
            if ($n -ieq $root) { continue }
            [void]$cur.Add($n)
            if ($cur.Count -ge $script:AdbScanHistoryMax) { break }
        }
        Save-AdbScanHistory -Paths @($cur)
        Refresh-AdbScanHistoryCombo -SelectPath $root
    }

    function script:Refresh-AdbScanHistoryCombo {
        param([string]$SelectPath = '')
        $cmb = $script:AdbScanHistoryCombo
        if (-not $cmb) { return }
        try {
            $items = @(Read-AdbScanHistory)
            $cmb.Items.Clear()
            foreach ($p in $items) { [void]$cmb.Items.Add($p) }
            $btn = $script:AdbRepairWindow.FindName('BtnAdbScanRecent')
            $has = $cmb.Items.Count -gt 0
            $cmb.IsEnabled = $has -and (-not $script:AdbRepairBusy)
            if ($btn) { $btn.IsEnabled = $has -and (-not $script:AdbRepairBusy) }
            if (-not $has) { return }
            if ($SelectPath) {
                for ($i = 0; $i -lt $cmb.Items.Count; $i++) {
                    if ([string]$cmb.Items[$i] -ieq $SelectPath) {
                        $cmb.SelectedIndex = $i
                        return
                    }
                }
            }
            if ($cmb.SelectedIndex -lt 0) { $cmb.SelectedIndex = 0 }
        }
        catch { }
    }

    function script:Format-AdbEta {
        param([double]$Seconds)
        if ($Seconds -lt 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) { return '…' }
        $sec = [int][Math]::Max(0, [Math]::Ceiling($Seconds))
        if ($sec -lt 60) { return ("~{0} s" -f $sec) }
        $m = [int][Math]::Floor($sec / 60)
        $s = $sec % 60
        if ($m -lt 60) { return ("~{0} min {1:D2} s" -f $m, $s) }
        $h = [int][Math]::Floor($m / 60)
        $m2 = $m % 60
        return ("~{0} h {1:D2} min" -f $h, $m2)
    }

    function script:Set-AdbProgressUi {
        param(
            [string]$Phase = 'idle',
            [int]$Current = 0,
            [int]$Total = 0,
            [int]$FilesSeen = 0,
            [string]$Message = '',
            [datetime]$Started = [datetime]::MinValue,
            [switch]$Hide
        )
        try {
            if ($Hide) {
                if ($script:AdbProgressPanel) { $script:AdbProgressPanel.Visibility = [System.Windows.Visibility]::Collapsed }
                if ($script:AdbProgressBar) {
                    $script:AdbProgressBar.IsIndeterminate = $false
                    $script:AdbProgressBar.Value = 0
                }
                return
            }
            if ($script:AdbProgressPanel) { $script:AdbProgressPanel.Visibility = [System.Windows.Visibility]::Visible }

            $phaseLabel = switch -Regex ($Phase) {
                '^(?i)enum$' { 'Enumeration des fichiers' }
                '^(?i)analyze$' { 'Analyse des dossiers' }
                '^(?i)hash$' { 'Hash SHA-256' }
                '^(?i)root$' { 'Parcours des emplacements' }
                '^(?i)repair$' { 'Reparation' }
                '^(?i)done$' { 'Termine' }
                '^(?i)fetch|learn$' { 'Preparation packs' }
                default { 'En cours' }
            }
            if ($script:AdbProgressLabel) { $script:AdbProgressLabel.Text = $phaseLabel }

            $detail = $Message
            if ($detail.Length -gt 90) { $detail = '…' + $detail.Substring($detail.Length - 89) }
            if ($FilesSeen -gt 0 -and $Phase -eq 'enum') {
                $detail = ('{0:N0} fichiers vus' -f $FilesSeen) + $(if ($Message) { ' · ' + $detail } else { '' })
            }
            if ($script:AdbProgressDetail) { $script:AdbProgressDetail.Text = $detail }

            $elapsed = 0.0
            if ($Started -ne [datetime]::MinValue) {
                $elapsed = ([datetime]::UtcNow - $Started).TotalSeconds
            }

            $indeterminate = ($Phase -eq 'enum' -or $Phase -eq 'fetch' -or $Phase -eq 'learn' -or ($Total -le 0 -and $Phase -ne 'done'))
            $pct = 0.0
            $etaText = ''

            if ($Phase -eq 'done') {
                $indeterminate = $false
                $pct = 100
                $etaText = 'termine'
            }
            elseif (-not $indeterminate -and $Total -gt 0) {
                $pct = [Math]::Min(100.0, (100.0 * [double]$Current / [double]$Total))
                if ($Current -gt 0 -and $elapsed -gt 1.5) {
                    $rate = $Current / $elapsed
                    if ($rate -gt 0) {
                        $remain = ($Total - $Current) / $rate
                        $etaText = 'reste ' + (Format-AdbEta $remain)
                    }
                }
                else {
                    $etaText = 'calcul…'
                }
            }
            elseif ($Phase -eq 'enum' -and $FilesSeen -gt 0 -and $elapsed -gt 2) {
                $rate = $FilesSeen / $elapsed
                $etaText = ('{0:N0}/s' -f $rate)
                # Soft fill based on log scale of files seen (visual only)
                $pct = [Math]::Min(85.0, 12.0 * [Math]::Log10([Math]::Max(10, $FilesSeen)))
                $indeterminate = $false
            }
            else {
                $etaText = '…'
            }

            if ($script:AdbProgressBar) {
                $script:AdbProgressBar.IsIndeterminate = $indeterminate
                if (-not $indeterminate) { $script:AdbProgressBar.Value = $pct }
            }
            if ($script:AdbProgressPct) {
                if ($indeterminate) {
                    $script:AdbProgressPct.Text = if ($FilesSeen -gt 0) { ('{0:N0}' -f $FilesSeen) } else { '…' }
                }
                elseif ($Total -gt 0 -and $Phase -ne 'done' -and $Phase -ne 'enum') {
                    $script:AdbProgressPct.Text = ('{0} / {1}  ·  {2:0}%' -f $Current, $Total, $pct)
                }
                else {
                    $script:AdbProgressPct.Text = ('{0:0} %' -f $pct)
                }
            }
            if ($script:AdbProgressEta) { $script:AdbProgressEta.Text = $etaText }
        }
        catch { }
    }

    function script:Write-AdbRepairUiLog {
        param([string]$Text, [switch]$Append)
        try {
            if (Get-Command Add-UiLog -ErrorAction SilentlyContinue) {
                Add-UiLog -Line $Text -Source 'ADB'
                return
            }
        }
        catch { }
    }

    function script:Set-AdbRepairBusy {
        param([bool]$Busy)
        $script:AdbRepairBusy = [bool]$Busy
        $enabled = -not $Busy
        $names = @(
            'BtnAdbScanFolder', 'BtnAdbScanCommon', 'BtnAdbScanDrive',
            'BtnAdbFetchClean', 'BtnAdbLearnPacks', 'BtnAdbRepairAll',
            'BtnAdbPathLapwiz', 'BtnAdbScanRecent', 'CmbAdbScanHistory',
            'BtnAdbCheckAll', 'BtnAdbUncheckAll'
            # BtnAdbOpenQuarantine reste actif : parcours en lecture seule pendant un job
        )
        $win = $script:AdbRepairWindow
        foreach ($n in $names) {
            try {
                if (-not $win) { break }
                $b = $win.FindName($n)
                if ($null -eq $b) { continue }
                # Toujours assigner IsEnabled (eviter le test PSObject.Properties fragile sur WPF)
                $b.IsEnabled = $enabled
            }
            catch { }
        }
        # Historique : ne reactiver Rescanner que s'il y a des entrees
        try {
            if (-not $Busy) { Refresh-AdbScanHistoryCombo }
        }
        catch { }
    }

    function script:Complete-AdbRepairJobUi {
        <# Reactivation forcee si un job a laisse l'UI bloquee. #>
        $script:AdbRepairBusy = $false
        try { Set-AdbRepairBusy $false } catch { }
        try {
            if ($script:AdbRepairTimerState -and $script:AdbRepairTimerState.Timer) {
                $script:AdbRepairTimerState.Timer.Stop()
            }
        }
        catch { }
        $script:AdbRepairTimerState = $null
    }

    function script:Show-AdbRepairReportWindow {
        param([Parameter(Mandatory)]$Report)

        $ok = 0; $fail = 0; $skip = 0
        try { $ok = [int]$Report.Ok } catch { }
        try { $fail = [int]$Report.Fail } catch { }
        try { $skip = [int]$Report.Skip } catch { }
        $qRoot = ''
        try { $qRoot = [string]$Report.Quarantine } catch { }
        $reportPath = ''
        try { $reportPath = [string]$Report.ReportPath } catch { }
        $startedAt = ''
        try { $startedAt = [string]$Report.StartedAt } catch { }
        $endedAt = ''
        try { $endedAt = [string]$Report.EndedAt } catch { }
        $actions = @()
        try {
            foreach ($a in @($Report.Actions)) {
                if ($null -eq $a) { continue }
                $actions += [pscustomobject]@{
                    Status     = [string]$a.Status
                    Action     = [string]$a.Action
                    Name       = [string]$a.Name
                    Path       = [string]$a.Path
                    Source     = [string]$a.Source
                    Pack       = [string]$a.Pack
                    Quarantine = [string]$a.Quarantine
                    Hash       = [string]$a.Hash
                }
            }
        }
        catch { }

        $ptFolders = @()
        $scFolders = @()
        try { $ptFolders = @($Report.PlatformToolsFolders | ForEach-Object { [string]$_ }) } catch { }
        try { $scFolders = @($Report.ScrcpyFolders | ForEach-Object { [string]$_ }) } catch { }
        $issues = @()
        try {
            foreach ($i in @($Report.Issues)) {
                if ($null -eq $i) { continue }
                $issues += [pscustomobject]@{
                    Severity = [string]$i.Severity
                    Code     = [string]$i.Code
                    Name     = [string]$i.Name
                    Path     = [string]$i.Path
                    Detail   = [string]$i.Detail
                }
            }
        }
        catch { }
        $verifyFail = 0
        $verifyWarn = 0
        try { $verifyFail = [int]$Report.VerifyFail } catch { }
        try { $verifyWarn = [int]$Report.VerifyWarn } catch { }
        if ($verifyFail -eq 0 -and $verifyWarn -eq 0 -and $issues.Count -gt 0) {
            $verifyFail = @($issues | Where-Object { $_.Severity -eq 'FAIL' }).Count
            $verifyWarn = @($issues | Where-Object { $_.Severity -eq 'WARN' }).Count
        }

        $win = New-Object System.Windows.Window
        $win.Title = 'Lapwiz — Rapport reparation ADB'
        $win.Width = 820
        $win.Height = 620
        $win.MinWidth = 640
        $win.MinHeight = 420
        $win.WindowStartupLocation = 'CenterOwner'
        if ($script:AdbRepairWindow) {
            try { $win.Owner = $script:AdbRepairWindow } catch { }
        }
        $win.Background = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0xF2, 0xF6, 0xF5))

        $root = New-Object System.Windows.Controls.DockPanel
        $root.LastChildFill = $true
        $root.Margin = [System.Windows.Thickness]::new(0)

        # Header
        $header = New-Object System.Windows.Controls.Border
        $header.Background = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0x12, 0x1F, 0x22))
        $header.Padding = [System.Windows.Thickness]::new(20, 16, 20, 16)
        [System.Windows.Controls.DockPanel]::SetDock($header, 'Top')

        $headerStack = New-Object System.Windows.Controls.StackPanel
        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = 'Rapport de reparation ADB / scrcpy'
        $title.FontSize = 18
        $title.FontWeight = 'SemiBold'
        $title.Foreground = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0xE8, 0xF4, 0xF1))
        $sub = New-Object System.Windows.Controls.TextBlock
        $sub.Margin = [System.Windows.Thickness]::new(0, 4, 0, 12)
        $sub.FontSize = 12
        $sub.Foreground = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0x6F, 0x8F, 0x8A))
        $timeLine = @()
        if ($startedAt) { $timeLine += "Debut $startedAt" }
        if ($endedAt) { $timeLine += "Fin $endedAt" }
        $sub.Text = if ($timeLine.Count -gt 0) { ($timeLine -join '  ·  ') } else { 'Detail des fichiers traites' }

        $chips = New-Object System.Windows.Controls.WrapPanel
        function New-AdbReportChip([string]$Label, [string]$Value, [byte]$R, [byte]$G, [byte]$B) {
            $b = New-Object System.Windows.Controls.Border
            $b.CornerRadius = [System.Windows.CornerRadius]::new(10)
            $b.Padding = [System.Windows.Thickness]::new(12, 8, 12, 8)
            $b.Margin = [System.Windows.Thickness]::new(0, 0, 8, 4)
            $b.Background = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.Color]::FromArgb(40, $R, $G, $B))
            $b.BorderBrush = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.Color]::FromRgb($R, $G, $B))
            $b.BorderThickness = [System.Windows.Thickness]::new(1)
            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.Orientation = 'Horizontal'
            $t1 = New-Object System.Windows.Controls.TextBlock
            $t1.Text = $Label
            $t1.FontSize = 11
            $t1.VerticalAlignment = 'Center'
            $t1.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
            $t1.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.Color]::FromRgb(0xA8, 0xC4, 0xBF))
            $t2 = New-Object System.Windows.Controls.TextBlock
            $t2.Text = $Value
            $t2.FontSize = 16
            $t2.FontWeight = 'Bold'
            $t2.VerticalAlignment = 'Center'
            $t2.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.Color]::FromRgb($R, $G, $B))
            [void]$sp.Children.Add($t1)
            [void]$sp.Children.Add($t2)
            $b.Child = $sp
            return $b
        }
        [void]$chips.Children.Add((New-AdbReportChip 'OK' ([string]$ok) 0x6B 0xCF 0x9B))
        [void]$chips.Children.Add((New-AdbReportChip 'Echecs' ([string]$fail) 0xFF 0x7A 0x6E))
        [void]$chips.Children.Add((New-AdbReportChip 'Ignores' ([string]$skip) 0xE2 0xB4 0x5C))
        [void]$chips.Children.Add((New-AdbReportChip 'Actions' ([string]$actions.Count) 0x7E 0xB8 0xC9))
        if ($verifyFail -gt 0) {
            [void]$chips.Children.Add((New-AdbReportChip 'Incoherences' ([string]$issues.Count) 0xFF 0x7A 0x6E))
        }
        else {
            [void]$chips.Children.Add((New-AdbReportChip 'Incoherences' ([string]$issues.Count) 0x65 0xB8 0xA2))
        }

        [void]$headerStack.Children.Add($title)
        [void]$headerStack.Children.Add($sub)
        [void]$headerStack.Children.Add($chips)
        $header.Child = $headerStack
        [void]$root.Children.Add($header)

        # Footer buttons
        $footer = New-Object System.Windows.Controls.Border
        $footer.Background = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0xFF, 0xFF, 0xFF))
        $footer.BorderBrush = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0xC9, 0xD8, 0xD5))
        $footer.BorderThickness = [System.Windows.Thickness]::new(0, 1, 0, 0)
        $footer.Padding = [System.Windows.Thickness]::new(16, 12, 16, 12)
        [System.Windows.Controls.DockPanel]::SetDock($footer, 'Bottom')

        $footerDock = New-Object System.Windows.Controls.DockPanel
        $btnClose = New-Object System.Windows.Controls.Button
        $btnClose.Content = 'Fermer'
        $btnClose.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
        $btnClose.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
        [System.Windows.Controls.DockPanel]::SetDock($btnClose, 'Right')
        $btnClose.Add_Click({ $win.Close() }.GetNewClosure())

        $btnOpenQ = New-Object System.Windows.Controls.Button
        $btnOpenQ.Content = 'Ouvrir quarantaine'
        $btnOpenQ.Padding = [System.Windows.Thickness]::new(14, 8, 14, 8)
        $btnOpenQ.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
        [System.Windows.Controls.DockPanel]::SetDock($btnOpenQ, 'Right')
        $btnOpenQ.IsEnabled = (-not [string]::IsNullOrWhiteSpace($qRoot) -and (Test-Path -LiteralPath $qRoot))
        $btnOpenQ.Add_Click({
                param($s, $e)
                try {
                    if ($qRoot -and (Test-Path -LiteralPath $qRoot)) {
                        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $qRoot + '"') | Out-Null
                    }
                }
                catch { }
            }.GetNewClosure())

        $btnCopy = New-Object System.Windows.Controls.Button
        $btnCopy.Content = 'Copier le rapport'
        $btnCopy.Padding = [System.Windows.Thickness]::new(14, 8, 14, 8)
        [System.Windows.Controls.DockPanel]::SetDock($btnCopy, 'Right')
        $btnCopy.Add_Click({
                try {
                    $lines = New-Object System.Collections.Generic.List[string]
                    [void]$lines.Add("Lapwiz ADB Repair — OK=$ok Fail=$fail Skip=$skip")
                    if ($qRoot) { [void]$lines.Add("Quarantaine: $qRoot") }
                    foreach ($a in $actions) {
                        [void]$lines.Add(("[{0}] {1} | {2} | {3}" -f $a.Status, $a.Action, $a.Name, $a.Path))
                    }
                    [System.Windows.Clipboard]::SetText(($lines -join [Environment]::NewLine))
                    $btnCopy.Content = 'Copie !'
                }
                catch { }
            }.GetNewClosure())

        $hint = New-Object System.Windows.Controls.TextBlock
        $hint.VerticalAlignment = 'Center'
        $hint.FontSize = 11
        $hint.TextWrapping = 'Wrap'
        $hint.Foreground = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0x5F, 0x73, 0x78))
        if ($reportPath) {
            $hint.Text = "Rapport enregistre : $reportPath"
        }
        elseif ($qRoot) {
            $hint.Text = "Quarantaine : $qRoot"
        }
        else {
            $hint.Text = 'Aucune quarantaine (rien a reparer).'
        }

        [void]$footerDock.Children.Add($btnClose)
        [void]$footerDock.Children.Add($btnOpenQ)
        [void]$footerDock.Children.Add($btnCopy)
        [void]$footerDock.Children.Add($hint)
        $footer.Child = $footerDock
        [void]$root.Children.Add($footer)

        # Body scroll
        $scroll = New-Object System.Windows.Controls.ScrollViewer
        $scroll.VerticalScrollBarVisibility = 'Auto'
        $scroll.Padding = [System.Windows.Thickness]::new(16, 14, 16, 14)

        $body = New-Object System.Windows.Controls.StackPanel

        if ($ptFolders.Count -gt 0 -or $scFolders.Count -gt 0) {
            $foldersBox = New-Object System.Windows.Controls.Border
            $foldersBox.Background = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.Color]::FromRgb(0xFF, 0xFF, 0xFF))
            $foldersBox.BorderBrush = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.Color]::FromRgb(0xC9, 0xD8, 0xD5))
            $foldersBox.BorderThickness = [System.Windows.Thickness]::new(1)
            $foldersBox.CornerRadius = [System.Windows.CornerRadius]::new(12)
            $foldersBox.Padding = [System.Windows.Thickness]::new(14, 12, 14, 12)
            $foldersBox.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
            $fs = New-Object System.Windows.Controls.StackPanel
            $fh = New-Object System.Windows.Controls.TextBlock
            $fh.Text = 'Dossiers synchronises'
            $fh.FontWeight = 'SemiBold'
            $fh.FontSize = 13
            $fh.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
            $fh.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.Color]::FromRgb(0x28, 0x33, 0x38))
            [void]$fs.Children.Add($fh)
            foreach ($f in $ptFolders) {
                $t = New-Object System.Windows.Controls.TextBlock
                $t.Text = "platform-tools  ·  $f"
                $t.FontSize = 12
                $t.TextWrapping = 'Wrap'
                $t.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
                $t.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                    [System.Windows.Media.Color]::FromRgb(0x2A, 0x6F, 0x97))
                [void]$fs.Children.Add($t)
            }
            foreach ($f in $scFolders) {
                $t = New-Object System.Windows.Controls.TextBlock
                $t.Text = "scrcpy + ADB Google  ·  $f"
                $t.FontSize = 12
                $t.TextWrapping = 'Wrap'
                $t.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
                $t.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                    [System.Windows.Media.Color]::FromRgb(0x1C, 0x5D, 0x5F))
                [void]$fs.Children.Add($t)
            }
            $foldersBox.Child = $fs
            [void]$body.Children.Add($foldersBox)
        }

        # Incoherences
        $issTitle = New-Object System.Windows.Controls.TextBlock
        $issTitle.Text = if ($issues.Count -eq 0) {
            'Verification : aucune incoherence'
        }
        else {
            ("Verification : {0} incoherence(s) (FAIL={1} WARN={2})" -f $issues.Count, $verifyFail, $verifyWarn)
        }
        $issTitle.FontWeight = 'SemiBold'
        $issTitle.FontSize = 13
        $issTitle.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
        $issTitle.Foreground = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0x28, 0x33, 0x38))
        [void]$body.Children.Add($issTitle)

        foreach ($i in $issues) {
            $card = New-Object System.Windows.Controls.Border
            $card.BorderThickness = [System.Windows.Thickness]::new(1)
            $card.CornerRadius = [System.Windows.CornerRadius]::new(10)
            $card.Padding = [System.Windows.Thickness]::new(12, 10, 12, 10)
            $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
            $sev = ([string]$i.Severity).ToUpperInvariant()
            if ($sev -eq 'FAIL') {
                $card.Background = New-Object System.Windows.Media.SolidColorBrush (
                    [System.Windows.Media.Color]::FromRgb(0xFF, 0xEB, 0xE8))
                $card.BorderBrush = New-Object System.Windows.Media.SolidColorBrush (
                    [System.Windows.Media.Color]::FromRgb(0xFF, 0x7A, 0x6E))
            }
            else {
                $card.Background = New-Object System.Windows.Media.SolidColorBrush (
                    [System.Windows.Media.Color]::FromRgb(0xFF, 0xF4, 0xE0))
                $card.BorderBrush = New-Object System.Windows.Media.SolidColorBrush (
                    [System.Windows.Media.Color]::FromRgb(0xE2, 0xB4, 0x5C))
            }
            $sp = New-Object System.Windows.Controls.StackPanel
            $t1 = New-Object System.Windows.Controls.TextBlock
            $t1.Text = ("[{0}] {1}  ·  {2}" -f $i.Severity, $i.Code, $i.Name)
            $t1.FontWeight = 'SemiBold'
            $t1.FontSize = 12
            $t2 = New-Object System.Windows.Controls.TextBlock
            $t2.Text = [string]$i.Detail
            $t2.FontSize = 11
            $t2.TextWrapping = 'Wrap'
            $t3 = New-Object System.Windows.Controls.TextBlock
            $t3.Text = [string]$i.Path
            $t3.FontSize = 11
            $t3.TextWrapping = 'Wrap'
            $t3.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.Color]::FromRgb(0x5F, 0x73, 0x78))
            [void]$sp.Children.Add($t1)
            [void]$sp.Children.Add($t2)
            [void]$sp.Children.Add($t3)
            $card.Child = $sp
            [void]$body.Children.Add($card)
        }

        $listTitle = New-Object System.Windows.Controls.TextBlock
        $listTitle.Text = ('Fichiers traites ({0})' -f $actions.Count)
        $listTitle.FontWeight = 'SemiBold'
        $listTitle.FontSize = 13
        $listTitle.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
        $listTitle.Foreground = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0x28, 0x33, 0x38))
        [void]$body.Children.Add($listTitle)

        if ($actions.Count -eq 0) {
            $empty = New-Object System.Windows.Controls.TextBlock
            $empty.Text = 'Aucune action enregistree.'
            $empty.FontSize = 13
            $empty.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.Color]::FromRgb(0x5F, 0x73, 0x78))
            [void]$body.Children.Add($empty)
        }
        else {
            foreach ($a in $actions) {
                $card = New-Object System.Windows.Controls.Border
                $card.Background = New-Object System.Windows.Media.SolidColorBrush (
                    [System.Windows.Media.Color]::FromRgb(0xFF, 0xFF, 0xFF))
                $card.BorderBrush = New-Object System.Windows.Media.SolidColorBrush (
                    [System.Windows.Media.Color]::FromRgb(0xC9, 0xD8, 0xD5))
                $card.BorderThickness = [System.Windows.Thickness]::new(1)
                $card.CornerRadius = [System.Windows.CornerRadius]::new(10)
                $card.Padding = [System.Windows.Thickness]::new(12, 10, 12, 10)
                $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)

                $row = New-Object System.Windows.Controls.DockPanel
                $row.LastChildFill = $true

                $badge = New-Object System.Windows.Controls.Border
                $badge.CornerRadius = [System.Windows.CornerRadius]::new(6)
                $badge.Padding = [System.Windows.Thickness]::new(8, 3, 8, 3)
                $badge.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
                $badge.VerticalAlignment = 'Top'
                [System.Windows.Controls.DockPanel]::SetDock($badge, 'Left')
                $badgeTxt = New-Object System.Windows.Controls.TextBlock
                $badgeTxt.Text = [string]$a.Status
                $badgeTxt.FontSize = 11
                $badgeTxt.FontWeight = 'Bold'
                $st = ([string]$a.Status).ToUpperInvariant()
                if ($st -eq 'OK') {
                    $badge.Background = New-Object System.Windows.Media.SolidColorBrush (
                        [System.Windows.Media.Color]::FromRgb(0xE3, 0xF6, 0xEC))
                    $badgeTxt.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                        [System.Windows.Media.Color]::FromRgb(0x1F, 0x8A, 0x5B))
                }
                elseif ($st -eq 'FAIL') {
                    $badge.Background = New-Object System.Windows.Media.SolidColorBrush (
                        [System.Windows.Media.Color]::FromRgb(0xFF, 0xEB, 0xE8))
                    $badgeTxt.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                        [System.Windows.Media.Color]::FromRgb(0xB5, 0x4A, 0x4A))
                }
                else {
                    $badge.Background = New-Object System.Windows.Media.SolidColorBrush (
                        [System.Windows.Media.Color]::FromRgb(0xFF, 0xF4, 0xE0))
                    $badgeTxt.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                        [System.Windows.Media.Color]::FromRgb(0xA0, 0x74, 0x20))
                }
                $badge.Child = $badgeTxt

                $actBadge = New-Object System.Windows.Controls.TextBlock
                $actBadge.Text = [string]$a.Action
                $actBadge.Width = 72
                $actBadge.FontSize = 11
                $actBadge.FontWeight = 'SemiBold'
                $actBadge.VerticalAlignment = 'Top'
                $actBadge.Margin = [System.Windows.Thickness]::new(0, 2, 10, 0)
                $actBadge.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                    [System.Windows.Media.Color]::FromRgb(0x2A, 0x6F, 0x97))
                [System.Windows.Controls.DockPanel]::SetDock($actBadge, 'Left')

                $stack = New-Object System.Windows.Controls.StackPanel
                $n1 = New-Object System.Windows.Controls.TextBlock
                $packPart = if ($a.Pack) { "  ·  $($a.Pack)" } else { '' }
                $n1.Text = "$($a.Name)$packPart"
                $n1.FontSize = 13
                $n1.FontWeight = 'SemiBold'
                $n1.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                    [System.Windows.Media.Color]::FromRgb(0x28, 0x33, 0x38))
                $n2 = New-Object System.Windows.Controls.TextBlock
                $n2.Text = [string]$a.Path
                $n2.FontSize = 11
                $n2.TextWrapping = 'Wrap'
                $n2.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                    [System.Windows.Media.Color]::FromRgb(0x5F, 0x73, 0x78))
                [void]$stack.Children.Add($n1)
                [void]$stack.Children.Add($n2)
                if ($a.Hash) {
                    $n3 = New-Object System.Windows.Controls.TextBlock
                    $h = [string]$a.Hash
                    if ($h.Length -gt 16) { $h = $h.Substring(0, 16) + '…' }
                    $n3.Text = "SHA-256  $h"
                    $n3.FontSize = 10
                    $n3.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas, Cascadia Mono, Courier New')
                    $n3.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                        [System.Windows.Media.Color]::FromRgb(0x9B, 0xB7, 0xFF))
                    [void]$stack.Children.Add($n3)
                }

                [void]$row.Children.Add($badge)
                [void]$row.Children.Add($actBadge)
                [void]$row.Children.Add($stack)
                $card.Child = $row
                [void]$body.Children.Add($card)
            }
        }

        $scroll.Content = $body
        [void]$root.Children.Add($scroll)
        $win.Content = $root

        try {
            [void]$win.ShowDialog()
        }
        catch {
            try { [void]$win.Show() } catch { }
        }
    }

    function script:Show-AdbRepairGuideWindow {
        $sections = @(
            @{
                Icon = [char]0xE8F1
                Title = 'A — Role de ADB Repair'
                Body  = "Detecte et remplace les binaires ADB / scrcpy alteres (souvent apres Expiro ou infection) par des packs propres. Ne touche jamais aux fichiers metier hors pack (DB Coolray, APK, configs)."
            },
            @{
                Icon = [char]0xE8B7
                Title = 'B — Packs clean (etape 1)'
                Body  = "Apprendre packs Desktop : copie Bureau\platform-tools + scrcpy-win64-v4.1 vers %LocalAppData%\LapwizSetup\clean-tools.`nTelecharger clean : telecharge platform-tools (Google) + scrcpy (GitHub) puis meme cache.`nCes packs sont la reference SHA-256 pour scanner et reparer."
            },
            @{
                Icon = [char]0xE721
                Title = 'C — Scanner (etape 2)'
                Body  = "Choisir dossier : un chemin precis.`nScan rapide : emplacements courants.`nScan disque : un disque entier (long).`nRecents / Rescanner : rejoue un scan precedent.`nResultat : liste des fichiers ADB/scrcpy avec statut Match ou a reparer."
            },
            @{
                Icon = [char]0xE73E
                Title = 'D — Resultats, cocher / decocher'
                Body  = "Chaque ligne = un fichier trouve. Cochez ceux a traiter.`nTout cocher / Tout decocher : selection globale.`nSeuls les fichiers coches declenchent la reparation."
            },
            @{
                Icon = [char]0xE90F
                Title = 'E — Tout reparer (etape 3)'
                Body  = "1) Recharge les packs Bureau si presents.`n2) Classifie chaque dossier : scrcpy (sync pack scrcpy + ADB Google) ou platform-tools (sync pack Google complet).`n3) Flux strict : backup quarantaine → suppression → copie clean.`n4) Fichiers hors pack dans le meme dossier : intacts.`n5) Verification SHA-256 (incoherences)."
            },
            @{
                Icon = [char]0xE8CE
                Title = 'F — PATH et quarantaine (etape 4)'
                Body  = "PATH ADB Lapwiz : pointe le PATH utilisateur vers un ADB Lapwiz stable.`nOuvrir dossier quarantaine : Explorateur sur %LocalAppData%\LapwizSetup\adb-quarantine (sessions horodatees + repair-report.txt)."
            },
            @{
                Icon = [char]0xE9D5
                Title = 'G — Rapport detaille automatique'
                Body  = "En fin de reparation, une fenetre s'ouvre : compteurs OK/Echecs, dossiers synchronises, liste des actions (Installe/Remplace/Supprime), incoherences, bouton quarantaine / copier."
            },
            @{
                Icon = [char]0xE8AB
                Title = 'H — ADB Google vs ADB scrcpy'
                Body  = "Le ZIP scrcpy embarque souvent un adb.exe different de Google.`nLapwiz force le trio Google (adb.exe, AdbWinApi.dll, AdbWinUsbApi.dll) a cote de scrcpy pour la coherence."
            },
            @{
                Icon = [char]0xE7BA
                Title = 'I — Ce qui n''est PAS touche'
                Body  = "Bases Coolray (.db), APK, fichiers langue, README metier, tout nom absent du pack appris.`nSeuls les fichiers de la liste blanche platform-tools / scrcpy sont remplaces ou purges s'ils sont obsoletes."
            },
            @{
                Icon = [char]0xE8FD
                Title = 'J — Ordre recommande (A → Z)'
                Body  = "1 Packs (Apprendre ou Telecharger)`n2 Scanner (dossier / rapide / disque)`n3 Cocher les fichiers (ou Tout cocher)`n4 Tout reparer → lire le rapport`n5 Optionnel : PATH ADB Lapwiz + consulter quarantaine"
            },
            @{
                Icon = [char]0xE946
                Title = 'K — Journal et progression'
                Body  = "Barre de progression + ETA pendant scan/reparation.`nLe journal detaille est a droite de Lapwiz (statut, chemins, codes).`nLes boutons se reactivent automatiquement en fin de job."
            },
            @{
                Icon = [char]0xE7C3
                Title = 'L — Emplacements cles'
                Body  = "Bureau\platform-tools et Bureau\scrcpy-win64-v4.1 = references.`nclean-tools = cache Lapwiz.`nadb-quarantine\yyyyMMdd_HHmmss = sauvegardes avant remplacement + repair-report.txt."
            }
        )

        $win = New-Object System.Windows.Window
        $win.Title = 'Lapwiz — Guide ADB Repair'
        $win.Width = 760
        $win.Height = 640
        $win.MinWidth = 560
        $win.MinHeight = 420
        $win.WindowStartupLocation = 'CenterOwner'
        if ($script:AdbRepairWindow) {
            try { $win.Owner = $script:AdbRepairWindow } catch { }
        }
        $win.Background = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0xF2, 0xF6, 0xF5))

        $root = New-Object System.Windows.Controls.DockPanel
        $root.LastChildFill = $true

        $header = New-Object System.Windows.Controls.Border
        $header.Background = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0x12, 0x1F, 0x22))
        $header.Padding = [System.Windows.Thickness]::new(20, 16, 20, 16)
        [System.Windows.Controls.DockPanel]::SetDock($header, 'Top')
        $hs = New-Object System.Windows.Controls.StackPanel
        $ht = New-Object System.Windows.Controls.DockPanel
        $iconBadge = New-Object System.Windows.Controls.Border
        $iconBadge.Width = 36; $iconBadge.Height = 36; $iconBadge.CornerRadius = [System.Windows.CornerRadius]::new(18)
        $iconBadge.Background = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0x2A, 0x6F, 0x97))
        $iconBadge.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
        [System.Windows.Controls.DockPanel]::SetDock($iconBadge, 'Left')
        $iconGlyph = New-Object System.Windows.Controls.TextBlock
        $iconGlyph.Text = [string]([char]0xE946)
        $iconGlyph.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
        $iconGlyph.FontSize = 16
        $iconGlyph.Foreground = [System.Windows.Media.Brushes]::White
        $iconGlyph.HorizontalAlignment = 'Center'
        $iconGlyph.VerticalAlignment = 'Center'
        $iconBadge.Child = $iconGlyph
        $titles = New-Object System.Windows.Controls.StackPanel
        $t1 = New-Object System.Windows.Controls.TextBlock
        $t1.Text = 'Guide ADB / scrcpy Repair'
        $t1.FontSize = 18
        $t1.FontWeight = 'SemiBold'
        $t1.Foreground = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0xE8, 0xF4, 0xF1))
        $t2 = New-Object System.Windows.Controls.TextBlock
        $t2.Text = 'Fonctions de A a Z — role, ordre et fonctionnement'
        $t2.FontSize = 12
        $t2.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
        $t2.Foreground = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0x6F, 0x8F, 0x8A))
        [void]$titles.Children.Add($t1)
        [void]$titles.Children.Add($t2)
        [void]$ht.Children.Add($iconBadge)
        [void]$ht.Children.Add($titles)
        [void]$hs.Children.Add($ht)
        $header.Child = $hs
        [void]$root.Children.Add($header)

        $footer = New-Object System.Windows.Controls.Border
        $footer.Padding = [System.Windows.Thickness]::new(16, 12, 16, 12)
        $footer.Background = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0xFF, 0xFF, 0xFF))
        $footer.BorderBrush = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0xC9, 0xD8, 0xD5))
        $footer.BorderThickness = [System.Windows.Thickness]::new(0, 1, 0, 0)
        [System.Windows.Controls.DockPanel]::SetDock($footer, 'Bottom')
        $fd = New-Object System.Windows.Controls.DockPanel
        $btnClose = New-Object System.Windows.Controls.Button
        $btnClose.Content = 'Fermer'
        $btnClose.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
        [System.Windows.Controls.DockPanel]::SetDock($btnClose, 'Right')
        $btnClose.Add_Click({ $win.Close() }.GetNewClosure())
        $hint = New-Object System.Windows.Controls.TextBlock
        $hint.Text = 'Astuce : placez platform-tools et scrcpy-win64-v4.1 sur le Bureau avant « Tout reparer ».'
        $hint.FontSize = 11
        $hint.TextWrapping = 'Wrap'
        $hint.VerticalAlignment = 'Center'
        $hint.Foreground = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.Color]::FromRgb(0x5F, 0x73, 0x78))
        [void]$fd.Children.Add($btnClose)
        [void]$fd.Children.Add($hint)
        $footer.Child = $fd
        [void]$root.Children.Add($footer)

        $scroll = New-Object System.Windows.Controls.ScrollViewer
        $scroll.VerticalScrollBarVisibility = 'Auto'
        $scroll.Padding = [System.Windows.Thickness]::new(16, 14, 16, 14)
        $body = New-Object System.Windows.Controls.StackPanel

        foreach ($sec in $sections) {
            $card = New-Object System.Windows.Controls.Border
            $card.Background = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.Color]::FromRgb(0xFF, 0xFF, 0xFF))
            $card.BorderBrush = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.Color]::FromRgb(0xC9, 0xD8, 0xD5))
            $card.BorderThickness = [System.Windows.Thickness]::new(1)
            $card.CornerRadius = [System.Windows.CornerRadius]::new(12)
            $card.Padding = [System.Windows.Thickness]::new(14, 12, 14, 12)
            $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)

            $row = New-Object System.Windows.Controls.DockPanel
            $row.LastChildFill = $true
            $chip = New-Object System.Windows.Controls.Border
            $chip.Width = 40; $chip.Height = 40
            $chip.CornerRadius = [System.Windows.CornerRadius]::new(12)
            $chip.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
            $chip.VerticalAlignment = 'Top'
            $chip.Background = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.Color]::FromRgb(0xE6, 0xEF, 0xED))
            [System.Windows.Controls.DockPanel]::SetDock($chip, 'Left')
            $gi = New-Object System.Windows.Controls.TextBlock
            $gi.Text = [string]$sec.Icon
            $gi.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
            $gi.FontSize = 18
            $gi.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.Color]::FromRgb(0x2A, 0x6F, 0x97))
            $gi.HorizontalAlignment = 'Center'
            $gi.VerticalAlignment = 'Center'
            $chip.Child = $gi

            $txt = New-Object System.Windows.Controls.StackPanel
            $st = New-Object System.Windows.Controls.TextBlock
            $st.Text = [string]$sec.Title
            $st.FontSize = 14
            $st.FontWeight = 'SemiBold'
            $st.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.Color]::FromRgb(0x28, 0x33, 0x38))
            $sb = New-Object System.Windows.Controls.TextBlock
            $sb.Text = [string]$sec.Body
            $sb.FontSize = 12
            $sb.TextWrapping = 'Wrap'
            $sb.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0)
            $sb.LineHeight = 18
            $sb.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.Color]::FromRgb(0x5F, 0x73, 0x78))
            [void]$txt.Children.Add($st)
            [void]$txt.Children.Add($sb)
            [void]$row.Children.Add($chip)
            [void]$row.Children.Add($txt)
            $card.Child = $row
            [void]$body.Children.Add($card)
        }

        $scroll.Content = $body
        [void]$root.Children.Add($scroll)
        $win.Content = $root
        try {
            [void]$win.ShowDialog()
        }
        catch {
            try { [void]$win.Show() } catch { }
        }
    }

    function script:Update-AdbRepairHitList {
        param([object[]]$Hits)
        $script:AdbRepairHits = @($Hits)
        if (-not $script:AdbRepairList) { return }
        $script:AdbRepairList.Items.Clear()
        $differ = 0
        foreach ($h in $script:AdbRepairHits) {
            if ([string]$h.Status -ne 'Match') { $differ++ }
            $panel = New-Object System.Windows.Controls.DockPanel
            $panel.Margin = [System.Windows.Thickness]::new(4, 3, 4, 3)
            $panel.LastChildFill = $true

            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.IsChecked = [bool]$h.Selected
            $cb.VerticalAlignment = 'Center'
            $cb.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
            $cb.Tag = $h
            $cb.Add_Click({
                param($sender, $e)
                try {
                    if ($null -eq $sender) { $sender = $args[0] }
                    if ($sender -and $sender.Tag) {
                        try { $sender.Tag.Selected = [bool]$sender.IsChecked } catch {
                            try { $sender.Tag | Add-Member -NotePropertyName Selected -NotePropertyValue ([bool]$sender.IsChecked) -Force } catch { }
                        }
                    }
                }
                catch { }
            })
            [System.Windows.Controls.DockPanel]::SetDock($cb, 'Left')

            $st = New-Object System.Windows.Controls.TextBlock
            $st.Text = [string]$h.Status
            $st.Width = 72
            $st.FontSize = 11
            $st.VerticalAlignment = 'Center'
            $st.TextAlignment = 'Right'
            $st.Foreground = $script:AdbRepairWindow.TryFindResource('BrushAccentSoft')
            if ($null -eq $st.Foreground) {
                $st.Foreground = [System.Windows.Media.Brushes]::Gray
            }
            [System.Windows.Controls.DockPanel]::SetDock($st, 'Right')

            $stack = New-Object System.Windows.Controls.StackPanel
            $t1 = New-Object System.Windows.Controls.TextBlock
            $t1.Text = ('{0}  [{1}]' -f [string]$h.Name, [string]$h.Kind)
            $t1.FontSize = 13
            $t1.FontWeight = 'SemiBold'
            $t1.Foreground = $script:AdbRepairWindow.TryFindResource('BrushTextPrimary')
            if ($null -eq $t1.Foreground) {
                $t1.Foreground = [System.Windows.Media.Brushes]::Black
            }
            $t2 = New-Object System.Windows.Controls.TextBlock
            $t2.Text = [string]$h.Path
            $t2.FontSize = 11
            $t2.TextWrapping = 'Wrap'
            $t2.Foreground = $script:AdbRepairWindow.TryFindResource('BrushTextMuted')
            if ($null -eq $t2.Foreground) {
                $t2.Foreground = [System.Windows.Media.Brushes]::Gray
            }
            [void]$stack.Children.Add($t1)
            [void]$stack.Children.Add($t2)

            [void]$panel.Children.Add($cb)
            [void]$panel.Children.Add($st)
            [void]$panel.Children.Add($stack)
            [void]$script:AdbRepairList.Items.Add($panel)
        }
        if ($script:AdbRepairSummary) {
            $script:AdbRepairSummary.Text = ('{0} fichier(s) · {1} a reparer' -f $script:AdbRepairHits.Count, $differ)
        }
    }

    function script:Set-AdbRepairSelection {
        param([bool]$Selected)
        if (-not $script:AdbRepairHits) { return }
        foreach ($h in $script:AdbRepairHits) {
            try { $h.Selected = $Selected } catch {
                try { $h | Add-Member -NotePropertyName Selected -NotePropertyValue $Selected -Force } catch { }
            }
        }
        if (-not $script:AdbRepairList) { return }
        foreach ($item in @($script:AdbRepairList.Items)) {
            try {
                if ($item -is [System.Windows.Controls.Panel]) {
                    foreach ($child in @($item.Children)) {
                        if ($child -is [System.Windows.Controls.CheckBox]) {
                            $child.IsChecked = $Selected
                            if ($child.Tag) {
                                try { $child.Tag.Selected = $Selected } catch { }
                            }
                        }
                    }
                }
            }
            catch { }
        }
    }

    function script:Start-AdbRepairJob {
        param(
            [Parameter(Mandatory)][ValidateSet('ScanFolder', 'ScanCommon', 'ScanDrive', 'FetchClean', 'LearnPacks', 'Repair')]
            [string]$JobType,
            [hashtable]$JobArgs = @{},
            [string]$Label = 'ADB Repair'
        )
        if ($script:AdbRepairBusy) { return }
        try {
        Set-AdbRepairBusy $true
        $script:AdbProgressStarted = [datetime]::UtcNow
        $script:AdbPendingRepairReport = $null
        $script:AdbOpenRepairReport = ($JobType -eq 'Repair')
        Set-AdbProgressUi -Phase 'work' -Message $Label -Started $script:AdbProgressStarted
        Write-AdbRepairUiLog -Text ("-- $Label --") -Append

        $logQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $progressBox = [hashtable]::Synchronized(@{
                Phase      = 'work'
                Current    = 0
                Total      = 0
                FilesSeen  = 0
                Message    = $Label
                StartedUtc = [datetime]::UtcNow
                Tick       = [datetime]::UtcNow.Ticks
            })
        $resultBox = [hashtable]::Synchronized(@{
                Done     = $false
                Error    = $null
                Hits     = $null
                Packages = $null
                Repair   = $null
                HashMap  = $null
                JobType  = $JobType
            })

        # Snapshot serializable args
        $argCopy = [hashtable]::Synchronized(@{})
        foreach ($k in @($JobArgs.Keys)) { $argCopy[$k] = $JobArgs[$k] }
        $argCopy['JobType'] = $JobType
        if ($script:AdbCleanPackages) {
            $argCopy['PlatformToolsDir'] = [string]$script:AdbCleanPackages.PlatformToolsDir
            $argCopy['ScrcpyDir'] = [string]$script:AdbCleanPackages.ScrcpyDir
        }
        if ($script:AdbCleanHashMap) {
            $argCopy['CleanHashMap'] = $script:AdbCleanHashMap
        }
        if ($JobType -eq 'Repair') {
            $argCopy['HitPaths'] = @($script:AdbRepairHits | Where-Object { [bool]$_.Selected } | ForEach-Object {
                    @{ Path = [string]$_.Path; Kind = [string]$_.Kind; Name = [string]$_.Name }
                })
        }

        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = 'STA'
        $runspace.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $runspace

        [void]$ps.AddScript({
                param($EnginePath, $LogQueue, $ResultBox, $JobArgs, $ProgressBox)
                Set-StrictMode -Version Latest
                $ErrorActionPreference = 'Stop'
                . $EnginePath
                $onLog = {
                    param($m, $l)
                    [void]$LogQueue.Enqueue([string]$m)
                }
                try {
                    $job = [string]$JobArgs['JobType']
                    $map = $null
                    if ($JobArgs.ContainsKey('CleanHashMap')) { $map = $JobArgs['CleanHashMap'] }
                    Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'work' -Message $job

                    switch ($job) {
                        'ScanFolder' {
                            $root = [string]$JobArgs['Root']
                            $pt = if ($JobArgs.ContainsKey('PlatformToolsDir')) { [string]$JobArgs['PlatformToolsDir'] } else { $null }
                            $sc = if ($JobArgs.ContainsKey('ScrcpyDir')) { [string]$JobArgs['ScrcpyDir'] } else { $null }
                            $hits = Scan-AdbScrcpyRoots -Roots @($root) -CleanHashMap $map -OnLog $onLog -Recurse `
                                -ProgressBox $ProgressBox -PlatformToolsDir $pt -ScrcpyDir $sc
                            $ResultBox['Hits'] = $hits
                        }
                        'ScanCommon' {
                            $roots = Get-AdbCommonScanRoots
                            $pt = if ($JobArgs.ContainsKey('PlatformToolsDir')) { [string]$JobArgs['PlatformToolsDir'] } else { $null }
                            $sc = if ($JobArgs.ContainsKey('ScrcpyDir')) { [string]$JobArgs['ScrcpyDir'] } else { $null }
                            $hits = Scan-AdbScrcpyRoots -Roots $roots -CleanHashMap $map -OnLog $onLog -Recurse `
                                -ProgressBox $ProgressBox -PlatformToolsDir $pt -ScrcpyDir $sc
                            $ResultBox['Hits'] = $hits
                        }
                        'ScanDrive' {
                            $root = [string]$JobArgs['Root']
                            $pt = if ($JobArgs.ContainsKey('PlatformToolsDir')) { [string]$JobArgs['PlatformToolsDir'] } else { $null }
                            $sc = if ($JobArgs.ContainsKey('ScrcpyDir')) { [string]$JobArgs['ScrcpyDir'] } else { $null }
                            $hits = Scan-AdbScrcpyRoots -Roots @($root) -CleanHashMap $map -OnLog $onLog -Recurse `
                                -ProgressBox $ProgressBox -PlatformToolsDir $pt -ScrcpyDir $sc
                            $ResultBox['Hits'] = $hits
                        }
                        'FetchClean' {
                            Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'fetch' -Message 'Telechargement packs clean…'
                            $force = [bool]$JobArgs['ForceRefresh']
                            $pkgs = Ensure-AdbCleanPackages -OnLog $onLog -ForceRefresh:$force
                            $ResultBox['Packages'] = $pkgs
                            $ResultBox['HashMap'] = Build-AdbCleanHashMap -PlatformToolsDir $pkgs.PlatformToolsDir -ScrcpyDir $pkgs.ScrcpyDir
                            Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'done' -Current 1 -Total 1 -Message 'Packs prets'
                        }
                        'LearnPacks' {
                            Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'learn' -Message 'Apprentissage packs Desktop…'
                            $ptSrc = if ($JobArgs.ContainsKey('PlatformToolsSource')) { [string]$JobArgs['PlatformToolsSource'] } else { '' }
                            $scSrc = if ($JobArgs.ContainsKey('ScrcpySource')) { [string]$JobArgs['ScrcpySource'] } else { '' }
                            $pkgs = Import-AdbReferencePacks -PlatformToolsSource $ptSrc -ScrcpySource $scSrc -OnLog $onLog
                            $ResultBox['Packages'] = $pkgs
                            $ResultBox['HashMap'] = Build-AdbCleanHashMap -PlatformToolsDir $pkgs.PlatformToolsDir -ScrcpyDir $pkgs.ScrcpyDir
                            Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'done' -Current 1 -Total 1 -Message 'Packs appris'
                        }
                        'Repair' {
                            Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'learn' -Message 'Packs Desktop (platform-tools + scrcpy)…'
                            $desk = [Environment]::GetFolderPath('Desktop')
                            $ptSrc = Join-Path $desk 'platform-tools'
                            $scSrc = ''
                            foreach ($cand in @(
                                    (Join-Path $desk 'scrcpy-win64-v4.1'),
                                    (Join-Path $desk 'scrcpy-win64'),
                                    (Join-Path $desk 'scrcpy')
                                )) {
                                if (Test-Path -LiteralPath (Join-Path $cand 'scrcpy.exe')) {
                                    $scSrc = $cand
                                    break
                                }
                            }
                            if ((Test-Path -LiteralPath $ptSrc) -and $scSrc) {
                                [void]$LogQueue.Enqueue("[Info] Recharge packs : $ptSrc | $scSrc")
                                $pkgs = Import-AdbReferencePacks -PlatformToolsSource $ptSrc -ScrcpySource $scSrc -OnLog $onLog
                                $pt = [string]$pkgs.PlatformToolsDir
                                $sc = [string]$pkgs.ScrcpyDir
                                $ResultBox['Packages'] = $pkgs
                                $map = Build-AdbCleanHashMap -PlatformToolsDir $pt -ScrcpyDir $sc
                            }
                            else {
                                $pt = [string]$JobArgs['PlatformToolsDir']
                                $sc = [string]$JobArgs['ScrcpyDir']
                                if (-not $pt -or -not $sc) { throw 'Packages clean manquants (placez platform-tools + scrcpy-win64-v4.1 sur le Bureau).' }
                                [void]$LogQueue.Enqueue('[Warn] Packs Desktop incomplets — utilisation du cache clean-tools.')
                            }
                            $hitObjs = @()
                            $paths = @($JobArgs['HitPaths'])
                            $pi = 0
                            foreach ($hp in $paths) {
                                $pi++
                                Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'hash' -Current $pi -Total ([Math]::Max(1, $paths.Count)) `
                                    -Message ('Prepare ' + [string]$hp.Path)
                                if ($hp -and $hp.Path -and (Test-Path -LiteralPath $hp.Path)) {
                                    $hitObjs += (New-AdbHitObject -Path $hp.Path -Kind $hp.Kind -CleanHashMap $map)
                                    $hitObjs[-1].Selected = $true
                                }
                            }
                            $rep = Repair-AdbScrcpyHits -Hits $hitObjs -PlatformToolsDir $pt -ScrcpyDir $sc -OnLog $onLog `
                                -ProgressBox $ProgressBox -OnlySelected
                            $ResultBox['Repair'] = $rep
                            $newMap = Build-AdbCleanHashMap -PlatformToolsDir $pt -ScrcpyDir $sc
                            $ResultBox['HashMap'] = $newMap
                            $refreshed = @()
                            foreach ($hp in @($JobArgs['HitPaths'])) {
                                if ($hp.Path -and (Test-Path -LiteralPath $hp.Path)) {
                                    $refreshed += (New-AdbHitObject -Path $hp.Path -Kind $hp.Kind -CleanHashMap $newMap)
                                }
                            }
                            $ResultBox['Hits'] = $refreshed
                        }
                    }
                }
                catch {
                    $ResultBox['Error'] = [string]$_
                    [void]$LogQueue.Enqueue('[Error] ' + $_)
                    try { Write-AdbRepairProgress -ProgressBox $ProgressBox -Phase 'done' -Message ('Erreur : ' + $_) } catch { }
                }
                finally {
                    $ResultBox['Done'] = $true
                }
            }).AddArgument($script:AdbRepairEnginePath).AddArgument($logQueue).AddArgument($resultBox).AddArgument($argCopy).AddArgument($progressBox)

        $handle = $ps.BeginInvoke()
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:AdbRepairTimerState = @{
            Timer     = $timer
            Ps        = $ps
            Handle    = $handle
            Runspace  = $runspace
            Queue     = $logQueue
            Box       = $resultBox
            Progress  = $progressBox
            Label     = $Label
            Started   = $script:AdbProgressStarted
            LastTick  = 0L
        }
        $timer.Add_Tick({
                $state = $script:AdbRepairTimerState
                if (-not $state) { return }
                if ($state.ContainsKey('Finishing') -and $state['Finishing']) { return }

                try {
                    $line = $null
                    while ($state.Queue.TryDequeue([ref]$line)) {
                        try { Write-AdbRepairUiLog -Text $line -Append } catch { }
                    }
                }
                catch { }

                try {
                    $pb = $state.Progress
                    if ($pb) {
                        $tick = 0L
                        try { $tick = [int64]$pb['Tick'] } catch { }
                        if ($tick -ne $state.LastTick) {
                            $state.LastTick = $tick
                            $started = $state.Started
                            try {
                                if ($pb['StartedUtc']) { $started = [datetime]$pb['StartedUtc'] }
                            }
                            catch { }
                            Set-AdbProgressUi -Phase ([string]$pb['Phase']) -Current ([int]$pb['Current']) `
                                -Total ([int]$pb['Total']) -FilesSeen ([int]$pb['FilesSeen']) `
                                -Message ([string]$pb['Message']) -Started $started
                        }
                    }
                }
                catch { }

                $done = $false
                $completed = $false
                try { $done = [bool]$state.Box['Done'] } catch { }
                try { $completed = [bool]$state.Handle.IsCompleted } catch { }
                if (-not $done -and -not $completed) { return }

                $state['Finishing'] = $true
                try { $state.Timer.Stop() } catch { }

                # Reactiver les boutons AVANT EndInvoke / liste (scan rapide peut etre lourd)
                try { Complete-AdbRepairJobUi } catch {
                    $script:AdbRepairBusy = $false
                    try { Set-AdbRepairBusy $false } catch { }
                }

                try {
                    # EndInvoke AVANT Close — recuperer les objets du runspace
                    try { $null = $state.Ps.EndInvoke($state.Handle) } catch { }

                    $line = $null
                    while ($state.Queue.TryDequeue([ref]$line)) {
                        try { Write-AdbRepairUiLog -Text $line -Append } catch { }
                    }

                    # Snapshot resultats en objets simples (survivent a la fermeture du runspace)
                    $errMsg = $null
                    $pkgs = $null
                    $hashMap = $null
                    $repair = $null
                    $hitSnap = @()
                    try { $errMsg = $state.Box['Error'] } catch { }
                    try { $pkgs = $state.Box['Packages'] } catch { }
                    try { $hashMap = $state.Box['HashMap'] } catch { }
                    try { $repair = $state.Box['Repair'] } catch { }
                    try {
                        foreach ($h in @($state.Box['Hits'])) {
                            if ($null -eq $h) { continue }
                            $hitSnap += [pscustomobject]@{
                                Path      = [string]$h.Path
                                Name      = [string]$h.Name
                                Directory = [string]$h.Directory
                                Length    = $(try { [long]$h.Length } catch { 0 })
                                Hash      = $(try { [string]$h.Hash } catch { '' })
                                CleanHash = $(try { [string]$h.CleanHash } catch { '' })
                                Kind      = [string]$h.Kind
                                Status    = [string]$h.Status
                                Selected  = $(try { [bool]$h.Selected } catch { $true })
                            }
                        }
                    }
                    catch { }

                    if ($errMsg) {
                        Write-AdbRepairUiLog -Text ('Echec : ' + $errMsg) -Append
                        try {
                            [System.Windows.MessageBox]::Show([string]$errMsg, 'Lapwiz — ADB Repair', 'OK', 'Warning') | Out-Null
                        }
                        catch { }
                    }
                    if ($pkgs) { $script:AdbCleanPackages = $pkgs }
                    if ($hashMap) { $script:AdbCleanHashMap = $hashMap }

                    $jobTypeDone = ''
                    try { $jobTypeDone = [string]$state.Box['JobType'] } catch { }
                    $isScanJob = $jobTypeDone -match '^(ScanFolder|ScanCommon|ScanDrive)$'
                    $hitsWereSet = $false
                    try { $hitsWereSet = $null -ne $state.Box['Hits'] } catch { }
                    if ($isScanJob -or $hitsWereSet) {
                        try { Update-AdbRepairHitList -Hits $hitSnap } catch {
                            Write-AdbRepairUiLog -Text ('[Warn] Liste resultats : ' + $_) -Append
                        }
                    }
                    if ($repair -or ($jobTypeDone -eq 'Repair') -or $script:AdbOpenRepairReport) {
                        try {
                            Write-AdbRepairUiLog -Text ("Repair termine OK={0} Fail={1} Skip={2}" -f $(try { $repair.Ok } catch { 0 }), $(try { $repair.Fail } catch { 0 }), $(try { $repair.Skip } catch { 0 })) -Append
                        }
                        catch { }
                        try {
                            # Snapshot serialisable pour la fenetre rapport (hors runspace)
                            $actionSnap = @()
                            try {
                                foreach ($a in @($repair.Actions)) {
                                    if ($null -eq $a) { continue }
                                    $actionSnap += [pscustomobject]@{
                                        Status     = [string]$a.Status
                                        Action     = [string]$a.Action
                                        Name       = [string]$a.Name
                                        Path       = [string]$a.Path
                                        Source     = [string]$a.Source
                                        Pack       = [string]$a.Pack
                                        Quarantine = [string]$a.Quarantine
                                        Hash       = [string]$a.Hash
                                    }
                                }
                            }
                            catch { }
                            $ptSnap = @()
                            $scSnap = @()
                            try { $ptSnap = @($repair.PlatformToolsFolders | ForEach-Object { [string]$_ }) } catch { }
                            try { $scSnap = @($repair.ScrcpyFolders | ForEach-Object { [string]$_ }) } catch { }
                            $reportSnap = [pscustomobject]@{
                                Ok                   = $(try { [int]$repair.Ok } catch { 0 })
                                Fail                 = $(try { [int]$repair.Fail } catch { 0 })
                                Skip                 = $(try { [int]$repair.Skip } catch { 0 })
                                Quarantine           = $(try { [string]$repair.Quarantine } catch { '' })
                                ReportPath           = $(try { [string]$repair.ReportPath } catch { '' })
                                StartedAt            = $(try { [string]$repair.StartedAt } catch { '' })
                                EndedAt              = $(try { [string]$repair.EndedAt } catch { '' })
                                Actions              = $actionSnap
                                PlatformToolsFolders = $ptSnap
                                ScrcpyFolders        = $scSnap
                                VerifyFail           = $(try { [int]$repair.VerifyFail } catch { 0 })
                                VerifyWarn           = $(try { [int]$repair.VerifyWarn } catch { 0 })
                                Issues               = $(try {
                                        @($repair.Issues | ForEach-Object {
                                                [pscustomobject]@{
                                                    Severity = [string]$_.Severity
                                                    Code     = [string]$_.Code
                                                    Name     = [string]$_.Name
                                                    Path     = [string]$_.Path
                                                    Detail   = [string]$_.Detail
                                                }
                                            })
                                    }
                                    catch { @() })
                            }
                            # Differe l'ouverture hors du Tick (ShowDialog dans Timer = souvent ignore)
                            $script:AdbPendingRepairReport = $reportSnap
                            Write-AdbRepairUiLog -Text 'Rapport detaille pret — ouverture…' -Append
                        }
                        catch {
                            Write-AdbRepairUiLog -Text ('[Warn] Rapport reparation : ' + $_) -Append
                        }
                    }
                    try { Set-AdbProgressUi -Phase 'done' -Current 1 -Total 1 -Message 'Termine' -Started $state.Started } catch { }
                    Write-AdbRepairUiLog -Text ("-- Fin $($state.Label) --") -Append
                }
                catch {
                    try { Write-AdbRepairUiLog -Text ('[Warn] Finalisation ADB : ' + $_) -Append } catch { }
                }
                finally {
                    try { $state.Ps.Dispose() } catch { }
                    try { $state.Runspace.Close() } catch { }
                    try { $state.Runspace.Dispose() } catch { }
                    # Garantie : boutons actifs meme si Complete a echoue plus haut
                    try { Complete-AdbRepairJobUi } catch {
                        $script:AdbRepairBusy = $false
                        try { Set-AdbRepairBusy $false } catch { }
                    }
                    $script:AdbOpenRepairReport = $false

                    # Ouvrir le rapport detaille automatiquement (apres le tick)
                    if ($script:AdbPendingRepairReport) {
                        $owner = $script:AdbRepairWindow
                        try {
                            if ($owner -and $owner.Dispatcher) {
                                $null = $owner.Dispatcher.BeginInvoke(
                                    [System.Windows.Threading.DispatcherPriority]::ApplicationIdle,
                                    [Action]{
                                        $rep = $script:AdbPendingRepairReport
                                        $script:AdbPendingRepairReport = $null
                                        if (-not $rep) { return }
                                        try {
                                            Show-AdbRepairReportWindow -Report $rep
                                        }
                                        catch {
                                            try { Write-AdbRepairUiLog -Text ('[Warn] Fenetre rapport : ' + $_) -Append } catch { }
                                            try {
                                                $rp = [string]$rep.ReportPath
                                                if ($rp -and (Test-Path -LiteralPath $rp)) {
                                                    Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $rp + '"') | Out-Null
                                                }
                                            }
                                            catch { }
                                        }
                                    }
                                )
                            }
                            else {
                                $rep = $script:AdbPendingRepairReport
                                $script:AdbPendingRepairReport = $null
                                if ($rep) { Show-AdbRepairReportWindow -Report $rep }
                            }
                        }
                        catch {
                            try {
                                $rep = $script:AdbPendingRepairReport
                                $script:AdbPendingRepairReport = $null
                                if ($rep) { Show-AdbRepairReportWindow -Report $rep }
                            }
                            catch {
                                try { Write-AdbRepairUiLog -Text ('[Warn] Ouverture rapport : ' + $_) -Append } catch { }
                            }
                        }
                    }
                }
            })
        $timer.Start()
        }
        catch {
            Write-AdbRepairUiLog -Text ('[Error] Demarrage job ADB : ' + $_) -Append
            $script:AdbOpenRepairReport = $false
            $script:AdbPendingRepairReport = $null
            Complete-AdbRepairJobUi
        }
    }

    $btnFolder = $Window.FindName('BtnAdbScanFolder')
    if ($btnFolder) {
        $btnFolder.Add_Click({
                try {
                    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                    $dlg.Description = 'Choisir un dossier ou une application a scanner (adb / scrcpy)'
                    $dlg.ShowNewFolderButton = $false
                    $hist = @(Read-AdbScanHistory)
                    if ($hist.Count -gt 0 -and (Test-Path -LiteralPath $hist[0])) {
                        try { $dlg.SelectedPath = $hist[0] } catch { }
                    }
                    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
                    $root = $dlg.SelectedPath
                    Add-AdbScanHistory -Root $root
                    Start-AdbRepairJob -JobType ScanFolder -Label ('Scan dossier : ' + $root) -JobArgs @{ Root = $root }
                }
                catch {
                    Write-AdbRepairUiLog -Text ([string]$_) -Append
                }
            })
    }

    $btnRecent = $Window.FindName('BtnAdbScanRecent')
    if ($btnRecent) {
        $btnRecent.Add_Click({
                try {
                    $cmb = $script:AdbScanHistoryCombo
                    if (-not $cmb -or $cmb.SelectedIndex -lt 0) { return }
                    $root = [string]$cmb.SelectedItem
                    if ([string]::IsNullOrWhiteSpace($root)) { return }
                    if (-not (Test-Path -LiteralPath $root)) {
                        [System.Windows.MessageBox]::Show(
                            ("Dossier introuvable :`n$root`n`nIl sera retire de l'historique."),
                            'Lapwiz — ADB Repair', 'OK', 'Warning') | Out-Null
                        $left = @((Read-AdbScanHistory) | Where-Object { $_ -ine $root })
                        Save-AdbScanHistory -Paths $left
                        Refresh-AdbScanHistoryCombo
                        return
                    }
                    Add-AdbScanHistory -Root $root
                    $isDrive = ($root -match '^[A-Za-z]:\\$')
                    if ($isDrive) {
                        Start-AdbRepairJob -JobType ScanDrive -Label ('Scan disque ' + $root.TrimEnd('\')) -JobArgs @{ Root = $root }
                    }
                    else {
                        Start-AdbRepairJob -JobType ScanFolder -Label ('Scan recent : ' + $root) -JobArgs @{ Root = $root }
                    }
                }
                catch {
                    Write-AdbRepairUiLog -Text ([string]$_) -Append
                }
            })
    }

    $btnCommon = $Window.FindName('BtnAdbScanCommon')
    if ($btnCommon) {
        $btnCommon.Add_Click({
                Start-AdbRepairJob -JobType ScanCommon -Label 'Scan rapide'
            })
    }

    $btnDrive = $Window.FindName('BtnAdbScanDrive')
    if ($btnDrive) {
        $btnDrive.Add_Click({
                try {
                    $drives = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq 'Fixed' } | ForEach-Object { $_.Name.TrimEnd('\') })
                    if ($drives.Count -eq 0) {
                        [System.Windows.MessageBox]::Show('Aucun disque fixe detecte.', 'Lapwiz — ADB Repair', 'OK', 'Information') | Out-Null
                        return
                    }
                    $choice = $drives[0]
                    $r = [System.Windows.MessageBox]::Show(
                        ("Scanner tout le disque {0} ?`nLong (plusieurs minutes). WinSxS / Corbeille exclus." -f $choice),
                        'Lapwiz — Scan disque',
                        'YesNo',
                        'Warning'
                    )
                    if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }
                    $root = $choice + '\'
                    Add-AdbScanHistory -Root $root
                    Start-AdbRepairJob -JobType ScanDrive -Label ('Scan disque ' + $choice) -JobArgs @{ Root = $root }
                }
                catch {
                    Write-AdbRepairUiLog -Text ([string]$_) -Append
                }
            })
    }

    $btnFetch = $Window.FindName('BtnAdbFetchClean')
    if ($btnFetch) {
        $btnFetch.Add_Click({
                $force = $true
                if ($script:AdbCleanPackages) {
                    $ask = [System.Windows.MessageBox]::Show(
                        "Cache clean deja present.`nOui = retélécharger`nNon = utiliser le cache",
                        'Lapwiz — ADB Repair',
                        'YesNoCancel',
                        'Question'
                    )
                    if ($ask -eq [System.Windows.MessageBoxResult]::Cancel) { return }
                    $force = ($ask -eq [System.Windows.MessageBoxResult]::Yes)
                }
                Start-AdbRepairJob -JobType FetchClean -Label 'Telecharger clean' -JobArgs @{ ForceRefresh = $force }
            })
    }

    $btnLearn = $Window.FindName('BtnAdbLearnPacks')
    if ($btnLearn) {
        $btnLearn.Add_Click({
                $desk = [Environment]::GetFolderPath('Desktop')
                $ptDefault = Join-Path $desk 'platform-tools'
                $scDefault = ''
                foreach ($cand in @(
                        (Join-Path $desk 'scrcpy-win64-v4.1'),
                        (Join-Path $desk 'scrcpy-win64'),
                        (Join-Path $desk 'scrcpy')
                    )) {
                    if (Test-Path -LiteralPath (Join-Path $cand 'scrcpy.exe')) {
                        $scDefault = $cand
                        break
                    }
                }
                if (-not (Test-Path -LiteralPath $ptDefault) -and [string]::IsNullOrWhiteSpace($scDefault)) {
                    [System.Windows.MessageBox]::Show(
                        "Aucun pack trouve sur le Bureau.`nAttendu : platform-tools et/ou scrcpy-win64-v4.1",
                        'Lapwiz — Apprendre packs', 'OK', 'Warning') | Out-Null
                    return
                }
                $msg = "Apprendre TOUS les fichiers des dossiers reference,`n" +
                    "les copier dans clean-tools, puis pouvoir les supprimer/remplacer.`n`n" +
                    "platform-tools :`n$(if (Test-Path -LiteralPath $ptDefault) { $ptDefault } else { '(absent)' })`n`n" +
                    "scrcpy :`n$(if ($scDefault) { $scDefault } else { '(detection auto engine)' })`n`nContinuer ?"
                $ask = [System.Windows.MessageBox]::Show($msg, 'Lapwiz — Apprendre packs', 'YesNo', 'Question')
                if ($ask -ne [System.Windows.MessageBoxResult]::Yes) { return }
                $jobArgs = @{}
                if (Test-Path -LiteralPath $ptDefault) { $jobArgs['PlatformToolsSource'] = $ptDefault }
                if ($scDefault) { $jobArgs['ScrcpySource'] = $scDefault }
                Start-AdbRepairJob -JobType LearnPacks -Label 'Apprendre packs Desktop' -JobArgs $jobArgs
            })
    }

    $btnRepair = $Window.FindName('BtnAdbRepairAll')
    if ($btnRepair) {
        $btnRepair.Add_Click({
                if (-not $script:AdbRepairHits -or $script:AdbRepairHits.Count -eq 0) {
                    [System.Windows.MessageBox]::Show('Lancez d''abord un scan.', 'Lapwiz — ADB Repair', 'OK', 'Information') | Out-Null
                    return
                }
                $selected = @($script:AdbRepairHits | Where-Object { [bool]$_.Selected })
                if ($selected.Count -eq 0) {
                    [System.Windows.MessageBox]::Show('Cochez au moins un fichier.', 'Lapwiz — ADB Repair', 'OK', 'Information') | Out-Null
                    return
                }
                if (-not $script:AdbCleanPackages) {
                    [System.Windows.MessageBox]::Show('Apprenez ou telechargez d''abord les packs clean.', 'Lapwiz — ADB Repair', 'OK', 'Warning') | Out-Null
                    return
                }
                $confirm = [System.Windows.MessageBox]::Show(
                    ("Remplacer {0} fichier(s) / packs ?`n`n" -f $selected.Count) +
                    "platform-tools : sync COMPLET du pack appris (tous les fichiers)`n" +
                    "scrcpy : sync COMPLET du pack appris`n" +
                    "Flux : backup → SUPPRIMER → copie clean + SHA-256`n`n" +
                    "Fichiers hors pack dans le meme dossier : intacts.",
                    'Lapwiz — Packs ADB / scrcpy (strict)',
                    'YesNo',
                    'Warning'
                )
                if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
                Start-AdbRepairJob -JobType Repair -Label 'Remplacement'
            })
    }

    $btnCheckAll = $Window.FindName('BtnAdbCheckAll')
    if ($btnCheckAll) {
        $btnCheckAll.Add_Click({
                if (-not $script:AdbRepairHits -or $script:AdbRepairHits.Count -eq 0) { return }
                Set-AdbRepairSelection -Selected $true
            })
    }
    $btnUncheckAll = $Window.FindName('BtnAdbUncheckAll')
    if ($btnUncheckAll) {
        $btnUncheckAll.Add_Click({
                if (-not $script:AdbRepairHits -or $script:AdbRepairHits.Count -eq 0) { return }
                Set-AdbRepairSelection -Selected $false
            })
    }

    $btnGuide = $Window.FindName('BtnAdbGuideInfo')
    if ($btnGuide) {
        $btnGuide.Add_Click({
                try {
                    Show-AdbRepairGuideWindow
                }
                catch {
                    Write-AdbRepairUiLog -Text ('[Warn] Guide ADB : ' + $_) -Append
                }
            })
    }

    $btnPath = $Window.FindName('BtnAdbPathLapwiz')
    if ($btnPath) {
        $btnPath.Add_Click({
                try {
                    Write-AdbRepairUiLog -Text 'Configuration PATH ADB Lapwiz…' -Append
                    if (-not (Get-Command Set-AdbPath -ErrorAction SilentlyContinue)) {
                        throw 'Set-AdbPath indisponible (Install-Engine non charge).'
                    }
                    $onLog = {
                        param($m, $l)
                        Write-AdbRepairUiLog -Text ([string]$m) -Append
                    }
                    if ($script:AdbCleanPackages -and (Test-Path -LiteralPath (Join-Path $script:AdbCleanPackages.PlatformToolsDir 'adb.exe'))) {
                        if (Get-Command Install-StableAdbCopy -ErrorAction SilentlyContinue) {
                            $null = Install-StableAdbCopy -SourceDir $script:AdbCleanPackages.PlatformToolsDir -OnLog $onLog
                        }
                    }
                    $ok = Set-AdbPath -OnLog $onLog
                    if ($ok) {
                        [System.Windows.MessageBox]::Show('PATH ADB Lapwiz configure.', 'Lapwiz — ADB Repair', 'OK', 'Information') | Out-Null
                    }
                    else {
                        [System.Windows.MessageBox]::Show('PATH ADB : voir journal.', 'Lapwiz — ADB Repair', 'OK', 'Warning') | Out-Null
                    }
                }
                catch {
                    Write-AdbRepairUiLog -Text ([string]$_) -Append
                    [System.Windows.MessageBox]::Show([string]$_, 'Lapwiz — ADB Repair', 'OK', 'Warning') | Out-Null
                }
            })
    }

    $btnQ = $Window.FindName('BtnAdbOpenQuarantine')
    if ($btnQ) {
        $btnQ.Add_Click({
                try {
                    $qRoot = $null
                    if (Get-Command Get-AdbQuarantineRoot -ErrorAction SilentlyContinue) {
                        $qRoot = Get-AdbQuarantineRoot
                    }
                    if ([string]::IsNullOrWhiteSpace($qRoot)) {
                        $qRoot = Join-Path $env:LOCALAPPDATA 'LapwizSetup\adb-quarantine'
                    }
                    if (-not (Test-Path -LiteralPath $qRoot)) {
                        New-Item -ItemType Directory -Path $qRoot -Force | Out-Null
                    }

                    $target = $qRoot
                    $latest = @(Get-ChildItem -LiteralPath $qRoot -Directory -ErrorAction SilentlyContinue |
                            Sort-Object Name -Descending |
                            Select-Object -First 1)
                    if ($latest.Count -gt 0) { $target = $latest[0].FullName }

                    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $target + '"') | Out-Null
                    Write-AdbRepairUiLog -Text ("Dossier quarantaine ouvert : $target") -Append
                }
                catch {
                    Write-AdbRepairUiLog -Text ([string]$_) -Append
                    [System.Windows.MessageBox]::Show(
                        [string]$_,
                        'Lapwiz — ADB Repair', 'OK', 'Warning') | Out-Null
                }
            })
    }

    Write-AdbRepairUiLog -Text 'ADB Repair pret. 1) Apprendre packs Desktop (ou Telecharger)  2) Scanner  3) Tout reparer'
    Refresh-AdbScanHistoryCombo

    # Auto-charge si clean-tools deja presents
    try {
        $pt0 = Get-DefaultPlatformToolsDir
        $sc0 = Get-DefaultScrcpyDir
        if ($pt0 -and $sc0) {
            $script:AdbCleanPackages = [pscustomobject]@{ PlatformToolsDir = $pt0; ScrcpyDir = $sc0 }
            $script:AdbCleanHashMap = Build-AdbCleanHashMap -PlatformToolsDir $pt0 -ScrcpyDir $sc0
            Write-AdbRepairUiLog -Text (
                "Packs deja en cache : PT={0} fichiers, scrcpy={1}." -f `
                    (Get-PlatformToolsCleanFileMap -PlatformToolsDir $pt0).Count, `
                    (Get-ScrcpyCleanFileMap -ScrcpyDir $sc0).Count
            ) -Append
        }
    }
    catch { }
}
