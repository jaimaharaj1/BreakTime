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
| **3-Option Break Dialog** | High-contrast dark dialog with prominent coffee icon, bold border, and drop shadow. Three options: (1) Taking Break Now → full-screen countdown, (2) Lock Screen & Break → locks PC and resets timer, (3) Snooze |
| **Snooze** | One 3-minute snooze allowed per break cycle, then snooze is hidden and break is mandatory |
| **System Tray** | Color-coded icons: 🟢 tracking, 🟠 break soon, 🔴 overdue, ⚫ paused |
| **Settings UI** | Dark-themed WPF window with sliders for all settings |

---

## Architecture

### Tech Stack

- **PowerShell 5.1+** — script host, no compilation needed
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
                     ┌───────┼───────────┐
               [Take Break] [Lock Screen] [Snooze]
                     │         │              │
                     ▼         ▼              ▼
              Full-Screen   Lock PC +     Snoozed ──[3 min]──► Show Prompt (no snooze)
              Countdown     Reset Timer
                     │
               [completed]
                     │
                     ▼
                   Reset
```

**States:**

| State | Description |
|-------|-------------|
| `Tracking` | Counting sitting time. Checks every 10 seconds. |
| `Deferred` | Break is due but user is in a meeting. Waits for meeting to end. |
| `Buffering` | Meeting just ended. Waits for post-meeting buffer before showing break. |
| `Snoozed` | User snoozed the break. Waits 3 minutes then shows mandatory break. |

### Timer Reset Conditions

The sitting timer resets (back to 0) when any of these occur:

- **Natural break** — No keyboard/mouse input AND no audio playing for the idle threshold duration
- **Screen locked** — Screen was locked for 2+ minutes (detected on unlock)
- **Break completed** — Countdown overlay reached 0:00, or "Lock Screen & Break" was chosen
- **Manual reset** — User clicks "Reset Timer" in tray menu
- **Resume from pause** — User un-pauses tracking

### Timer Continues When

- Any keyboard or mouse activity (even if you looked away briefly)
- Media/audio is playing (watching a video, listening to music — you're still sitting)

---

## Files

```
BreakTime/
├── BreakTime.ps1       # Main application (~1120 lines)
├── settings.json       # User-configurable settings
├── Start-BreakTime.bat # Launcher (runs PS in STA mode, hides console)
└── README.md           # This file
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
| Break Prompt | Centered WPF dialog with high-contrast dark theme (`#DD1a1a2e`), 2px border, strong drop shadow, large coffee icon (FontSize 56). Three options: Take Break Now, Lock Screen & Break, Snooze. Snooze hidden after first use. Matching visual style with the floating widget. |
| Break Countdown | Idle-gated WPF dialog shown after choosing "Taking Break Now." Timer only counts down while user is idle (10s threshold). Turns red with flashing ✋ hand when user is active. Includes Lock Screen button. Resets timer on completion. |
| Settings Window | WPF dialog with sliders for all 4 configurable values |
| System Tray | `NotifyIcon` with context menu: status display, Take a Break, Pause/Resume, Reset Timer, Settings, Exit |
| Main Timer | `DispatcherTimer` at 10-second interval driving the state machine |
| Entry Point | Creates WPF `Application` with `OnExplicitShutdown`, starts timer on `Startup` event |

### settings.json

```json
{
    "BreakIntervalMinutes": 45,
    "BreakDurationMinutes": 3,
    "PostMeetingBufferMinutes": 2,
    "IdleThresholdMinutes": 2
}
```

| Setting | Default | Description |
|---------|---------|-------------|
| `BreakIntervalMinutes` | 45 | Minutes of continuous sitting before a break is triggered |
| `BreakDurationMinutes` | 3 | Length of the break countdown |
| `PostMeetingBufferMinutes` | 2 | Grace period after a meeting ends before showing the break overlay |
| `IdleThresholdMinutes` | 2 | Minutes of no input + no audio required to count as a natural break |

---

## Usage

### Launch

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
| **⏸ Snooze (3 min)** | Delays the break by 3 minutes. Only available once — after snooze, the next prompt has no snooze option. |

### System Tray Menu (right-click)

| Item | Action |
|------|--------|
| **Sitting: X / Y min** | Status display (not clickable) |
| **Take a Break Now** | Shows the break prompt dialog |
| **Pause / Resume** | Stops/restarts tracking. Resume resets the timer. |
| **Reset Timer** | Resets sitting time to 0 without taking a break |
| **Hide / Show Widget** | Toggles the floating countdown widget |
| **Settings...** | Opens the settings window |
| **Exit** | Closes the app |

Double-clicking the tray icon opens Settings.

### Auto-Start with Windows

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

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Floating countdown widget** | Always visible remaining time without clicking into anything. Resets live so you always know where you stand. |
| **3-option break prompt** | "Lock Screen & Break" is the fastest path — one click and you're up. "Take Break Now" for monitored breaks. Snooze as safety valve. |
| **PowerShell + WPF** | Zero compilation, zero dependencies. Runs on any Windows 10/11 machine out of the box. |
| **Inline C# via Add-Type** | Needed for Win32 P/Invoke and WASAPI COM interop. PowerShell can't do these natively. |
| **WASAPI peak meter** | Only reliable way to detect audio playback without third-party libraries. Simpler than enumerating audio sessions. |
| **Registry for mic/camera** | More reliable than process scanning. Works regardless of which app is using the device. |
| **1 snooze max** | Prevent infinite snooze loops. One grace period, then mandatory. |
| **Mandatory = no Alt+F4** | The break countdown `Closing` event is canceled unless completed. Prompt dialog also blocks dismiss when snooze was used. |
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
