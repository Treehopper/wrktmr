<#
wrktmr - a lightweight system-tray time tracker for staying within a
39h/week work limit. Runs as the logged-in user, no admin rights required.

- Auto-pauses when the workstation is locked, auto-resumes on unlock.
- Manual Pause/Resume from the tray menu (e.g. for lunch) independent of lock state.
- Persists state to disk every tick so a restart (e.g. via the Startup
  folder at logon) picks up where the week left off.
- Notifies at 90% and 100% of the weekly limit, then once per additional
  overtime hour.
- Writes a human-readable status.txt and a per-day history.csv.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Single instance guard ---
$mutexName = "Local\WrkTmr-SingleInstance"
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show(
        "wrktmr is already running (check the system tray).", "wrktmr") | Out-Null
    exit
}

# --- Paths ---
$dataDir    = Join-Path $env:LOCALAPPDATA "wrktmr"
$stateFile  = Join-Path $dataDir "state.json"
$statusFile = Join-Path $dataDir "status.txt"
$historyCsv = Join-Path $dataDir "history.csv"
$errorLog   = Join-Path $dataDir "error.log"
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
if (-not (Test-Path $historyCsv)) {
    "Date,Hours" | Out-File -FilePath $historyCsv -Encoding utf8
}

# --- Config ---
$WeeklyLimitHours   = 39
$WeeklyLimitSeconds = $WeeklyLimitHours * 3600
$TickIntervalMs     = 15000

function Get-WeekStart([datetime]$date) {
    # Monday-based week start.
    $offset = ([int]$date.DayOfWeek + 6) % 7
    return $date.Date.AddDays(-$offset)
}

# --- Persisted state ---
$script:state = [ordered]@{
    weekStart          = (Get-WeekStart (Get-Date)).ToString("yyyy-MM-dd")
    weeklySeconds      = 0
    today              = (Get-Date).ToString("yyyy-MM-dd")
    todaySeconds       = 0
    manualPause        = $false
    notified90         = $false
    notified100        = $false
    notifiedOvertimeHr = 0
}

function Load-State {
    if (Test-Path $stateFile) {
        try {
            $loaded = Get-Content $stateFile -Raw | ConvertFrom-Json
            foreach ($key in @($script:state.Keys)) {
                if ($null -ne $loaded.$key) { $script:state[$key] = $loaded.$key }
            }
        } catch {
            # Corrupt or unreadable state file - keep defaults.
        }
    }
}

function Save-State {
    try {
        ($script:state | ConvertTo-Json) | Out-File -FilePath $stateFile -Encoding utf8
    } catch {
        "$(Get-Date -Format o) Save-State failed: $_" | Out-File -FilePath $errorLog -Append -Encoding utf8
    }
}

function Roll-DayAndWeek {
    $today     = (Get-Date).ToString("yyyy-MM-dd")
    $weekStart = (Get-WeekStart (Get-Date)).ToString("yyyy-MM-dd")

    if ($script:state.today -ne $today) {
        $hours = [math]::Round($script:state.todaySeconds / 3600, 2)
        "$($script:state.today),$hours" | Out-File -FilePath $historyCsv -Append -Encoding utf8
        $script:state.today = $today
        $script:state.todaySeconds = 0
    }

    if ($script:state.weekStart -ne $weekStart) {
        $script:state.weekStart = $weekStart
        $script:state.weeklySeconds = 0
        $script:state.notified90 = $false
        $script:state.notified100 = $false
        $script:state.notifiedOvertimeHr = 0
    }
}

# --- Runtime-only flag, not persisted (set from the SystemEvents thread) ---
$script:isLocked = $false

function Test-IsTracking {
    return (-not $script:state.manualPause) -and (-not $script:isLocked)
}

Load-State
Roll-DayAndWeek

# --- Tray icon ---
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
$notifyIcon.Visible = $true
$notifyIcon.Text = "wrktmr"

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$pauseItem  = $menu.Items.Add("Pause")
$statusItem = $menu.Items.Add("Show status")
$menu.Items.Add("-") | Out-Null
$exitItem   = $menu.Items.Add("Exit")
$notifyIcon.ContextMenuStrip = $menu

function Update-TrayText {
    $weekHours  = [math]::Round($script:state.weeklySeconds / 3600, 2)
    $todayHours = [math]::Round($script:state.todaySeconds / 3600, 2)
    $pct  = [math]::Round(($script:state.weeklySeconds / $WeeklyLimitSeconds) * 100)
    $mode = if ($script:isLocked) { "locked" } elseif ($script:state.manualPause) { "paused" } else { "tracking" }
    $text = "wrktmr: {0}h today / {1}h wk ({2}%) [{3}]" -f $todayHours, $weekHours, $pct, $mode
    if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + "..." }
    $notifyIcon.Text = $text
    $pauseItem.Text = if ($script:state.manualPause) { "Resume" } else { "Pause" }
}

