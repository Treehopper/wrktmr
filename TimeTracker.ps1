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
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -Namespace WrkTmr -Name NativeMethods -MemberDefinition @"
[DllImport("user32.dll")]
public static extern bool DestroyIcon(IntPtr handle);
"@

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
$WorkDaysPerWeek    = 5
$WeeklyLimitSeconds = $WeeklyLimitHours * 3600
$DailyPlanSeconds   = $WeeklyLimitSeconds / $WorkDaysPerWeek
$BreakSeconds       = 3600
$BreakCutoffHour    = 13
$TickIntervalMs     = 15000

function Get-WeekStart([datetime]$date) {
    # Monday-based week start.
    $offset = ([int]$date.DayOfWeek + 6) % 7
    return $date.Date.AddDays(-$offset)
}

function Test-IsWorkday([datetime]$date) {
    return $date.DayOfWeek -ne [System.DayOfWeek]::Saturday -and $date.DayOfWeek -ne [System.DayOfWeek]::Sunday
}

function Count-Workdays([datetime]$from, [datetime]$toExclusive) {
    # Number of workdays in [from.Date, toExclusive.Date).
    $count = 0
    $d = $from.Date
    while ($d -lt $toExclusive.Date) {
        if (Test-IsWorkday $d) { $count++ }
        $d = $d.AddDays(1)
    }
    return $count
}

function Format-SignedHours([double]$seconds) {
    return ("{0:+0.00;-0.00;0.00}h" -f ($seconds / 3600))
}

function Get-DailyStats {
    # Deviation-based view of progress: an equal daily plan across the week's
    # workdays, with any over/under-logging on earlier days carried over onto
    # today's target (and, transitively, the rest of the week).
    $now = Get-Date
    $weekStartDate = [datetime]::ParseExact($script:state.weekStart, "yyyy-MM-dd", $null)

    $workdaysBeforeToday  = Count-Workdays $weekStartDate $now
    $todayIsWorkday       = Test-IsWorkday $now
    $workdaysThroughToday = $workdaysBeforeToday + $(if ($todayIsWorkday) { 1 } else { 0 })

    $plannedBeforeToday = $workdaysBeforeToday * $DailyPlanSeconds
    $actualBeforeToday  = $script:state.weeklySeconds - $script:state.todaySeconds
    $carryOverSeconds   = $actualBeforeToday - $plannedBeforeToday

    $todayPlanSeconds     = if ($todayIsWorkday) { $DailyPlanSeconds } else { 0 }
    $timeLeftTodaySeconds = $todayPlanSeconds - $script:state.todaySeconds - $carryOverSeconds

    $weeklyDeviationSeconds = $script:state.weeklySeconds - ($workdaysThroughToday * $DailyPlanSeconds)

    # Past the cutoff hour, the break is assumed to have already happened,
    # so it's no longer added on top of the projected end time.
    $breakSecondsRemaining = if ($now.Hour -ge $BreakCutoffHour) { 0 } else { $BreakSeconds }

    return [ordered]@{
        TodayPlanSeconds       = $todayPlanSeconds
        TimeLeftTodaySeconds   = $timeLeftTodaySeconds
        CarryOverSeconds       = $carryOverSeconds
        WeeklyDeviationSeconds = $weeklyDeviationSeconds
        ProjectedEnd           = $now.AddSeconds($timeLeftTodaySeconds + $breakSecondsRemaining)
        TodayIsWorkday         = $todayIsWorkday
        BreakIncluded          = $breakSecondsRemaining -gt 0
    }
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

function Get-TrackingMode {
    if ($script:isLocked) { return "Locked" }
    if ($script:state.manualPause) { return "Paused" }
    return "Tracking"
}

Load-State
Roll-DayAndWeek

# --- Tray icon ---
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
$notifyIcon.Visible = $true
$notifyIcon.Text = "wrktmr"

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$pauseItem    = $menu.Items.Add("Pause")
$addTimeItem  = $menu.Items.Add("Add time...")
$statusItem   = $menu.Items.Add("Show status")
$menu.Items.Add("-") | Out-Null
$exitItem   = $menu.Items.Add("Exit")
$notifyIcon.ContextMenuStrip = $menu

function New-StateIcon([string]$mode) {
    # Renders a small state icon at runtime so no external asset files are
    # needed: a colored circle with a glyph (play/pause/lock) baked in.
    $bgColor = switch ($mode) {
        "Tracking" { [System.Drawing.Color]::FromArgb(39, 174, 96) }   # green
        "Paused"   { [System.Drawing.Color]::FromArgb(230, 126, 34) }  # orange
        default    { [System.Drawing.Color]::FromArgb(127, 140, 141) } # grey (locked)
    }

    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)

        $bgBrush = New-Object System.Drawing.SolidBrush($bgColor)
        try { $g.FillEllipse($bgBrush, 0, 0, 16, 16) } finally { $bgBrush.Dispose() }

        $glyphBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        try {
            switch ($mode) {
                "Tracking" {
                    $points = @(
                        (New-Object System.Drawing.Point(5, 4)),
                        (New-Object System.Drawing.Point(5, 12)),
                        (New-Object System.Drawing.Point(12, 8))
                    )
                    $g.FillPolygon($glyphBrush, $points)
                }
                "Paused" {
                    $g.FillRectangle($glyphBrush, 5, 4, 2, 8)
                    $g.FillRectangle($glyphBrush, 9, 4, 2, 8)
                }
                default {
                    # Locked: simple padlock shape.
                    $pen = New-Object System.Drawing.Pen($glyphBrush, 1.5)
                    try { $g.DrawArc($pen, 6, 3, 4, 5, 180, 180) } finally { $pen.Dispose() }
                    $g.FillRectangle($glyphBrush, 5, 7, 6, 5)
                }
            }
        } finally { $glyphBrush.Dispose() }
    } finally { $g.Dispose() }

    $hIcon = $bmp.GetHicon()
    $bmp.Dispose()
    try {
        $srcIcon = [System.Drawing.Icon]::FromHandle($hIcon)
        try {
            return $srcIcon.Clone()
        } finally {
            $srcIcon.Dispose()
        }
    } finally {
        [WrkTmr.NativeMethods]::DestroyIcon($hIcon) | Out-Null
    }
}

