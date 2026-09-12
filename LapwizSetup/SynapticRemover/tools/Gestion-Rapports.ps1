# Report manager - max 5 reports kept
$script:ReportLines = New-Object System.Collections.Generic.List[string]
$script:ReportStart = Get-Date
$script:ReportDir = $null
$script:MaxReports = 5

function Get-ReportDirectory {
    param([string]$ToolsPath)
    $root = Split-Path -Parent $ToolsPath
    $dir = Join-Path $root 'reports'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Start-Report {
    param(
        [string]$ToolsPath,
        [string]$Lang = 'fr'
    )
    $script:ReportLines = New-Object System.Collections.Generic.List[string]
    $script:ReportStart = Get-Date
    $script:ReportDir = Get-ReportDirectory -ToolsPath $ToolsPath
    Add-Report 'HEADER' "SynapticRemover report"
    Add-Report 'INFO' ("Lang={0}" -f $Lang)
    Add-Report 'INFO' ("Computer={0}" -f $env:COMPUTERNAME)
    Add-Report 'INFO' ("User={0}" -f $env:USERNAME)
    Add-Report 'INFO' ("OS={0}" -f [Environment]::OSVersion.VersionString)
    Add-Report 'INFO' ("Start={0:yyyy-MM-dd HH:mm:ss}" -f $script:ReportStart)
}

function Add-Report {
    param(
        [ValidateSet('HEADER', 'STEP', 'OK', 'WARN', 'ERR', 'INFO', 'SCAN', 'FOOTER')]
        [string]$Level,
        [string]$Message
    )
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = "[{0}] [{1,-6}] {2}" -f $ts, $Level, $Message
    [void]$script:ReportLines.Add($line)
}

function Add-ReportStep([int]$N, [string]$Title) {
    Add-Report 'STEP' ("--- Step {0}: {1} ---" -f $N, $Title)
}

function Complete-Report {
    param(
        [bool]$HasTraces = $false,
        [string]$ScanPath = ''
    )
    $end = Get-Date
    Add-Report 'INFO' ("End={0:yyyy-MM-dd HH:mm:ss}" -f $end)
    Add-Report 'INFO' ("DurationSec={0}" -f [int]($end - $script:ReportStart).TotalSeconds)
    if ($ScanPath) { Add-Report 'SCAN' ("DeepScanPath={0}" -f $ScanPath) }
    Add-Report 'FOOTER' ("ResultTraces={0}" -f $(if ($HasTraces) { 'YES' } else { 'NO' }))

    if (-not $script:ReportDir) { return $null }

    $name = "SynapticRemover_{0:yyyyMMdd_HHmmss}.txt" -f $script:ReportStart
    $path = Join-Path $script:ReportDir $name
    $header = @(
        '============================================================',
        ' SynapticRemover - Cleanup Report',
        '============================================================',
        ''
    )
    ($header + $script:ReportLines) | Set-Content -LiteralPath $path -Encoding UTF8

    # Keep only the 5 newest reports
    $all = @(Get-ChildItem -LiteralPath $script:ReportDir -File -Filter 'SynapticRemover_*.txt' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($all.Count -gt $script:MaxReports) {
        $all | Select-Object -Skip $script:MaxReports | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    return $path
}

function Get-VolumeTypeName([int]$DriveType) {
    switch ($DriveType) {
        0 { return 'Unknown' }
        1 { return 'NoRoot' }
        2 { return 'Removable' }
        3 { return 'Fixed' }
        4 { return 'Network' }
        5 { return 'CDROM' }
        6 { return 'RAMDisk' }
        default { return "Type$DriveType" }
    }
}

function Get-ReadyVolumes {
    param(
        [switch]$ExcludeSystem,
        [switch]$IncludeSystem
    )
    $sys = $env:SystemDrive.TrimEnd(':').ToUpperInvariant()
    $list = @()
    Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
        # Ready / has a root that exists
        $letter = $_.DeviceID  # e.g. C:
        if (-not $letter) { return }
        $root = "$letter\"
        if (-not (Test-Path -LiteralPath $root)) { return }

        $isSys = ($letter.TrimEnd(':').ToUpperInvariant() -eq $sys)
        if ($ExcludeSystem -and $isSys) { return }
        if (-not $IncludeSystem -and -not $ExcludeSystem -and $false) { }

        $list += [pscustomobject]@{
            Letter    = $letter
            Root      = $root
            DriveType = [int]$_.DriveType
            TypeName  = Get-VolumeTypeName ([int]$_.DriveType)
            Label     = $_.VolumeName
            SizeGB    = if ($_.Size) { [math]::Round($_.Size / 1GB, 1) } else { 0 }
            FreeGB    = if ($_.FreeSpace) { [math]::Round($_.FreeSpace / 1GB, 1) } else { 0 }
            IsSystem  = $isSys
        }
    }
    return $list | Sort-Object Letter
}
