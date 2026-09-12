# SynapticRemover - main cleanup flow (FR / EN / AR)

param(

    [ValidateSet('fr', 'en', 'ar', 'auto')]

    [string]$Lang = 'auto',

    [switch]$Interactive,

    [switch]$Reboot,

    [ValidateSet('Profile', 'System', 'OtherVolumes', 'AllVolumes')]

    [string]$ScanMode = 'AllVolumes'

)

$ErrorActionPreference = 'Continue'

$Tools = Split-Path -Parent $MyInvocation.MyCommand.Path

$Root = Split-Path -Parent $Tools

# Automatique par defaut ; -Interactive pour le mode manuel

$IsAuto = -not [bool]$Interactive

function Resolve-UiLang([string]$Requested) {

    if ($Requested -and $Requested -ne 'auto') { return $Requested }

    $cult = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName

    switch ($cult) {

        'fr' { return 'fr' }

        'ar' { return 'ar' }

        default { return 'en' }

    }

}

$Lang = Resolve-UiLang $Lang

# NOTE: pas de relance Windows Terminal (casse souvent les droits Admin / bloque le scan)

. (Join-Path $Tools 'Traductions.ps1') -Lang $Lang
. (Join-Path $Tools 'Interface-UI.ps1')
. (Join-Path $Tools 'Gestion-Rapports.ps1')
Set-UiEncoding

# Journal arabe leger (etapes seulement, pas chaque ligne)
if ($Lang -eq 'ar') {
    . (Join-Path $Tools 'Journal-Arabe.ps1')
    Start-ArabicGuiLog
    Write-ArabicGui (Get-Msg 'Title')
    Write-ArabicGui (Get-Msg 'AutoMode')
    Write-ArabicGui (Get-Msg 'AutoModeHint')
}

$TotalSteps = 11

$Val = 'Synaptics Pointing Device Driver'

$ValNoti = 'StartupTNotiSynaptics Pointing Device Driver'

$host.UI.RawUI.WindowTitle = (Get-Msg 'Title')

$script:DeepScanPath = ''

Start-Report -ToolsPath $Tools -Lang $Lang

Add-Report 'INFO' ("Mode=" + $(if ($IsAuto) { 'AUTO' } else { 'INTERACTIVE' }))

Add-Report 'INFO' ("ScanMode=$ScanMode")

function Show-Banner {

    Show-BannerColored -SubTitle (Get-Msg 'BannerSub') -LangCode $script:Lang

}

function Show-Step([int]$n, [string]$text) {
    Show-StepColored -Number $n -Total $TotalSteps -Label $text -StepWord (Get-Msg 'Step')
    Add-ReportStep $n $text
    if (Get-Command Write-ArabicGui -ErrorAction SilentlyContinue) {
        Write-ArabicGui ("{0} {1}/{2} - {3}" -f (Get-Msg 'Step'), $n, $TotalSteps, $text)
    }
}

function Invoke-Heavy([scriptblock]$Action) {
    if (Get-Command Suspend-ArabicGui -ErrorAction SilentlyContinue) { Suspend-ArabicGui }
    try {
        & $Action
    } finally {
        if (Get-Command Resume-ArabicGui -ErrorAction SilentlyContinue) { Resume-ArabicGui }
    }
}

function Read-Choice([string]$Keys, [string]$Prompt) {

    Read-ChoiceColored -Keys $Keys -Prompt $Prompt

}

function Test-IsAdmin {

    $id = [Security.Principal.WindowsIdentity]::GetCurrent()

    $p = [Security.Principal.WindowsPrincipal]::new($id)

    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

}

function Remove-RegValue([string]$Path, [string]$Name, [ref]$Removed) {

    try {

        if (-not (Test-Path -LiteralPath $Path)) { return }

        $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue

        if ($null -eq $item) { return }

        $props = $item.GetValueNames()

        if ($props -contains $Name) {

            Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction Stop

            Write-Ok (Get-Msg 'RegRemoved' @($Path, $Name))

            $Removed.Value = $true

        }

    } catch {

        Write-WarnMsg (Get-Msg 'RegFail' @($Path, $Name))

    }

}

function Remove-VirusDir([string]$Dir) {

    if (-not (Test-Path -LiteralPath $Dir)) {

        Write-Info (Get-Msg 'DirMissing' @($Dir))

        return

    }

    try {

        Get-ChildItem -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue |

            Where-Object { -not $_.PSIsContainer -and $_.Extension -ieq '.exe' } |

            ForEach-Object {

                Stop-Process -Name $_.BaseName -Force -ErrorAction SilentlyContinue

            }

        attrib -h -s -r "$Dir\*.*" /s /d 2>$null | Out-Null

        attrib -h -s -r $Dir 2>$null | Out-Null

        Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction Stop

        if (Test-Path -LiteralPath $Dir) {

            Write-WarnMsg (Get-Msg 'DirFail' @($Dir))

        } else {

            Write-Ok (Get-Msg 'DirRemoved' @($Dir))

        }

    } catch {

        Write-WarnMsg (Get-Msg 'DirFail' @($Dir))

    }

}

