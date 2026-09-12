# Choix de langue FR / EN / AR via fenetre Windows (affiche correctement l'arabe)
param(
    [string]$OutFile = $(Join-Path $env:TEMP 'synapticremover_lang.txt')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:SelectedLang = $null

$form = New-Object System.Windows.Forms.Form
$form.Text = 'SynapticRemover - Language / اللغة'
$form.Size = New-Object System.Drawing.Size(420, 320)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.TopMost = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 24)
$form.ForeColor = [System.Drawing.Color]::White

$title = New-Object System.Windows.Forms.Label
$title.Text = 'SynapticRemover'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(110, 20)
$title.ForeColor = [System.Drawing.Color]::FromArgb(80, 220, 120)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = "Choisissez la langue / Choose language / اختر اللغة"
$sub.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$sub.AutoSize = $true
$sub.Location = New-Object System.Drawing.Point(55, 60)
$sub.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 190)
$sub.RightToLeft = 'Yes'

function New-LangButton([string]$Text, [string]$Code, [int]$Y) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Tag = $Code
    $b.Size = New-Object System.Drawing.Size(300, 40)
    $b.Location = New-Object System.Drawing.Point(50, $Y)
    $b.FlatStyle = 'Flat'
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $b.BackColor = [System.Drawing.Color]::FromArgb(40, 44, 52)
    $b.ForeColor = [System.Drawing.Color]::White
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 90, 110)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Code -eq 'ar') {
        $b.RightToLeft = 'Yes'
        $b.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    }
    $b.Add_Click({
        $script:SelectedLang = [string]$this.Tag
        $this.FindForm().Close()
    })
    return $b
}

$btnFr = New-LangButton '1  -  Francais (FR)' 'fr' 100
$btnEn = New-LangButton '2  -  English (EN)' 'en' 150
$btnAr = New-LangButton '3  -  العربية (AR)' 'ar' 200

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Utilisez la souris ou Entrée après sélection'
$hint.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$hint.AutoSize = $true
$hint.Location = New-Object System.Drawing.Point(70, 255)
$hint.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 130)

$form.Controls.AddRange(@($title, $sub, $btnFr, $btnEn, $btnAr, $hint))
$form.AcceptButton = $btnFr
[void]$form.ShowDialog()

if (-not $script:SelectedLang) { $script:SelectedLang = 'fr' }

Set-Content -LiteralPath $OutFile -Value $script:SelectedLang -Encoding ASCII -NoNewline
exit 0
