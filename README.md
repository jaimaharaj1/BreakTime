# BreakTime — Smart Break Reminder for Windows

A lightweight, intelligent desktop app that tracks continuous sitting time and reminds you to take breaks. Built entirely in PowerShell + WPF, it runs from the system tray with zero external dependencies.

---

## Why This Exists

Sitting for long stretches is bad for you — but traditional break reminders are dumb. They interrupt you mid-meeting, they can't tell if you just walked to the kitchen, and they don't know you're watching a training video (still sitting!). BreakTime fixes all of that.

### The Core Insight

"Sitting time" isn't just "time since last keyboard press." It includes:

- **Watching videos/media** — audio is playing but you haven't touched the keyboard. You're still sitting.
- **In a meeting** — mic or camera is active. Don't interrupt.
- **Actually idle** — no input AND no audio means you walked away. That's a break.

---

## Features

| Feature | How It Works |
|---------|-------------|
| **Floating Countdown Widget** | Always-on-top mini window with centered, high-contrast MM:SS countdown. Prominent clock icon, bold border, dark translucent background. Draggable, color-coded per state. Shows "On Break!" with ☕ icon in green during active breaks. |
| **Input Monitoring** | Win32 `GetLastInputInfo` via P/Invoke — tracks seconds since last keyboard/mouse input |
| **Media Detection** | WASAPI COM `IAudioMeterInformation` peak meter — detects active audio playback with a 30-second grace window to prevent false resets during quiet moments in videos |
| **Meeting Detection** | Windows registry check (`CapabilityAccessManager\ConsentStore`) for active mic/camera usage + process scan for Teams, Zoom, Webex, Slack |
| **Natural Break Detection** | Idle time exceeds threshold AND no media playing → you walked away → timer resets automatically |
| **Screen Lock Detection** | `SessionSwitch` events — if screen is locked for 2+ minutes, counts as a break on unlock |
| **Smart Deferral** | Break reminder is deferred during meetings, with a configurable post-meeting buffer before it triggers |
| **4-Option Break Dialog** | High-contrast dark dialog with prominent coffee icon, bold border, and drop shadow. Four options: (1) Taking Break Now → full-screen countdown, (2) Lock Screen & Break → locks PC and resets timer, (3) Snooze, (4) Reset Timer → resets sitting clock without taking a break. Shows in taskbar for easy Alt+Tab access. Escape key dismisses (counts as snooze). |
| **Configurable Snoozes** | Up to N snoozes allowed per break cycle (default 3, configurable 1–5 via settings). Snooze count displayed on the prompt. After all snoozes are used, snooze is hidden and break is mandatory. |
| **Reset Timer Button** | Available on every prompt (even mandatory ones). Resets the sitting timer without taking a break — useful when you've been standing at a desk or stretching informally. |
| **Analytics & Reporting** | Comprehensive event logging to daily JSON files. Auto-generates styled HTML daily reports (on day rollover) and weekly reports (on Mondays). Health Score system (0–100) with letter grades A–F. |
| **System Tray** | Color-coded icons: 🟢 tracking, 🟠 break soon, 🔴 overdue, ⚫ paused |
| **Settings UI** | Dark-themed WPF window with sliders for all settings including MaxSnoozes |

---

## Architecture

### Tech Stack

- **PowerShell 5.1+** — script host, no compilation needed
- **ps2exe** — optional compilation to standalone `.exe` (no PowerShell console required)
- **WPF (Windows Presentation Foundation)** — overlay and settings UI via XAML
- **Windows Forms** — system tray (`NotifyIcon`)
- **C# via `Add-Type`** — inline compiled helpers for Win32 interop and COM audio
- **WASAPI COM** — audio peak meter detection without third-party libraries
- **Windows Registry** — mic/camera active state via ConsentStore

### State Machine

```
Tracking ──[interval reached]──┬──[in meeting]──► Deferred
                               │                      │
                               │              [meeting ends]
                               │                      │
                               │                      ▼
                               │                 Buffering
                               │                      │
                               │          [buffer elapsed, no meeting]
                               │                      │
                               ├──────────────────────┘
                               │
                               ▼
                        Show Break Prompt
               ┌───────┼───────────┬───────────┐
         [Take Break] [Lock Screen] [Snooze]  [Reset Timer]
               │         │              │           │
               ▼         ▼              ▼           ▼
        Full-Screen   Lock PC +     Snoozed     Reset Timer
        Countdown     Reset Timer      │        (no break)
               │                       │
         [completed]            [3 min, snoozes left?]
               │                  ┌────┴────┐
               ▼               [yes]      [no]
             Reset                │         │
                                  ▼         ▼
                            Show Prompt  Mandatory Prompt
                           (with snooze) (snooze hidden)
```

