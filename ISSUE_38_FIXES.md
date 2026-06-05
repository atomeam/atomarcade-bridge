# Issue #38 Fixes - Heartbeat Staleness & Bridge Monitoring

## Summary
Fixed the heartbeat staleness issue that caused the bridge to stop writing to Notion databases since 2026-05-12 11:10Z. Implemented comprehensive monitoring, alerting, and auto-restart mechanisms.

## Root Cause Analysis
The bridge process stopped writing heartbeat data because there was **no scheduled heartbeat mechanism**. The script only wrote to the Automations DB when processing commands from the Command Bus, so if no commands were queued, no heartbeat rows were written.

## Fixes Implemented

### 1. ✅ Heartbeat Mechanism (FIXED)
**File:** `homebase.ps1`

**Changes:**
- Added `$HEARTBEAT_SECONDS = 300` (5-minute heartbeat interval)
- Added `Write-Heartbeat()` function that writes heartbeat rows to Automations DB
- Added heartbeat scheduling in main loop: checks every HEARTBEAT_SECONDS
- Added heartbeat tracking: `$script:LastHeartbeat` and `$script:Metrics.heartbeat_writes_total`
- Updated version from `v0.6.3-log-db-fallback` to `v0.6.8.6-heartbeat-monitor`

**Heartbeat Data Written:**
- Name: "Heartbeat - {hostname}"
- Kind: "heartbeat"
- Command: "SYSTEM_HEARTBEAT"
- Interval: 300 seconds
- Last Run: current timestamp
- Run Count: incrementing counter
- Last Result: uptime, memory, CPU stats

### 2. ✅ Monitoring/Alerting (FIXED)
**Files:** `homebase.ps1`, `heartbeat-monitor.ps1`

**Changes:**
- Added `/api/heartbeat/status` endpoint that returns:
  - Last heartbeat timestamp
  - Gap in seconds
  - Is stale flag (gap > 30 minutes)
  - Total heartbeats written
- Added "Heartbeat Monitor" card to dashboard showing:
  - Last heartbeat time
  - Current gap
  - Status (healthy/stale)
  - Total heartbeats
- Created `heartbeat-monitor.ps1` script that:
  - Checks bridge heartbeat status every 10 minutes
  - Sends alerts to Notion Logs DB if gap > 30 minutes
  - Logs all checks to `heartbeat-monitor.log`

**Alert Threshold:** 30 minutes (configurable via `$ALERT_THRESHOLD_MINUTES`)

### 3. ✅ Logs DB Fallback (ALREADY FIXED)
**File:** `homebase.ps1` (lines 23-28)

**Status:** Already implemented in v0.6.3
- Hardcoded fallback: `$NOTION_LOG_DB_ID_FALLBACK = '4ee3980e62fa4abea716c7d6656011ba'`
- Env var takes precedence when present
- Prevents silent logging failures

### 4. ✅ Watchdog/Auto-Restart (FIXED)
**File:** `setup-taskscheduler.ps1`

**Changes:**
- Created Task Scheduler setup script that configures:
  - **Heartbeat Monitor Task:** Runs every 10 minutes
  - **Bridge Auto-Restart Task:** Runs at startup, restarts on failure (3 retries, 5-minute intervals)
- Both tasks configured to run whether user is logged on or not
- Tasks run with highest privileges
- No idle stop, battery-friendly

**Usage:**
```powershell
# Run as Administrator
pwsh -File setup-taskscheduler.ps1
```

### 5. ✅ Version Reporting (FIXED)
**File:** `homebase.ps1` (line 16)

**Changes:**
- Updated `$VERSION` from `v0.6.3-log-db-fallback` to `v0.6.8.6-heartbeat-monitor`
- Dashboard now reports correct version

## Deployment Instructions

### Step 1: Update Bridge Script
```powershell
# The homebase.ps1 file has been updated with all fixes
# No manual changes needed
```

### Step 2: Deploy Monitoring Scripts
```powershell
# Files are already in place:
# - heartbeat-monitor.ps1
# - setup-taskscheduler.ps1
```

### Step 3: Set Environment Variables (CRITICAL for S4U Tasks)
```powershell
# Set as SYSTEM environment variables (Machine scope) - REQUIRED for S4U tasks
# Run as Administrator
[System.Environment]::SetEnvironmentVariable('ATOMARCADE_NOTION_TOKEN', 'your-token', 'Machine')
[System.Environment]::SetEnvironmentVariable('ATOMARCADE_NOTION_DB_ID', 'your-db-id', 'Machine')
[System.Environment]::SetEnvironmentVariable('ATOMARCADE_NOTION_AUTO_DB_ID', 'your-auto-db-id', 'Machine')
# Optional: ATOMARCADE_NOTION_LOG_DB_ID (has fallback if not set)
```

