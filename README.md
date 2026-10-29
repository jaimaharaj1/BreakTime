# BreakTime — Smart Break Reminder for Windows

A lightweight desktop app that estimates continuous desk time and reminds you to take breaks. Built entirely in PowerShell + WPF, it runs from the system tray with no third-party runtime dependencies.

---

## Why This Exists

Sitting for long stretches is bad for you — but traditional break reminders are dumb. They interrupt you mid-meeting, they can't tell if you just walked to the kitchen, and they don't know you're watching a training video (still sitting!). BreakTime fixes all of that.

### The Core Insight

"Sitting time" isn't just "time since last keyboard press." It includes:

- **Watching videos/media** — audio is playing but you haven't touched the keyboard. You're still sitting.
- **In a Teams meeting** — connected call controls are present, even when muted, camera-off or minimised. Don't interrupt.
- **Actually idle** — no input, detected media or meeting for the full idle threshold. That's an inferred break.

Sitting time is an estimate of continuous desk time, not a physical posture measurement. The reminder and widget share a live minutes-and-seconds value. Pausing freezes it; resuming preserves it. Time waiting for you to return after a reset is not counted, and clock/time-zone changes do not affect it.

---

## Features

| Feature | How It Works |
|---------|-------------|
| **Floating Countdown Widget** | Always-on-top mini window with centred MM:SS countdown and a separate live sitting-time line. Draggable, colour-coded per state. Shows "On Break!" during active breaks. |
| **Input Monitoring** | Win32 `GetLastInputInfo` via P/Invoke — tracks seconds since last keyboard/mouse input |
| **Media Detection** | WASAPI peak meters monitor all active audio outputs, including headphones and per-app routing. Playback prevents idle resets but does not suppress break reminders. |
| **Meeting Detection** | Background UI Automation checks for connected Teams call controls; existing registry/process heuristics remain for other meeting apps |
| **Natural Break Detection** | No input, detected media or meeting for the entire configured idle threshold resets the timer |
| **Screen Lock Detection** | Unattended lock time and sleep are excluded. Detected meetings/media preserve the session; sitting time can continue while locked if meeting/media activity is detected. |
| **Smart Deferral** | Break reminder is deferred during meetings, with a configurable post-meeting buffer before it triggers |
| **5-Option Break Dialog** | High-contrast dark dialog with prominent coffee icon, bold border, and drop shadow. Five options: (1) Taking Break Now → full-screen countdown, (2) Lock Screen & Break → locks PC and resets timer, (3) Snooze, (4) Reset Timer → resets sitting clock without taking a break, (5) Break Already Taken → resets timer acknowledging a break was already taken. Shows in taskbar for easy Alt+Tab access. Escape key dismisses (counts as snooze). |
| **Configurable Snoozes** | Up to N snoozes allowed per break cycle (default 3, configurable 1–5 via settings). Snooze count displayed on the prompt. After all snoozes are used, snooze is hidden and break is mandatory. |
| **Reset Timer Button** | Available on every prompt (even mandatory ones). Resets the sitting timer without taking a break — useful when you've been standing at a desk or stretching informally. |
| **Widget Auto-Recovery** | If the floating widget disappears unexpectedly, clicking "Show Widget" in the tray menu automatically recreates it. The tray label updates to reflect the widget's actual state. |
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
- **Windows UI Automation** — connected Teams call controls, inspected on a background MTA worker
- **Windows Registry** — mic/camera active state via ConsentStore for legacy non-Teams detection

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
               ┌───────┼───────────┬───────────┬────────────────┐
         [Take Break] [Lock Screen] [Snooze]  [Reset Timer] [Already Taken]
               │         │              │           │              │
               ▼         ▼              ▼           ▼              ▼
        Full-Screen   Lock PC +     Snoozed     Reset Timer    Reset Timer
        Countdown     Reset Timer      │        (no break)     (break done)
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
| `Tracking` | Counting estimated sitting time. Activity and displays update every second; Teams scans run in the background every five seconds. |
| `Deferred` | Break is due, but a meeting is detected or Teams detection is not ready. Holds reminders until the condition clears. |
| `Buffering` | Call-end grace has cleared. Waits for the configured post-meeting buffer; another call returns the session to `Deferred`. |
| `Snoozed` | User snoozed the break. Waits 3 minutes then re-prompts. If snooze count < MaxSnoozes, snooze is still available; otherwise, break is mandatory. |

### Timer Reset Conditions

The sitting timer resets (back to 0) when any of these occur:

