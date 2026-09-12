#Requires -Version 5.1
<#
.SYNOPSIS
    Catalogue utilisateur Lapwiz — merge packages.json + packages.user.json (AppData).
.NOTES
    Ne modifie jamais packages.json (integrite SHA256). Persistance :
    %LOCALAPPDATA%\LapwizSetup\packages.user.json
#>
Set-StrictMode -Version Latest

function script:Read-OfficialPackages {
    param([Parameter(Mandatory)][string]$PackagesPath)
    if (-not (Test-Path -LiteralPath $PackagesPath)) {
        throw "Fichier packages.json introuvable : $PackagesPath"
    }
    # PS 5.1 : ConvertFrom-Json via pipeline enveloppe le tableau JSON en 1 objet.
    # Toujours utiliser -InputObject, puis aplatir en liste a plat.
    $raw = Get-Content -LiteralPath $PackagesPath -Raw -Encoding UTF8
    $parsed = ConvertFrom-Json -InputObject $raw
    $list = [System.Collections.Generic.List[object]]::new()
    # Iterer le tableau JSON directement (sans @() qui peut re-imbriquer)
    if ($parsed -is [System.Array]) {
        foreach ($item in $parsed) {
            if ($null -ne $item -and ($item.PSObject.Properties['id'])) {
                [void]$list.Add($item)
            }
        }
    }
    elseif ($null -ne $parsed -and ($parsed.PSObject.Properties['id'])) {
        [void]$list.Add($parsed)
    }
    Write-Output -NoEnumerate $list.ToArray()
}

function script:Get-UserPackagesPath {
    $dir = Join-Path $env:LOCALAPPDATA 'LapwizSetup'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return (Join-Path $dir 'packages.user.json')
}

function script:Get-HiddenPackagesPath {
    $dir = Join-Path $env:LOCALAPPDATA 'LapwizSetup'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return (Join-Path $dir 'packages.hidden.json')
}

function script:Read-HiddenPackageIds {
    $list = [System.Collections.Generic.List[string]]::new()
    $path = Get-HiddenPackagesPath
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Output -NoEnumerate $list.ToArray()
        return
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Output -NoEnumerate $list.ToArray()
            return
        }
        $parsed = ConvertFrom-Json -InputObject $raw
        foreach ($item in @($parsed)) {
            if ($null -eq $item) { continue }
            $id = [string]$item
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                [void]$list.Add($id.Trim())
            }
        }
    }
    catch {
        Write-Warning "packages.hidden.json illisible : $_"
    }
    Write-Output -NoEnumerate $list.ToArray()
}

function script:Save-HiddenPackageIds {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Ids)
    $path = Get-HiddenPackagesPath
    $clean = @($Ids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    if ($clean.Count -eq 0) {
        $json = '[]'
    }
    elseif ($clean.Count -eq 1) {
        $json = '[' + (ConvertTo-Json -InputObject $clean[0]) + ']'
    }
    else {
        $json = ConvertTo-Json -InputObject $clean -Depth 4
    }
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($path, $json, $utf8Bom)
    return $path
}

function script:Hide-PackageFromList {
    param([Parameter(Mandatory)][string]$Id)
    $id = $Id.Trim()
    if ([string]::IsNullOrWhiteSpace($id)) { return $false }
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($h in (Read-HiddenPackageIds)) {
        if ([string]$h -ine $id) { [void]$list.Add([string]$h) }
    }
    [void]$list.Add($id)
    Save-HiddenPackageIds -Ids @($list.ToArray()) | Out-Null
    return $true
}

function script:Remove-PackageFromList {
    <#
    .SYNOPSIS
        Retire une app de la liste UI.
        - source user : supprime de packages.user.json
        - catalogue officiel : masque via packages.hidden.json (ne modifie pas packages.json)
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Source = ''
    )
    $id = $Id.Trim()
    if ([string]::IsNullOrWhiteSpace($id)) { return $false }

    $isUser = ($Source -ieq 'user')
    if (-not $isUser) {
        foreach ($p in (Read-UserPackages)) {
            if ([string]$p.id -ieq $id) { $isUser = $true; break }
        }
    }

    if ($isUser) {
        return [bool](Remove-UserPackage -Id $id)
    }
    return [bool](Hide-PackageFromList -Id $id)
}

function script:Read-UserPackages {
    $list = [System.Collections.Generic.List[object]]::new()
    $path = Get-UserPackagesPath
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Output -NoEnumerate $list.ToArray()
        return
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Output -NoEnumerate $list.ToArray()
            return
        }
        $parsed = ConvertFrom-Json -InputObject $raw
        if ($parsed -is [System.Array]) {
            foreach ($item in $parsed) {
                if ($null -ne $item -and ($item.PSObject.Properties['id'])) {
                    [void]$list.Add($item)
                }
            }
        }
        elseif ($null -ne $parsed -and ($parsed.PSObject.Properties['id'])) {
            [void]$list.Add($parsed)
        }
    }
    catch {
        Write-Warning "packages.user.json illisible : $_"
    }
    Write-Output -NoEnumerate $list.ToArray()
}

