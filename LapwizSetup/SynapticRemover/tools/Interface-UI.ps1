# Shared colored UI helpers for SynapticRemover
# Legend:
#   Green  = OK / success
#   Yellow = warning
#   Red    = error / danger
#   Cyan   = info
#   White  = step titles
#   Magenta= brand / accents
#   DarkGray = secondary / paths

function Write-UiColored([string]$Text, [ConsoleColor]$Color, [switch]$NoNewline) {
    # Ne plus mirroir chaque ligne vers la GUI arabe (causait le freeze pendant les scans)
    if (Get-Command Write-UiText -ErrorAction SilentlyContinue) {
        Write-UiText -Text $Text -ForegroundColor $Color -NoNewline:$NoNewline
        return
    }
    if ($NoNewline) {
        Write-Host $Text -NoNewline -ForegroundColor $Color
    } else {
        Write-Host $Text -ForegroundColor $Color
    }
}

function Write-Ok([string]$m) {
    Write-UiColored '  [' DarkGray -NoNewline
    Write-UiColored '+' Green -NoNewline
    Write-UiColored '] ' DarkGray -NoNewline
    Write-UiColored $m Green
}

function Write-WarnMsg([string]$m) {
    Write-UiColored '  [' DarkGray -NoNewline
    Write-UiColored '!' Yellow -NoNewline
    Write-UiColored '] ' DarkGray -NoNewline
    Write-UiColored $m Yellow
}

function Write-ErrMsg([string]$m) {
    Write-UiColored '  [' DarkGray -NoNewline
    Write-UiColored 'x' Red -NoNewline
    Write-UiColored '] ' DarkGray -NoNewline
    Write-UiColored $m Red
}

function Write-Info([string]$m) {
    Write-UiColored '  [' DarkGray -NoNewline
    Write-UiColored 'i' Cyan -NoNewline
    Write-UiColored '] ' DarkGray -NoNewline
    Write-UiColored $m Cyan
}

function Write-PromptLine([string]$m) {
    Write-UiColored '  [' DarkGray -NoNewline
    Write-UiColored '?' Magenta -NoNewline
    Write-UiColored '] ' DarkGray -NoNewline
    Write-UiColored $m White -NoNewline
}

function Write-Muted([string]$m) {
    Write-UiColored ("  $m") DarkGray
}

function Write-Option([string]$key, [string]$text, [ConsoleColor]$keyColor = [ConsoleColor]::Yellow) {
    Write-Host '    ' -NoNewline
    Write-Host "[$key]" -NoNewline -ForegroundColor $keyColor
    Write-UiColored ("  $text") White
}

function Show-Rule([ConsoleColor]$Color = [ConsoleColor]::DarkCyan, [int]$Width = 70) {
    Write-UiColored ('  ' + ('=' * $Width)) $Color
}

function Show-SoftRule([ConsoleColor]$Color = [ConsoleColor]::DarkGray, [int]$Width = 70) {
    Write-UiColored ('  ' + ('-' * $Width)) $Color
}