- **Natural break** — No keyboard/mouse input, detected media or meeting for the entire configured idle threshold
- **Screen locked/sleeping** — A sufficiently long unattended interval, provided meeting/media detection does not indicate continued presence
- **App-managed break** — Countdown overlay reached 0:00, was closed early, or "Lock Screen & Break" was chosen
- **Manual reset** — User clicks "Reset Timer" in tray menu or on the break prompt
- **Break already taken** — User clicks "Break Already Taken" on the break prompt

Resuming from pause does not reset the session. Detection errors suspend automatic idle resets instead of treating unknown state as absence.

### Timer Continues When

- Any keyboard or mouse activity (even if you looked away briefly)
- Media/audio is playing (watching a video, listening to music — you're still sitting)
- A meeting is detected, including silent, muted Teams calls

### Sitting-Time Behaviour

The reminder shows `You've been sitting for 32m 15s`; the widget shows `Sitting: 32m 15s` alongside its existing countdown or status. Both use the same elapsed-time snapshot and refresh every second, including while the reminder is open. Whole seconds are displayed without rounding minutes up.

- **Startup and after resets:** the value stays at zero until keyboard/mouse activity, detected media or a meeting indicates your return. Previous sessions are not restored when the app restarts.
- **Pause/resume:** the value freezes while paused and continues from the same value after resuming. Paused time is not added later.
- **Snooze and meetings:** sitting time continues; deferring a reminder does not reset or pause the sitting session.
- **Inactivity:** an automatic reset requires the full configured idle threshold since the last input, detected audio or meeting-presence signal. Keyboard/mouse inactivity alone is not enough during a detected meeting or playback.
- **Lock/sleep:** short unattended intervals preserve the accumulated value without counting time away. Sufficiently long unattended intervals can reset it, but detected meetings/media prevent a false reset. Sleep itself is not counted.
- **App-managed breaks:** the sitting value freezes during the break countdown. Completing or closing that countdown resets it, including an early close, as an explicit user choice.

Automatic reset decisions are conservative when call or audio detection is unavailable. The app cannot determine physical posture or distinguish a completely silent video from someone leaving the desk; see [Known Limitations](#known-limitations).

---

## Files

```
BreakTime/
├── BreakTime.ps1       # Main application
├── BreakTime.exe       # Compiled standalone executable (built via ps2exe, not committed)
├── settings.json       # User-configurable settings
├── Start-BreakTime.bat # Launcher (runs PS in STA mode, hides console)
├── tests/
│   └── BreakTime.Tests.ps1 # Pester regression tests and synthetic call-window fixtures
└── README.md           # This file
```

### BreakTime.ps1 — Module Breakdown

| Section | Purpose |
|---------|---------|
| STA Mode Check | Ensures PowerShell runs in Single-Threaded Apartment mode (required for WPF). Re-launches itself in STA if needed. |
| C# NativeMethods | `GetTickCount64` supplies monotonic elapsed time; `GetLastInputInfo` supplies wrap-safe idle time. Also hides the console and supports locking the workstation. |
| C# AudioDetector | Enumerates active render endpoints, reads `IAudioMeterInformation.GetPeakValue()` and releases COM objects after sampling. Peak > 0.0001 indicates playback. |
| C# TeamsCallDetector | Enumerates Teams windows and checks fixed connected-call control IDs asynchronously, including minimised windows. Returns only call status or an error code. |
| Settings Management | Loads/saves `settings.json`. Falls back to defaults if file is missing or corrupt. |
| Detection Functions | Cache background call results, apply call-end grace, track input/media presence and guard natural-break decisions against unknown detection state. |
| Sitting-Time Functions | `Get-SittingSeconds`, `Get-SittingText`, `Suspend-SittingTimer`, `Resume-SittingTimer` and `Reset-SittingTimer` supply shared elapsed-time accounting. |
| Session/Power Handlers | `SystemEvents.SessionSwitch` and `PowerModeChanged` handle lock/unlock and suspend/resume without counting unattended time or discarding detected meeting/media sessions. |
| Icon Creation | Generates colored circle icons programmatically via `System.Drawing` (no external icon files needed) |
| Countdown Widget | Always-on-top floating WPF window with centered layout, large clock icon (FontSize 30), bold timer text (FontSize 26), and high-contrast colors on a dark translucent background (`#CC1a1a2e`) with a 2px border. Title bar with minimize/close buttons. Updates every 1 second. Shows state: countdown, on break (green), BREAK!, PAUSED, MEETING, snooze remaining. Icon and border colors update per-state. |
| Break Prompt | Centered WPF dialog with high-contrast dark theme (`#DD1a1a2e`), 2px border, strong drop shadow, large coffee icon (FontSize 56). Five options: Take Break Now, Lock Screen & Break, Snooze (with remaining count), Reset Timer, Break Already Taken. Snooze hidden after max snoozes used. Shows in taskbar. Escape key dismisses. Matching visual style with the floating widget. |
| Break Countdown | Idle-gated WPF dialog shown after choosing "Taking Break Now." Timer only counts down while user is idle (10s threshold). Turns red when user is active. Includes Lock Screen button. Completion or early close resets sitting time. |
| Settings Window | WPF dialog with sliders for all 5 configurable values (including MaxSnoozes) |
| System Tray | `NotifyIcon` with context menu: status display, Take a Break, Pause/Resume, Reset Timer, Show/Hide Widget, Settings, Exit |
| Main Timer | One-second `DispatcherTimer` updates tracking, the widget and open reminder; reminders are queued separately so modal windows do not stop tracking |
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
| `PostMeetingBufferMinutes` | 2 | 0–10 | Additional delay after the fixed 30-second call-end grace before showing the reminder |
| `IdleThresholdMinutes` | 2 | 1–5 | Full unattended interval without input, detected media or a meeting required to infer a natural break; also used for lock/sleep resets |
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

After changing `BreakTime.ps1`, rebuild the executable to apply those changes to the standalone app. Exit the running copy from its tray menu before replacing `BreakTime.exe`, then launch the rebuilt file. Keep `settings.json` beside the executable to preserve your preferences. Restarting begins a new sitting session.

#### Option 2: PowerShell Script

Double-click **Start-BreakTime.bat**, or run directly:

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "BreakTime.ps1"
```

A tray icon and a small widget appear in the top-left corner. The widget can briefly show `CHECKING` while the first Teams scan completes. Sitting time begins when input, media or a meeting is detected.

### Countdown Widget

The floating widget stays on top of other windows. A separate `Sitting: Xm YYs` line uses red (`#F44336`) text in the monospaced Consolas font and is synchronised with the reminder's live elapsed-time message. This styling applies only to the widget's sitting-time line; the reminder's font and the main countdown's state-dependent colours are unchanged.

The main widget display retains its countdown or status:

| Widget State | Display |
|-------------|--------|
| Normal | `32:15` in blue — minutes:seconds until next break |
| Break soon (< 5 min) | `4:30` in orange with "break soon" |
| Break overdue | `BREAK!` in red with "X min overdue" |
| On break | `On Break!` in green with ☕ icon and "stretch & walk around" |
| Paused | `PAUSED` in gray |
| In meeting | `MEETING` in blue with "break deferred" |
| Snoozed | `2:15` in orange with "snooze left" |

`Ready` means the timer is waiting for activity after startup or a reset. `CHECKING` means Teams detection is pending or unavailable; automatic reminders are held while that state persists. `MEETING` appears when a break is due and has been deferred, not necessarily throughout every meeting.

- **Drag** anywhere on screen by clicking and dragging the title bar or content area
- **Minimize** (—) or **Close** (✕) buttons hide the widget; timer continues in the background
- Re-show via tray menu → Show Widget

### Break Prompt

When the break interval is reached and no meeting or detection hold is active, a centred dialog appears with five options. Its sitting-time message updates every second rather than remaining fixed at the value when the window opened.

| Button | Action |
|--------|--------|
| **🚶 Taking Break Now** | Opens an idle-gated countdown dialog. Timer only ticks while you're away from the keyboard (10+ seconds idle). If you keep working, the UI turns red until you step away. Completing or closing the countdown, including an early close, resets sitting time. |
| **🔒 Lock Screen & Break** | Immediately locks your PC and resets the sitting timer. Walk away! |
| **⏸ Snooze (3 min)** | Delays the break by 3 minutes. Shows remaining snooze count (e.g., "2 of 3 remaining"). Hidden once all snoozes are used — break becomes mandatory. |
| **🔄 Reset Timer** | Resets the sitting timer to zero without taking a break. Always available, even on mandatory prompts. Useful when you've been standing or stretching informally. |
| **✅ Break Already Taken** | Resets the sitting timer, acknowledging you've already taken a break (e.g., walked to the kitchen) but didn't dismiss the prompt earlier. Always available, even on mandatory prompts. |
| **Escape key** | Dismisses the prompt (counts as a snooze if snoozes remain). |

> **Note:** The break prompt now shows in the Windows taskbar (`ShowInTaskbar`) so it can be found via Alt+Tab if covered by other windows.

Closing the **reminder** counts as a snooze when allowed; closing the separate **break countdown** resets sitting time. If a meeting is detected while a reminder is already open, the reminder closes and defers without consuming a snooze. A confirmed natural break also closes an open reminder and resets the session.

### System Tray Menu (right-click)

| Item | Action |
|------|--------|
| **Sitting: Xm YYs / Z min** | Live elapsed sitting time and configured break interval (not clickable) |
| **Take a Break Now** | Shows the break prompt dialog |
| **Pause / Resume** | Stops/restarts tracking. Resume continues the timer from where it left off. |
| **Reset Timer** | Resets sitting time to 0 without taking a break |
| **Hide / Show Widget** | Toggles the floating countdown widget. Automatically recreates the widget if it was lost. |
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

### Teams: Connected Call Controls

BreakTime enumerates all visible Teams top-level windows, including minimised and separate meeting windows, rather than relying on `MainWindowTitle`. A background MTA worker checks for the fixed UI Automation IDs `hangup-button`, `microphone-button` and `call-duration-custom` in the same window. It does not collect meeting titles, participants, chats or shared content.

All three controls are required, so Teams simply being open, microphone use on its own, and media playback do not qualify as a connected Teams call. Detection runs every five seconds. A 30-second call-end grace precedes the configured post-meeting buffer.

For example, a two-minute buffer means approximately two minutes and 30 seconds after detection stops reporting a call, plus scan/timer scheduling delay. Setting the buffer to zero does not remove the fixed call-end grace. Detection is periodic, not instantaneous.

An accessibility error or a scan exceeding ten seconds holds reminders and shows a warning instead of assuming the call ended. Only one scan can be outstanding, so a stalled provider cannot accumulate background workers. Restart BreakTime if the warning persists.

Teams control IDs can change with future updates. Real meeting checks confirmed the current controls while muted, camera-off and minimised. Synthetic regression cases cover media players and pre-join-like controls; the actual Teams pre-join screen has not been verified.

### Other Apps: Existing Registry and Process Heuristics

Windows tracks which apps are using the microphone and webcam via:

```
HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone
HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam
```

Each app subkey has `LastUsedTimeStart` and `LastUsedTimeStop` timestamps. If `Start > Stop`, the device is treated as in use. Teams records are excluded because device usage is not proof of a connected Teams call.

Checks for meeting-related window titles in known apps:

- Zoom (`Zoom`)
- Webex (`webexmeetings`)
- Slack (`slack`)

A process match only counts if the window title contains keywords like "Meeting", "Call", or "Sharing".

These legacy non-Teams heuristics remain approximate. Playback audio never suppresses a break reminder; it only prevents an incorrect idle reset. Playback detection monitors all active audio outputs, including headphones and per-app routing.

---

## Audio Detection Details

Uses Windows Audio Session API (WASAPI) via COM interop:

1. **Create** `MMDeviceEnumerator` (CLSID `BCDE0395-E52F-467C-8E3D-C4579291692E`)
2. **Enumerate** active audio render endpoints (`eRender`, `DEVICE_STATE_ACTIVE`)
3. **Activate** `IAudioMeterInformation` on each device
4. **Read** `GetPeakValue()` — returns a float 0.0 to 1.0 — and release COM objects after sampling

Audio is sampled each second. If any endpoint reports a peak above 0.0001, playback is detected. A 30-second recent-media window bridges short gaps and can recognise your return after a reset. Natural-break detection additionally requires the entire configured idle threshold without input, detected media or meeting presence, rather than resetting as soon as the recent-media window expires.

Media is a presence signal, not a meeting signal: watching a recording or YouTube keeps sitting time running and still allows a due break reminder. An audio-detection failure raises a warning and suspends automatic idle resets instead of being treated as silence.

---

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Compiled `.exe` via ps2exe** | Eliminates the PowerShell console window entirely. No risk of accidental closure or interference from other PS sessions. The app behaves like a native Windows desktop application. |
| **Floating countdown widget** | Always visible remaining time without clicking into anything. Resets live so you always know where you stand. |
| **5-option break prompt** | "Lock Screen & Break" is the fastest path — one click and you're up. "Take Break Now" for monitored breaks. Snooze as safety valve. Reset Timer as escape hatch when you're already standing. "Break Already Taken" for when you forgot to dismiss the prompt earlier. |
| **PowerShell + WPF** | Zero dependencies. Runs on any Windows 10/11 machine. Can be compiled to standalone `.exe` via ps2exe for console-free operation. |
| **Inline C# via Add-Type** | Needed for Win32 P/Invoke and WASAPI COM interop. PowerShell can't do these natively. |
| **WASAPI peak meter** | Detects audio activity across active output devices without third-party libraries or inspecting media content. It does not prove that a silent video is playing. |
| **Teams call-control detection** | Checks connected-call control IDs on a background MTA worker, independently of microphone mute state and window title. |
| **Configurable snooze limit** | Default 3 snoozes prevents infinite deferral while giving reasonable flexibility. Configurable 1–5 via settings. |
| **Mandatory reminder** | The reminder blocks dismissal when all snoozes are used, but Reset Timer and Break Already Taken remain available. The separate break countdown can be closed early and resets sitting time. |
| **Widget auto-recovery** | WPF windows in PowerShell can occasionally be garbage-collected. The tray menu detects this and recreates the widget on demand. |
| **One-second heartbeat** | Keeps sitting-time displays live, including while a reminder is open. Teams accessibility scans run separately every five seconds. |
| **Color-coded tray icons** | Glanceable status without clicking anything. Generated via GDI+ — no icon files needed. |
| **Post-meeting buffer** | A fixed 30-second call-end grace avoids reacting to transient detection loss; the configurable buffer adds settling time after that grace. |
| **Dark theme UI** | High-contrast translucent dark backgrounds (`#CC`–`#DD` opacity) with 2px borders and strong drop shadows. Consistent visual language across widget and dialog. |
| **Media grace and full idle threshold** | Recent media helps recognise presence; natural resets require the full idle threshold since the last presence signal, so a short playback pause does not immediately clear the session. |
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

## Known Limitations

- **No posture sensor:** "sitting" means estimated continuous desk time. Standing at the desk or leaving audio playing while away cannot be distinguished reliably; use Pause, Reset Timer or Break Already Taken when appropriate.
- **Silent media:** completely silent videos, or audio activity below the detection threshold for the full idle interval, can look like inactivity. Muting does not guarantee either outcome because the Windows peak meter depends on the playback path. Pause tracking when watching content that is not detected.
- **Teams compatibility:** fixed accessibility IDs may change in a future Teams release. The detector is designed for the desktop `ms-teams`/`Teams` processes; Teams in a browser is not covered by this call-control detector.
- **Other meeting apps:** legacy microphone/camera and title heuristics can produce false positives or negatives. They are not equivalent to the Teams connected-call check.
- **Verification scope:** a real Teams meeting was inspected muted, camera-off and minimised. Media-player and pre-join-like windows were tested synthetically; the real Teams pre-join screen was not checked.

## Regression Tests

From the app directory, run the existing Pester suite in Windows PowerShell with STA enabled:

```powershell
powershell.exe -STA -NoProfile -Command "Invoke-Pester -Script '.\tests\BreakTime.Tests.ps1' -EnableExit"
```

The suite uses Pester (validated with the installed version 3.4.0); Pester is a development/test dependency, not an app runtime dependency. The 29 October 2026 update passed 36 checks covering elapsed-time accuracy, pause/reset/waiting behaviour, meeting and playback handling, lock/sleep, call-end grace, background scan failures/timeouts, shared live displays, queued reminders, window markup and synthetic call-control fixtures.

Synthetic accessibility fixtures do not access real Teams meeting content. The suite does not launch the BreakTime entry point or modify your settings, but briefly creates non-activating off-screen test windows.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Widget not visible | Right-click tray icon → Show Widget. This will recreate the widget if it was lost. |
| No tray icon appears | Ensure you're running with `-STA` flag. Use `Start-BreakTime.bat`. |
| Console window stays visible | Normal for a moment on first launch. The script hides it via `ShowWindow`. If it persists, use `-WindowStyle Hidden`. |
| Audio detection not working | Check that playback reaches an active Windows output device. All active outputs are sampled. A detection warning prevents automatic idle resets; restart BreakTime if it persists. |
| Widget shows CHECKING | Wait for the initial scan. If "call detection unavailable" or a timeout warning persists, restart BreakTime. Automatic reminders remain held while detection is unavailable. |
| Sitting time resets during a silent video | Audio-based playback detection cannot identify completely silent content. Pause tracking while watching it if needed. |
| Sitting time differs from physical sitting time | This is an estimate based on input, detected audio and calls, not posture. Confirm a break or reset the timer when appropriate. |
| Meeting not detected | Teams requires connected-call controls, not microphone permission. If call detection is unavailable, check for a warning and restart BreakTime. |
| Break appears during meeting | Teams control IDs may have changed; non-Teams apps still use approximate mic/camera and window-title heuristics. |
| Settings don't save | Ensure the script has write permission to the `BreakTime` folder. |