function script:Save-UserPackages {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Packages)
    $path = Get-UserPackagesPath
    $list = @($Packages)
    if ($list.Count -eq 0) {
        $json = '[]'
    }
    elseif ($list.Count -eq 1) {
        $json = '[' + (ConvertTo-Json -InputObject $list[0] -Depth 6) + ']'
    }
    else {
        $json = ConvertTo-Json -InputObject $list -Depth 6
    }
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($path, $json, $utf8Bom)
    return $path
}

function script:Normalize-PackageList {
    param($InputObject)
    $list = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $InputObject) {
        Write-Output -NoEnumerate $list.ToArray()
        return
    }

    $stack = [System.Collections.Generic.Queue[object]]::new()
    [void]$stack.Enqueue($InputObject)
    while ($stack.Count -gt 0) {
        $item = $stack.Dequeue()
        if ($null -eq $item) { continue }
        if ($item -is [string]) { continue }

        # Tableaux / listes d'abord (un .id sur un Object[] agregait tous les ids)
        if ($item -is [System.Array] -or
            ($item -is [System.Collections.IList] -and $item -isnot [string])) {
            foreach ($inner in $item) {
                if ($null -ne $inner) { [void]$stack.Enqueue($inner) }
            }
            continue
        }

        if ($null -ne $item.PSObject.Properties['id'] -and -not [string]::IsNullOrWhiteSpace([string]$item.id)) {
            [void]$list.Add($item)
        }
    }
    Write-Output -NoEnumerate $list.ToArray()
}

function script:Merge-LapwizPackages {
    param(
        [Parameter(Mandatory)]$Official,
        $User = @(),
        $HiddenIds = $null
    )
    if ($null -eq $HiddenIds) {
        $HiddenIds = Read-HiddenPackageIds
    }
    $hidden = @{}
    foreach ($h in @($HiddenIds)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$h)) {
            $hidden[[string]$h.ToLowerInvariant()] = $true
        }
    }

    $merged = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($pkg in (Normalize-PackageList -InputObject $Official)) {
        $id = [string]$pkg.id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $key = $id.ToLowerInvariant()
        if ($hidden.ContainsKey($key)) { continue }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$merged.Add($pkg)
    }
    foreach ($pkg in (Normalize-PackageList -InputObject $User)) {
        $id = [string]$pkg.id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $key = $id.ToLowerInvariant()
        if ($hidden.ContainsKey($key)) { continue }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$merged.Add($pkg)
    }
    Write-Output -NoEnumerate $merged.ToArray()
}

function script:Add-UserPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [string]$Category = 'Autres',
        [string]$Notes = 'Ajoute manuellement',
        [bool]$Selected = $true,
        [string]$Icon = '',
        [string]$IconPath = '',
        [string]$InstallMode = 'winget',
        [string]$LocalPath = '',
        [string]$InstallUrl = ''
    )
    $id = $Id.Trim()
    $name = $Name.Trim()
    if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($name)) {
        throw 'Id et Name requis.'
    }
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($p in (Read-UserPackages)) {
        if (-not ($p.PSObject.Properties['id'])) { continue }
        if ([string]$p.id -ieq $id) { continue }
        [void]$list.Add($p)
    }
    $entry = [ordered]@{
        id       = $id
        name     = $name
        category = $(if ([string]::IsNullOrWhiteSpace($Category)) { 'Autres' } else { $Category.Trim() })
        notes    = $Notes
        selected = $Selected
        source   = 'user'
    }
    if (-not [string]::IsNullOrWhiteSpace($Icon)) { $entry['icon'] = $Icon.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($IconPath)) {
        $entry['iconPath'] = $IconPath.Trim()
        # Toujours aussi un nom relatif stable (survit aux deplacements AppData)
        if ([string]::IsNullOrWhiteSpace($Icon) -and (Get-Command Get-SafeIconFileName -ErrorAction SilentlyContinue)) {
            $entry['icon'] = Get-SafeIconFileName -Id $id
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($InstallMode) -and $InstallMode -ine 'winget') {
        $entry['installMode'] = $InstallMode.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($LocalPath)) { $entry['localPath'] = $LocalPath.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($InstallUrl)) { $entry['installUrl'] = $InstallUrl.Trim() }
    [void]$list.Add([pscustomobject]$entry)
    Save-UserPackages -Packages @($list.ToArray()) | Out-Null
    return [pscustomobject]$entry
}