function Get-RecoverExe {

    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') { 'x86_64' } else { 'x86' }

    $exe = Join-Path $Tools "synaptics-recover\$arch\synaptics-recover.exe"

    if (Test-Path -LiteralPath $exe) { return $exe }

    $alt = Join-Path $Tools 'synaptics-recover\x86\synaptics-recover.exe'

    if (Test-Path -LiteralPath $alt) { return $alt }

    $alt64 = Join-Path $Tools 'synaptics-recover\x86_64\synaptics-recover.exe'

    if (Test-Path -LiteralPath $alt64) { return $alt64 }

    return $null

}

if (-not (Test-IsAdmin)) {

    Write-Host ''

    Write-ErrMsg (Get-Msg 'NeedAdmin')

    Write-ErrMsg (Get-Msg 'NeedAdminHint')

    Write-Host ''

    Write-PromptLine ((Get-Msg 'PressKey') + ' ')

    [void][Console]::ReadKey($true)

    exit 1

}

Show-Banner

Write-Host ''

if ($IsAuto) {

    Write-Ok (Get-Msg 'AutoMode')

    Write-Info (Get-Msg 'AutoModeHint')

} else {

    Write-Info (Get-Msg 'Intro1')

    Write-Info (Get-Msg 'Intro2')

}

Write-Host ''

Write-Host '  ' -NoNewline

Write-Host (Get-Msg 'Sources') -ForegroundColor White

Write-Muted '- d5-i/Synaptics.exe-Backdoor'

Write-Muted '- SineStriker/synaptics-recover'

Write-Host ''

if (-not $IsAuto) {

    Write-PromptLine ((Get-Msg 'PressKey') + ' ')

    [void][Console]::ReadKey($true)

    Write-Host ''

}

Write-Host ''

Show-Step 1 (Get-Msg 'Step1')

reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' /v Hidden /t REG_DWORD /d 1 /f 2>$null | Out-Null

reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' /v ShowSuperHidden /t REG_DWORD /d 1 /f 2>$null | Out-Null

Write-Ok (Get-Msg 'Step1Ok')

Show-Step 2 (Get-Msg 'Step2')

$killed = $false

Get-Process -Name 'Synaptics' -ErrorAction SilentlyContinue | ForEach-Object {

    try {

        Stop-Process -Id $_.Id -Force -ErrorAction Stop

        Write-Ok (Get-Msg 'ProcKilled')

        $script:killed = $true

        $killed = $true

    } catch {

        Write-WarnMsg (Get-Msg 'ProcKillFail')

    }

}

foreach ($dir in @(

        (Join-Path $env:ALLUSERSPROFILE 'Synaptics'),

        (Join-Path $env:WINDIR 'System32\Synaptics'),

        'C:\Users\All Users\Synaptics'

    )) {

    if (-not (Test-Path -LiteralPath $dir)) { continue }

    Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.exe' -Force -ErrorAction SilentlyContinue | ForEach-Object {

        $exePath = $_.FullName

        $name = $_.Name

        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |

            Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $exePath) } |

            ForEach-Object {

                try {

                    Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop

                    Write-Ok (Get-Msg 'ProcKilledPid' @($name, $_.ProcessId))

                    $killed = $true

                } catch {}

            }

    }

}

if (-not $killed) { Write-Info (Get-Msg 'ProcNone') }

Show-Step 3 (Get-Msg 'Step3')

$removed = $false

Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | ForEach-Object {

    $sid = $_.PSChildName

    if ($sid -notmatch '^S-') { return }

    Remove-RegValue "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Run" $Val ([ref]$removed)

    Remove-RegValue "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\RunNotification" $ValNoti ([ref]$removed)

}

Remove-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' $Val ([ref]$removed)

Remove-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunNotification' $ValNoti ([ref]$removed)

Remove-RegValue 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' $Val ([ref]$removed)

Remove-RegValue 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunNotification' $ValNoti ([ref]$removed)

if (-not $removed) { Write-Info (Get-Msg 'RegNone') }

Show-Step 4 (Get-Msg 'Step4')

Remove-VirusDir (Join-Path $env:ALLUSERSPROFILE 'Synaptics')

Remove-VirusDir (Join-Path $env:WINDIR 'System32\Synaptics')

