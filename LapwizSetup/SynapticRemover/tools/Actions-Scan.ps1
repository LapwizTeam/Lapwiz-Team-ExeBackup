# SynapticRemover helper - scan caches, USB, verify, ensure tool

param(

    [Parameter(Mandatory = $true)]

    [ValidateSet('ScanCaches', 'ScanUsb', 'ScanVolumes', 'Verify', 'EnsureTool')]

    [string]$Action,

    [string]$ToolsRoot = '',

    [ValidateSet('fr', 'en', 'ar')]

    [string]$Lang = 'fr'

)

$ErrorActionPreference = 'Continue'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $here 'Traductions.ps1') -Lang $Lang

. (Join-Path $here 'Interface-UI.ps1')

Set-UiEncoding

if (-not $ToolsRoot) { $ToolsRoot = $here }

# Write-Ok / Write-Warn / Write-Info come from Interface-UI.ps1

# Keep Write-Warn alias for existing helper code

function Write-Warn([string]$m) { Write-WarnMsg $m }

function Get-VirusDirs {

    @(

        (Join-Path $env:ALLUSERSPROFILE 'Synaptics'),

        (Join-Path $env:WINDIR 'System32\Synaptics'),

        'C:\Users\All Users\Synaptics'

    ) | Select-Object -Unique

}

function Ensure-Tool {

    param([string]$Root)

    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') { 'x86_64' } else { 'x86' }

    $exe = Join-Path $Root "synaptics-recover\$arch\synaptics-recover.exe"

    $alt = if ($arch -eq 'x86_64') { 'x86' } else { 'x86_64' }

    $exeAlt = Join-Path $Root "synaptics-recover\$alt\synaptics-recover.exe"

    if (Test-Path -LiteralPath $exe) {

        Write-Ok (Get-Msg 'H_ToolPresent' @($exe))

        return

    }

    if (Test-Path -LiteralPath $exeAlt) {

        Write-Ok (Get-Msg 'H_ToolPresent' @($exeAlt))

        return

    }

    Write-Info (Get-Msg 'H_Downloading')

    $zip = Join-Path $Root 'synaptics-recover.zip'

    $dest = Join-Path $Root 'synaptics-recover'

    New-Item -ItemType Directory -Force -Path $Root | Out-Null

    try {

        Invoke-WebRequest -Uri 'https://github.com/SineStriker/synaptics-recover/releases/download/0.0.1.6/synaptics-recover-0.0.1.6.zip' -OutFile $zip -UseBasicParsing

        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }

        Expand-Archive -Path $zip -DestinationPath $dest -Force

        Remove-Item $zip -Force -ErrorAction SilentlyContinue

    } catch {

        Write-Warn (Get-Msg 'H_DlFail' @($_.Exception.Message))

        return

    }

    if (Test-Path -LiteralPath $exe) {

        Write-Ok (Get-Msg 'H_Downloaded' @($exe))

    } elseif (Test-Path -LiteralPath $exeAlt) {

        Write-Ok (Get-Msg 'H_Downloaded' @($exeAlt))

    } else {

        Write-Warn (Get-Msg 'H_BinMissing')

    }

}

function Test-ExcludedPath([string]$Path) {

    $p = $Path.ToLowerInvariant()

    $deny = @(

        '\appdata\local\microsoft\',

        '\appdata\local\packages\',

        '\appdata\local\temp\',

        '\appdata\local\pip\',

        '\appdata\local\npm-cache\',

        '\appdata\local\yarn\',

        '\appdata\roaming\npm\',

        '\windowsapps\',

        '\node_modules\',

        '\.git\',

        '\.cache\',

        '\winsxs\',

        '\system volume information\',

        '\$recycle.bin\'

    )

    foreach ($d in $deny) {

        if ($p.Contains($d)) { return $true }

    }

    return $false

}

function Remove-CacheHit([System.IO.FileInfo]$File, [ref]$Found, [ref]$Removed) {

    $Found.Value++

    Write-Warn (Get-Msg 'H_Found' @($File.FullName))

    try {

        $File.Attributes = 'Normal'

        Remove-Item -LiteralPath $File.FullName -Force -ErrorAction Stop

        Write-Ok (Get-Msg 'H_Deleted' @($File.FullName))

        $Removed.Value++

    } catch {

        Write-Warn (Get-Msg 'H_DelFail' @($File.FullName))

    }

}