# --- Runtime-only, not persisted: tracks the icon currently shown so it's
# only regenerated (and the old GDI handle released) when the mode changes.
$script:currentTrayMode = $null
$script:currentTrayIcon = $null

function Update-TrayIcon([string]$mode) {
    if ($mode -eq $script:currentTrayMode) { return }
    $newIcon = New-StateIcon $mode
    $notifyIcon.Icon = $newIcon
    if ($script:currentTrayIcon) { $script:currentTrayIcon.Dispose() }
    $script:currentTrayIcon = $newIcon
    $script:currentTrayMode = $mode
}

function Update-TrayText {
    $stats      = Get-DailyStats
    $todayHours = [math]::Round($script:state.todaySeconds / 3600, 2)
    $devStr     = Format-SignedHours $stats.WeeklyDeviationSeconds
    $endStr     = $stats.ProjectedEnd.ToString("HH:mm")
    $text = "{0}h today, dev {1}, end {2}" -f $todayHours, $devStr, $endStr
    if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + "..." }
    $notifyIcon.Text = $text
    $pauseItem.Text = if ($script:state.manualPause) { "Resume" } else { "Pause" }
    Update-TrayIcon (Get-TrackingMode)
}

function Write-StatusFile {
    $stats          = Get-DailyStats
    $weekHours      = [math]::Round($script:state.weeklySeconds / 3600, 2)
    $todayHours     = [math]::Round($script:state.todaySeconds / 3600, 2)
    $todayPlanHours = [math]::Round($stats.TodayPlanSeconds / 3600, 2)
    $leftStr        = Format-SignedHours $stats.TimeLeftTodaySeconds
    $devStr         = Format-SignedHours $stats.WeeklyDeviationSeconds
    $carryStr       = Format-SignedHours $stats.CarryOverSeconds
    $mode = switch (Get-TrackingMode) {
        "Paused" { "Paused (manual)" }
        default  { $_ }
    }
    $breakNote = if ($stats.BreakIncluded) { " (incl. 1h break)" } else { " (break already assumed taken)" }
    @"
wrktmr status - $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Status: $mode
Today: $todayHours h (plan: $todayPlanHours h)
Carry-over from previous days: $carryStr
Time left today: $leftStr
Projected end time today$($breakNote): $($stats.ProjectedEnd.ToString("HH:mm"))
Deviation from plan (this week): $devStr
This week (since $($script:state.weekStart)): $weekHours h
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

$addTimeItem.add_Click({
    $input = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Minutes to add (use a negative number to subtract):",
        "wrktmr - Add time",
        "0")
    if ([string]::IsNullOrWhiteSpace($input)) { return }

    $minutes = 0.0
    if (-not [double]::TryParse($input, [ref]$minutes)) {
        Show-Balloon "wrktmr" "Not a valid number of minutes." ([System.Windows.Forms.ToolTipIcon]::Error)
        return
    }
    if ($minutes -eq 0) { return }

    $seconds = $minutes * 60
    $script:state.todaySeconds  = [math]::Max(0, $script:state.todaySeconds + $seconds)
    $script:state.weeklySeconds = [math]::Max(0, $script:state.weeklySeconds + $seconds)

    Update-TrayText
    Write-StatusFile
    Save-State

    Show-Balloon "wrktmr" ("{0:+0.##;-0.##} minutes added." -f $minutes)
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
            $weekHoursSoFar = [math]::Round($script:state.weeklySeconds / 3600, 2)
            Show-Balloon "wrktmr" ("Nearing weekly limit: {0}h logged of {1}h budget." -f $weekHoursSoFar, $WeeklyLimitHours) ([System.Windows.Forms.ToolTipIcon]::Warning)
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
Save-State

[System.Windows.Forms.Application]::Run()

# --- Cleanup after Application.Exit() ---
$timer.Stop()
$notifyIcon.Dispose()
$mutex.ReleaseMutex()
$mutex.Dispose()