### Step 4: Setup Task Scheduler (Run as Administrator)
```powershell
cd C:\Users\adamm\atomarcade-bridge
pwsh -File setup-taskscheduler.ps1
```

### Step 5: Restart Bridge
```powershell
# Stop existing bridge (Ctrl+C in current session)
# Start new bridge:
pwsh -File homebase.ps1
```

### Step 6: Verify Heartbeat
```powershell
# Check heartbeat status via API:
Invoke-RestMethod -Uri 'http://localhost:8080/api/heartbeat/status'

# Or check dashboard:
# Open http://localhost:8080/
# Look for "Heartbeat Monitor" card
```

### Step 7: Test Monitoring
```powershell
# Manually trigger heartbeat monitor:
Start-ScheduledTask -TaskName 'AtomArcade-HeartbeatMonitor'

# Check monitor log:
Get-Content heartbeat-monitor.log
```

## Smoke Test Checklist (Production Readiness)

### 1) Verify Heartbeat Writes
```powershell
# Wait 5-10 minutes after bridge start
# Check Automations DB for "Heartbeat - {hostname}" rows
# Verify rows appear every ~5 minutes with uptime/memory/CPU stats
```

### 2) Test Monitor Alerting
```powershell
# Temporarily stop bridge (Ctrl+C)
# Wait >30 minutes (or edit heartbeat-monitor.ps1: $ALERT_THRESHOLD_MINUTES = 1)
# Verify monitor detects staleness via /api/heartbeat/status
# Check Logs DB for alert record with "HEARTBEAT ALERT" event
```

### 3) Test Watchdog Restart
```powershell
# Kill bridge process (Get-Process pwsh | Stop-Process -Force)
# Verify Task Scheduler restarts bridge within 5 minutes
# Check homebase-transcript-*.log for restart evidence
# Verify bridge doesn't require interactive login
```

### 4) Task Configuration Verification
```powershell
# Check both tasks' "Last Run Result" after:
# 1) Normal run: should be "0 (0x0)"
# 2) Forced failure: should restart bridge
# 3) Reboot test: should start automatically at boot

# Verify task settings:
# - Start in: C:\Users\adamm\atomarcade-bridge
# - Run whether user is logged on or not: Yes
# - Run with highest privileges: Yes
# - Stop if runs longer than: Disabled (bridge task)
# - Multiple instances: StopExisting (both tasks)
```

## Verification Checklist

- [ ] Bridge starts successfully with new version `v0.6.8.6-heartbeat-monitor`
- [ ] Heartbeat rows appear in Automations DB every 5 minutes
- [ ] Dashboard shows "Heartbeat Monitor" card with healthy status
- [ ] `/api/heartbeat/status` returns correct heartbeat data
- [ ] Task Scheduler tasks are created and enabled
- [ ] Heartbeat monitor runs every 10 minutes
- [ ] Bridge auto-restarts on failure
- [ ] Alerts are sent to Notion Logs DB when heartbeat is stale

## Monitoring & Troubleshooting

### Check Heartbeat Status
```powershell
# Via API
Invoke-RestMethod -Uri 'http://localhost:8080/api/heartbeat/status' | ConvertTo-Json

# Via Dashboard
# Open http://localhost:8080/ and check "Heartbeat Monitor" card
```

### Check Monitor Logs
```powershell
# Heartbeat monitor log (script-level)
Get-Content C:\Users\adamm\atomarcade-bridge\heartbeat-monitor.log -Tail 20

# Heartbeat monitor task logs (timestamped per run)
Get-ChildItem C:\Users\adamm\atomarcade-bridge\heartbeat-monitor-task-*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -Tail 20

# Bridge log (legacy)
Get-Content C:\Users\adamm\atomarcade-bridge\homebase.log -Tail 20

# Bridge transcript logs (Start-Transcript - preferred for Task Scheduler)
Get-ChildItem C:\Users\adamm\atomarcade-bridge\homebase-transcript-*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -Tail 20

# Bridge JSONL log (structured events)
Get-Content C:\Users\adamm\atomarcade-bridge\homebase-logs.jsonl -Tail 10
```