**States:**

| State | Description |
|-------|-------------|
| `Tracking` | Counting sitting time. Checks every 10 seconds. |
| `Deferred` | Break is due but user is in a meeting. Waits for meeting to end. |
| `Buffering` | Meeting just ended. Waits for post-meeting buffer before showing break. |
| `Snoozed` | User snoozed the break. Waits 3 minutes then re-prompts. If snooze count < MaxSnoozes, snooze is still available; otherwise, break is mandatory. |

### Timer Reset Conditions

The sitting timer resets (back to 0) when any of these occur:

- **Natural break** — No keyboard/mouse input AND no audio playing for the idle threshold duration
- **Screen locked** — Screen was locked for 2+ minutes (detected on unlock)
- **Break completed** — Countdown overlay reached 0:00, or "Lock Screen & Break" was chosen
- **Manual reset** — User clicks "Reset Timer" in tray menu or on the break prompt
- **Resume from pause** — User un-pauses tracking

### Timer Continues When

- Any keyboard or mouse activity (even if you looked away briefly)
- Media/audio is playing (watching a video, listening to music — you're still sitting)

---

## Files

```
BreakTime/
├── BreakTime.ps1       # Main application (~1900 lines)
├── BreakTime.exe       # Compiled standalone executable (built via ps2exe, not committed)
├── settings.json       # User-configurable settings
├── Start-BreakTime.bat # Launcher (runs PS in STA mode, hides console)
├── README.md           # This file
├── logs/               # Daily event logs (auto-created)
│   └── YYYY-MM-DD.json             # One JSON-Lines file per day
└── reports/            # Generated HTML reports (auto-created)
    ├── daily-YYYY-MM-DD.html       # Daily health report
    └── weekly-YYYY-MM-DD.html      # Weekly summary (Monday date)
```

### BreakTime.ps1 — Module Breakdown

| Section | Purpose |
|---------|---------|
| STA Mode Check | Ensures PowerShell runs in Single-Threaded Apartment mode (required for WPF). Re-launches itself in STA if needed. |
| C# NativeMethods | `GetLastInputInfo` for idle time, `ShowWindow`/`GetConsoleWindow` for hiding console, `LockWorkStation` for lock-screen breaks |
| C# AudioDetector | WASAPI COM interop: `MMDeviceEnumerator` → `IMMDevice` → `IAudioMeterInformation.GetPeakValue()`. Peak > 0.0001 = audio playing. |
| Settings Management | Loads/saves `settings.json`. Falls back to defaults if file is missing or corrupt. |
| Detection Functions | `Test-MediaPlaying`, `Test-DeviceInUse`, `Test-InMeeting`, `Update-MediaActivity`, `Test-MediaRecentlyActive`, `Test-NaturalBreak` |
| Screen Lock Handler | `SystemEvents.SessionSwitch` handler — tracks lock/unlock times |
| Icon Creation | Generates colored circle icons programmatically via `System.Drawing` (no external icon files needed) |
| Countdown Widget | Always-on-top floating WPF window with centered layout, large clock icon (FontSize 30), bold timer text (FontSize 26), and high-contrast colors on a dark translucent background (`#CC1a1a2e`) with a 2px border. Title bar with minimize/close buttons. Updates every 1 second. Shows state: countdown, on break (green), BREAK!, PAUSED, MEETING, snooze remaining. Icon and border colors update per-state. |
| Break Prompt | Centered WPF dialog with high-contrast dark theme (`#DD1a1a2e`), 2px border, strong drop shadow, large coffee icon (FontSize 56). Four options: Take Break Now, Lock Screen & Break, Snooze (with remaining count), Reset Timer. Snooze hidden after max snoozes used. Shows in taskbar. Escape key dismisses. Matching visual style with the floating widget. |
| Break Countdown | Idle-gated WPF dialog shown after choosing "Taking Break Now." Timer only counts down while user is idle (10s threshold). Turns red with flashing ✋ hand when user is active. Includes Lock Screen button. Resets timer on completion. |
| Event Logging | `Write-BreakTimeEvent` appends JSON-Lines to daily log files in `logs/`. Tracks 15 event types with timestamps and contextual data. |
| Analytics Engine | `Get-DailyMetrics` computes compliance rate, snooze rate, break quality, hourly distribution. `Get-HealthScore` produces a weighted 0–100 score. |
| Report Generators | `New-DailyReport` and `New-WeeklyReport` produce dark-themed HTML reports with health scores, metric cards, progress bars, insights, and activity timelines. |
| Settings Window | WPF dialog with sliders for all 5 configurable values (including MaxSnoozes) |
| System Tray | `NotifyIcon` with context menu: status display, Take a Break, Pause/Resume, Reset Timer, Show/Hide Widget, Generate Today's Report, View Reports Folder, Settings, Exit |
| Main Timer | `DispatcherTimer` at 10-second interval driving the state machine |
| Entry Point | Creates WPF `Application` with `OnExplicitShutdown`, starts timer on `Startup` event |

### settings.json

```json
{
    "BreakIntervalMinutes": 45,
    "BreakDurationMinutes": 3,
    "PostMeetingBufferMinutes": 2,
    "IdleThresholdMinutes": 2,
    "MaxSnoozes": 3
}
```

| Setting | Default | Range | Description |
|---------|---------|-------|-------------|
| `BreakIntervalMinutes` | 45 | 5–120 | Minutes of continuous sitting before a break is triggered |
| `BreakDurationMinutes` | 3 | 1–10 | Length of the break countdown |
| `PostMeetingBufferMinutes` | 2 | 1–10 | Grace period after a meeting ends before showing the break overlay |
| `IdleThresholdMinutes` | 2 | 1–10 | Minutes of no input + no audio required to count as a natural break |
| `MaxSnoozes` | 3 | 1–5 | Number of snoozes allowed per break cycle before the break becomes mandatory |

---

## Usage

### Launch

#### Option 1: Standalone Executable (Recommended)

Compile the script to a standalone `.exe` using [ps2exe](https://github.com/MScholtes/PS2EXE) — no PowerShell console required:

```powershell
Install-Module -Name ps2exe -Scope CurrentUser -Force
Invoke-ps2exe -InputFile ".\BreakTime.ps1" -OutputFile ".\BreakTime.exe" -NoConsole -STA -Title "BreakTime" -Description "Smart Break Reminder for Windows"
```

Then simply double-click **BreakTime.exe** to run. This eliminates the dependency on a PowerShell console window — the app runs as a native Windows process.

#### Option 2: PowerShell Script

Double-click **Start-BreakTime.bat**, or run directly:

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "BreakTime.ps1"
```

A green circle appears in your system tray and a small countdown widget appears in the top-left corner. That's it — it's tracking.

### Countdown Widget

The floating widget stays on top of all windows and shows:

| Widget State | Display |
|-------------|--------|
| Normal | `32:15` in blue — minutes:seconds until next break |
| Break soon (< 5 min) | `4:30` in orange with "break soon" |
| Break overdue | `BREAK!` in red with "X min overdue" |
| On break | `On Break!` in green with ☕ icon and "stretch & walk around" |
| Paused | `PAUSED` in gray |
| In meeting | `MEETING` in blue with "break deferred" |
| Snoozed | `2:15` in orange with "snooze left" |

- **Drag** anywhere on screen by clicking and dragging the title bar or content area
- **Minimize** (—) or **Close** (✕) buttons hide the widget; timer continues in the background
- Re-show via tray menu → Show Widget

### Break Prompt

When the break interval is reached, a centered dialog appears with three options:

| Button | Action |
|--------|--------|
| **🚶 Taking Break Now** | Opens an idle-gated countdown dialog. Timer only ticks while you're away from the keyboard (10+ seconds idle). If you keep working, the UI turns red with a flashing ✋ hand until you step away. Timer resets when countdown finishes. |
| **🔒 Lock Screen & Break** | Immediately locks your PC and resets the sitting timer. Walk away! |
| **⏸ Snooze (3 min)** | Delays the break by 3 minutes. Shows remaining snooze count (e.g., "2 of 3 remaining"). Hidden once all snoozes are used — break becomes mandatory. |
| **🔄 Reset Timer** | Resets the sitting timer to zero without taking a break. Always available, even on mandatory prompts. Useful when you've been standing or stretching informally. |
| **Escape key** | Dismisses the prompt (counts as a snooze if snoozes remain). |

> **Note:** The break prompt now shows in the Windows taskbar (`ShowInTaskbar`) so it can be found via Alt+Tab if covered by other windows.

### System Tray Menu (right-click)

| Item | Action |
|------|--------|
| **Sitting: X / Y min** | Status display (not clickable) |
| **Take a Break Now** | Shows the break prompt dialog |
| **Pause / Resume** | Stops/restarts tracking. Resume continues the timer from where it left off. |
| **Reset Timer** | Resets sitting time to 0 without taking a break |
| **Hide / Show Widget** | Toggles the floating countdown widget |
| **Generate Today's Report** | Creates an HTML report for today's activity and opens it in your browser |
| **View Reports Folder** | Opens the `reports/` folder in File Explorer |
| **Settings...** | Opens the settings window |
| **Exit** | Closes the app |

Double-clicking the tray icon opens Settings.

### Auto-Start with Windows

#### If using the compiled `.exe` (Recommended)

Run this PowerShell command to create a startup shortcut:

```powershell
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut("$([System.Environment]::GetFolderPath('Startup'))\BreakTime.lnk")
$shortcut.TargetPath = "<full path to BreakTime.exe>"
$shortcut.WorkingDirectory = "<folder containing BreakTime.exe>"
$shortcut.Description = "BreakTime - Smart Break Reminder"
$shortcut.Save()
```

Or manually: press **Win+R** → `shell:startup` → place a shortcut to `BreakTime.exe` there.

#### If using the PowerShell script

Create a shortcut to `Start-BreakTime.bat` and place it in:

```
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
```

---

## Meeting Detection Details

BreakTime detects meetings through two mechanisms:

### 1. Registry-Based (Primary)

Windows tracks which apps are using the microphone and webcam via:

```
HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone
HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam
```

Each app subkey has `LastUsedTimeStart` and `LastUsedTimeStop` timestamps. If `Start > Stop`, the device is currently in use — meaning you're in a meeting.

### 2. Process Scan (Backup)

Checks for meeting-related window titles in known apps:

- Microsoft Teams (`ms-teams`, `Teams`)
- Zoom (`Zoom`)
- Webex (`webexmeetings`)
- Slack (`slack`)

A process match only counts if the window title contains keywords like "Meeting", "Call", or "Sharing".

---

## Audio Detection Details

Uses Windows Audio Session API (WASAPI) via COM interop:

1. **Create** `MMDeviceEnumerator` (CLSID `BCDE0395-E52F-467C-8E3D-C4579291692E`)
2. **Get** default audio render endpoint (`eRender`, `eMultimedia`)
3. **Activate** `IAudioMeterInformation` interface on the device
4. **Read** `GetPeakValue()` — returns a float 0.0 to 1.0

If peak > 0.0001, audio is actively playing. This detects any audio output: music, video, meeting audio, notifications — anything coming through the speakers/headphones.

---

## Analytics & Reporting

BreakTime includes a comprehensive analytics system that tracks every meaningful event and generates styled HTML reports automatically.

### Event Logging

Every action is logged as a JSON-Lines entry in `logs/breaktime-YYYY-MM-DD.json`. Each entry includes a timestamp, event type, and optional contextual data.

| Event | When Logged | Data |
|-------|-------------|------|
| `AppStarted` | App launches | Version, interval, duration settings |
| `AppStopped` | App exits via tray menu | — |
| `BreakPrompted` | Break prompt dialog shown | AllowSnooze, current SnoozeCount |
| `BreakTaken` | User clicks "Taking Break Now" | — |
| `BreakCompleted` | Break countdown reaches 0:00 | BreakDurationSeconds |
| `BreakEndedEarly` | User closes break before completion | ElapsedSeconds, TotalSeconds |
| `LockScreenBreak` | User clicks "Lock Screen & Break" | — |
| `Snoozed` | User clicks Snooze | SnoozeNumber, MaxSnoozes |
| `Dismissed` | User closes prompt via X button | SnoozeNumber |
| `ResetTimer` | Timer reset from prompt or tray | Source (BreakPrompt / TrayMenu) |
| `MeetingDeferred` | Break deferred due to active meeting | SittingMinutes |
| `NaturalBreak` | Idle + no media detected → walked away | — |
| `Paused` / `Resumed` | Tracking paused/resumed via tray | — |
| `ScreenLocked` | Windows session locked | — |
| `ScreenUnlocked` | Windows session unlocked | LockedMinutes |

### Health Score (0–100)

A weighted composite score calculated daily:

| Component | Weight | Logic |
|-----------|--------|-------|
| **Compliance** | 40% | Percentage of prompts that led to breaks |
| **Break Quality** | 20% | Ratio of fully completed breaks vs. taken |
| **Low Snooze** | 20% | Lower snooze rate = higher score |
| **Sitting Discipline** | 15% | Penalty for sitting streaks > 50 minutes |
| **Reset Penalty** | 5% | Resets bypass the system, mild penalty |

**Letter grades:** A (90+), B (75–89), C (60–74), D (40–59), F (<40)

### Daily Reports

Auto-generated when BreakTime detects a new day (or on-demand via tray menu). Includes:

- **Health Score card** with letter grade and color coding
- **Key metrics** — total breaks, prompts, completions, meeting deferrals
- **Progress bars** — compliance rate and snooze rate
- **Insights** — contextual tips based on your data (e.g., "High snooze rate — try taking breaks on the first prompt")
- **Activity timeline** — chronological event log with color-coded event types

### Weekly Reports

Auto-generated on Monday mornings for the previous Mon–Sun week. Includes:

- **Average health score** across the week
- **Weekly summary metrics** — total breaks, prompts, compliance, active days
- **Day-by-day breakdown** — individual scores and stats per day
- **Trend analysis** — upward/downward/steady scoring trend
- **Weekly insights** — meeting deferral patterns, natural break frequency

### Report Files

Reports are saved as self-contained HTML in `reports/`:

- `daily-2026-03-09.html` — daily report
- `weekly-2026-03-03.html` — weekly report (named by Monday of that week)

Open them in any browser — they use a dark theme matching the app aesthetic with no external dependencies.

---

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Compiled `.exe` via ps2exe** | Eliminates the PowerShell console window entirely. No risk of accidental closure or interference from other PS sessions. The app behaves like a native Windows desktop application. |
| **Floating countdown widget** | Always visible remaining time without clicking into anything. Resets live so you always know where you stand. |
| **4-option break prompt** | "Lock Screen & Break" is the fastest path — one click and you're up. "Take Break Now" for monitored breaks. Snooze as safety valve. Reset Timer as escape hatch when you're already standing. |
| **PowerShell + WPF** | Zero dependencies. Runs on any Windows 10/11 machine. Can be compiled to standalone `.exe` via ps2exe for console-free operation. |
| **Inline C# via Add-Type** | Needed for Win32 P/Invoke and WASAPI COM interop. PowerShell can't do these natively. |
| **WASAPI peak meter** | Only reliable way to detect audio playback without third-party libraries. Simpler than enumerating audio sessions. |
| **Registry for mic/camera** | More reliable than process scanning. Works regardless of which app is using the device. |
| **Configurable snooze limit** | Default 3 snoozes prevents infinite deferral while giving reasonable flexibility. Configurable 1–5 via settings. |
| **Mandatory = no Alt+F4** | The break countdown `Closing` event is canceled unless completed. Prompt dialog blocks dismiss when all snoozes are used — but Reset Timer is always available as an escape hatch. |
| **Guarded DragMove** | Title bar drag only activates when left mouse button is pressed, preventing WPF freezes from right-click or edge-case mouse events. |
| **Event-driven analytics** | Every meaningful action is logged with timestamps and context. Reports are generated passively on day/week boundaries — no user action required. |
| **Health Score weighting** | 40% compliance + 20% break quality + 20% low-snooze + 15% sitting discipline + 5% reset penalty. Balanced to reward consistency without being punitive. |
| **10-second tick interval** | Responsive enough for state changes. Lightweight enough to be invisible in Task Manager. |
| **Color-coded tray icons** | Glanceable status without clicking anything. Generated via GDI+ — no icon files needed. |
| **Post-meeting buffer** | You don't want a break overlay the instant you leave a meeting. 2-minute default lets you settle. |
| **Dark theme UI** | High-contrast translucent dark backgrounds (`#CC`–`#DD` opacity) with 2px borders and strong drop shadows. Consistent visual language across widget and dialog. |
| **Media grace window** | 30-second window after last audio detection prevents false timer resets during quiet video moments (e.g., scene transitions, paused dialog). |
| **Per-state icon coloring** | Widget clock icon changes color to match the current state (blue, orange, red, green) for at-a-glance status. |
| **Idle-gated break countdown** | Break timer only ticks while user is actually idle (10s gate). Prevents "sitting through" a break while typing. |
| **Red flash on active during break** | If user keeps working during break, the dialog goes red with a flashing ✋ hand — impossible to ignore. Restores to calm green once idle. |

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1+ (pre-installed on all modern Windows)
- No admin rights required
- No internet connection required
- No external dependencies

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Widget not visible | Right-click tray icon → Show Widget. Or restart the app. |
| No tray icon appears | Ensure you're running with `-STA` flag. Use `Start-BreakTime.bat`. |
| Console window stays visible | Normal for a moment on first launch. The script hides it via `ShowWindow`. If it persists, use `-WindowStyle Hidden`. |
| Audio detection not working | Ensure a default audio output device is set in Windows Sound settings. |
| Meeting not detected | Check that Teams/Zoom has microphone or camera permission granted in Windows Privacy settings. |
| Break appears during meeting | The app checks mic/camera registry state. If your meeting app doesn't use either (audio-only phone bridge, for example), it won't be detected. |
| Settings don't save | Ensure the script has write permission to the `BreakTime` folder. |
