# wrktmr

A tiny Windows system-tray time tracker that helps you stay within a 39h/week
work limit. Pure PowerShell, no admin rights required.

## How it tracks time

- Tracking is **on** whenever your Windows session is unlocked and you
  haven't manually paused it.
- **Auto-pauses** when you lock your screen (`Win+L` / idle lock), **auto-resumes**
  on unlock.
- **Manual pause/resume** from the tray icon's right-click menu, e.g. for a
  lunch break while still logged in - this stays paused across lock/unlock
  until you resume it yourself.
- **Manual time entry** via "Add time..." in the tray icon's right-click
  menu - useful for time worked offline. Enter a number of minutes to add
  (a negative number subtracts) to both today's and this week's totals.
- **Stops** naturally at logout/shutdown (Windows kills the process); state is
  saved continuously (every 15s) and on logoff, so nothing is lost.
- **Starts** automatically at your next login if you've installed the startup
  shortcut (see below).
- The week resets **Monday 00:00**.

## Deviations, not percentages

Instead of a weekly percentage, wrktmr works off an equal daily plan
(the weekly limit split evenly across your workdays, Monday-Friday) and
shows how far off that plan you are:

- **Time left today** - what's left to log today to hit plan, adjusted by
  carry-over from earlier days this week (log too little on Monday and
  Tuesday's target grows; log too much and it shrinks).
- **Deviation** - your running total ahead of or behind plan for the week
  so far.
- **Projected end time** - today's likely finish time, based on the time
  still left to log plus a 1-hour break. Once it's past the break cutoff
  (1pm by default), the break is assumed to have already happened and is
  no longer added.

The tray icon's tooltip always shows today's hours, time left, and
deviation. Right-click > "Show status" opens a live status file with the
full detail, including the projected end time.

## Notifications

- A toast/balloon when nearing (90%) and at (100%) the 39h weekly limit,
  then one more for each additional hour of overtime.

## Files

All data lives under `%LOCALAPPDATA%\wrktmr\`:

- `state.json` - internal state (used to resume correctly after a restart)
- `status.txt` - human-readable current status
- `history.csv` - one row per day with hours worked
- `error.log` - only appears if something goes wrong

## Setup

1. Copy this folder anywhere on your Windows machine.
2. Run `TimeTracker.ps1` once to try it out:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\TimeTracker.ps1
   ```
   Look for the icon in the system tray (you may need to expand hidden
   icons).
3. To have it start automatically at login, run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-Startup.ps1
   ```
   This adds a shortcut to your per-user Startup folder - no admin rights
   needed, and nothing outside your own profile is touched.

To remove the auto-start shortcut later, run `Uninstall-Startup.ps1`.

## Changing the weekly limit

Edit `$WeeklyLimitHours = 39` near the top of `TimeTracker.ps1`. The daily
plan is this limit split across `$WorkDaysPerWeek` (default 5); the
assumed break used for the projected end time is `$BreakSeconds` (default
1 hour), added only until `$BreakCutoffHour` (default 13, i.e. 1pm) - all
are configurable in the same place.
