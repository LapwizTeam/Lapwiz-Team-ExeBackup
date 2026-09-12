# SynapticRemover i18n loader (FR / EN / AR) - reads messages.json (UTF-8 BOM)

param(

    [ValidateSet('fr', 'en', 'ar')]

    [string]$Lang = 'fr'

)

$script:Lang = $Lang

$jsonPath = Join-Path $PSScriptRoot 'messages.json'

if (-not (Test-Path -LiteralPath $jsonPath)) {

    throw "messages.json missing: $jsonPath"

}

# Lecture UTF-8 explicite (avec ou sans BOM)

$raw = [System.IO.File]::ReadAllText($jsonPath, (New-Object System.Text.UTF8Encoding $true))

$script:Messages = $raw | ConvertFrom-Json

function Get-Msg {

    param(

        [Parameter(Mandatory)][string]$Key,

        [object[]]$FormatArgs = @()

    )

    $langObj = $script:Messages.$($script:Lang)

    if (-not $langObj -or -not ($langObj.PSObject.Properties.Name -contains $Key)) {

        $langObj = $script:Messages.en

    }

    $text = [string]$langObj.$Key

    # Marque RTL pour un meilleur affichage arabe dans la console

    if ($script:Lang -eq 'ar' -and $text -and ($text -match '[\u0600-\u06FF]')) {

        $text = ([char]0x200F).ToString() + $text

    }

    if ($FormatArgs.Count -gt 0) {

        return ($text -f $FormatArgs)

    }

    return $text

}

function Set-UiEncoding {

    try { chcp 65001 | Out-Null } catch {}

    try {

        $enc = New-Object System.Text.UTF8Encoding $false

        [Console]::OutputEncoding = $enc

        [Console]::InputEncoding = $enc

        $global:OutputEncoding = $enc

        try { $PSDefaultParameterValues['*:Encoding'] = 'utf8' } catch {}

    } catch {}

    # Active le traitement VT (Unicode / couleurs modernes)

    try {

        $sig = @'

[DllImport("kernel32.dll", SetLastError=true)]

public static extern bool SetConsoleMode(IntPtr hConsoleHandle, int mode);

[DllImport("kernel32.dll", SetLastError=true)]

public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out int mode);

[DllImport("kernel32.dll", SetLastError=true)]

public static extern IntPtr GetStdHandle(int nStdHandle);

'@

        $type = Add-Type -MemberDefinition $sig -Name ConsoleVtMode -Namespace Win32Sr -PassThru -ErrorAction SilentlyContinue

        if ($type) {

            $hwnd = $type::GetStdHandle(-11)

            $mode = 0

            if ($type::GetConsoleMode($hwnd, [ref]$mode)) {

                [void]$type::SetConsoleMode($hwnd, ($mode -bor 0x0004))

            }

        }

    } catch {}

}

function Write-UiText {

    param(

        [string]$Text,

        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray,

        [switch]$NoNewline

    )

    $old = [Console]::ForegroundColor

    try {

        [Console]::ForegroundColor = $ForegroundColor

        if ($NoNewline) {

            [Console]::Write($Text)

        } else {

            [Console]::WriteLine($Text)

        }

    } finally {

        [Console]::ForegroundColor = $old

    }

}