### Check Task Scheduler
```powershell
# List tasks
Get-ScheduledTask | Where-Object { $_.TaskName -like '*AtomArcade*' }

# Check task status
Get-ScheduledTaskInfo -TaskName 'AtomArcade-HeartbeatMonitor'
Get-ScheduledTaskInfo -TaskName 'AtomArcade-Bridge'

# View task history
Get-ScheduledTask -TaskName 'AtomArcade-HeartbeatMonitor' | Export-ScheduledTask
```

### Manual Restart
```powershell
# Restart heartbeat monitor
Stop-ScheduledTask -TaskName 'AtomArcade-HeartbeatMonitor'
Start-ScheduledTask -TaskName 'AtomArcade-HeartbeatMonitor'

# Restart bridge
Stop-ScheduledTask -TaskName 'AtomArcade-Bridge'
Start-ScheduledTask -TaskName 'AtomArcade-Bridge'
```

## Failure Mode Handling

### Sleep/Hibernate Scenarios
**Symptom:** Bridge stops writing heartbeats after laptop sleep/hibernate
**Detection:** Heartbeat gap > 30 minutes triggers alert
**Recovery:** Task Scheduler auto-restarts bridge on next wake (if configured with AtStartup trigger)
**Mitigation:** Task Scheduler tasks use S4U logon type (runs whether user logged on or not)

### Missing Environment Variables (S4U Critical)
**Symptom:** Bridge fails to start or heartbeat writes fail when running as S4U task
**Detection:** Check homebase-transcript-*.log for "ENV DIAGNOSTICS" showing MISSING vars
**Root Cause:** S4U tasks only see Machine-scope env vars, not User-scope
**Recovery:** Set required env vars as SYSTEM (Machine scope):
```powershell
# CRITICAL: Must use Machine scope for S4U tasks
# Run as Administrator
[System.Environment]::SetEnvironmentVariable('ATOMARCADE_NOTION_TOKEN', 'your-token', 'Machine')
[System.Environment]::SetEnvironmentVariable('ATOMARCADE_NOTION_DB_ID', 'your-db-id', 'Machine')
[System.Environment]::SetEnvironmentVariable('ATOMARCADE_NOTION_AUTO_DB_ID', 'your-auto-db-id', 'Machine')
# Optional: ATOMARCADE_NOTION_LOG_DB_ID (has fallback if not set)
```
**Verification:** Bridge logs env var diagnostics at startup showing "PRESENT (length: XX)"

### Notion API Errors
**Symptom:** Heartbeat writes fail, alerts still fire
**Detection:** Check heartbeat-monitor-task.log for Notion API errors
**Recovery:** Script fails gracefully, continues monitoring, retries on next run
**Mitigation:** Logs DB fallback prevents silent failures (v0.6.3 feature)

### Task Permission Issues
**Symptom:** Tasks fail to start or run with insufficient privileges
**Detection:** Check Task Scheduler history for "0x1" or "0x41301" error codes
**Recovery:** Re-run setup-taskscheduler.ps1 as Administrator
**Mitigation:** Tasks configured with RunLevel Highest and S4U logon type

### PowerShell Not Found
**Symptom:** Tasks fail with "pwsh.exe not found"
**Detection:** Check setup-taskscheduler.log for path resolution errors
**Recovery:** Install PowerShell 7+ or update $pwshPath in setup script
**Mitigation:** Setup script now validates pwsh.exe path before creating tasks

## Rollback Procedure

### If Heartbeat Causes Issues
```powershell
# 1. Stop monitoring
Stop-ScheduledTask -TaskName 'AtomArcade-HeartbeatMonitor'

# 2. Revert to previous version
cd C:\Users\adamm\atomarcade-bridge
git log --oneline
git checkout <previous-commit-hash>

# 3. Restart bridge manually
pwsh -File homebase.ps1
```

### If Task Scheduler Tasks Fail
```powershell
# 1. Remove tasks
Unregister-ScheduledTask -TaskName 'AtomArcade-HeartbeatMonitor' -Confirm:$false
Unregister-ScheduledTask -TaskName 'AtomArcade-Bridge' -Confirm:$false

# 2. Run bridge manually
cd C:\Users\adamm\atomarcade-bridge
pwsh -File homebase.ps1
```

### If Monitoring Causes False Alerts
```powershell
# 1. Adjust alert threshold in heartbeat-monitor.ps1
# Edit $ALERT_THRESHOLD_MINUTES = 30 to desired value

# 2. Restart monitor
Stop-ScheduledTask -TaskName 'AtomArcade-HeartbeatMonitor'
Start-ScheduledTask -TaskName 'AtomArcade-HeartbeatMonitor'
```

