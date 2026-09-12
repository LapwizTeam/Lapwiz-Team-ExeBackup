# Journal graphique arabe (Segoe UI) - version non bloquante
$script:ArGuiReady = $false
$script:ArGuiSuspended = $false
$script:ArForm = $null
$script:ArBox = $null
$script:ArLastUi = 0

function Start-ArabicGuiLog {
    if ($script:ArGuiReady) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch { return }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'SynapticRemover - AR'
    $form.Size = New-Object System.Drawing.Size(560, 360)
    $form.StartPosition = 'WindowsDefaultLocation'
    $form.TopMost = $false
    $form.RightToLeft = 'Yes'
    $form.RightToLeftLayout = $true
    $form.ShowInTaskbar = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 22)
    $form.ForeColor = [System.Drawing.Color]::White

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'سجل التنظيف - لا تغلق هذه النافذة أثناء الفحص'
    $lbl.Dock = 'Top'
    $lbl.Height = 32
    $lbl.TextAlign = 'MiddleCenter'
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(80, 220, 120)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ScrollBars = 'Vertical'
    $box.Dock = 'Fill'
    $box.ReadOnly = $true
    $box.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 34)
    $box.ForeColor = [System.Drawing.Color]::White
    $box.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $box.RightToLeft = 'Yes'

    $form.Controls.Add($box)
    $form.Controls.Add($lbl)

    $script:ArForm = $form
    $script:ArBox = $box
    $script:ArGuiReady = $true
    $script:ArGuiSuspended = $false

    # Show non-modal, single DoEvents
    $form.Show()
    try { [System.Windows.Forms.Application]::DoEvents() } catch {}
}

function Suspend-ArabicGui {
    $script:ArGuiSuspended = $true
    if ($script:ArGuiReady -and $script:ArBox) {
        try {
            $ts = Get-Date -Format 'HH:mm:ss'
            $script:ArBox.AppendText("[$ts] ... فحص جارٍ، يرجى الانتظار ...`r`n")
        } catch {}
    }
}

function Resume-ArabicGui {
    $script:ArGuiSuspended = $false
    try { [System.Windows.Forms.Application]::DoEvents() } catch {}
}

function Write-ArabicGui([string]$Message) {
    if (-not $script:ArGuiReady) { return }
    if ($script:ArGuiSuspended) { return }
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    try {
        $ts = Get-Date -Format 'HH:mm:ss'
        $script:ArBox.AppendText("[$ts] $Message`r`n")
        # Throttle UI refresh (evite freeze)
        $now = [Environment]::TickCount64
        if (($now - $script:ArLastUi) -gt 800) {
            $script:ArBox.SelectionStart = $script:ArBox.Text.Length
            $script:ArBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
            $script:ArLastUi = $now
        }
    } catch {}
}

function Close-ArabicGuiLog {
    $script:ArGuiSuspended = $true
    if ($script:ArForm) {
        try {
            $script:ArForm.Close()
            $script:ArForm.Dispose()
        } catch {}
    }
    $script:ArForm = $null
    $script:ArBox = $null
    $script:ArGuiReady = $false
}
