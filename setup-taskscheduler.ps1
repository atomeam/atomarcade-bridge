# Task Scheduler Setup for AtomArcade Bridge
# Sets up:
# 1. Heartbeat monitor (runs every 10 minutes)
# 2. Bridge auto-restart (runs at startup + restart on failure)
# Usage: pwsh -File setup-taskscheduler.ps1 (run as Administrator)

$ErrorActionPreference = 'Stop'

$scriptPath = $PSScriptRoot
$homebaseScript = Join-Path $scriptPath 'homebase.ps1'
$monitorScript = Join-Path $scriptPath 'heartbeat-monitor.ps1'
$taskNameHeartbeat = 'AtomArcade-HeartbeatMonitor'
$taskNameBridge = 'AtomArcade-Bridge'

function Write-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    "$timestamp `t $Message" | Out-File -FilePath 'setup-taskscheduler.log' -Encoding UTF8 -Append
    Write-Host $Message
}

Write-Log "Starting Task Scheduler setup..."

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Log "ERROR: This script must be run as Administrator"
    exit 1
}

# Remove existing tasks if they exist
Write-Log "Removing existing tasks (if any)..."
try {
    Unregister-ScheduledTask -TaskName $taskNameHeartbeat -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskNameBridge -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "Existing tasks removed"
} catch {
    Write-Log "No existing tasks to remove"
}

# Create Heartbeat Monitor Task
Write-Log "Creating Heartbeat Monitor task..."
$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-File `"$monitorScript`"" -WorkingDirectory $scriptPath
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 10)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $taskNameHeartbeat -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "AtomArcade Bridge Heartbeat Monitor - checks every 10 minutes for stale heartbeat" | Out-Null
Write-Log "Heartbeat Monitor task created: $taskNameHeartbeat"

# Create Bridge Auto-Restart Task
Write-Log "Creating Bridge Auto-Restart task..."
$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-File `"$homebaseScript`"" -WorkingDirectory $scriptPath
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5)

Register-ScheduledTask -TaskName $taskNameBridge -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "AtomArcade Bridge Auto-Restart - starts at boot, restarts on failure" | Out-Null
Write-Log "Bridge Auto-Restart task created: $taskNameBridge"

# Configure task to run whether user is logged on or not
Write-Log "Configuring tasks to run whether user is logged on or not..."
Set-ScheduledTask -TaskName $taskNameHeartbeat -Principal (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Highest)
Set-ScheduledTask -TaskName $taskNameBridge -Principal (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Highest)

Write-Log "Task Scheduler setup completed successfully!"
Write-Log ""
Write-Log "Tasks created:"
Write-Log "  - $taskNameHeartbeat (runs every 10 minutes)"
Write-Log "  - $taskNameBridge (runs at startup, restarts on failure)"
Write-Log ""
Write-Log "To test manually:"
Write-Log "  Start-ScheduledTask -TaskName '$taskNameHeartbeat'"
Write-Log "  Start-ScheduledTask -TaskName '$taskNameBridge'"