function Write-StatusFile {
    $weekHours  = [math]::Round($script:state.weeklySeconds / 3600, 2)
    $todayHours = [math]::Round($script:state.todaySeconds / 3600, 2)
    $remaining  = [math]::Round($WeeklyLimitHours - $weekHours, 2)
    $mode = if ($script:isLocked) { "Locked" } elseif ($script:state.manualPause) { "Paused (manual)" } else { "Tracking" }
    @"
wrktmr status - $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Status: $mode
Today: $todayHours h
This week (since $($script:state.weekStart)): $weekHours h / $WeeklyLimitHours h
Remaining this week: $remaining h
"@ | Out-File -FilePath $statusFile -Encoding utf8
}

function Show-Balloon($title, $text, $icon = [System.Windows.Forms.ToolTipIcon]::Info) {
    $notifyIcon.BalloonTipTitle = $title
    $notifyIcon.BalloonTipText  = $text
    $notifyIcon.BalloonTipIcon  = $icon
    $notifyIcon.ShowBalloonTip(8000)
}

$pauseItem.add_Click({
    $script:state.manualPause = -not $script:state.manualPause
    Save-State
    Update-TrayText
    if ($script:state.manualPause) {
        Show-Balloon "wrktmr" "Tracking paused manually."
    } else {
        Show-Balloon "wrktmr" "Tracking resumed."
    }
})

$statusItem.add_Click({
    Write-StatusFile
    Start-Process notepad.exe $statusFile
})

$exitItem.add_Click({
    Save-State
    $notifyIcon.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

# --- Session lock/unlock/logoff handling ---
# IMPORTANT: SystemEvents raises these on its own background thread, not the
# UI thread. Only touch plain script-scope flags and do file I/O here - never
# touch $notifyIcon (or any WinForms UI object) from these handlers. The
# 15s timer tick (which runs on the UI thread) picks up the flag change.
$sessionHandler = [Microsoft.Win32.SessionSwitchEventHandler]{
    param($sender, $e)
    switch ($e.Reason) {
        ([Microsoft.Win32.SessionSwitchReason]::SessionLock)   { $script:isLocked = $true }
        ([Microsoft.Win32.SessionSwitchReason]::SessionUnlock) { $script:isLocked = $false }
        ([Microsoft.Win32.SessionSwitchReason]::SessionLogoff) { Save-State }
        default { }
    }
}
[Microsoft.Win32.SystemEvents]::add_SessionSwitch($sessionHandler)

$endingHandler = [Microsoft.Win32.SessionEndingEventHandler]{
    param($sender, $e)
    Save-State
}
[Microsoft.Win32.SystemEvents]::add_SessionEnding($endingHandler)

# --- Main tick (runs on the UI thread) ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $TickIntervalMs
$timer.add_Tick({
    try {
        Roll-DayAndWeek

        if (Test-IsTracking) {
            $elapsed = $TickIntervalMs / 1000
            $script:state.todaySeconds  += $elapsed
            $script:state.weeklySeconds += $elapsed
        }

        $pctFraction = $script:state.weeklySeconds / $WeeklyLimitSeconds

        if (-not $script:state.notified90 -and $pctFraction -ge 0.9) {
            $script:state.notified90 = $true
            Show-Balloon "wrktmr" ("90% of your weekly {0}h limit reached." -f $WeeklyLimitHours) ([System.Windows.Forms.ToolTipIcon]::Warning)
        }
        if (-not $script:state.notified100 -and $pctFraction -ge 1.0) {
            $script:state.notified100 = $true
            Show-Balloon "wrktmr" ("Weekly limit of {0}h reached." -f $WeeklyLimitHours) ([System.Windows.Forms.ToolTipIcon]::Warning)
        }
        if ($pctFraction -ge 1.0) {
            $overHours = [math]::Floor(($script:state.weeklySeconds - $WeeklyLimitSeconds) / 3600)
            if ($overHours -gt $script:state.notifiedOvertimeHr) {
                $script:state.notifiedOvertimeHr = $overHours
                Show-Balloon "wrktmr" ("{0}h over your weekly limit." -f $overHours) ([System.Windows.Forms.ToolTipIcon]::Error)
            }
        }

        Update-TrayText
        Write-StatusFile
        Save-State
    } catch {
        "$(Get-Date -Format o) Tick failed: $_" | Out-File -FilePath $errorLog -Append -Encoding utf8
    }
})
$timer.Start()

Update-TrayText
Write-StatusFile

[System.Windows.Forms.Application]::Run()

# --- Cleanup after Application.Exit() ---
$timer.Stop()
$notifyIcon.Dispose()
$mutex.ReleaseMutex()
$mutex.Dispose()
