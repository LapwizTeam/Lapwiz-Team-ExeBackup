# Lapwiz — icones package (EXE local, URL / favicon, cache utilisateur)
# Dot-source depuis Start-LapwizSetup.ps1

Set-StrictMode -Version Latest

function script:Get-UserIconsDirectory {
    $dir = Join-Path $env:LOCALAPPDATA 'LapwizSetup\user-icons'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function script:Get-SafeIconFileName {
    param([Parameter(Mandatory)][string]$Id)
    $safe = ($Id -replace '[^A-Za-z0-9._-]', '_')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'app' }
    return ($safe + '.png')
}

function script:Save-BitmapAsPng {
    param(
        [Parameter(Mandatory)]$Bitmap,
        [Parameter(Mandatory)][string]$OutPath
    )
    $dir = Split-Path -Parent $OutPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Bitmap.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
}

function script:Save-IconFromExecutable {
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$OutPngPath
    )
    if (-not (Test-Path -LiteralPath $ExePath)) { return $false }
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
        if (-not $icon) { return $false }
        try {
            $bmp = $icon.ToBitmap()
            try {
                # Preferer une taille lisible pour les tuiles Store
                $sized = New-Object System.Drawing.Bitmap 128, 128
                try {
                    $g = [System.Drawing.Graphics]::FromImage($sized)
                    try {
                        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                        $g.Clear([System.Drawing.Color]::Transparent)
                        $g.DrawImage($bmp, 0, 0, 128, 128)
                    }
                    finally { $g.Dispose() }
                    Save-BitmapAsPng -Bitmap $sized -OutPath $OutPngPath
                }
                finally { $sized.Dispose() }
            }
            finally { $bmp.Dispose() }
        }
        finally { $icon.Dispose() }
        return (Test-Path -LiteralPath $OutPngPath)
    }
    catch {
        return $false
    }
}

function script:Save-IconFromUrl {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutPngPath
    )
    try {
        $tmp = Join-Path $env:TEMP ('lapwiz-icon-' + [guid]::NewGuid().ToString('N'))
        $wc = New-Object System.Net.WebClient
        $wc.Headers['User-Agent'] = 'LapwizSetup/1.0'
        try {
            $wc.DownloadFile($Url, $tmp)
        }
        finally { $wc.Dispose() }

        if (-not (Test-Path -LiteralPath $tmp) -or ((Get-Item -LiteralPath $tmp).Length -lt 32)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            return $false
        }

        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        # Charger via bytes pour liberer le fichier tmp immediatement
        $bytes = [IO.File]::ReadAllBytes($tmp)
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        $ms = [IO.MemoryStream]::new($bytes)
        $img = [System.Drawing.Image]::FromStream($ms)
        try {
            $sized = New-Object System.Drawing.Bitmap 128, 128, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            try {
                $g = [System.Drawing.Graphics]::FromImage($sized)
                try {
                    $g.Clear([System.Drawing.Color]::Transparent)
                    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $g.DrawImage($img, 0, 0, 128, 128)
                }
                finally { $g.Dispose() }
                Save-BitmapAsPng -Bitmap $sized -OutPath $OutPngPath
            }
            finally { $sized.Dispose() }
        }
        finally {
            $img.Dispose()
            $ms.Dispose()
        }
        return ((Test-Path -LiteralPath $OutPngPath) -and ((Get-Item -LiteralPath $OutPngPath).Length -ge 64))
    }
    catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function script:Get-FaviconUrlCandidates {
    param([string]$HomepageOrDomain)
    if ([string]::IsNullOrWhiteSpace($HomepageOrDomain)) { return @() }
    $raw = $HomepageOrDomain.Trim()
    $hostName = $raw
    try {
        if ($raw -notmatch '^https?://') { $raw = 'https://' + $raw }
        $uri = [Uri]$raw
        $hostName = $uri.Host
    }
    catch {
        $hostName = ($HomepageOrDomain -replace '^https?://', '' -split '/')[0]
    }
    if ([string]::IsNullOrWhiteSpace($hostName)) { return @() }
    return @(
        ("https://www.google.com/s2/favicons?domain={0}&sz=128" -f $hostName),
        ("https://icons.duckduckgo.com/ip3/{0}.ico" -f $hostName),
        ("https://{0}/favicon.ico" -f $hostName)
    )
}

function script:Resolve-WingetHomepage {
    param([Parameter(Mandatory)][string]$PackageId)
    try {
        $output = & winget show --id $PackageId -e --accept-source-agreements --disable-interactivity 2>&1 | Out-String
        if ($output -match '(?im)^\s*(Homepage|Page d.accueil|Page d''accueil)\s*:\s*(\S+)') {
            return $Matches[2].Trim()
        }
        if ($output -match '(?im)^\s*URL[^\r\n]*:\s*(https?://\S+)') {
            return $Matches[1].Trim()
        }
    }
    catch { }
    return $null
}