function Show-BannerColored {
    param([string]$SubTitle, [string]$LangCode)
    Clear-Host
    try { $host.UI.RawUI.BackgroundColor = 'Black' } catch {}
    Write-Host ''
    Show-Rule Magenta 70
    Write-Host ''
    $logo = @(
        '     ##### #   # #   #   #   ##### ##### #  ####   ####',
        '    #      #   # ##  #  # #  #   #   #   #  #   # #',
        '     ####  #   # # # # ##### #####   #   #  #   #  ###',
        '         #  # #  #  ## #   # #       #   #  #   #     #',
        '    #####    #   #   # #   # #       #   #  ####  ####'
    )
    foreach ($line in $logo) {
        Write-UiColored $line Green
    }
    Write-Host ''
    Write-UiColored ("              $SubTitle") White
    Write-UiColored '           XRed / Synaptics Pointing Device Driver' DarkGray
    Write-UiColored '                    Windows 10 / 11' DarkGray
    Write-Host '              [' -NoNewline -ForegroundColor DarkGray
    Write-Host $LangCode.ToUpper() -NoNewline -ForegroundColor Magenta
    Write-Host ']' -ForegroundColor DarkGray
    Write-Host ''
    Show-Rule Magenta 70

    $legend = 'LEGENDE'
    $ok = 'OK'
    $warn = 'WARN'
    $err = 'ERR'
    $info = 'INFO'
    if (Get-Command Get-Msg -ErrorAction SilentlyContinue) {
        try {
            $legend = Get-Msg 'LegendTitle'
            $ok = Get-Msg 'LegendOk'
            $warn = Get-Msg 'LegendWarn'
            $err = Get-Msg 'LegendErr'
            $info = Get-Msg 'LegendInfo'
        } catch {}
    }
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-UiColored $legend White -NoNewline
    Write-Host '  ' -NoNewline
    Write-Host '[+]' -NoNewline -ForegroundColor Green
    Write-UiColored (" $ok  ") DarkGray -NoNewline
    Write-Host '[!]' -NoNewline -ForegroundColor Yellow
    Write-UiColored (" $warn  ") DarkGray -NoNewline
    Write-Host '[x]' -NoNewline -ForegroundColor Red
    Write-UiColored (" $err  ") DarkGray -NoNewline
    Write-Host '[i]' -NoNewline -ForegroundColor Cyan
    Write-UiColored (" $info") DarkGray
}

function Show-StepColored {
    param(
        [int]$Number,
        [int]$Total,
        [string]$Label,
        [string]$StepWord = 'STEP'
    )
    Write-Host ''
    Show-Rule DarkCyan 70
    Write-Host '  ' -NoNewline
    Write-UiColored $StepWord Cyan -NoNewline
    Write-Host ' ' -NoNewline
    Write-Host $Number -NoNewline -ForegroundColor Yellow
    Write-Host ' / ' -NoNewline -ForegroundColor DarkGray
    Write-Host $Total -NoNewline -ForegroundColor DarkGray
    Write-Host '  -  ' -NoNewline -ForegroundColor DarkGray
    Write-UiColored $Label White

    $barWidth = 28
    $filled = [Math]::Max(1, [Math]::Round(($Number / [double]$Total) * $barWidth))
    $empty = $barWidth - $filled
    Write-Host '  [' -NoNewline -ForegroundColor DarkGray
    Write-Host ('#' * $filled) -NoNewline -ForegroundColor Green
    Write-Host ('-' * $empty) -NoNewline -ForegroundColor DarkGray
    Write-Host ('] {0,3}%' -f [int](($Number / [double]$Total) * 100)) -ForegroundColor DarkGray
    Show-Rule DarkCyan 70
}

function Show-DoneBox {
    param(
        [string]$Title,
        [string]$HashLabel,
        [string]$Hash,
        [string]$CreditsLabel,
        [string[]]$CreditLines
    )
    Write-Host ''
    Show-Rule Green 70
    Write-UiColored ('  ' + $Title) Green
    Show-SoftRule DarkGreen 70
    Write-UiColored ('  ' + $HashLabel) DarkGray
    Write-UiColored ('  ' + $Hash) Yellow
    Show-SoftRule DarkGreen 70
    Write-UiColored ('  ' + $CreditsLabel) DarkGray
    foreach ($line in $CreditLines) {
        Write-UiColored ('  ' + $line) DarkGray
    }
    Show-Rule Green 70
}

function Read-ChoiceColored([string]$Keys, [string]$Prompt) {
    while ($true) {
        Write-PromptLine $Prompt
        $key = [Console]::ReadKey($true)
        $ch = $key.KeyChar.ToString().ToUpperInvariant()
        $keysU = $Keys.ToUpperInvariant()
        $idx = $keysU.IndexOf($ch)
        if ($idx -ge 0) {
            Write-Host $ch -ForegroundColor Yellow
            return ($idx + 1)
        }
    }
}
