# HomebaseButton.ps1 - button-only Homebase app. Click does nothing.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Homebase'
$form.Size            = New-Object System.Drawing.Size(320, 200)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.BackColor       = [System.Drawing.Color]::FromArgb(245, 245, 250)

$button = New-Object System.Windows.Forms.Button
$button.Text      = 'Homebase'
$button.Size      = New-Object System.Drawing.Size(180, 70)
$button.Location  = New-Object System.Drawing.Point(70, 55)
$button.Font      = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$button.FlatStyle = 'Flat'
$button.BackColor = [System.Drawing.Color]::FromArgb(70, 100, 180)
$button.ForeColor = [System.Drawing.Color]::White
$button.FlatAppearance.BorderSize = 0
$button.Add_Click({ })  # does nothing

$form.Controls.Add($button)
[void]$form.ShowDialog()