function script:Update-UserPackageIconMeta {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$IconPath = '',
        [string]$Icon = ''
    )
    $id = $Id.Trim()
    $list = [System.Collections.Generic.List[object]]::new()
    $changed = $false
    foreach ($p in (Read-UserPackages)) {
        if (-not ($p.PSObject.Properties['id'])) { continue }
        if ([string]$p.id -ieq $id) {
            $h = [ordered]@{}
            foreach ($prop in $p.PSObject.Properties) {
                $h[$prop.Name] = $prop.Value
            }
            if (-not [string]::IsNullOrWhiteSpace($IconPath)) {
                $h['iconPath'] = $IconPath
                $changed = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($Icon)) {
                $h['icon'] = $Icon
                $changed = $true
            }
            elseif (-not [string]::IsNullOrWhiteSpace($IconPath) -and (Get-Command Get-SafeIconFileName -ErrorAction SilentlyContinue)) {
                $h['icon'] = Get-SafeIconFileName -Id $id
                $changed = $true
            }
            [void]$list.Add([pscustomobject]$h)
        }
        else {
            [void]$list.Add($p)
        }
    }
    if ($changed) {
        Save-UserPackages -Packages @($list.ToArray()) | Out-Null
    }
    return $changed
}

function script:Remove-UserPackage {
    param([Parameter(Mandatory)][string]$Id)
    $id = $Id.Trim()
    $before = @(Read-UserPackages)
    $after = @($before | Where-Object {
            ($_.PSObject.Properties['id']) -and ([string]$_.id -ine $id)
        })
    if ($after.Count -eq $before.Count) { return $false }
    Save-UserPackages -Packages $after | Out-Null
    return $true
}

function script:Test-LooksLikeWingetId {
    param([string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) { return $false }
    return ($Query -match '^[A-Za-z0-9][A-Za-z0-9+_.-]*\.[A-Za-z0-9][A-Za-z0-9+_.-]*$')
}

function script:Search-WingetPackages {
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$MaxResults = 15
    )
    $q = $Query.Trim()
    $results = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($q)) { return $results }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = ''
    try {
        $output = & winget search $q --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    }
    catch {
        throw "winget search echoue : $_"
    }
    finally {
        $ErrorActionPreference = $prev
    }

    if ($output -match '(?i)No package found|Aucun package') {
        return $results
    }

    $seen = @{}

    foreach ($line in ($output -split "`r?`n")) {
        $trim = $line.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($trim)) { continue }
        if ($trim -match '^-{5,}') { continue }
        if ($trim -match '(?i)^Name\s+Id\s+') { continue }
        if ($trim -match '(?i)^The `?source`?') { continue }
        if ($trim -match '(?i)^Failed when searching') { continue }
        if ($trim -match '(?i)^No package') { continue }

        if ($trim -notmatch '([A-Za-z0-9][A-Za-z0-9+_.-]*\.[A-Za-z0-9][A-Za-z0-9+_.-]*)') { continue }
        $pkgId = $Matches[1]

        if ($pkgId -match '\.(exe|msi|msix|zip|json|png|dll)$') { continue }

        $before = $trim.Substring(0, $trim.IndexOf($pkgId)).Trim()
        $pkgName = if ($before) { ($before -replace '\s{2,}', ' ').Trim() } else { $pkgId }
        if ([string]::IsNullOrWhiteSpace($pkgName)) { $pkgName = $pkgId }

        $after = ''
        $idx = $trim.IndexOf($pkgId) + $pkgId.Length
        if ($idx -lt $trim.Length) { $after = $trim.Substring($idx).Trim() }
        $version = ''
        if ($after -match '^(\S+)') { $version = $Matches[1] }

        $key = $pkgId.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        [void]$results.Add([pscustomobject]@{
            Name    = $pkgName
            Id      = $pkgId
            Version = $version
            Display = if ($version) { "$pkgName  ($pkgId)  $version" } else { "$pkgName  ($pkgId)" }
        })

        if ($results.Count -ge $MaxResults) { break }
    }

    if (Test-LooksLikeWingetId -Query $q) {
        $reordered = [System.Collections.Generic.List[object]]::new()
        $exact = @($results | Where-Object { $_.Id -ieq $q })
        $rest = @($results | Where-Object { $_.Id -ine $q })
        if ($exact.Count -eq 0) {
            [void]$reordered.Add([pscustomobject]@{
                Name    = $q
                Id      = $q
                Version = ''
                Display = "$q  (ID exact)"
            })
        }
        else {
            foreach ($r in $exact) { [void]$reordered.Add($r) }
        }
        foreach ($r in $rest) {
            if ($reordered.Count -ge $MaxResults) { break }
            [void]$reordered.Add($r)
        }
        return $reordered
    }

    return $results
}