Remove-VirusDir 'C:\Users\All Users\Synaptics'

Remove-VirusDir 'C:\ProgramData\Synaptics'

Show-Step 5 (Get-Msg 'Step5')

Invoke-Heavy { & (Join-Path $Tools 'Actions-Scan.ps1') -Action ScanCaches -Lang $Lang }

Show-Step 6 (Get-Msg 'Step6')

Invoke-Heavy { & (Join-Path $Tools 'Actions-Scan.ps1') -Action ScanVolumes -Lang $Lang }

Add-Report 'OK' 'Volume surface scan done'

Show-Step 7 (Get-Msg 'Step7')

Write-Info (Get-Msg 'TempTarget' @($env:TEMP))

Get-ChildItem -LiteralPath $env:TEMP -Force -ErrorAction SilentlyContinue | ForEach-Object {

    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue

}

Write-Ok (Get-Msg 'TempOk')

Show-Step 8 (Get-Msg 'Step8')

$recover = Get-RecoverExe

if (-not $recover) {

    Write-Info (Get-Msg 'ToolDownloading')

    & (Join-Path $Tools 'Actions-Scan.ps1') -Action EnsureTool -ToolsRoot $Tools -Lang $Lang

    $recover = Get-RecoverExe

}

if ($recover) {

    Write-Ok (Get-Msg 'ToolReady' @($recover))

} else {

    Write-WarnMsg (Get-Msg 'ToolMissing')

}

Show-Step 9 (Get-Msg 'Step9')

if ($recover) {

    Write-Info (Get-Msg 'ToolLaunch' @($recover))

    Write-Host ''

    Invoke-Heavy { & $recover -k }

    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {

        Write-WarnMsg (Get-Msg 'KillFail')

    } else {

        Write-Ok (Get-Msg 'KillOk')

    }

} else {

    Write-Info (Get-Msg 'StepSkipped')

}

Show-Step 10 (Get-Msg 'Step10')

Write-Host ''

Write-Info (Get-Msg 'ScanIntro1')

Write-Info (Get-Msg 'ScanIntro2')

Write-Host ''

$allVols = @(Get-ReadyVolumes -IncludeSystem)

Write-Host '  ' -NoNewline

Write-Host (Get-Msg 'VolListTitle') -ForegroundColor White

foreach ($v in $allVols) {

    $mark = if ($v.IsSystem) { '*' } else { ' ' }

    Write-Muted ("{0} {1}  [{2,-10}]  {3}  {4} GB free" -f $mark, $v.Root, $v.TypeName, $(if ($v.Label) { $v.Label } else { '-' }), $v.FreeGB)

}

Write-Muted (Get-Msg 'VolListHint')

Write-Host ''

$pathsToScan = @()

