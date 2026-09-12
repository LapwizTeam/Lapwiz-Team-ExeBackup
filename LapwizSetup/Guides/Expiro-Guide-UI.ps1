#Requires -Version 5.1
<#
.SYNOPSIS
    Onglet Guide Expiro — navigation par phases (wizard moderne) + actions automatisees.
#>

function Initialize-ExpiroGuideUi {
    param(
        [Parameter(Mandatory)] $Window,
        [Parameter(Mandatory)][string]$ScriptRoot
    )

    $phaseList = $Window.FindName('ExpiroPhaseList')
    $stepHost = $Window.FindName('ExpiroStepHost')
    $progressFill = $Window.FindName('ExpiroProgressFill')
    $progressLabel = $Window.FindName('ExpiroProgressLabel')
    $btnPrev = $Window.FindName('BtnExpiroPrev')
    $btnNext = $Window.FindName('BtnExpiroNext')

    $lightbox = $Window.FindName('ExpiroLightbox')
    $lightboxDim = $Window.FindName('ExpiroLightboxDim')
    $lightboxImage = $Window.FindName('ExpiroLightboxImage')
    $lightboxCaption = $Window.FindName('ExpiroLightboxCaption')
    $btnLightboxClose = $Window.FindName('BtnExpiroLightboxClose')

    $remPath = Join-Path $ScriptRoot 'Guides\Expiro-Trend-Remediation.ps1'
    if (Test-Path -LiteralPath $remPath) { . $remPath }

    $script:ExpiroGuideText = ''
    $guideTxt = Join-Path $ScriptRoot 'Guides\Expiro-WinTips.txt'
    if (Test-Path -LiteralPath $guideTxt) {
        $script:ExpiroGuideText = Get-Content -LiteralPath $guideTxt -Raw -Encoding UTF8
    }

    $script:ExpiroImgDir = Join-Path $ScriptRoot 'Guides\images'
    $script:ExpiroWindow = $Window
    $script:ExpiroStepHost = $stepHost
    $script:ExpiroPhaseList = $phaseList
    $script:ExpiroProgressFill = $progressFill
    $script:ExpiroProgressLabel = $progressLabel
    $script:ExpiroLightbox = $lightbox
    $script:ExpiroLightboxImage = $lightboxImage
    $script:ExpiroLightboxCaption = $lightboxCaption
    $script:ExpiroLastArtifacts = @()
    $script:ExpiroPhaseIndex = 0

    $script:ExpiroAccentFg = $Window.TryFindResource('BrushAccentSoft')
    if (-not $script:ExpiroAccentFg) {
        $script:ExpiroAccentFg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(101, 184, 162))
    }
    $script:ExpiroBodyFg = $Window.TryFindResource('BrushLogText')
    if (-not $script:ExpiroBodyFg) {
        $script:ExpiroBodyFg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(184, 212, 207))
    }
    $script:ExpiroMutedFg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(150, 180, 174))
    $script:ExpiroCardBg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(255, 255, 255))
    $script:ExpiroBorder = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(201, 216, 213))
    $script:ExpiroCardFg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(40, 51, 56))
    $script:ExpiroCardMutedFg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(95, 115, 120))
    $script:ExpiroChipBg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(28, 93, 95))

    # Manifest images WinTips
    $script:ExpiroImageEntries = [System.Collections.Generic.List[object]]::new()
    $manifest = Join-Path $ScriptRoot 'Guides\expiro-images.json'
    if (Test-Path -LiteralPath $manifest) {
        Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object {
            if ($_ -is [System.Array]) { foreach ($s in $_) { [void]$script:ExpiroImageEntries.Add($s) } }
            elseif ($null -ne $_) { [void]$script:ExpiroImageEntries.Add($_) }
        }
    }

    $script:ExpiroPhases = @(
        @{
            Id = 'understand'; Title = 'Comprendre'; Subtitle = 'Trend + !MTB'
            Hero = '01-hero-expiro.png'; Extra = @()
            Body = @"
Virus de fichiers EXE (Win32/Win64 Expiro). Detection Defender typique : Virus:Win32/Expiro.A!MTB (!MTB = cloud/ML).

Trend Micro Virus.Win64.EXPIRO.AA
• Infecte les .EXE (Bureau, demarrage, USB, partages)
• Detourne Startup → %LocalAppData%\{aleatoire}\cmd.exe
• Stoppe WinDefend / MsMpSvc / wscsvc / wuauserv
• Exfiltre infos machine en HTTP POST
• Alias : Ikarus, Fortinet W64/Expiro.CE, ESET Expiro.NDH

Regle d'or : ne restaure jamais d'anciens EXE. Docs/photos OK. Apps → onglet Installateur.
"@
        }
        @{
            Id = 'livedisk'; Title = 'LiveDisk'; Subtitle = 'Hors Windows'
            Hero = 'guide-livedisk.png'; Extra = @()
            WinTipsSteps = @(1, 2)
            Body = @"
Si Windows est trop infecte, boot depuis un PC SAIN :

1. Telecharge Dr.Web LiveDisk (ISO) sur un autre PC
2. USB bootable (Rufus) ou DVD
3. BIOS/UEFI : boot USB
4. Scanner → Full Scan → Cure des EXE
5. Eteins proprement, retire le media

Les captures WinTips ci-dessous suivent l'ordre du tutoriel.
"@
        }
        @{
            Id = 'safemode'; Title = 'Safe Mode'; Subtitle = 'Audit Lapwiz'
            Hero = 'guide-safemode.png'; Extra = @()
            WinTipsSteps = @(3)
            Body = @"
Windows 10/11 : Parametres → Systeme → Recuperation → Demarrage avance
OU msconfig → Demarrage securise + Reseau.

Ensuite : onglet Scripts → Audit Trend, Startup, services AV.
Puis RogueKiller / Adw / MBAM / KVRT (Scripts + onglet KVRT).
"@
        }
        @{
            Id = 'tools'; Title = 'Outils'; Subtitle = 'MBAM · KVRT · RK'
            Hero = 'guide-malwarebytes.png'; Extra = @('guide-scan-kvrt.png')
            WinTipsSteps = @(4, 5, 6)
            Body = @"
Ordre recommande (forum Malwarebytes / WinTips) :

1. RogueKiller — Scan + Registry
2. AdwCleaner — Scan → Clean
3. Malwarebytes — Threat Scan (PUP en quarantaine)
4. Kaspersky KVRT — scan one-shot (bases a jour = re-telecharger)

KVRT (support Kaspersky) :
Lancer → Change parameters si besoin → Start scan → traiter menaces → Close
Puis antivirus temps reel (Defender).

Automatise : onglet Scripts (KVRT, MBAM, Defender).
"@
        }
        @{
            Id = 'defender'; Title = 'Defender'; Subtitle = 'Scan final'
            Hero = 'guide-scan-kvrt.png'; Extra = @()
            Body = @"
Apres les outils tiers :

1. Scan complet Microsoft Defender (tous disques + USB)
2. Relance Audit Trend Lapwiz
3. Si detections Expiro massives ou retour apres reboot → reinstall Windows propre

Onglet Scripts → Scan Defender complet (admin).
"@
        }
        @{
            Id = 'reinstall'; Title = 'Apps'; Subtitle = 'winget'
            Hero = 'guide-reinstall.png'; Extra = @()
            WinTipsSteps = @(7)
            Body = @"
Meme apres Cure, les EXE peuvent rester instables.

→ Onglet Installateur Lapwiz (winget) pour reinstaller proprement.
→ Ne recolle pas Program Files / installateurs d'une sauvegarde infectee.
→ Sauvegarde seulement documents, photos, videos.
"@
        }
    )

    function script:Write-ExpiroRemediationLog {
        param([string]$Text, [switch]$Append)
        if (Get-Command Add-UiLog -ErrorAction SilentlyContinue) {
            Add-UiLog -Line $Text -Source 'Expiro'
        }
    }

    function script:Hide-ExpiroLightbox {
        if ($script:ExpiroLightbox) {
            $script:ExpiroLightbox.Visibility = [System.Windows.Visibility]::Collapsed
            if ($script:ExpiroLightboxImage) { $script:ExpiroLightboxImage.Source = $null }
        }
    }

    function script:Show-ExpiroLightbox {
        param([string]$ImagePath, [string]$Caption = '')
        if (-not $script:ExpiroLightbox -or -not $script:ExpiroLightboxImage) { return }
        try {
            $full = (Resolve-Path -LiteralPath $ImagePath).Path
            $bi = New-Object System.Windows.Media.Imaging.BitmapImage
            $bi.BeginInit()
            $bi.UriSource = [Uri]::new($full)
            $bi.DecodePixelWidth = 1600
            $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bi.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
            $bi.EndInit()
            $bi.Freeze()
            $script:ExpiroLightboxImage.Source = $bi
            if ($script:ExpiroLightboxCaption) { $script:ExpiroLightboxCaption.Text = $Caption }
            $script:ExpiroLightbox.Visibility = [System.Windows.Visibility]::Visible
        }
        catch {
            [System.Windows.MessageBox]::Show("Impossible d'agrandir l'image.", 'Lapwiz Setup', 'OK', 'Warning') | Out-Null
        }
    }

    function script:Add-ExpiroUiText {
        param($Panel, [string]$Text, [double]$Size = 13, $Fg = $null, [string]$Weight = 'Normal', [double]$MarginTop = 0)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $Text
        $tb.FontSize = $Size
        $tb.TextWrapping = 'Wrap'
        $tb.Margin = [System.Windows.Thickness]::new(0, $MarginTop, 0, 6)
        if ($Weight -eq 'SemiBold') { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }
        $tb.Foreground = $(if ($Fg) { $Fg } else { $script:ExpiroBodyFg })
        [void]$Panel.Children.Add($tb)
    }

    function script:Add-ExpiroImageCard {
        param($Panel, [string]$FileName, [string]$Caption, [int]$OrderIndex = 0, [double]$MaxHeight = 220)
        if ([string]::IsNullOrWhiteSpace($FileName)) { return }
        $imgPath = Join-Path $script:ExpiroImgDir $FileName
        if (-not (Test-Path -LiteralPath $imgPath)) { return }
        try {
            $card = New-Object System.Windows.Controls.Border
            $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
            $card.Padding = [System.Windows.Thickness]::new(10)
            $card.CornerRadius = [System.Windows.CornerRadius]::new(12)
            $card.Background = $script:ExpiroCardBg
            $card.BorderBrush = $script:ExpiroBorder
            $card.BorderThickness = [System.Windows.Thickness]::new(1)
            $card.Cursor = [System.Windows.Input.Cursors]::Hand
            $card.ToolTip = 'Cliquez pour agrandir'
            $card.Tag = @{ Path = $imgPath; Caption = $Caption }

            $stack = New-Object System.Windows.Controls.StackPanel
            $cap = New-Object System.Windows.Controls.TextBlock
            $prefix = if ($OrderIndex -gt 0) { "Illustr. $OrderIndex — " } else { '' }
            $cap.Text = "$prefix$Caption"
            $cap.FontSize = 12
            $cap.FontWeight = [System.Windows.FontWeights]::SemiBold
            $cap.Foreground = $script:ExpiroCardFg
            $cap.TextWrapping = 'Wrap'
            $cap.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)

            $full = (Resolve-Path -LiteralPath $imgPath).Path
            $bi = New-Object System.Windows.Media.Imaging.BitmapImage
            $bi.BeginInit()
            $bi.UriSource = [Uri]::new($full)
            $bi.DecodePixelWidth = 960
            $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bi.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
            $bi.EndInit()
            $bi.Freeze()

            $img = New-Object System.Windows.Controls.Image
            $img.Source = $bi
            $img.MaxHeight = $MaxHeight
            $img.Stretch = 'Uniform'
            $img.HorizontalAlignment = 'Left'
            [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')

            [void]$stack.Children.Add($cap)
            [void]$stack.Children.Add($img)
            $card.Child = $stack
            $card.Add_MouseLeftButtonUp({
                param($sender, $e)
                $tag = $sender.Tag
                if ($null -eq $tag) { return }
                Show-ExpiroLightbox -ImagePath ([string]$tag['Path']) -Caption ([string]$tag['Caption'])
            }.GetNewClosure())
            [void]$Panel.Children.Add($card)
        }
        catch {}
    }

    function script:Update-ExpiroProgress {
        $n = $script:ExpiroPhases.Count
        $i = $script:ExpiroPhaseIndex + 1
        if ($script:ExpiroProgressLabel) {
            $fmt = 'Phase {0} / {1}'
            if ((Get-Command Get-UiString -ErrorAction SilentlyContinue) -and $script:LapwizUi) {
                $fmt = Get-UiString -Table $script:LapwizUi -Key 'ExpiroPhaseFmt' -Default $fmt
            }
            try { $script:ExpiroProgressLabel.Text = ($fmt -f $i, $n) } catch { $script:ExpiroProgressLabel.Text = "Phase $i / $n" }
        }
        if ($script:ExpiroProgressFill -and $n -gt 0) {
            $script:ExpiroProgressFill.Width = [Math]::Max(8, (220.0 * $i / $n))
        }
    }

    function script:Show-ExpiroPhase {
        param([int]$Index)
        if (-not $script:ExpiroStepHost) { return }
        if ($Index -lt 0) { $Index = 0 }
        if ($Index -ge $script:ExpiroPhases.Count) { $Index = $script:ExpiroPhases.Count - 1 }
        $script:ExpiroPhaseIndex = $Index
        $phase = $script:ExpiroPhases[$Index]
        Update-ExpiroProgress

        if ($script:ExpiroPhaseList -and $script:ExpiroPhaseList.SelectedIndex -ne $Index) {
            $script:ExpiroPhaseList.SelectedIndex = $Index
        }

        $script:ExpiroStepHost.Children.Clear()

        # Hero bandeau
        Add-ExpiroUiText -Panel $script:ExpiroStepHost -Text $phase.Title -Size 22 -Fg $script:ExpiroAccentFg -Weight 'SemiBold'
        Add-ExpiroUiText -Panel $script:ExpiroStepHost -Text $phase.Subtitle -Size 13 -Fg $script:ExpiroMutedFg
        Add-ExpiroImageCard -Panel $script:ExpiroStepHost -FileName $phase.Hero -Caption $phase.Title -MaxHeight 180
        Add-ExpiroUiText -Panel $script:ExpiroStepHost -Text $phase.Body -Size 13 -MarginTop 4

        foreach ($ex in @($phase.Extra)) {
            Add-ExpiroImageCard -Panel $script:ExpiroStepHost -FileName $ex -Caption $ex -MaxHeight 160
        }

        # Images WinTips dans l'ordre pour les etapes liees
        $order = 0
        $wanted = @()
        if ($phase.ContainsKey('WinTipsSteps') -and $phase.WinTipsSteps) {
            $wanted = @($phase.WinTipsSteps)
        }
        if ($wanted.Count -gt 0) {
            Add-ExpiroUiText -Panel $script:ExpiroStepHost -Text 'Illustrations WinTips (ordre tutoriel)' -Size 14 -Fg $script:ExpiroAccentFg -Weight 'SemiBold' -MarginTop 10
            foreach ($entry in $script:ExpiroImageEntries) {
                $step = 0
                try { $step = [int]$entry.step } catch { $step = 0 }
                if ($wanted -contains $step) {
                    $order++
                    $file = [string]$entry.file
                    $cap = [string]$entry.caption
                    Add-ExpiroImageCard -Panel $script:ExpiroStepHost -FileName $file -Caption $cap -OrderIndex $order -MaxHeight 240
                }
            }
        }
    }

    function script:Start-ExpiroUrl {
        param([string]$Url)
        try { Start-Process $Url } catch {
            [System.Windows.MessageBox]::Show("Impossible d'ouvrir : $Url", 'Lapwiz Setup', 'OK', 'Warning') | Out-Null
        }
    }

    # Remplir ListBox phases
    if ($phaseList) {
        $phaseList.Items.Clear()
        $idx = 0
        foreach ($p in $script:ExpiroPhases) {
            $idx++
            $item = New-Object System.Windows.Controls.ListBoxItem
            $item.Padding = [System.Windows.Thickness]::new(10, 10, 10, 10)
            $item.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
            $item.Tag = ($idx - 1)

            $sp = New-Object System.Windows.Controls.StackPanel
            $num = New-Object System.Windows.Controls.TextBlock
            $num.Text = "{0:00}" -f $idx
            $num.FontSize = 11
            $num.FontWeight = [System.Windows.FontWeights]::SemiBold
            $num.Foreground = $script:ExpiroAccentFg

            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = $p.Title
            $t.FontSize = 14
            $t.FontWeight = [System.Windows.FontWeights]::SemiBold
            $t.Foreground = $Window.TryFindResource('BrushTextPrimary')
            if (-not $t.Foreground) { $t.Foreground = $script:ExpiroCardFg }

            $s = New-Object System.Windows.Controls.TextBlock
            $s.Text = $p.Subtitle
            $s.FontSize = 11
            $s.Foreground = $Window.TryFindResource('BrushTextMuted')
            if (-not $s.Foreground) { $s.Foreground = $script:ExpiroCardMutedFg }
            $s.TextWrapping = 'Wrap'

            [void]$sp.Children.Add($num)
            [void]$sp.Children.Add($t)
            [void]$sp.Children.Add($s)
            $item.Content = $sp
            # Clic phase : pas de SelectionChanged (re-fire au ShowDialog → GetContextFromTLS / crash)
            $item.Add_PreviewMouseLeftButtonUp({
                param($sender, $e)
                try {
                    $it = $sender
                    if ($it -isnot [System.Windows.Controls.ListBoxItem]) {
                        $it = [System.Windows.Media.VisualTreeHelper]::GetParent($sender)
                        while ($null -ne $it -and $it -isnot [System.Windows.Controls.ListBoxItem]) {
                            $it = [System.Windows.Media.VisualTreeHelper]::GetParent($it)
                        }
                    }
                    if ($it -is [System.Windows.Controls.ListBoxItem]) {
                        Show-ExpiroPhase -Index ([int]$it.Tag)
                    }
                }
                catch {}
                $e.Handled = $false
            }.GetNewClosure())
            [void]$phaseList.Items.Add($item)
        }
    }

    if ($btnPrev) {
        $btnPrev.Add_Click({
            Show-ExpiroPhase -Index ($script:ExpiroPhaseIndex - 1)
        }.GetNewClosure())
    }
    if ($btnNext) {
        $btnNext.Add_Click({
            Show-ExpiroPhase -Index ($script:ExpiroPhaseIndex + 1)
        }.GetNewClosure())
    }

    if ($lightboxDim) { $lightboxDim.Add_MouseLeftButtonUp({ Hide-ExpiroLightbox }) }
    if ($lightboxImage) { $lightboxImage.Add_MouseLeftButtonUp({ Hide-ExpiroLightbox }) }
    if ($btnLightboxClose) { $btnLightboxClose.Add_Click({ Hide-ExpiroLightbox }) }
    $Window.Add_PreviewKeyDown({
        param($sender, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
            if ($script:ExpiroLightbox -and $script:ExpiroLightbox.Visibility -eq [System.Windows.Visibility]::Visible) {
                Hide-ExpiroLightbox
                $e.Handled = $true
            }
        }
    }.GetNewClosure())

    # Liens docs uniquement (scripts → onglet Scripts)
    $map = @{
        BtnExpiroWinTips   = { Start-ExpiroUrl 'https://www.wintips.org/remove-win32-expiro-virus/' }
        BtnExpiroTrend     = { Start-ExpiroUrl 'https://www.trendmicro.com/vinfo/us/threat-encyclopedia/malware/virus.win64.expiro.aa' }
        BtnExpiroCopyGuide = {
            try {
                [System.Windows.Clipboard]::SetText($script:ExpiroGuideText)
                [System.Windows.MessageBox]::Show('Checklist copiee.', 'Lapwiz Setup', 'OK', 'Information') | Out-Null
            }
            catch {}
        }
    }

    foreach ($name in $map.Keys) {
        $btn = $Window.FindName($name)
        if ($btn) {
            $btn.Add_Click($map[$name].GetNewClosure())
        }
    }
    Show-ExpiroPhase -Index 0
    if ($phaseList -and $phaseList.Items.Count -gt 0) {
        $phaseList.SelectedIndex = 0
    }
}