function Scan-Caches {

    Write-Info (Get-Msg 'H_CacheSearch')

    $found = 0

    $removed = 0

    $scannedDirs = 0

    $lastPulse = [Environment]::TickCount64

    $filters = @('._cache_*', '~$cache1')

    # Dossiers prioritaires (rapides) — la ou le virus depose souvent les caches

    $priority = New-Object System.Collections.Generic.List[string]

    foreach ($p in @(

            (Join-Path $env:USERPROFILE 'Desktop'),

            (Join-Path $env:USERPROFILE 'Documents'),

            (Join-Path $env:USERPROFILE 'Downloads'),

            (Join-Path $env:USERPROFILE 'Pictures'),

            (Join-Path $env:USERPROFILE 'Videos'),

            (Join-Path $env:USERPROFILE 'Music'),

            (Join-Path $env:PUBLIC 'Desktop'),

            (Join-Path $env:PUBLIC 'Documents'),

            (Join-Path $env:PUBLIC 'Downloads')

        )) {

        if ($p -and (Test-Path -LiteralPath $p)) { [void]$priority.Add($p) }

    }

    # OneDrive / dossiers cloud courants

    if (Test-Path -LiteralPath $env:USERPROFILE) {

        Get-ChildItem -LiteralPath $env:USERPROFILE -Force -Directory -ErrorAction SilentlyContinue |

            Where-Object { $_.Name -like 'OneDrive*' -or $_.Name -eq 'Dropbox' -or $_.Name -eq 'Google Drive' } |

            ForEach-Object { [void]$priority.Add($_.FullName) }

    }

    # Fichiers eventuels a la racine du profil

    if ($env:USERPROFILE -and (Test-Path -LiteralPath $env:USERPROFILE)) {

        foreach ($filter in $filters) {

            Get-ChildItem -LiteralPath $env:USERPROFILE -Force -File -Filter $filter -ErrorAction SilentlyContinue |

                ForEach-Object { Remove-CacheHit $_ ([ref]$found) ([ref]$removed) }

        }

    }

    $priority = @($priority | Select-Object -Unique)

    foreach ($root in $priority) {

        Write-Info ("→ $root")

        $stack = [System.Collections.Generic.Stack[string]]::new()

        $stack.Push($root)

        while ($stack.Count -gt 0) {

            $dir = $stack.Pop()

            if (Test-ExcludedPath $dir) { continue }

            $scannedDirs++

            $now = [Environment]::TickCount64

            if (($now - $lastPulse) -gt 800) {

                Write-Host ("  ... $scannedDirs dirs | $dir") -ForegroundColor DarkGray

                $lastPulse = $now

            }

            # Fichiers cibles dans ce dossier (filtre FS = rapide)

            foreach ($filter in $filters) {

                try {

                    Get-ChildItem -LiteralPath $dir -Force -File -Filter $filter -ErrorAction SilentlyContinue |

                        ForEach-Object { Remove-CacheHit $_ ([ref]$found) ([ref]$removed) }

                } catch {}

            }

            # Enfants dossiers (sauf exclusions)

            try {

                $children = @(Get-ChildItem -LiteralPath $dir -Force -Directory -ErrorAction SilentlyContinue)

                foreach ($child in $children) {

                    if (Test-ExcludedPath $child.FullName) { continue }

                    # Eviter AppData\Local (tres lent) — garder Roaming uniquement

                    $isUserRoot = ($dir.TrimEnd('\') -ieq $env:USERPROFILE.TrimEnd('\'))

                    if ($isUserRoot -and $child.Name -ieq 'AppData') {

                        $roaming = Join-Path $child.FullName 'Roaming'

                        if (Test-Path -LiteralPath $roaming) { $stack.Push($roaming) }

                        continue

                    }

                    $stack.Push($child.FullName)

                }

            } catch {}

        }

    }

    Write-Info (Get-Msg 'H_CacheSummary' @($found, $removed))

    Write-Info (Get-Msg 'H_DirsScanned' @($scannedDirs))

}

function Scan-Volumes {

    Write-Info (Get-Msg 'H_VolScan')

    $drives = Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |

        Where-Object { $_.DeviceID -and (Test-Path -LiteralPath ($_.DeviceID + '\')) }

    if (-not $drives) {

        Write-Info (Get-Msg 'H_NoVol')

        return @{ Checked = 0; Cleaned = 0 }

    }

    $checked = 0

    $cleaned = 0

    foreach ($d in $drives) {

        $root = $d.DeviceID + '\'

        $typeName = switch ([int]$d.DriveType) {

            2 { 'Removable' }

            3 { 'Fixed' }

            4 { 'Network' }

            5 { 'CDROM' }

            6 { 'RAMDisk' }

            default { "Type$([int]$d.DriveType)" }

        }

        $label = if ($d.VolumeName) { $d.VolumeName } else { '-' }

        Write-Info (Get-Msg 'H_Drive' @("$root [$typeName] ($label)"))

        $checked++

        if (Get-Command Add-Report -ErrorAction SilentlyContinue) {

            Add-Report 'SCAN' ("Volume $root type=$typeName label=$label")

        }

        # Skip CDROM write attempts if read-only - still check for files

        $autorun = Join-Path $root 'autorun.inf'

        if (Test-Path -LiteralPath $autorun) {

            $content = Get-Content -LiteralPath $autorun -Raw -ErrorAction SilentlyContinue

            if ($content -match 'Synaptics|synaptics\.exe') {

                Write-Warn (Get-Msg 'H_AutorunBad' @($autorun))

                try {

                    attrib -h -s -r $autorun 2>$null

                    Remove-Item -LiteralPath $autorun -Force -ErrorAction Stop

                    Write-Ok (Get-Msg 'H_Deleted' @($autorun))

                    $cleaned++

                    if (Get-Command Add-Report -ErrorAction SilentlyContinue) { Add-Report 'OK' "Removed $autorun" }

                } catch {

                    Write-Warn (Get-Msg 'H_Fail' @($autorun))

                    if (Get-Command Add-Report -ErrorAction SilentlyContinue) { Add-Report 'WARN' "Fail $autorun" }

                }

            } else {

                Write-Info (Get-Msg 'H_AutorunOk')

            }

        }

        $syn = Join-Path $root 'Synaptics'

        if (Test-Path -LiteralPath $syn) {

            Write-Warn (Get-Msg 'H_UsbDir' @($syn))

            try {

                Remove-Item -LiteralPath $syn -Recurse -Force -ErrorAction Stop

                Write-Ok (Get-Msg 'H_Deleted' @($syn))

                $cleaned++

                if (Get-Command Add-Report -ErrorAction SilentlyContinue) { Add-Report 'OK' "Removed $syn" }

            } catch {

                Write-Warn (Get-Msg 'H_Fail' @($syn))

            }

        }

        Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue |

            Where-Object { -not $_.PSIsContainer -and ($_.Name -like '._cache_*' -or $_.Name -eq '~$cache1' -or $_.Name -ieq 'Synaptics.exe') } |

            ForEach-Object {

                Write-Warn (Get-Msg 'H_UsbFile' @($_.FullName))

                try {

                    $_.Attributes = 'Normal'

                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop

                    Write-Ok (Get-Msg 'H_Deleted' @($_.FullName))

                    $cleaned++

                    if (Get-Command Add-Report -ErrorAction SilentlyContinue) { Add-Report 'OK' "Removed $($_.FullName)" }

                } catch {

                    Write-Warn (Get-Msg 'H_Fail' @($_.FullName))

                }

            }

    }

    Write-Info (Get-Msg 'H_VolSummary' @($checked, $cleaned))

    return @{ Checked = $checked; Cleaned = $cleaned }

}

function Verify-Clean {

    $issues = 0

    foreach ($dir in Get-VirusDirs) {

        if (Test-Path $dir) {

            Write-Warn (Get-Msg 'H_StillPresent' @($dir))

            $issues++

        }

    }

    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -ieq 'Synaptics' }

    if ($procs) {

        Write-Warn (Get-Msg 'H_ProcAlive')

        $issues++

    }

    $val = 'Synaptics Pointing Device Driver'

    $noti = 'StartupTNotiSynaptics Pointing Device Driver'

    foreach ($path in @(

            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',

            'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunNotification',

            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'

        )) {

        if (Test-Path $path) {

            $props = (Get-ItemProperty -Path $path -ErrorAction SilentlyContinue)

            if ($null -ne $props.PSObject.Properties[$val]) {

                Write-Warn (Get-Msg 'H_RegLeft' @($path, $val))

                $issues++

            }

            if ($null -ne $props.PSObject.Properties[$noti]) {

                Write-Warn (Get-Msg 'H_RegLeft' @($path, $noti))

                $issues++

            }

        }

    }

    if ($issues -eq 0) {

        Write-Ok (Get-Msg 'H_VerifyOk')

    } else {

        Write-Warn (Get-Msg 'H_VerifyWarn' @($issues))

    }

    return $issues

}

switch ($Action) {

    'EnsureTool' { Ensure-Tool -Root $ToolsRoot }

    'ScanCaches' { Scan-Caches }

    'ScanUsb' { Scan-Volumes }      # legacy alias

    'ScanVolumes' { Scan-Volumes }

    'Verify' { Verify-Clean }

}