if ($IsAuto) {

    Write-Info (Get-Msg 'AutoScan' @($ScanMode))

    Add-Report 'INFO' "Auto deep scan mode=$ScanMode"

    switch ($ScanMode) {

        'Profile' { $pathsToScan = @($env:USERPROFILE) }

        'System' { $pathsToScan = @("$($env:SystemDrive)\") }

        'OtherVolumes' {

            $pathsToScan = @($allVols | Where-Object { -not $_.IsSystem } | ForEach-Object { $_.Root })

        }

        default {

            # AllVolumes

            $pathsToScan = @($allVols | ForEach-Object { $_.Root })

        }

    }

    if ($pathsToScan.Count -eq 0) {

        Write-WarnMsg (Get-Msg 'VolNoneOther')

        Add-Report 'WARN' 'No volumes to scan'

    }

} else {

    Write-Option '1' ((Get-Msg 'ScanOpt1' @($env:USERPROFILE)) -replace '^\[1\]\s*', '')

    Write-Option '2' ((Get-Msg 'ScanOpt2' @($env:SystemDrive)) -replace '^\[2\]\s*', '') -keyColor Magenta

    Write-Option '3' (Get-Msg 'ScanOpt3') -keyColor Cyan

    Write-Option '4' (Get-Msg 'ScanOpt4') -keyColor Yellow

    Write-Option '5' (Get-Msg 'ScanOpt5') -keyColor DarkGray

    Write-Host ''

    $scanChoice = Read-Choice '12345' (Get-Msg 'ScanPrompt')

    if ($scanChoice -eq 5) {

        Write-Info (Get-Msg 'ScanSkipped')

        Add-Report 'INFO' 'Deep scan skipped'

    } elseif (-not $recover) {

        Write-WarnMsg (Get-Msg 'ScanNoTool')

        Add-Report 'WARN' 'Deep scan skipped - tool missing'

    } elseif ($scanChoice -eq 1) {

        $pathsToScan = @($env:USERPROFILE)

    } elseif ($scanChoice -eq 2) {

        $pathsToScan = @("$($env:SystemDrive)\")

    } elseif ($scanChoice -eq 3) {

        $pathsToScan = @($allVols | Where-Object { -not $_.IsSystem } | ForEach-Object { $_.Root })

        if ($pathsToScan.Count -eq 0) {

            Write-WarnMsg (Get-Msg 'VolNoneOther')

            Add-Report 'WARN' 'No other volumes to scan'

        }

    } elseif ($scanChoice -eq 4) {

        $pathsToScan = @($allVols | ForEach-Object { $_.Root })

    }

}

if ($IsAuto -and -not $recover -and $pathsToScan.Count -gt 0) {

    Write-WarnMsg (Get-Msg 'ScanNoTool')

    Add-Report 'WARN' 'Deep scan skipped - tool missing'

    $pathsToScan = @()

}

foreach ($scanPath in $pathsToScan) {

    Write-Host ''

    Write-Info (Get-Msg 'ScanRunning' @($scanPath))

    Write-Info (Get-Msg 'ScanDontClose')

    Write-Host ''

    Add-Report 'SCAN' ("Deep scan start: $scanPath")

    $script:DeepScanPath = if ($script:DeepScanPath) { "$script:DeepScanPath; $scanPath" } else { $scanPath }

    Invoke-Heavy { & $recover $scanPath }

    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {

        Write-WarnMsg (Get-Msg 'ScanWarn')

        Add-Report 'WARN' ("Deep scan warnings: $scanPath")

    } else {

        Write-Ok (Get-Msg 'ScanOk')

        Add-Report 'OK' ("Deep scan done: $scanPath")

    }

}

Show-Step 11 (Get-Msg 'Step11')

& (Join-Path $Tools 'Actions-Scan.ps1') -Action Verify -Lang $Lang

$found = $false

if (Test-Path (Join-Path $env:ALLUSERSPROFILE 'Synaptics')) { $found = $true }

if (Test-Path (Join-Path $env:WINDIR 'System32\Synaptics')) { $found = $true }

if (Get-Process -Name 'Synaptics' -ErrorAction SilentlyContinue) { $found = $true }

if ($found) { Add-Report 'WARN' 'Traces still present' } else { Add-Report 'OK' 'No obvious traces' }

$reportPath = Complete-Report -HasTraces $found -ScanPath $script:DeepScanPath

Write-Host ''

Show-DoneBox -Title (Get-Msg 'DoneTitle') `

    -HashLabel (Get-Msg 'HashRef') `

    -Hash '59923677C6EB8195C3592850F4B436FCDC4E15B2361FB9C30398AA098CA0EFBC' `

    -CreditsLabel (Get-Msg 'Credits') `

    -CreditLines @(

        '- Guide : github.com/d5-i/Synaptics.exe-Backdoor',

        '- Recover : github.com/SineStriker/synaptics-recover (GPL-3.0)'

    )

Write-Host ''

if ($found) {

    Write-WarnMsg (Get-Msg 'TracesRemain')

} else {

    Write-Ok (Get-Msg 'NoTraces')

}

if ($reportPath) {

    Write-Host ''

    Write-Ok (Get-Msg 'ReportSaved' @($reportPath))

    Write-Info (Get-Msg 'ReportLimit')

}

Write-Host ''

if ($IsAuto) {

    if ($Reboot) {

        Write-WarnMsg (Get-Msg 'RebootIn10')

        Add-Report 'INFO' 'Auto reboot requested'

        shutdown /r /t 10 /c (Get-Msg 'RebootMsg')

    } else {

        Write-Info (Get-Msg 'AutoNoReboot')

        Add-Report 'INFO' 'No reboot (auto mode)'

        Write-Host ''

        Write-Info (Get-Msg 'AutoDoneWait')

        if (Get-Command Write-ArabicGui -ErrorAction SilentlyContinue) { Write-ArabicGui (Get-Msg 'DoneTitle') }; Start-Sleep -Seconds 8

    }

} else {

    $rebootKeys = Get-Msg 'RebootYesKeys'

    $rebootChoice = Read-Choice $rebootKeys (Get-Msg 'RebootPrompt')

    if ($rebootChoice -eq 1) {

        Write-Host ''

        Write-WarnMsg (Get-Msg 'RebootIn10')

        shutdown /r /t 10 /c (Get-Msg 'RebootMsg')

    } else {

        Write-Host ''

        Write-Info (Get-Msg 'RebootCancel')

        Write-Host ''

        Write-PromptLine ((Get-Msg 'PressKey') + ' ')

        [void][Console]::ReadKey($true)

    }

}