function script:Get-KnownPackageDomain {
    param([string]$PackageId)
    if ([string]::IsNullOrWhiteSpace($PackageId)) { return $null }
    $map = @{
        'Anysphere.Cursor'     = 'cursor.com'
        'Google.Chrome'        = 'google.com'
        'Mozilla.Firefox'      = 'mozilla.org'
        'Opera.Opera'          = 'opera.com'
        'Git.Git'              = 'git-scm.com'
        'Kaspersky.KVRT'       = 'kaspersky.com'
        '7zip.7zip'            = '7-zip.org'
        'RARLab.WinRAR'        = 'win-rar.com'
        'Notepad++.Notepad++'  = 'notepad-plus-plus.org'
        'OpenJS.NodeJS.LTS'    = 'nodejs.org'
        'Python.Python.3.12'   = 'python.org'
        'Google.AndroidStudio' = 'developer.android.com'
        'Google.PlatformTools' = 'developer.android.com'
    }
    $key = $PackageId.Trim()
    if ($map.ContainsKey($key)) { return $map[$key] }
    # Heuristique : Publisher.Product -> publisher.com
    if ($key -match '^([A-Za-z0-9]+)\.') {
        return ($Matches[1].ToLowerInvariant() + '.com')
    }
    return $null
}

function script:Ensure-PackageIconFile {
    param(
        [Parameter(Mandatory)][object]$Pkg,
        [switch]$AllowDownload
    )
    try {
    $id = [string]$Pkg.id
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }

    $userDir = Get-UserIconsDirectory
    $safeName = Get-SafeIconFileName -Id $id
    $userPath = Join-Path $userDir $safeName

    # Deja en cache utilisateur
    if (Test-Path -LiteralPath $userPath) {
        if ((Get-Item -LiteralPath $userPath).Length -ge 64) { return $userPath }
    }

    # iconPath absolu encore valide
    $pathProp = $Pkg.PSObject.Properties['iconPath']
    if ($null -ne $pathProp -and -not [string]::IsNullOrWhiteSpace([string]$pathProp.Value)) {
        $abs = [string]$pathProp.Value
        if ((Test-Path -LiteralPath $abs) -and ((Get-Item -LiteralPath $abs).Length -ge 64)) {
            try {
                Copy-Item -LiteralPath $abs -Destination $userPath -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $userPath) { return $userPath }
            }
            catch { }
            return $abs
        }
    }

    # Asset officiel / nom icon
    $iconProp = $Pkg.PSObject.Properties['icon']
    if ($null -ne $iconProp -and -not [string]::IsNullOrWhiteSpace([string]$iconProp.Value)) {
        $name = [string]$iconProp.Value
        $roots = [System.Collections.Generic.List[string]]::new()
        if ($script:ScriptRoot) { [void]$roots.Add((Join-Path $script:ScriptRoot 'assets\app-icons')) }
        if ($PSScriptRoot) {
            [void]$roots.Add((Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\app-icons'))
            [void]$roots.Add((Join-Path $PSScriptRoot '..\assets\app-icons'))
        }
        foreach ($r in $roots) {
            try {
                $cand = Join-Path $r $name
                if ((Test-Path -LiteralPath $cand) -and ((Get-Item -LiteralPath $cand).Length -ge 64)) {
                    return $cand
                }
            }
            catch { }
        }
        $userNamed = Join-Path $userDir $name
        if ((Test-Path -LiteralPath $userNamed) -and ((Get-Item -LiteralPath $userNamed).Length -ge 64)) {
            return $userNamed
        }
    }

    # EXE local
    $localProp = $Pkg.PSObject.Properties['localPath']
    if ($null -ne $localProp -and -not [string]::IsNullOrWhiteSpace([string]$localProp.Value)) {
        $exe = [string]$localProp.Value
        if (Test-Path -LiteralPath $exe) {
            if (Save-IconFromExecutable -ExePath $exe -OutPngPath $userPath) {
                return $userPath
            }
        }
    }

    # Telechargement reseau uniquement si demande (pas au rebuild UI — evite freeze/crash)
    if ($AllowDownload) {
        $homePageUrl = $null
        $homeProp = $Pkg.PSObject.Properties['homepage']
        if ($null -ne $homeProp) { $homePageUrl = [string]$homeProp.Value }
        if ([string]::IsNullOrWhiteSpace($homePageUrl)) {
            $homePageUrl = Get-KnownPackageDomain -PackageId $id
        }
        $saved = Save-PackageIconForId -Id $id -Homepage $homePageUrl
        if ($saved) { return $saved }
    }

    return $null
    }
    catch {
        return $null
    }
}

function script:Save-PackageIconForId {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Homepage,
        [string]$LocalExePath,
        [string]$IconUrl
    )
    $out = Join-Path (Get-UserIconsDirectory) (Get-SafeIconFileName -Id $Id)

    if (-not [string]::IsNullOrWhiteSpace($LocalExePath) -and (Test-Path -LiteralPath $LocalExePath)) {
        if (Save-IconFromExecutable -ExePath $LocalExePath -OutPngPath $out) {
            return $out
        }
    }

    $urls = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($IconUrl)) { [void]$urls.Add($IconUrl.Trim()) }
    foreach ($u in (Get-FaviconUrlCandidates -HomepageOrDomain $Homepage)) {
        [void]$urls.Add($u)
    }
    $known = Get-KnownPackageDomain -PackageId $Id
    if ($known) {
        foreach ($u in (Get-FaviconUrlCandidates -HomepageOrDomain $known)) {
            if (-not $urls.Contains($u)) { [void]$urls.Add($u) }
        }
    }

    foreach ($u in $urls) {
        if (Save-IconFromUrl -Url $u -OutPngPath $out) {
            return $out
        }
    }
    return $null
}
