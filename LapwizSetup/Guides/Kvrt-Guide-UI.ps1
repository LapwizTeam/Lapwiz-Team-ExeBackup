#Requires -Version 5.1
<#
.SYNOPSIS
    Onglet independant Kaspersky Virus Removal Tool (KVRT).
#>

function Initialize-KvrtGuideUi {
    param(
        [Parameter(Mandatory)] $Window,
        [Parameter(Mandatory)][string]$ScriptRoot
    )

    $remPath = Join-Path $ScriptRoot 'Guides\Expiro-Trend-Remediation.ps1'
    if (Test-Path -LiteralPath $remPath) { . $remPath }

    $feed = $Window.FindName('KvrtGuideFeed')
    $imgDir = Join-Path $ScriptRoot 'Guides\images'

    $script:KvrtGuideText = ''
    $guidePath = Join-Path $ScriptRoot 'Guides\Kvrt-Guide.txt'
    if (Test-Path -LiteralPath $guidePath) {
        $script:KvrtGuideText = Get-Content -LiteralPath $guidePath -Raw -Encoding UTF8
    }

    $script:KvrtAccentFg = $Window.TryFindResource('BrushAccentSoft')
    if (-not $script:KvrtAccentFg) {
        $script:KvrtAccentFg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(101, 184, 162))
    }
    $script:KvrtBodyFg = $Window.TryFindResource('BrushLogText')
    if (-not $script:KvrtBodyFg) {
        $script:KvrtBodyFg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(184, 212, 207))
    }
    $script:KvrtMutedFg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(150, 180, 174))
    $script:KvrtCardBg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(255, 255, 255))
    $script:KvrtBorder = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(201, 216, 213))
    $script:KvrtCardFg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(40, 51, 56))

    $script:KvrtLightbox = $Window.FindName('ExpiroLightbox')
    $script:KvrtLightboxImage = $Window.FindName('ExpiroLightboxImage')
    $script:KvrtLightboxCaption = $Window.FindName('ExpiroLightboxCaption')

    function script:Write-KvrtLog {
        param([string]$Text, [switch]$Append)
        if (Get-Command Add-UiLog -ErrorAction SilentlyContinue) {
            Add-UiLog -Line $Text -Source 'KVRT'
        }
    }

    function script:Show-KvrtLightbox {
        param([string]$ImagePath, [string]$Caption = '')
        if (Get-Command Show-ExpiroLightbox -ErrorAction SilentlyContinue) {
            Show-ExpiroLightbox -ImagePath $ImagePath -Caption $Caption
            return
        }
        if (-not $script:KvrtLightbox -or -not $script:KvrtLightboxImage) { return }
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
            $script:KvrtLightboxImage.Source = $bi
            if ($script:KvrtLightboxCaption) { $script:KvrtLightboxCaption.Text = $Caption }
            $script:KvrtLightbox.Visibility = [System.Windows.Visibility]::Visible
        }
        catch {}
    }

    function script:Add-KvrtHeading {
        param($Panel, [string]$Text)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $Text
        $tb.FontSize = 16
        $tb.FontWeight = [System.Windows.FontWeights]::SemiBold
        $tb.Foreground = $script:KvrtAccentFg
        $tb.Margin = [System.Windows.Thickness]::new(0, 12, 0, 6)
        $tb.TextWrapping = 'Wrap'
        [void]$Panel.Children.Add($tb)
    }

    function script:Add-KvrtBody {
        param($Panel, [string]$Text)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $Text
        $tb.FontSize = 13
        $tb.Foreground = $script:KvrtBodyFg
        $tb.TextWrapping = 'Wrap'
        $tb.LineHeight = 20
        $tb.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
        [void]$Panel.Children.Add($tb)
    }

    function script:Add-KvrtImageCard {
        param($Panel, [string]$FileName, [string]$Caption, [double]$MaxHeight = 240)
        $imgPath = Join-Path $imgDir $FileName
        if (-not (Test-Path -LiteralPath $imgPath)) { return }
        try {
            $card = New-Object System.Windows.Controls.Border
            $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
            $card.Padding = [System.Windows.Thickness]::new(10)
            $card.CornerRadius = [System.Windows.CornerRadius]::new(12)
            $card.Background = $script:KvrtCardBg
            $card.BorderBrush = $script:KvrtBorder
            $card.BorderThickness = [System.Windows.Thickness]::new(1)
            $card.Cursor = [System.Windows.Input.Cursors]::Hand
            $card.ToolTip = 'Agrandir'
            $card.Tag = @{ Path = $imgPath; Caption = $Caption }

            $stack = New-Object System.Windows.Controls.StackPanel
            $cap = New-Object System.Windows.Controls.TextBlock
            $cap.Text = $Caption
            $cap.FontSize = 12
            $cap.FontWeight = [System.Windows.FontWeights]::SemiBold
            $cap.Foreground = $script:KvrtCardFg
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
                Show-KvrtLightbox -ImagePath ([string]$tag['Path']) -Caption ([string]$tag['Caption'])
            }.GetNewClosure())
            [void]$Panel.Children.Add($card)
        }
        catch {}
    }

    if ($feed) {
        $feed.Children.Clear()

        Add-KvrtHeading -Panel $feed -Text 'Presentation'
        Add-KvrtBody -Panel $feed -Text @"
Kaspersky Virus Removal Tool nettoie un PC Windows deja infecte.
Outil ponctuel : pas de bouclier permanent, bases figées dans l'exe telecharge.
Apres usage → Defender (ou AV) + reinstall apps si Expiro (onglet Installateur).

Captures officielles : support.kaspersky.com/kvrt2020/howto/15674
"@

        Add-KvrtHeading -Panel $feed -Text 'Etape 1 — Telecharger & lancer'
        Add-KvrtBody -Panel $feed -Text @"
Telecharge via onglet Scripts → Telecharger KVRT (build officiel, ~120 Mo).
Fichier : %LocalAppData%\Lapwiz\tools\KVRT.exe
Pour des bases a jour, re-telecharge periodiquement (KVRT ne se met pas a jour tout seul).
Lance via Scripts → Lancer KVRT.
"@

        Add-KvrtHeading -Panel $feed -Text 'Etape 2 — Change parameters'
        Add-KvrtImageCard -Panel $feed -FileName 'kvrt-official-01-change-params.png' -Caption 'Change parameters — definir la portee du scan (howto Kaspersky)' -MaxHeight 320
        Add-KvrtBody -Panel $feed -Text @"
Si besoin, clique Change parameters pour regler le perimetre du scan.
"@

        Add-KvrtHeading -Panel $feed -Text 'Etape 3 — Objets a scanner'
        Add-KvrtImageCard -Panel $feed -FileName 'kvrt-official-02-scan-settings.png' -Caption 'Scan settings — cocher les objets / Add object → OK' -MaxHeight 320
        Add-KvrtBody -Panel $feed -Text @"
1. Coche les zones a analyser
2. Add object pour un dossier ou disque precis
3. OK
"@

        Add-KvrtHeading -Panel $feed -Text 'Etape 4 — Start scan'
        Add-KvrtImageCard -Panel $feed -FileName 'kvrt-official-03-start-scan.png' -Caption 'Start scan — lancer l''analyse' -MaxHeight 320
        Add-KvrtBody -Panel $feed -Text @"
Clique Start scan et attends la fin.
Ferme les autres applis pendant le scan si possible.
Si menaces : suis la demande d'action (desinfecter / supprimer…).
"@

        Add-KvrtHeading -Panel $feed -Text 'Etape 5 — Details (rapport)'
        Add-KvrtImageCard -Panel $feed -FileName 'kvrt-official-04-details.jpg' -Caption 'details — voir le rapport du scan' -MaxHeight 320
        Add-KvrtBody -Panel $feed -Text @"
Clique details pour afficher le resume des detections et actions.
"@

        Add-KvrtHeading -Panel $feed -Text 'Etape 6 — Fermer'
        Add-KvrtImageCard -Panel $feed -FileName 'kvrt-official-05-close.jpg' -Caption 'Close — quitter KVRT' -MaxHeight 320
        Add-KvrtBody -Panel $feed -Text @"
Ferme avec Close (ou la croix).
Puis : scan Defender complet (onglet Scripts) + antivirus temps reel.
"@

        Add-KvrtHeading -Panel $feed -Text 'Apres KVRT'
        Add-KvrtBody -Panel $feed -Text @"
• Ne compte pas sur KVRT comme antivirus permanent
• Si Expiro : LiveDisk + Safe Mode + MBAM, puis winget (Installateur)
• USB / disques externes : inclus-les dans le scope du scan (Add object)
"@

        $foot = New-Object System.Windows.Controls.TextBlock
        $foot.Text = 'Images © Kaspersky Lab — howto 15674 (usage educatif local). https://support.kaspersky.com/kvrt2020/howto/15674'
        $foot.FontSize = 11
        $foot.Foreground = $script:KvrtMutedFg
        $foot.TextWrapping = 'Wrap'
        $foot.Margin = [System.Windows.Thickness]::new(0, 8, 0, 4)
        [void]$feed.Children.Add($foot)
    }

    $btnHowto = $Window.FindName('BtnKvrtHowto')
    $btnOfficial = $Window.FindName('BtnKvrtOfficial')
    $btnCopy = $Window.FindName('BtnKvrtCopyGuide')

    if ($btnHowto) {
        $btnHowto.Add_Click({ Start-Process 'https://support.kaspersky.com/kvrt2020/howto/15674' })
    }
    if ($btnOfficial) {
        $btnOfficial.Add_Click({ Start-Process 'https://www.kaspersky.com/downloads/free-virus-removal-tool' })
    }
    if ($btnCopy) {
        $btnCopy.Add_Click({
            try {
                [System.Windows.Clipboard]::SetText($script:KvrtGuideText)
                [System.Windows.MessageBox]::Show('Guide KVRT copie.', 'Lapwiz — KVRT', 'OK', 'Information') | Out-Null
            }
            catch {}
        }.GetNewClosure())
    }
    Write-KvrtLog 'Guide KVRT. Telechargement / lancement → onglet Scripts.'
}