### Complete Rollback to Pre-Fix State
```powershell
# 1. Remove Task Scheduler tasks
Unregister-ScheduledTask -TaskName 'AtomArcade-HeartbeatMonitor' -Confirm:$false
Unregister-ScheduledTask -TaskName 'AtomArcade-Bridge' -Confirm:$false

# 2. Revert code changes
cd C:\Users\adamm\atomarcade-bridge
git log --oneline
git checkout <commit-before-fixes>

# 3. Remove new files
Remove-Item heartbeat-monitor.ps1
Remove-Item setup-taskscheduler.ps1
Remove-Item ISSUE_38_FIXES.md

# 4. Restart bridge manually
pwsh -File homebase.ps1
```

## Production-Ready Logging Strategy

### Logging Architecture (v0.6.8.6)

**Heartbeat Monitor (Short-Lived, Frequent Runs)**
- Uses timestamped log files per run: `heartbeat-monitor-task-YYYYMMDD-HHMMSS.log`
- Prevents file lock issues with frequent runs
- Shell redirection: `*> "$heartbeatLog"` captures stdout/stderr
- Script-level logging: `heartbeat-monitor.log` (append mode)

**Bridge (Long-Lived, Continuous)**
- Uses PowerShell `Start-Transcript` for comprehensive logging
- Timestamped transcript files: `homebase-transcript-YYYYMMDD-HHMMSS.log`
- No shell redirection (prevents file handle issues with long-running process)
- Internal logging: `homebase.log` (legacy), `homebase-logs.jsonl` (structured events)
- Environment variable diagnostics logged at startup for S4U troubleshooting

**Why This Strategy Works:**
- Timestamped logs prevent file lock contention
- Start-Transcript handles long-running processes gracefully
- Multiple log layers provide redundancy and debugging depth
- S4U env var diagnostics catch configuration issues early

### Task Configuration Details

**Both Tasks Share These Settings:**
- **Start in (Working Directory):** `C:\Users\adamm\atomarcade-bridge`
- **Run whether user is logged on or not:** Yes (S4U logon type)
- **Run with highest privileges:** Yes (required for port binding)
- **Multiple Instances:** StopExisting (prevents duplicate processes)

**Heartbeat Monitor Specific:**
- **Trigger:** Every 10 minutes (repeating)
- **Execution Time Limit:** Default (3 days)
- **Stop if runs longer than:** Enabled (default)
- **Restart on failure:** Not configured (monitor is disposable)

**Bridge Specific:**
- **Trigger:** At system startup
- **Execution Time Limit:** 365 days (effectively unlimited)
- **Stop if runs longer than:** Disabled (long-running process)
- **Restart on failure:** 3 retries, 5-minute intervals
- **Restart on idle:** Enabled

## Acceptance Criteria Met

✅ **Root cause identified:** No scheduled heartbeat mechanism existed
✅ **Heartbeat mechanism added:** Writes to Automations DB every 5 minutes
✅ **Monitoring added:** 30+ minute gap detection via `/api/heartbeat/status`
✅ **Alerting added:** Notion Logs DB alerts when heartbeat is stale
✅ **Watchdog added:** Task Scheduler with auto-restart on failure
✅ **Version fixed:** Updated to `v0.6.8.6-heartbeat-monitor`
✅ **Logs DB fallback:** Already implemented in v0.6.3

## Future Improvements

1. **NSSM Service:** Consider migrating to NSSM for more robust service management
2. **External Monitoring:** Add external monitoring (e.g., UptimeRobot, Pingdom)
3. **Health Check Endpoint:** Add comprehensive health check for external monitoring
4. **Graceful Shutdown:** Implement graceful shutdown on system power events
5. **Configuration File:** Move hardcoded values to external config file

## Files Modified

- `homebase.ps1` - Main bridge script (heartbeat mechanism, monitoring, version fix)
- `heartbeat-monitor.ps1` - New monitoring script
- `setup-taskscheduler.ps1` - New Task Scheduler setup script
- `ISSUE_38_FIXES.md` - This documentation file

## Related Issues

- Issue #38: Heartbeat staleness (this fix)
- PR #37: Logs DB fallback (already implemented)
- Issue #10: NSSM service install (future work)

## Version History

- v0.6.3-log-db-fallback: Logs DB fallback implemented
- v0.6.8.6-heartbeat-monitor: Heartbeat mechanism, monitoring, alerting, auto-restart
