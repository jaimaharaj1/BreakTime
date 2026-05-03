<#
.SYNOPSIS
    BreakTime - Smart Break Reminder for Windows
.DESCRIPTION
    Tracks continuous sitting time and reminds you to take breaks.
    - Media-aware: watching videos counts as sitting
    - Meeting-aware: defers breaks during calls
    - Idle-aware: walking away from desk counts as a break
    - Always-on-top countdown widget with centered, high-contrast display
    - 3-option break dialog: Take Break, Lock Screen, or Snooze
.NOTES
    Requires PowerShell 5.1+ on Windows 10/11. No external dependencies.
    Run via Start-BreakTime.bat or:
    powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File BreakTime.ps1
#>

# ══════════════════════════════════════════════════════════════
# STA MODE CHECK - WPF requires Single-Threaded Apartment
# ══════════════════════════════════════════════════════════════
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $scriptPath = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $PSCommandPath }
    Start-Process 'powershell.exe' -ArgumentList @(
        '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden', '-File', "`"$scriptPath`""
    )
    return
}

# ══════════════════════════════════════════════════════════════
# ASSEMBLIES — WPF, Windows Forms (tray), and GDI+ (icons)
# ══════════════════════════════════════════════════════════════
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ══════════════════════════════════════════════════════════════
# C# HELPERS — Win32 P/Invoke (idle time, console, lock screen)
#              and WASAPI COM interop (audio peak detection)
# ══════════════════════════════════════════════════════════════
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NativeMethods
{
    // --- Idle time detection ---
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);  // Hide/show windows

    [DllImport("user32.dll")]
    public static extern bool LockWorkStation();  // Lock screen for break

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();  // Get PS console handle

    // Returns seconds since last keyboard/mouse input
    public static double GetIdleSeconds()
    {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) return 0;
        return (Environment.TickCount - (int)lii.dwTime) / 1000.0;
    }

    public static void HideConsole()
    {
        IntPtr hwnd = GetConsoleWindow();
        if (hwnd != IntPtr.Zero) ShowWindow(hwnd, 0);
    }
}

public static class AudioDetector
{
    // WASAPI COM interfaces for reading the system audio peak meter.
    // This detects ANY audio output (music, video, meeting audio, etc.)
    // without requiring third-party libraries.
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumerator { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr ppDevices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams,
            [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation
    {
        int GetPeakValue(out float peak);
    }

    // Get default audio output → read peak value → true if > 0.0001
    public static bool IsAudioPlaying()
    {
        try
        {
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
            IMMDevice device;
            int hr = enumerator.GetDefaultAudioEndpoint(0, 1, out device);
            if (hr != 0 || device == null) return false;

            Guid iid = typeof(IAudioMeterInformation).GUID;
            object obj;
            hr = device.Activate(ref iid, 1, IntPtr.Zero, out obj);
            if (hr != 0 || obj == null) return false;

            var meter = (IAudioMeterInformation)obj;
            float peak;
            meter.GetPeakValue(out peak);
            return peak > 0.0001f;
        }
        catch { return false; }
    }
}
'@

# Hide console window
[NativeMethods]::HideConsole()

# ══════════════════════════════════════════════════════════════
# SCRIPT STATE — All mutable state tracked at script scope
# ══════════════════════════════════════════════════════════════
# Resolve the script's directory — works for both .ps1 and ps2exe .exe
$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
    elseif ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) {
        [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    } else { [System.IO.Directory]::GetCurrentDirectory() }

$script:SettingsPath   = Join-Path $script:ScriptDir 'settings.json'
$script:Settings       = $null
$script:LastBreakTime  = [DateTime]::Now          # Timestamp of last break/reset
$script:State          = 'Tracking'                # Tracking | Deferred | Buffering | Snoozed
$script:SnoozeCount    = 0                         # Snoozes used this break cycle (configurable max)
$script:SnoozedAt      = $null                     # Timestamp when snooze started
$script:MeetingEndedAt = $null                     # Timestamp when meeting ended (for buffer)
$script:ScreenLocked   = $false                    # True while screen is locked
$script:ScreenLockedAt = $null                     # Timestamp when screen was locked
$script:Paused         = $false                    # User paused tracking
$script:PausedElapsed  = $null                     # Sitting minutes elapsed when paused
$script:OverlayShowing = $false                    # Guard against overlapping dialogs
$script:TrayIcon       = $null                     # System tray NotifyIcon
$script:App            = $null                     # WPF Application instance
$script:Widget              = $null                # Floating countdown widget window
$script:WidgetTimer         = $null                # 1-second DispatcherTimer for widget updates
$script:WidgetVisible       = $true                # Widget visibility state
$script:LastMediaDetectedAt = $null                # Last time audio peak was detected
$script:MediaGraceSec       = 30                   # Seconds of silence before confirming no media
$script:OnBreak             = $false               # True while break countdown overlay is active
$script:BreakEndTime        = $null                # When the current break countdown ends
$script:BreakPaused         = $false               # True when idle-gated break is paused (user active; used by countdown timer closure)
$script:BreakRemaining      = 0                    # Seconds remaining in break (used by countdown timer closure)
$script:WaitingForActivity  = $false               # True after break/reset — timer won't start until input detected

# Analytics — event logging and report generation
$script:LogDir              = Join-Path $script:ScriptDir 'logs'
$script:ReportsDir          = Join-Path $script:ScriptDir 'reports'
$script:LastReportDate      = $null                 # Tracks last day a daily report was generated

# ══════════════════════════════════════════════════════════════
# EVENT LOGGING — Append timestamped events to daily JSON files
# ══════════════════════════════════════════════════════════════
function Write-BreakTimeEvent {
    param(
        [string]$EventType,
        [hashtable]$Data = @{}
    )
    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null }
        $dateStr = (Get-Date).ToString('yyyy-MM-dd')
        $logFile = Join-Path $script:LogDir "$dateStr.json"

        $entry = @{
            Timestamp = (Get-Date).ToString('o')
            Event     = $EventType
            SittingMinutes = [Math]::Round((Get-SittingMinutes), 1)
        }
        foreach ($k in $Data.Keys) { $entry[$k] = $Data[$k] }

        $json = $entry | ConvertTo-Json -Compress
        Add-Content -Path $logFile -Value $json -Encoding UTF8
    } catch { }
}

function Get-DailyEvents {
    param([string]$DateStr)  # 'yyyy-MM-dd'
    $logFile = Join-Path $script:LogDir "$DateStr.json"
    if (-not (Test-Path $logFile)) { return @() }
    try {
        $lines = Get-Content $logFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' }
        return $lines | ForEach-Object { $_ | ConvertFrom-Json }
    } catch { return @() }
}

# ══════════════════════════════════════════════════════════════
# DAILY METRICS — Compute analytics from raw event log
# ══════════════════════════════════════════════════════════════
function Get-DailyMetrics {
    param([string]$DateStr)
    $events = Get-DailyEvents -DateStr $DateStr
    if ($events.Count -eq 0) {
        return @{
            Date = $DateStr; HasData = $false
            TotalPrompts = 0; BreaksTaken = 0; BreaksCompleted = 0; BreaksEndedEarly = 0
            LockScreenBreaks = 0; TotalSnoozes = 0; TotalDismissals = 0; TotalResets = 0
            MeetingDeferrals = 0; NaturalBreaks = 0; PauseCount = 0; ScreenLocks = 0
            TotalBreakMinutes = 0; AvgSittingAtPrompt = 0; MaxSittingAtPrompt = 0
            AvgSnoozesPerBreak = 0; BreakComplianceRate = 0; SnoozeRate = 0
            HourlyPrompts = @{}; HourlyBreaks = @{}
            HealthScore = 0
        }
    }

    $prompted = @($events | Where-Object { $_.Event -eq 'BreakPrompted' })
    $taken = @($events | Where-Object { $_.Event -eq 'BreakTaken' })
    $completed = @($events | Where-Object { $_.Event -eq 'BreakCompleted' })
    $endedEarly = @($events | Where-Object { $_.Event -eq 'BreakEndedEarly' })
    $lockBreaks = @($events | Where-Object { $_.Event -eq 'LockScreenBreak' })
    $snoozed = @($events | Where-Object { $_.Event -eq 'Snoozed' })
    $dismissed = @($events | Where-Object { $_.Event -eq 'Dismissed' })
    $resets = @($events | Where-Object { $_.Event -eq 'ResetTimer' })
    $deferred = @($events | Where-Object { $_.Event -eq 'MeetingDeferred' })
    $natural = @($events | Where-Object { $_.Event -eq 'NaturalBreak' })
    $paused = @($events | Where-Object { $_.Event -eq 'Paused' })
    $screenLocks = @($events | Where-Object { $_.Event -eq 'ScreenLocked' })

    # Total breaks = explicit breaks + lock screen breaks + natural breaks
    $totalBreaks = $taken.Count + $lockBreaks.Count + $natural.Count

    # Break time from completed breaks
    $totalBreakMin = 0
    foreach ($evt in $completed) {
        if ($null -ne $evt.BreakDurationSeconds) { $totalBreakMin += $evt.BreakDurationSeconds / 60 }
    }
    foreach ($evt in $endedEarly) {
        if ($null -ne $evt.ElapsedSeconds) { $totalBreakMin += $evt.ElapsedSeconds / 60 }
    }

    # Sitting minutes at prompt time
    $sittingAtPrompt = @($prompted | ForEach-Object { if ($null -ne $_.SittingMinutes) { $_.SittingMinutes } })
    $avgSitting = if ($sittingAtPrompt.Count -gt 0) { ($sittingAtPrompt | Measure-Object -Average).Average } else { 0 }
    $maxSitting = if ($sittingAtPrompt.Count -gt 0) { ($sittingAtPrompt | Measure-Object -Maximum).Maximum } else { 0 }

    # Snooze rate
    $snoozeRate = if ($prompted.Count -gt 0) { [Math]::Round($snoozed.Count / $prompted.Count * 100, 0) } else { 0 }

    # Break compliance: breaks taken out of prompts
    $complianceRate = if ($prompted.Count -gt 0) { [Math]::Round($totalBreaks / $prompted.Count * 100, 0) } else { 0 }
    if ($complianceRate -gt 100) { $complianceRate = 100 }

    # Average snoozes per break cycle (snoozes / total break prompts that resulted in a break)
    $avgSnoozes = if ($totalBreaks -gt 0) { [Math]::Round($snoozed.Count / $totalBreaks, 1) } else { 0 }

    # Hourly distribution
    $hourlyPrompts = @{}
    $hourlyBreaks = @{}
    foreach ($evt in $prompted) {
        $h = ([DateTime]::Parse($evt.Timestamp)).Hour.ToString()
        if (-not $hourlyPrompts.ContainsKey($h)) { $hourlyPrompts[$h] = 0 }
        $hourlyPrompts[$h]++
    }
    foreach ($evt in ($taken + $lockBreaks)) {
        $h = ([DateTime]::Parse($evt.Timestamp)).Hour.ToString()
        if (-not $hourlyBreaks.ContainsKey($h)) { $hourlyBreaks[$h] = 0 }
        $hourlyBreaks[$h]++
    }

    # Health score
    $healthScore = Get-HealthScore -ComplianceRate $complianceRate -SnoozeRate $snoozeRate `
        -CompletedCount $completed.Count -TakenCount $taken.Count -MaxSitting $maxSitting `
        -MeetingDeferrals $deferred.Count -ResetCount $resets.Count

    return @{
        Date = $DateStr; HasData = $true
        TotalPrompts = $prompted.Count; BreaksTaken = $totalBreaks
        BreaksCompleted = $completed.Count; BreaksEndedEarly = $endedEarly.Count
        LockScreenBreaks = $lockBreaks.Count; TotalSnoozes = $snoozed.Count
        TotalDismissals = $dismissed.Count; TotalResets = $resets.Count
        MeetingDeferrals = $deferred.Count; NaturalBreaks = $natural.Count
        PauseCount = $paused.Count; ScreenLocks = $screenLocks.Count
        TotalBreakMinutes = [Math]::Round($totalBreakMin, 1)
        AvgSittingAtPrompt = [Math]::Round($avgSitting, 0)
        MaxSittingAtPrompt = [Math]::Round($maxSitting, 0)
        AvgSnoozesPerBreak = $avgSnoozes
        BreakComplianceRate = $complianceRate; SnoozeRate = $snoozeRate
        HourlyPrompts = $hourlyPrompts; HourlyBreaks = $hourlyBreaks
        HealthScore = $healthScore
    }
}

# ══════════════════════════════════════════════════════════════
# HEALTH SCORE — Weighted 0-100 composite score
# ══════════════════════════════════════════════════════════════
function Get-HealthScore {
    param(
        [double]$ComplianceRate, [double]$SnoozeRate,
        [int]$CompletedCount, [int]$TakenCount,
        [double]$MaxSitting, [int]$MeetingDeferrals, [int]$ResetCount
    )
    # Compliance (40%): direct percentage
    $compScore = [Math]::Min($ComplianceRate, 100)

    # Break quality (20%): completed vs taken (full breaks are better)
    $qualityScore = if ($TakenCount -gt 0) { ($CompletedCount / $TakenCount) * 100 } else { 100 }

    # Low snooze (20%): lower snooze rate = higher score
    $snoozeScore = [Math]::Max(0, 100 - ($SnoozeRate * 1.5))

    # Sitting discipline (15%): penalty for long streaks (>60 min is bad)
    $sittingScore = if ($MaxSitting -le 50) { 100 } elseif ($MaxSitting -le 90) { 100 - (($MaxSitting - 50) * 2.5) } else { 0 }

    # Reset penalty (5%): resets bypass the system
    $resetScore = [Math]::Max(0, 100 - ($ResetCount * 25))

    $weighted = ($compScore * 0.40) + ($qualityScore * 0.20) + ($snoozeScore * 0.20) + ($sittingScore * 0.15) + ($resetScore * 0.05)
    return [Math]::Round([Math]::Min([Math]::Max($weighted, 0), 100), 0)
}

# ══════════════════════════════════════════════════════════════
# HTML REPORT GENERATORS — Daily & Weekly styled reports
# ══════════════════════════════════════════════════════════════

function Get-HealthGrade {
    param([int]$Score)
    if ($Score -ge 90) { return @{ Grade = 'A'; Color = '#4CAF50'; Emoji = [char]::ConvertFromUtf32(0x1F31F) } }  # 🌟
    if ($Score -ge 75) { return @{ Grade = 'B'; Color = '#8BC34A'; Emoji = [char]::ConvertFromUtf32(0x2705) } }   # ✅
    if ($Score -ge 60) { return @{ Grade = 'C'; Color = '#FFC107'; Emoji = [char]::ConvertFromUtf32(0x26A0) } }   # ⚠
    if ($Score -ge 40) { return @{ Grade = 'D'; Color = '#FF9800'; Emoji = [char]::ConvertFromUtf32(0x1F614) } }  # 😔
    return @{ Grade = 'F'; Color = '#F44336'; Emoji = [char]::ConvertFromUtf32(0x1F6A8) } # 🚨
}

function Get-ReportCSS {
    return @"
<style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #1a1a2e; color: #e0e0e0; padding: 24px; }
    .container { max-width: 720px; margin: 0 auto; }
    h1 { color: #00d4ff; font-size: 28px; margin-bottom: 4px; }
    h2 { color: #00d4ff; font-size: 20px; margin: 24px 0 12px; border-bottom: 1px solid #333; padding-bottom: 6px; }
    .subtitle { color: #888; font-size: 14px; margin-bottom: 20px; }
    .score-card { background: #16213e; border-radius: 12px; padding: 24px; text-align: center; margin: 16px 0; }
    .score-big { font-size: 64px; font-weight: bold; line-height: 1.1; }
    .score-label { font-size: 14px; color: #888; margin-top: 4px; }
    .grade-badge { display: inline-block; font-size: 18px; font-weight: bold; padding: 4px 16px; border-radius: 20px; margin-top: 8px; }
    .metrics { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin: 16px 0; }
    .metric-card { background: #16213e; border-radius: 10px; padding: 16px; }
    .metric-value { font-size: 28px; font-weight: bold; color: #00d4ff; }
    .metric-label { font-size: 12px; color: #888; margin-top: 2px; }
    .timeline { background: #16213e; border-radius: 10px; padding: 16px; margin: 16px 0; }
    .timeline-event { padding: 6px 0; border-bottom: 1px solid #222; font-size: 13px; display: flex; justify-content: space-between; }
    .timeline-event:last-child { border-bottom: none; }
    .timeline-time { color: #888; font-family: 'Consolas', monospace; min-width: 60px; }
    .timeline-type { font-weight: 600; min-width: 140px; }
    .event-BreakTaken, .event-BreakCompleted { color: #4CAF50; }
    .event-Snoozed, .event-Dismissed { color: #FF9800; }
    .event-BreakEndedEarly { color: #FFC107; }
    .event-LockScreenBreak, .event-NaturalBreak { color: #8BC34A; }
    .event-MeetingDeferred { color: #9C27B0; }
    .event-ResetTimer { color: #F44336; }
    .event-Paused { color: #FF5722; }
    .event-Resumed, .event-AppStarted { color: #00BCD4; }
    .event-ScreenLocked, .event-ScreenUnlocked { color: #607D8B; }
    .bar-container { background: #0a0a1a; border-radius: 6px; height: 18px; margin: 4px 0; overflow: hidden; }
    .bar-fill { height: 100%; border-radius: 6px; transition: width 0.3s; }
    .insights { background: #16213e; border-radius: 10px; padding: 16px; margin: 16px 0; }
    .insight-item { padding: 6px 0; font-size: 14px; }
    .insight-icon { margin-right: 6px; }
    .footer { text-align: center; color: #555; font-size: 12px; margin-top: 24px; }
    .week-day { background: #16213e; border-radius: 8px; padding: 12px; margin: 8px 0; display: flex; align-items: center; justify-content: space-between; }
    .week-day-name { font-weight: 600; min-width: 90px; }
    .week-day-score { font-size: 24px; font-weight: bold; min-width: 50px; text-align: center; }
    .week-day-stats { font-size: 12px; color: #888; }
</style>
"@
}

function New-DailyReport {
    param([string]$Date)
    if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }

    $metrics = Get-DailyMetrics -Date $Date
    if (-not $metrics -or $metrics.TotalPrompts -eq 0) { return $null }

    $healthScore = Get-HealthScore -ComplianceRate $metrics.ComplianceRate -SnoozeRate $metrics.SnoozeRate `
        -CompletedCount $metrics.BreaksCompleted -TakenCount $metrics.BreaksTaken `
        -MaxSitting $metrics.MaxSittingStreak -MeetingDeferrals $metrics.MeetingDeferrals -ResetCount $metrics.TimerResets
    $grade = Get-HealthGrade $healthScore

    $events = Get-DailyEvents -Date $Date
    $displayDate = ([DateTime]::ParseExact($Date, 'yyyy-MM-dd', $null)).ToString('dddd, MMMM d, yyyy')

    # Build timeline HTML
    $timelineHtml = ""
    $eventTypeFriendly = @{
        'BreakPrompted' = 'Break Prompted'; 'BreakTaken' = 'Break Taken'; 'BreakCompleted' = 'Break Completed'
        'BreakEndedEarly' = 'Ended Early'; 'LockScreenBreak' = 'Lock Screen'; 'Snoozed' = 'Snoozed'
        'Dismissed' = 'Dismissed'; 'ResetTimer' = 'Timer Reset'; 'MeetingDeferred' = 'Meeting Deferred'
        'NaturalBreak' = 'Natural Break'; 'Paused' = 'Paused'; 'Resumed' = 'Resumed'
        'ScreenLocked' = 'Screen Locked'; 'ScreenUnlocked' = 'Screen Unlocked'
        'AppStarted' = 'App Started'; 'AppStopped' = 'App Stopped'
    }
    foreach ($evt in $events) {
        $time = ([DateTime]::Parse($evt.Timestamp)).ToString('HH:mm')
        $typeName = if ($eventTypeFriendly[$evt.Event]) { $eventTypeFriendly[$evt.Event] } else { $evt.Event }
        $detail = ''
        if ($evt.Event -eq 'Snoozed' -and $evt.Data.SnoozeNumber) { $detail = "#$($evt.Data.SnoozeNumber) of $($evt.Data.MaxSnoozes)" }
        elseif ($evt.Event -eq 'BreakEndedEarly' -and $evt.Data.ElapsedSeconds) { $detail = "$([Math]::Round($evt.Data.ElapsedSeconds/60, 1))m of $([Math]::Round($evt.Data.TotalSeconds/60, 1))m" }
        elseif ($evt.Event -eq 'MeetingDeferred' -and $evt.Data.SittingMinutes) { $detail = "at $($evt.Data.SittingMinutes)m" }
        elseif ($evt.Event -eq 'ScreenUnlocked' -and $evt.Data.LockedMinutes) { $detail = "$($evt.Data.LockedMinutes)m away" }
        elseif ($evt.Event -eq 'ResetTimer' -and $evt.Data.Source) { $detail = "via $($evt.Data.Source)" }
        $detailSpan = if ($detail) { "<span style='color:#666;margin-left:8px;'>$detail</span>" } else { '' }
        $timelineHtml += "<div class='timeline-event'><span class='timeline-time'>$time</span><span class='timeline-type event-$($evt.Event)'>$typeName</span>$detailSpan</div>`n"
    }

    # Generate insights
    $insightsHtml = ""
    if ($metrics.ComplianceRate -ge 80) {
        $insightsHtml += "<div class='insight-item'><span class='insight-icon'>$([char]::ConvertFromUtf32(0x1F3C6))</span>Great compliance today &mdash; $([Math]::Round($metrics.ComplianceRate))% of prompts led to breaks!</div>`n"
    } elseif ($metrics.ComplianceRate -lt 50) {
        $insightsHtml += "<div class='insight-item'><span class='insight-icon'>$([char]::ConvertFromUtf32(0x1F4AA))</span>Room for improvement &mdash; only $([Math]::Round($metrics.ComplianceRate))% compliance today.</div>`n"
    }
    if ($metrics.MaxSittingStreak -gt 60) {
        $insightsHtml += "<div class='insight-item'><span class='insight-icon'>$([char]::ConvertFromUtf32(0x1FA91))</span>Longest sitting streak was $($metrics.MaxSittingStreak) min &mdash; try to keep it under 60.</div>`n"
    }
    if ($metrics.MeetingDeferrals -gt 2) {
        $insightsHtml += "<div class='insight-item'><span class='insight-icon'>$([char]::ConvertFromUtf32(0x1F4C5))</span>$($metrics.MeetingDeferrals) meeting deferrals today. Consider scheduling breaks between meetings.</div>`n"
    }
    if ($metrics.NaturalBreaks -gt 0) {
        $insightsHtml += "<div class='insight-item'><span class='insight-icon'>$([char]::ConvertFromUtf32(0x1F6B6))</span>$($metrics.NaturalBreaks) natural break(s) detected &mdash; good job stepping away!</div>`n"
    }
    if ($metrics.SnoozeRate -gt 50) {
        $insightsHtml += "<div class='insight-item'><span class='insight-icon'>$([char]::ConvertFromUtf32(0x23F0))</span>High snooze rate ($([Math]::Round($metrics.SnoozeRate))%). Try taking breaks on the first prompt.</div>`n"
    }
    if (-not $insightsHtml) {
        $insightsHtml = "<div class='insight-item'><span class='insight-icon'>$([char]::ConvertFromUtf32(0x2728))</span>Solid day! Keep up the healthy habits.</div>`n"
    }

    $compPct = [Math]::Min([Math]::Round($metrics.ComplianceRate), 100)
    $snoozePct = [Math]::Min([Math]::Round($metrics.SnoozeRate), 100)

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>BreakTime Daily Report - $Date</title>
    $(Get-ReportCSS)
</head>
<body>
<div class="container">
    <h1>$([char]::ConvertFromUtf32(0x2615)) BreakTime Daily Report</h1>
    <div class="subtitle">$displayDate</div>

    <div class="score-card">
        <div class="score-big" style="color: $($grade.Color);">$healthScore</div>
        <div class="score-label">Health Score</div>
        <div class="grade-badge" style="background: $($grade.Color); color: #fff;">$($grade.Emoji) Grade $($grade.Grade)</div>
    </div>

    <h2>$([char]::ConvertFromUtf32(0x1F4CA)) Key Metrics</h2>
    <div class="metrics">
        <div class="metric-card">
            <div class="metric-value">$($metrics.BreaksTaken + $metrics.LockScreenBreaks + $metrics.NaturalBreaks)</div>
            <div class="metric-label">Total Breaks</div>
        </div>
        <div class="metric-card">
            <div class="metric-value">$($metrics.TotalPrompts)</div>
            <div class="metric-label">Prompts Shown</div>
        </div>
        <div class="metric-card">
            <div class="metric-value">$($metrics.BreaksCompleted)</div>
            <div class="metric-label">Full Breaks Completed</div>
        </div>
        <div class="metric-card">
            <div class="metric-value">$($metrics.MeetingDeferrals)</div>
            <div class="metric-label">Meeting Deferrals</div>
        </div>
    </div>

    <div style="margin: 12px 0;">
        <div style="font-size:13px; margin-bottom:4px;">Compliance Rate: <strong>$compPct%</strong></div>
        <div class="bar-container"><div class="bar-fill" style="width:${compPct}%; background: linear-gradient(90deg, #00d4ff, #4CAF50);"></div></div>
    </div>
    <div style="margin: 12px 0;">
        <div style="font-size:13px; margin-bottom:4px;">Snooze Rate: <strong>$snoozePct%</strong></div>
        <div class="bar-container"><div class="bar-fill" style="width:${snoozePct}%; background: linear-gradient(90deg, #FF9800, #F44336);"></div></div>
    </div>

    <h2>$([char]::ConvertFromUtf32(0x1F4A1)) Insights</h2>
    <div class="insights">
        $insightsHtml
    </div>

    <h2>$([char]::ConvertFromUtf32(0x1F4C5)) Activity Timeline</h2>
    <div class="timeline">
        $timelineHtml
    </div>

    <div class="footer">Generated by BreakTime on $(Get-Date -Format 'yyyy-MM-dd HH:mm') &bull; Stay healthy, take breaks!</div>
</div>
</body>
</html>
"@

    if (-not (Test-Path $script:ReportsDir)) { New-Item -Path $script:ReportsDir -ItemType Directory -Force | Out-Null }
    $reportPath = Join-Path $script:ReportsDir "daily-$Date.html"
    $html | Set-Content $reportPath -Encoding UTF8
    return $reportPath
}

function New-WeeklyReport {
    param([DateTime]$WeekEndDate)
    if (-not $WeekEndDate) { $WeekEndDate = (Get-Date).Date }

    # Find the Monday-Sunday range for the week ending on WeekEndDate
    $dayOfWeek = [int]$WeekEndDate.DayOfWeek
    $sundayOffset = if ($dayOfWeek -eq 0) { 0 } else { 7 - $dayOfWeek }
    $weekEnd = $WeekEndDate.AddDays($sundayOffset)
    $weekStart = $weekEnd.AddDays(-6)

    $dailyData = @()
    $allBreaks = 0; $allPrompts = 0; $allCompleted = 0; $allSnoozes = 0; $allResets = 0
    $allNatural = 0; $allDeferred = 0; $maxSitting = 0; $daysActive = 0

    for ($i = 0; $i -lt 7; $i++) {
        $d = $weekStart.AddDays($i)
        $dateStr = $d.ToString('yyyy-MM-dd')
        $m = Get-DailyMetrics -Date $dateStr
        if ($m -and $m.TotalPrompts -gt 0) {
            $daysActive++
            $score = Get-HealthScore -ComplianceRate $m.ComplianceRate -SnoozeRate $m.SnoozeRate `
                -CompletedCount $m.BreaksCompleted -TakenCount $m.BreaksTaken `
                -MaxSitting $m.MaxSittingStreak -MeetingDeferrals $m.MeetingDeferrals -ResetCount $m.TimerResets
            $dailyData += @{ Date = $d; Metrics = $m; Score = $score }
            $allBreaks += $m.BreaksTaken + $m.LockScreenBreaks + $m.NaturalBreaks
            $allPrompts += $m.TotalPrompts
            $allCompleted += $m.BreaksCompleted
            $allSnoozes += $m.Snoozes
            $allResets += $m.TimerResets
            $allNatural += $m.NaturalBreaks
            $allDeferred += $m.MeetingDeferrals
            if ($m.MaxSittingStreak -gt $maxSitting) { $maxSitting = $m.MaxSittingStreak }
        } else {
            $dailyData += @{ Date = $d; Metrics = $null; Score = $null }
        }
    }

    if ($daysActive -eq 0) { return $null }

    $avgScore = [Math]::Round(($dailyData | Where-Object { $_.Score -ne $null } | ForEach-Object { $_.Score } | Measure-Object -Average).Average, 0)
    $avgCompliance = if ($allPrompts -gt 0) { [Math]::Round(($allBreaks / $allPrompts) * 100, 0) } else { 0 }
    $avgSnoozeRate = if ($allPrompts -gt 0) { [Math]::Round(($allSnoozes / $allPrompts) * 100, 0) } else { 0 }
    $grade = Get-HealthGrade $avgScore

    $weekRangeStr = "$($weekStart.ToString('MMM d')) - $($weekEnd.ToString('MMM d, yyyy'))"

    # Build daily breakdown
    $dayNames = @('Mon','Tue','Wed','Thu','Fri','Sat','Sun')
    $dayRowsHtml = ""
    for ($i = 0; $i -lt 7; $i++) {
        $dd = $dailyData[$i]
        $dayLabel = $dd.Date.ToString('ddd MMM d')
        if ($dd.Score -ne $null) {
            $dGrade = Get-HealthGrade $dd.Score
            $breaks = $dd.Metrics.BreaksTaken + $dd.Metrics.LockScreenBreaks + $dd.Metrics.NaturalBreaks
            $dayRowsHtml += @"
        <div class='week-day'>
            <span class='week-day-name'>$dayLabel</span>
            <span class='week-day-score' style='color:$($dGrade.Color);'>$($dd.Score)</span>
            <span class='week-day-stats'>$breaks breaks / $($dd.Metrics.TotalPrompts) prompts / $([Math]::Round($dd.Metrics.ComplianceRate))% compliance</span>
        </div>
"@
        } else {
            $dayRowsHtml += @"
        <div class='week-day' style='opacity:0.4;'>
            <span class='week-day-name'>$dayLabel</span>
            <span class='week-day-score'>-</span>
            <span class='week-day-stats'>No activity</span>
        </div>
"@
        }
    }

    # Trend analysis
    $scores = $dailyData | Where-Object { $_.Score -ne $null } | ForEach-Object { $_.Score }
    $trendHtml = ""
    if ($scores.Count -ge 2) {
        $first = $scores[0]; $last = $scores[-1]
        if ($last -gt $first + 5) {
            $trendHtml = "<div class='insight-item'><span class='insight-icon'>$([char]::ConvertFromUtf32(0x1F4C8))</span>Upward trend! Your health score improved from $first to $last this week.</div>"
        } elseif ($last -lt $first - 5) {
            $trendHtml = "<div class='insight-item'><span class='insight-icon'>$([char]::ConvertFromUtf32(0x1F4C9))</span>Downward trend. Your score went from $first to $last. Try to be more consistent.</div>"
        } else {
            $trendHtml = "<div class='insight-item'><span class='insight-icon'>$([char]::ConvertFromUtf32(0x27A1))</span>Steady week &mdash; scores stayed consistent around $avgScore.</div>"
        }
    }
    $weekInsightsHtml = $trendHtml
    if ($allBreaks -gt 0) {
        $weekInsightsHtml += "<div class='insight-item'><span class='insight-icon'>$([char]::ConvertFromUtf32(0x2615))</span>You took $allBreaks breaks across $daysActive active day(s) this week.</div>"
    }
    if ($allDeferred -gt 3) {
        $weekInsightsHtml += "<div class='insight-item'><span class='insight-icon'>$([char]::ConvertFromUtf32(0x1F4C5))</span>$allDeferred meeting deferrals &mdash; block short break slots between meetings.</div>"
    }
    if ($allNatural -gt 0) {
        $weekInsightsHtml += "<div class='insight-item'><span class='insight-icon'>$([char]::ConvertFromUtf32(0x1F6B6))</span>$allNatural natural breaks detected. Your body knows when to move!</div>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>BreakTime Weekly Report - $weekRangeStr</title>
    $(Get-ReportCSS)
</head>
<body>
<div class="container">
    <h1>$([char]::ConvertFromUtf32(0x1F4CA)) BreakTime Weekly Report</h1>
    <div class="subtitle">$weekRangeStr</div>

    <div class="score-card">
        <div class="score-big" style="color: $($grade.Color);">$avgScore</div>
        <div class="score-label">Average Health Score</div>
        <div class="grade-badge" style="background: $($grade.Color); color: #fff;">$($grade.Emoji) Grade $($grade.Grade)</div>
    </div>

    <h2>$([char]::ConvertFromUtf32(0x1F4CA)) Weekly Summary</h2>
    <div class="metrics">
        <div class="metric-card">
            <div class="metric-value">$allBreaks</div>
            <div class="metric-label">Total Breaks</div>
        </div>
        <div class="metric-card">
            <div class="metric-value">$allPrompts</div>
            <div class="metric-label">Total Prompts</div>
        </div>
        <div class="metric-card">
            <div class="metric-value">$avgCompliance%</div>
            <div class="metric-label">Avg Compliance</div>
        </div>
        <div class="metric-card">
            <div class="metric-value">$daysActive</div>
            <div class="metric-label">Active Days</div>
        </div>
    </div>

    <h2>$([char]::ConvertFromUtf32(0x1F5D3)) Daily Breakdown</h2>
    $dayRowsHtml

    <h2>$([char]::ConvertFromUtf32(0x1F4A1)) Weekly Insights</h2>
    <div class="insights">
        $weekInsightsHtml
    </div>

    <div class="footer">Generated by BreakTime on $(Get-Date -Format 'yyyy-MM-dd HH:mm') &bull; Stay healthy, take breaks!</div>
</div>
</body>
</html>
"@

    if (-not (Test-Path $script:ReportsDir)) { New-Item -Path $script:ReportsDir -ItemType Directory -Force | Out-Null }
    $reportPath = Join-Path $script:ReportsDir "weekly-$($weekStart.ToString('yyyy-MM-dd')).html"
    $html | Set-Content $reportPath -Encoding UTF8
    return $reportPath
}

# ══════════════════════════════════════════════════════════════
# SETTINGS MANAGEMENT — Load/save from settings.json
# ══════════════════════════════════════════════════════════════
$script:DefaultSettings = @{
    BreakIntervalMinutes     = 45
    BreakDurationMinutes     = 3
    PostMeetingBufferMinutes = 2
    IdleThresholdMinutes     = 2
    MaxSnoozes               = 3
}

function Load-Settings {
    try {
        if (Test-Path $script:SettingsPath) {
            $json = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
            $script:Settings = @{
                BreakIntervalMinutes     = [int]($json.BreakIntervalMinutes)
                BreakDurationMinutes     = [int]($json.BreakDurationMinutes)
                PostMeetingBufferMinutes = [int]($json.PostMeetingBufferMinutes)
                IdleThresholdMinutes     = [int]($json.IdleThresholdMinutes)
                MaxSnoozes               = if ($null -ne $json.MaxSnoozes) { [int]($json.MaxSnoozes) } else { 3 }
            }
        } else {
            $script:Settings = $script:DefaultSettings.Clone()
            Save-Settings
        }
    } catch {
        $script:Settings = $script:DefaultSettings.Clone()
    }
}

function Save-Settings {
    try {
        $script:Settings | ConvertTo-Json | Set-Content $script:SettingsPath -Encoding UTF8
    } catch { }
}

function Toggle-Pause {
    param([System.Windows.Forms.ToolStripMenuItem]$MenuItem)
    $script:Paused = -not $script:Paused
    if ($script:Paused) {
        $script:PausedElapsed = (Get-SittingMinutes)
        if ($MenuItem) { $MenuItem.Text = "Resume" }
        Write-BreakTimeEvent 'Paused'
    } else {
        if ($null -ne $script:PausedElapsed) {
            $script:LastBreakTime = [DateTime]::Now.AddMinutes(-$script:PausedElapsed)
            $script:PausedElapsed = $null
        }
        if ($MenuItem) { $MenuItem.Text = "Pause" }
        Write-BreakTimeEvent 'Resumed'
    }
    Update-TrayIcon
    Update-Widget
}

function Update-SettingsFromUI {
    param([int]$Interval, [int]$Duration, [int]$Buffer, [int]$Idle, [int]$MaxSnoozes)
    $script:Settings.BreakIntervalMinutes     = $Interval
    $script:Settings.BreakDurationMinutes     = $Duration
    $script:Settings.PostMeetingBufferMinutes = $Buffer
    $script:Settings.IdleThresholdMinutes     = $Idle
    $script:Settings.MaxSnoozes               = $MaxSnoozes
    Save-Settings
}

# ══════════════════════════════════════════════════════════════
# DETECTION FUNCTIONS — Media, meetings, idle, natural breaks
# ══════════════════════════════════════════════════════════════
function Test-MediaPlaying {
    try { return [AudioDetector]::IsAudioPlaying() }
    catch { return $false }
}

function Test-DeviceInUse {
    # Checks Windows ConsentStore registry for active mic/webcam usage.
    # If LastUsedTimeStart > LastUsedTimeStop for any app, device is in use.
    param([string]$DeviceType) # 'microphone' or 'webcam'
    $basePath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$DeviceType"
    try {
        if (-not (Test-Path $basePath)) { return $false }
        $appKeys = Get-ChildItem $basePath -Recurse -ErrorAction SilentlyContinue |
                   Where-Object { $_.Property -contains 'LastUsedTimeStart' }
        foreach ($key in $appKeys) {
            $props = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
            if ($null -ne $props.LastUsedTimeStart -and $null -ne $props.LastUsedTimeStop) {
                if ([long]$props.LastUsedTimeStart -gt [long]$props.LastUsedTimeStop) {
                    return $true
                }
            }
        }
    } catch { }
    return $false
}

function Test-InMeeting {
    # Primary: check mic/camera registry state (works for any app).
    # Backup: scan for known meeting app processes with active windows.
    if (Test-DeviceInUse 'microphone') { return $true }
    if (Test-DeviceInUse 'webcam') { return $true }

    # Backup: check known meeting app processes
    $meetingApps = @('ms-teams', 'Teams', 'Zoom', 'webexmeetings', 'slack')
    foreach ($app in $meetingApps) {
        $procs = Get-Process -Name $app -ErrorAction SilentlyContinue
        if ($procs | Where-Object { $_.MainWindowTitle -match 'Meeting|Call|Sharing|Webex' }) {
            return $true
        }
    }
    return $false
}

function Update-MediaActivity {
    # Called every tick — updates the last-detected timestamp if audio is playing.
    # This avoids single-point-in-time false negatives during quiet video moments.
    if (Test-MediaPlaying) {
        $script:LastMediaDetectedAt = [DateTime]::Now
    }
}

function Test-MediaRecentlyActive {
    # Returns $true if audio was detected within the grace window (default 30s).
    # Covers dialogue pauses, scene transitions, and buffering in videos.
    if ($null -eq $script:LastMediaDetectedAt) { return $false }
    $elapsed = ([DateTime]::Now - $script:LastMediaDetectedAt).TotalSeconds
    return ($elapsed -lt $script:MediaGraceSec)
}

function Test-NaturalBreak {
    # No input AND no recent media for threshold = walked away = break.
    # Skip if screen is locked — lock detection handles that case on unlock.
    if ($script:ScreenLocked) { return $false }
    $idleSeconds = [NativeMethods]::GetIdleSeconds()
    $thresholdSeconds = $script:Settings.IdleThresholdMinutes * 60
    if ($idleSeconds -ge $thresholdSeconds -and -not (Test-MediaRecentlyActive)) {
        return $true
    }
    return $false
}

function Get-SittingMinutes {
    return ([DateTime]::Now - $script:LastBreakTime).TotalMinutes
}

function Reset-SittingTimer {
    # Resets all tracking state — called after breaks, screen unlock, or manual reset.
    # Sets WaitingForActivity so the timer doesn't start until the user is back at the keyboard.
    $script:LastBreakTime = [DateTime]::Now
    $script:State = 'Tracking'
    $script:SnoozeCount = 0
    $script:SnoozedAt = $null
    $script:MeetingEndedAt = $null
    $script:LastMediaDetectedAt = $null
    $script:WaitingForActivity = $true
    Update-TrayIcon
    Update-Widget
}

# ══════════════════════════════════════════════════════════════
# SCREEN LOCK DETECTION — SessionSwitch events
# ══════════════════════════════════════════════════════════════
$sessionSwitchHandler = {
    param($sender, $e)
    if ($e.Reason -eq [Microsoft.Win32.SessionSwitchReason]::SessionLock) {
        $script:ScreenLocked = $true
        $script:ScreenLockedAt = [DateTime]::Now
        Write-BreakTimeEvent 'ScreenLocked'
    }
    if ($e.Reason -eq [Microsoft.Win32.SessionSwitchReason]::SessionUnlock) {
        $script:ScreenLocked = $false
        $lockedMinutes = 0
        if ($script:ScreenLockedAt) {
            $lockedMinutes = ([DateTime]::Now - $script:ScreenLockedAt).TotalMinutes
            if ($lockedMinutes -ge $script:Settings.IdleThresholdMinutes) {
                Reset-SittingTimer
            }
        }
        Write-BreakTimeEvent 'ScreenUnlocked' @{ LockedMinutes = [Math]::Round($lockedMinutes, 1) }
        $script:ScreenLockedAt = $null
    }
}
[Microsoft.Win32.SystemEvents]::add_SessionSwitch($sessionSwitchHandler)

# ══════════════════════════════════════════════════════════════
# ICON CREATION — Programmatic colored circles via GDI+
# ══════════════════════════════════════════════════════════════
function New-CircleIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $brush = New-Object System.Drawing.SolidBrush $Color
    $g.FillEllipse($brush, 1, 1, 14, 14)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(80, 255, 255, 255)), 1
    $g.DrawEllipse($pen, 1, 1, 14, 14)
    $g.Dispose(); $brush.Dispose(); $pen.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    return $icon
}

# Pre-create tray icons for each state
$script:IconGreen  = New-CircleIcon ([System.Drawing.Color]::FromArgb(76, 175, 80))   # Tracking
$script:IconOrange = New-CircleIcon ([System.Drawing.Color]::FromArgb(255, 152, 0))   # Break soon / snoozed
$script:IconRed    = New-CircleIcon ([System.Drawing.Color]::FromArgb(244, 67, 54))   # Overdue
$script:IconGray   = New-CircleIcon ([System.Drawing.Color]::FromArgb(158, 158, 158)) # Paused

function Update-TrayIcon {
    if (-not $script:TrayIcon) { return }
    $sitting = [int](Get-SittingMinutes)
    $interval = $script:Settings.BreakIntervalMinutes

    if ($script:Paused) {
        $script:TrayIcon.Icon = $script:IconGray
        $script:TrayIcon.Text = "BreakTime - Paused"
    } elseif ($sitting -ge $interval) {
        $script:TrayIcon.Icon = $script:IconRed
        $script:TrayIcon.Text = "BreakTime - Break overdue! ($sitting min)"
    } elseif ($sitting -ge ($interval - 5)) {
        $script:TrayIcon.Icon = $script:IconOrange
        $script:TrayIcon.Text = "BreakTime - Break soon ($sitting/$interval min)"
    } else {
        $script:TrayIcon.Icon = $script:IconGreen
        $script:TrayIcon.Text = "BreakTime - Sitting: $sitting/$interval min"
    }
}

# ══════════════════════════════════════════════════════════════
# ALWAYS-ON-TOP COUNTDOWN WIDGET — Centered, high-contrast
# ══════════════════════════════════════════════════════════════
function Initialize-Widget {
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        Width="200" Height="90" Left="10" Top="10">
    <Border Name="WidgetBorder" Background="#CC1a1a2e" CornerRadius="12"
            BorderBrush="#88667799" BorderThickness="2" Padding="0">
        <Border.Effect>
            <DropShadowEffect BlurRadius="16" ShadowDepth="3" Opacity="0.45" Color="Black"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="20"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <!-- Title bar with drag + minimize/close -->
            <Grid Grid.Row="0" Name="TitleBar" Background="Transparent">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="BreakTime" FontSize="9" Foreground="#88AABBCC"
                           VerticalAlignment="Center" Margin="10,0,0,0" FontFamily="Segoe UI"/>
                <Button Name="MinBtn" Grid.Column="1" Content="&#x2014;" FontSize="9"
                        Width="24" Height="20" Padding="0,-2,0,0"
                        Background="Transparent" Foreground="#AABBC5CF" BorderThickness="0"
                        Cursor="Hand" FontFamily="Segoe UI" VerticalContentAlignment="Center"
                        HorizontalContentAlignment="Center"/>
                <Button Name="CloseBtn" Grid.Column="2" Content="&#x2715;" FontSize="9"
                        Width="24" Height="20" Padding="0,-1,0,0"
                        Background="Transparent" Foreground="#AABBC5CF" BorderThickness="0"
                        Cursor="Hand" FontFamily="Segoe UI" VerticalContentAlignment="Center"
                        HorizontalContentAlignment="Center"/>
            </Grid>
            <!-- Timer content - centered -->
            <StackPanel Grid.Row="1" HorizontalAlignment="Center" VerticalAlignment="Center"
                        Margin="0,0,0,8">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <TextBlock Name="WidgetIcon" Text="&#x23F1;" FontSize="30"
                               Foreground="#DDEEF0F2" VerticalAlignment="Center"
                               Margin="0,0,8,0"/>
                    <TextBlock Name="WidgetTime" Text="45:00" FontSize="26" FontWeight="Bold"
                               Foreground="#4FC3F7" FontFamily="Consolas"
                               VerticalAlignment="Center"/>
                </StackPanel>
                <TextBlock Name="WidgetStatus" Text="until break" FontSize="11"
                           Foreground="#BBCFD8DC" FontFamily="Segoe UI"
                           HorizontalAlignment="Center" Margin="0,1,0,0"/>
            </StackPanel>
        </Grid>
    </Border>
</Window>
"@

    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    $script:Widget = [System.Windows.Markup.XamlReader]::Load($reader)

    # Title bar drag (try-catch: DragMove throws if mouse button isn't held)
    $titleBar = $script:Widget.FindName('TitleBar')
    $titleBar.Add_MouseLeftButtonDown({
        param($s, $e)
        try { $script:Widget.DragMove() } catch { }
    })

    # Also allow dragging from the content area
    $script:Widget.Add_MouseLeftButtonDown({
        param($s, $e)
        try { $s.DragMove() } catch { }
    })

    # Minimize button — hides widget, can re-show from tray
    $minBtn = $script:Widget.FindName('MinBtn')
    $minBtn.Add_Click({
        $script:Widget.Hide()
        $script:WidgetVisible = $false
    })

    # Close button — hides widget, timer keeps running
    $closeBtn = $script:Widget.FindName('CloseBtn')
    $closeBtn.Add_Click({
        $script:Widget.Hide()
        $script:WidgetVisible = $false
    })

    # Widget update timer (every 1 second for smooth countdown)
    $script:WidgetTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:WidgetTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:WidgetTimer.Add_Tick({ Update-Widget })
    $script:WidgetTimer.Start()

    $script:Widget.Show()
    $script:WidgetVisible = $true
}

function Update-Widget {
    # Updates the widget display every 1 second.
    # Shows different content and colors based on current state:
    #   Paused, On Break, Deferred, Snoozed, Overdue, Warning (<5 min), Normal
    if (-not $script:Widget) { return }

    $widgetTime   = $script:Widget.FindName('WidgetTime')
    $widgetStatus = $script:Widget.FindName('WidgetStatus')
    $widgetIcon   = $script:Widget.FindName('WidgetIcon')
    $widgetBorder = $script:Widget.FindName('WidgetBorder')
    if (-not $widgetTime) { return }

    $sitting  = (Get-SittingMinutes)
    $interval = $script:Settings.BreakIntervalMinutes
    $remainMinutes = $interval - $sitting

    if ($script:Paused) {
        $widgetTime.Text = "PAUSED"
        $widgetTime.FontSize = 22
        $widgetTime.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#CCAAAAAA')
        $widgetStatus.Text = ""
        $widgetIcon.Text = [char]0x23F8  # ⏸
        $widgetIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#CCAAAAAA')
        $widgetBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#55667799')
        return
    }

    # Waiting for activity after break/reset — don't count sitting time yet
    if ($script:WaitingForActivity) {
        $widgetTime.Text = "Ready"
        $widgetTime.FontSize = 24
        $widgetTime.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#66BB6A')
        $widgetStatus.Text = "waiting for activity"
        $widgetIcon.Text = [char]0x2705  # ✅
        $widgetIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#66BB6A')
        $widgetBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#66BB6A')
        return
    }

    # Active break — show simple "On Break!" status (no timer, avoids closure scoping issues)
    if ($script:OnBreak) {
        $widgetTime.Text = "On Break!"
        $widgetTime.FontSize = 22
        $widgetTime.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#66BB6A')
        $widgetStatus.Text = "stretch & walk around"
        $widgetIcon.Text = [char]0x2615  # ☕
        $widgetIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#66BB6A')
        $widgetBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#66BB6A')
        return
    }

    $widgetTime.FontSize = 26

    if ($script:State -eq 'Deferred') {
        $widgetTime.Text = "MEETING"
        $widgetTime.FontSize = 20
        $widgetTime.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#4FC3F7')
        $widgetStatus.Text = "break deferred"
        $widgetIcon.Text = [char]::ConvertFromUtf32(0x1F3A4)  # 🎤
        $widgetIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#4FC3F7')
        $widgetBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#4FC3F7')
        return
    }

    if ($script:State -eq 'Snoozed') {
        $snoozeLeft = 3 - ([DateTime]::Now - $script:SnoozedAt).TotalMinutes
        if ($snoozeLeft -lt 0) { $snoozeLeft = 0 }
        $snoozeSec = [int]($snoozeLeft * 60)
        $m = [Math]::Floor($snoozeSec / 60)
        $s = $snoozeSec % 60
        $widgetTime.Text = '{0}:{1:D2}' -f $m, $s
        $widgetTime.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF9800')
        $widgetStatus.Text = "snooze left"
        $widgetIcon.Text = [char]0x23F8
        $widgetIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF9800')
        $widgetBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF9800')
        return
    }

    if ($remainMinutes -le 0) {
        $overdue = [int][Math]::Abs($remainMinutes)
        $widgetTime.Text = "BREAK!"
        $widgetTime.FontSize = 24
        $widgetTime.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F44336')
        $widgetStatus.Text = "$overdue min overdue"
        $widgetIcon.Text = [char]0x26A0  # ⚠
        $widgetIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F44336')
        $widgetBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F44336')
    } elseif ($remainMinutes -le 5) {
        $totalSec = [int]($remainMinutes * 60)
        $m = [Math]::Floor($totalSec / 60)
        $s = $totalSec % 60
        $widgetTime.Text = '{0}:{1:D2}' -f $m, $s
        $widgetTime.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF9800')
        $widgetStatus.Text = "break soon"
        $widgetIcon.Text = [char]0x23F1
        $widgetIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF9800')
        $widgetBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF9800')
    } else {
        $totalSec = [int]($remainMinutes * 60)
        $m = [Math]::Floor($totalSec / 60)
        $s = $totalSec % 60
        $widgetTime.Text = '{0}:{1:D2}' -f $m, $s
        $widgetTime.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#4FC3F7')
        $widgetStatus.Text = "until break"
        $widgetIcon.Text = [char]0x23F1
        $widgetIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#DDEEF0F2')
        $widgetBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#88667799')
    }
}

# ══════════════════════════════════════════════════════════════
# BREAK PROMPT DIALOG — 3-option high-contrast dialog
# ══════════════════════════════════════════════════════════════
function Show-BreakPrompt {
    param([bool]$AllowSnooze = $true)

    $script:OverlayShowing = $true
    Write-BreakTimeEvent 'BreakPrompted' @{ AllowSnooze = $AllowSnooze; SnoozeCount = $script:SnoozeCount }

    # Determine UI visibility based on snooze allowance
    $snoozeVisibility = if ($AllowSnooze) { 'Visible' } else { 'Collapsed' }
    $closeVisibility = if ($AllowSnooze) { 'Visible' } else { 'Collapsed' }
    $maxSnoozes = $script:Settings.MaxSnoozes
    $snoozesRemaining = $maxSnoozes - $script:SnoozeCount
    $mandatoryNote = if (-not $AllowSnooze) {
        '<TextBlock Text="All snoozes used - please take a break" FontSize="12" Foreground="#EF5350" HorizontalAlignment="Center" Margin="0,0,0,4" FontFamily="Segoe UI"/>'
    } elseif ($snoozesRemaining -le $maxSnoozes -and $snoozesRemaining -gt 0) {
        "<TextBlock Text=`"$snoozesRemaining snooze$(if ($snoozesRemaining -ne 1) { 's' }) remaining`" FontSize=`"12`" Foreground=`"#FFB74D`" HorizontalAlignment=`"Center`" Margin=`"0,0,0,4`" FontFamily=`"Segoe UI`"/>"
    } else { '' }

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="CenterScreen" SizeToContent="WidthAndHeight"
        Topmost="True" ShowInTaskbar="True" ResizeMode="NoResize"
        Title="BreakTime - Break Reminder">
    <Border Background="#DD1a1a2e" CornerRadius="16" BorderBrush="#88667799"
            BorderThickness="2" Padding="0">
        <Border.Effect>
            <DropShadowEffect BlurRadius="24" ShadowDepth="5" Opacity="0.5" Color="Black"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="30"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <!-- Title bar -->
            <Grid Grid.Row="0" Name="PromptTitleBar" Background="Transparent">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="BreakTime" FontSize="11" Foreground="#88AABBCC"
                           VerticalAlignment="Center" Margin="16,0,0,0" FontFamily="Segoe UI"/>
                <Button Name="PromptCloseBtn" Grid.Column="1" Content="&#x2715;" FontSize="11"
                        Width="34" Height="30" Padding="0,-1,0,0"
                        Background="Transparent" Foreground="#AABBC5CF" BorderThickness="0"
                        Cursor="Hand" FontFamily="Segoe UI" VerticalContentAlignment="Center"
                        HorizontalContentAlignment="Center" Visibility="$closeVisibility"/>
            </Grid>
            <StackPanel Grid.Row="1" Margin="40,0,40,30">
                <TextBlock Text="&#x2615;" FontSize="56" Foreground="#DDEEF0F2"
                           HorizontalAlignment="Center" Margin="0,0,0,8"/>
                <TextBlock Text="Time for a Break!" FontSize="32" Foreground="#EEF0F0F0"
                           HorizontalAlignment="Center" FontWeight="SemiBold" FontFamily="Segoe UI"/>
                <TextBlock Text="You've been sitting for $([int](Get-SittingMinutes)) minutes"
                           FontSize="14" Foreground="#BBCFD8DC" HorizontalAlignment="Center"
                           Margin="0,6,0,24" FontFamily="Segoe UI"/>
                $mandatoryNote

                <Button Name="TakeBreakBtn" Cursor="Hand" Margin="0,0,0,10"
                        Background="#2E7D32" Foreground="White" BorderThickness="0"
                        FontFamily="Segoe UI" FontSize="15" Padding="40,14"
                        HorizontalAlignment="Stretch">
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                        <TextBlock Text="&#x1F6B6;  " FontSize="16" VerticalAlignment="Center"/>
                        <TextBlock Text="Taking Break Now" FontSize="15" VerticalAlignment="Center" FontWeight="SemiBold"/>
                    </StackPanel>
                </Button>

                <Button Name="LockScreenBtn" Cursor="Hand" Margin="0,0,0,10"
                        Background="#1565C0" Foreground="White" BorderThickness="0"
                        FontFamily="Segoe UI" FontSize="15" Padding="40,14"
                        HorizontalAlignment="Stretch">
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                        <TextBlock Text="&#x1F512;  " FontSize="16" VerticalAlignment="Center"/>
                        <TextBlock Text="Lock Screen &amp; Break" FontSize="15" VerticalAlignment="Center" FontWeight="SemiBold"/>
                    </StackPanel>
                </Button>

                <Button Name="SnoozeBtn" Cursor="Hand"
                        Background="#3d3d5c" Foreground="#CCBBC5CF" BorderThickness="0"
                        FontFamily="Segoe UI" FontSize="14" Padding="40,12"
                        HorizontalAlignment="Stretch"
                        Visibility="$snoozeVisibility">
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                        <TextBlock Text="&#x23F8;  " FontSize="14" VerticalAlignment="Center"/>
                        <TextBlock Text="Snooze (3 min)" FontSize="14" VerticalAlignment="Center"/>
                    </StackPanel>
                </Button>

                <Button Name="ResetBtn" Cursor="Hand" Margin="0,6,0,0"
                        Background="Transparent" Foreground="#88AABBCC" BorderThickness="1"
                        BorderBrush="#44667799"
                        FontFamily="Segoe UI" FontSize="13" Padding="40,10"
                        HorizontalAlignment="Stretch">
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                        <TextBlock Text="&#x1F504;  " FontSize="13" VerticalAlignment="Center"/>
                        <TextBlock Text="Reset Timer" FontSize="13" VerticalAlignment="Center"/>
                    </StackPanel>
                </Button>
            </StackPanel>
        </Grid>
    </Border>
</Window>
"@

    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $takeBreakBtn  = $window.FindName('TakeBreakBtn')
    $lockScreenBtn = $window.FindName('LockScreenBtn')
    $snoozeBtn     = $window.FindName('SnoozeBtn')

    # Title bar drag (guarded: only drag when mouse button is actually pressed)
    $promptTitleBar = $window.FindName('PromptTitleBar')
    $promptTitleBar.Add_MouseLeftButtonDown({
        param($s, $e)
        if ($e.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
            try { $window.DragMove() } catch { }
        }
    }.GetNewClosure())

    # Escape key to dismiss (same as close button when allowed, ignored on mandatory)
    $window.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
            if ($AllowSnooze) {
                $window.Tag = 'Dismissed'
                $window.Close()
            }
        }
    }.GetNewClosure())

    # Close button on prompt (only available when snooze is allowed)
    $promptCloseBtn = $window.FindName('PromptCloseBtn')
    $promptCloseBtn.Add_Click({
        $window.Tag = 'Dismissed'
        $window.Close()
    }.GetNewClosure())

    # Option 1: Taking Break Now → show countdown overlay
    $takeBreakBtn.Add_Click({
        $window.Tag = 'TakeBreak'
        $window.Close()
    }.GetNewClosure())

    # Option 2: Lock Screen & Break → lock workstation, reset timer
    $lockScreenBtn.Add_Click({
        $window.Tag = 'LockScreen'
        $window.Close()
    }.GetNewClosure())

    # Option 3: Snooze
    $snoozeBtn.Add_Click({
        $window.Tag = 'Snoozed'
        $window.Close()
    }.GetNewClosure())

    # Option 4: Reset Timer
    $resetBtn = $window.FindName('ResetBtn')
    $resetBtn.Add_Click({
        $window.Tag = 'Reset'
        $window.Close()
    }.GetNewClosure())

    # Prevent Alt+F4 on mandatory (no snooze) breaks
    if (-not $AllowSnooze) {
        $window.Add_Closing({
            param($s, $e)
            if ($window.Tag -ne 'TakeBreak' -and $window.Tag -ne 'LockScreen' -and $window.Tag -ne 'Reset') {
                $e.Cancel = $true
            }
        }.GetNewClosure())
    }

    $window.ShowDialog() | Out-Null

    # Handle user's choice
    switch ($window.Tag) {
        'TakeBreak' {
            Write-BreakTimeEvent 'BreakTaken'
            Show-BreakCountdown
        }
        'LockScreen' {
            Write-BreakTimeEvent 'LockScreenBreak'
            Reset-SittingTimer
            [NativeMethods]::LockWorkStation() | Out-Null
        }
        'Snoozed' {
            $script:SnoozeCount++
            $script:SnoozedAt = [DateTime]::Now
            $script:State = 'Snoozed'
            Write-BreakTimeEvent 'Snoozed' @{ SnoozeNumber = $script:SnoozeCount; MaxSnoozes = $script:Settings.MaxSnoozes }
        }
        'Dismissed' {
            # Closing via X counts as a snooze
            $script:SnoozeCount++
            $script:SnoozedAt = [DateTime]::Now
            $script:State = 'Snoozed'
            Write-BreakTimeEvent 'Dismissed' @{ SnoozeNumber = $script:SnoozeCount }
        }
        'Reset' {
            Write-BreakTimeEvent 'ResetTimer' @{ Source = 'BreakPrompt' }
            Reset-SittingTimer
        }
    }

    $script:OverlayShowing = $false
}

# ══════════════════════════════════════════════════════════════
# BREAK COUNTDOWN WINDOW — Idle-gated, draggable, with lock option
# ══════════════════════════════════════════════════════════════
function Show-BreakCountdown {
    # Shows an idle-gated break countdown window.
    # Timer only ticks while user is idle (no keyboard/mouse for 10+ seconds).
    # If user is active, timer pauses with a nudge to step away.
    # Lock Screen button lets user lock from this window.
    # Uses a hashtable for $state so the closure can mutate values.
    $breakSeconds = $script:Settings.BreakDurationMinutes * 60
    $idleGateSeconds = 10  # Must be idle this long for countdown to tick

    # Hashtable used as a mutable reference inside the timer closure
    $state = @{
        Remaining = $breakSeconds
        Completed = $false
        Paused    = $false       # True when user is active (not idle)
        FlashTick = 0            # Alternates each second for flashing effect
    }

    # Signal the widget to show green "on break" countdown
    $script:OnBreak = $true
    $script:BreakEndTime = [DateTime]::Now.AddSeconds($breakSeconds)

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="CenterScreen" SizeToContent="WidthAndHeight"
        Topmost="True" ShowInTaskbar="True" ResizeMode="NoResize"
        Title="BreakTime - Break">
    <Border Background="#DD1a1a2e" CornerRadius="16" BorderBrush="#88667799"
            BorderThickness="2" Padding="0">
        <Border.Effect>
            <DropShadowEffect BlurRadius="24" ShadowDepth="5" Opacity="0.5" Color="Black"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="32"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <!-- Title bar with drag + minimize/close -->
            <Grid Grid.Row="0" Name="BreakTitleBar" Background="Transparent">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="BreakTime" FontSize="11" Foreground="#88AABBCC"
                           VerticalAlignment="Center" Margin="16,0,0,0" FontFamily="Segoe UI"/>
                <Button Name="BreakMinBtn" Grid.Column="1" Content="&#x2014;" FontSize="11"
                        Width="34" Height="32" Padding="0,-2,0,0"
                        Background="Transparent" Foreground="#AABBC5CF" BorderThickness="0"
                        Cursor="Hand" FontFamily="Segoe UI" VerticalContentAlignment="Center"
                        HorizontalContentAlignment="Center"/>
                <Button Name="BreakCloseBtn" Grid.Column="2" Content="&#x2715;" FontSize="11"
                        Width="34" Height="32" Padding="0,-1,0,0"
                        Background="Transparent" Foreground="#AABBC5CF" BorderThickness="0"
                        Cursor="Hand" FontFamily="Segoe UI" VerticalContentAlignment="Center"
                        HorizontalContentAlignment="Center"/>
            </Grid>
            <StackPanel Grid.Row="1" Margin="50,0,50,36">
                <TextBlock Name="BreakIcon" Text="&#x2615;" FontSize="56" Foreground="#DDEEF0F2"
                           HorizontalAlignment="Center" Margin="0,0,0,8"/>
                <TextBlock Name="TitleText" Text="Break Time!" FontSize="42" Foreground="#EEF0F0F0"
                           HorizontalAlignment="Center" FontWeight="SemiBold" FontFamily="Segoe UI"/>
                <TextBlock Name="SubtitleText" Text="Stand up, stretch, and walk around" FontSize="18"
                           Foreground="#BBCFD8DC" HorizontalAlignment="Center"
                           Margin="0,6,0,30" FontFamily="Segoe UI"/>
                <Border Background="#2d2d44" CornerRadius="16" Padding="44,16"
                        HorizontalAlignment="Center">
                    <TextBlock Name="TimerText" Text="3:00" FontSize="72"
                               Foreground="#66BB6A" HorizontalAlignment="Center"
                               FontFamily="Consolas" FontWeight="Bold"/>
                </Border>
                <TextBlock Name="StatusText" Text="Enjoy your break" FontSize="14"
                           Foreground="#BBCFD8DC" HorizontalAlignment="Center"
                           Margin="0,16,0,0" FontFamily="Segoe UI"/>

                <!-- Lock Screen button -->
                <Button Name="LockScreenBtn" Cursor="Hand" Margin="0,20,0,0"
                        Background="#1565C0" Foreground="White" BorderThickness="0"
                        FontFamily="Segoe UI" FontSize="14" Padding="30,10"
                        HorizontalAlignment="Center">
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                        <TextBlock Text="&#x1F512;  " FontSize="14" VerticalAlignment="Center"/>
                        <TextBlock Text="Lock Screen" FontSize="14" VerticalAlignment="Center" FontWeight="SemiBold"/>
                    </StackPanel>
                </Button>
            </StackPanel>
        </Grid>
    </Border>
</Window>
"@

    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $timerText    = $window.FindName('TimerText')
    $statusText  = $window.FindName('StatusText')
    $breakIcon   = $window.FindName('BreakIcon')
    $titleText   = $window.FindName('TitleText')
    $subtitleText = $window.FindName('SubtitleText')

    # Format initial time
    $mins = [Math]::Floor($state.Remaining / 60)
    $secs = $state.Remaining % 60
    $timerText.Text = '{0}:{1:D2}' -f $mins, $secs

    # Title bar drag (guarded: only drag when mouse button is actually pressed)
    $breakTitleBar = $window.FindName('BreakTitleBar')
    $breakTitleBar.Add_MouseLeftButtonDown({
        param($s, $e)
        if ($e.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
            try { $window.DragMove() } catch { }
        }
    }.GetNewClosure())

    # Escape key to close break countdown early
    $window.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
            $state.Completed = $true
            $window.Tag = 'Completed'
            $window.Close()
        }
    }.GetNewClosure())

    # Minimize button — minimizes to taskbar, timer keeps running
    $breakMinBtn = $window.FindName('BreakMinBtn')
    $breakMinBtn.Add_Click({
        $window.WindowState = [System.Windows.WindowState]::Minimized
    }.GetNewClosure())

    # Close button — marks as completed early and closes
    $breakCloseBtn = $window.FindName('BreakCloseBtn')
    $breakCloseBtn.Add_Click({
        $state.Completed = $true
        $window.Tag = 'Completed'
        $window.Close()
    }.GetNewClosure())

    # Lock Screen button — locks PC and closes the break window
    $lockScreenBtn = $window.FindName('LockScreenBtn')
    $lockScreenBtn.Add_Click({
        $state.Completed = $true
        $window.Tag = 'LockScreen'
        $window.Close()
    }.GetNewClosure())

    # Idle-gated countdown timer — only ticks when user is idle.
    # Checks idle time each second; if idle >= gate threshold, counts down.
    # If user is active, pauses timer and shows a nudge message.
    $countdownTimer = New-Object System.Windows.Threading.DispatcherTimer
    $countdownTimer.Interval = [TimeSpan]::FromSeconds(1)
    $countdownTimer.Add_Tick({
        $idleSec = [NativeMethods]::GetIdleSeconds()
        $isIdle = ($idleSec -ge $idleGateSeconds)

        if ($isIdle) {
            # User is idle — countdown ticks
            if ($state.Paused) {
                # Resuming from paused state — restore green/calm appearance
                $state.Paused = $false
                $state.FlashTick = 0
                $script:BreakPaused = $false
                $timerText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#66BB6A')
                $breakIcon.Text = [char]0x2615  # ☕
                $breakIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#DDEEF0F2')
                $titleText.Text = 'Break Time!'
                $titleText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#EEF0F0F0')
                $subtitleText.Text = 'Stand up, stretch, and walk around'
                $subtitleText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#BBCFD8DC')
                $statusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#BBCFD8DC')
            }

            $state.Remaining--
            $script:BreakRemaining = $state.Remaining
            if ($state.Remaining -le 0) {
                $countdownTimer.Stop()
                $state.Completed = $true
                $window.Tag = 'Completed'
                $window.Close()
            } else {
                $mins = [Math]::Floor($state.Remaining / 60)
                $secs = $state.Remaining % 60
                $timerText.Text = '{0}:{1:D2}' -f $mins, $secs
                $statusText.Text = "Enjoy your break"

                # Update the widget's break end time to stay in sync
                $script:BreakEndTime = [DateTime]::Now.AddSeconds($state.Remaining)

                if ($state.Remaining -le 10) {
                    $timerText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#66BB6A')
                    $statusText.Text = "Almost done!"
                }
            }
        } else {
            # User is active — pause countdown, flash red to grab attention
            if (-not $state.Paused) {
                $state.Paused = $true
                $script:BreakPaused = $true
            }

            # Flash the hand icon on/off every second for urgency
            $state.FlashTick++
            $showHand = ($state.FlashTick % 2 -eq 0)

            $timerText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F44336')
            $statusText.Text = "Step away from the keyboard!"
            $statusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F44336')
            $titleText.Text = 'Take Your Break!'
            $titleText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F44336')
            $subtitleText.Text = 'Timer paused until you step away'
            $subtitleText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#EF9A9A')

            if ($showHand) {
                $breakIcon.Text = [char]0x270B  # ✋
                $breakIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F44336')
            } else {
                $breakIcon.Text = ''
                $breakIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F44336')
            }
        }
    }.GetNewClosure())

    $window.Add_Loaded({ $countdownTimer.Start() })

    # Allow closing at any time (close = end break early)
    $window.Add_Closing({
        param($s, $e)
        $countdownTimer.Stop()
    }.GetNewClosure())

    try {
        $window.ShowDialog() | Out-Null
    } finally {
        # Log break completion
        $elapsedSec = $breakSeconds - $state.Remaining
        if ($state.Completed -and $state.Remaining -le 0) {
            Write-BreakTimeEvent 'BreakCompleted' @{ BreakDurationSeconds = $breakSeconds }
        } elseif ($state.Completed -or $window.Tag -eq 'Completed') {
            Write-BreakTimeEvent 'BreakEndedEarly' @{ ElapsedSeconds = $elapsedSec; TotalSeconds = $breakSeconds }
        } elseif ($window.Tag -eq 'LockScreen') {
            Write-BreakTimeEvent 'BreakEndedEarly' @{ ElapsedSeconds = $elapsedSec; TotalSeconds = $breakSeconds; Reason = 'LockScreen' }
        }
        # Always clean up break state and restart the sitting timer
        $script:OnBreak = $false
        $script:BreakEndTime = $null
        $script:BreakPaused = $false
        $script:BreakRemaining = 0
        # If user chose Lock Screen, lock the workstation
        if ($window.Tag -eq 'LockScreen') {
            [NativeMethods]::LockWorkStation() | Out-Null
        }
        Reset-SittingTimer
    }
}

# ══════════════════════════════════════════════════════════════
# SETTINGS WINDOW — Dark-themed WPF dialog with sliders
# ══════════════════════════════════════════════════════════════
function Show-SettingsWindow {
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="BreakTime Settings" Width="420" Height="440"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#1e1e2e" Foreground="#E0E0E0" FontFamily="Segoe UI">
    <StackPanel Margin="25">
        <TextBlock Text="BreakTime Settings" FontSize="22" FontWeight="SemiBold"
                   Foreground="#4FC3F7" Margin="0,0,0,20"/>

        <TextBlock Text="Break interval (minutes):" Margin="0,0,0,4"/>
        <DockPanel>
            <TextBlock Name="IntervalValue" DockPanel.Dock="Right" Width="40"
                       TextAlignment="Right" VerticalAlignment="Center" Foreground="#4FC3F7"/>
            <Slider Name="IntervalSlider" Minimum="15" Maximum="90"
                    IsSnapToTickEnabled="True" TickFrequency="5" VerticalAlignment="Center"/>
        </DockPanel>

        <TextBlock Text="Break duration (minutes):" Margin="0,15,0,4"/>
        <DockPanel>
            <TextBlock Name="DurationValue" DockPanel.Dock="Right" Width="40"
                       TextAlignment="Right" VerticalAlignment="Center" Foreground="#4FC3F7"/>
            <Slider Name="DurationSlider" Minimum="1" Maximum="10"
                    IsSnapToTickEnabled="True" TickFrequency="1" VerticalAlignment="Center"/>
        </DockPanel>

        <TextBlock Text="Post-meeting buffer (minutes):" Margin="0,15,0,4"/>
        <DockPanel>
            <TextBlock Name="BufferValue" DockPanel.Dock="Right" Width="40"
                       TextAlignment="Right" VerticalAlignment="Center" Foreground="#4FC3F7"/>
            <Slider Name="BufferSlider" Minimum="0" Maximum="10"
                    IsSnapToTickEnabled="True" TickFrequency="1" VerticalAlignment="Center"/>
        </DockPanel>

        <TextBlock Text="Idle = break threshold (minutes):" Margin="0,15,0,4"/>
        <DockPanel>
            <TextBlock Name="IdleValue" DockPanel.Dock="Right" Width="40"
                       TextAlignment="Right" VerticalAlignment="Center" Foreground="#4FC3F7"/>
            <Slider Name="IdleSlider" Minimum="1" Maximum="5"
                    IsSnapToTickEnabled="True" TickFrequency="1" VerticalAlignment="Center"/>
        </DockPanel>

        <TextBlock Text="Max snoozes per break:" Margin="0,15,0,4"/>
        <DockPanel>
            <TextBlock Name="SnoozeValue" DockPanel.Dock="Right" Width="40"
                       TextAlignment="Right" VerticalAlignment="Center" Foreground="#4FC3F7"/>
            <Slider Name="SnoozeSlider" Minimum="1" Maximum="5"
                    IsSnapToTickEnabled="True" TickFrequency="1" VerticalAlignment="Center"/>
        </DockPanel>

        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,25,0,0">
            <Button Name="SaveButton" Content="Save" Width="80" Padding="0,8"
                    Background="#4FC3F7" Foreground="#1e1e2e" BorderThickness="0"
                    FontWeight="SemiBold" Cursor="Hand" Margin="0,0,10,0"/>
            <Button Name="CancelButton" Content="Cancel" Width="80" Padding="0,8"
                    Background="#3d3d5c" Foreground="#B0BEC5" BorderThickness="0"
                    Cursor="Hand"/>
        </StackPanel>
    </StackPanel>
</Window>
"@

    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $intervalSlider = $window.FindName('IntervalSlider')
    $intervalValue  = $window.FindName('IntervalValue')
    $durationSlider = $window.FindName('DurationSlider')
    $durationValue  = $window.FindName('DurationValue')
    $bufferSlider   = $window.FindName('BufferSlider')
    $bufferValue    = $window.FindName('BufferValue')
    $idleSlider     = $window.FindName('IdleSlider')
    $idleValue      = $window.FindName('IdleValue')
    $snoozeSlider   = $window.FindName('SnoozeSlider')
    $snoozeValue    = $window.FindName('SnoozeValue')
    $saveBtn        = $window.FindName('SaveButton')
    $cancelBtn      = $window.FindName('CancelButton')

    # Set current values
    $intervalSlider.Value = $script:Settings.BreakIntervalMinutes
    $durationSlider.Value = $script:Settings.BreakDurationMinutes
    $bufferSlider.Value   = $script:Settings.PostMeetingBufferMinutes
    $idleSlider.Value     = $script:Settings.IdleThresholdMinutes
    $snoozeSlider.Value   = $script:Settings.MaxSnoozes

    # Value display updaters
    $updateLabels = {
        $intervalValue.Text = "$([int]$intervalSlider.Value)"
        $durationValue.Text = "$([int]$durationSlider.Value)"
        $bufferValue.Text   = "$([int]$bufferSlider.Value)"
        $idleValue.Text     = "$([int]$idleSlider.Value)"
        $snoozeValue.Text   = "$([int]$snoozeSlider.Value)"
    }
    & $updateLabels

    $intervalSlider.Add_ValueChanged({ & $updateLabels }.GetNewClosure())
    $durationSlider.Add_ValueChanged({ & $updateLabels }.GetNewClosure())
    $bufferSlider.Add_ValueChanged({ & $updateLabels }.GetNewClosure())
    $idleSlider.Add_ValueChanged({ & $updateLabels }.GetNewClosure())
    $snoozeSlider.Add_ValueChanged({ & $updateLabels }.GetNewClosure())

    $saveBtn.Add_Click({
        Update-SettingsFromUI -Interval ([int]$intervalSlider.Value) -Duration ([int]$durationSlider.Value) `
            -Buffer ([int]$bufferSlider.Value) -Idle ([int]$idleSlider.Value) -MaxSnoozes ([int]$snoozeSlider.Value)
        $window.Close()
    }.GetNewClosure())

    $cancelBtn.Add_Click({ $window.Close() }.GetNewClosure())

    $window.ShowDialog() | Out-Null
}

# ══════════════════════════════════════════════════════════════
# SYSTEM TRAY — NotifyIcon with context menu
# ══════════════════════════════════════════════════════════════
function Initialize-SystemTray {
    $script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:TrayIcon.Icon = $script:IconGreen
    $script:TrayIcon.Text = "BreakTime - Starting..."
    $script:TrayIcon.Visible = $true

    # Context menu
    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    # Status item (display only)
    $statusItem = $menu.Items.Add("Sitting: 0 min")
    $statusItem.Enabled = $false
    $statusItem.Name = 'StatusItem'

    $menu.Items.Add('-') | Out-Null

    # Take a break now
    $breakNow = $menu.Items.Add("Take a Break Now")
    $breakNow.Add_Click({
        if (-not $script:OverlayShowing) {
            Show-BreakPrompt -AllowSnooze $false
        }
    })

    # Pause/Resume
    $pauseItem = $menu.Items.Add("Pause")
    $pauseItem.Name = 'PauseItem'
    $pauseItem.Add_Click({
        Toggle-Pause -MenuItem $pauseItem
    }.GetNewClosure())

    # Reset Timer
    $resetItem = $menu.Items.Add("Reset Timer")
    $resetItem.Add_Click({
        Write-BreakTimeEvent 'ResetTimer' @{ Source = 'TrayMenu' }
        Reset-SittingTimer
        Update-TrayIcon
    })

    # Show/Hide Widget
    $widgetItem = $menu.Items.Add("Hide Widget")
    $widgetItem.Name = 'WidgetItem'
    $widgetItem.Add_Click({
        if ($script:WidgetVisible) {
            $script:Widget.Hide()
            $script:WidgetVisible = $false
            $widgetItem.Text = 'Show Widget'
        } else {
            $script:Widget.Show()
            $script:WidgetVisible = $true
            $widgetItem.Text = 'Hide Widget'
        }
    }.GetNewClosure())

    $menu.Items.Add('-') | Out-Null

    # Reports
    $reportItem = $menu.Items.Add("Generate Today's Report")
    $reportItem.Add_Click({
        $todayStr = (Get-Date).ToString('yyyy-MM-dd')
        $path = New-DailyReport -Date $todayStr
        if ($path -and (Test-Path $path)) {
            Start-Process $path
        } else {
            [System.Windows.Forms.MessageBox]::Show("No break data recorded yet today.", "BreakTime Reports", 'OK', 'Information') | Out-Null
        }
    })

    $viewReportsItem = $menu.Items.Add("View Reports Folder")
    $viewReportsItem.Add_Click({
        if (-not (Test-Path $script:ReportsDir)) { New-Item -ItemType Directory -Path $script:ReportsDir -Force | Out-Null }
        Start-Process "explorer.exe" -ArgumentList $script:ReportsDir
    })

    $menu.Items.Add('-') | Out-Null

    # Settings
    $settingsItem = $menu.Items.Add("Settings...")
    $settingsItem.Add_Click({
        Show-SettingsWindow
        Update-TrayIcon
    })

    $menu.Items.Add('-') | Out-Null

    # Exit
    $exitItem = $menu.Items.Add("Exit")
    $exitItem.Add_Click({
        Write-BreakTimeEvent 'AppStopped'
        if ($script:WidgetTimer) { $script:WidgetTimer.Stop() }
        if ($script:Widget) { $script:Widget.Close() }
        $script:TrayIcon.Visible = $false
        $script:TrayIcon.Dispose()
        [Microsoft.Win32.SystemEvents]::remove_SessionSwitch($sessionSwitchHandler)
        [System.Windows.Application]::Current.Shutdown()
    })

    $script:TrayIcon.ContextMenuStrip = $menu

    # Double-click tray icon to open settings
    $script:TrayIcon.Add_DoubleClick({
        Show-SettingsWindow
        Update-TrayIcon
    })
}

# ══════════════════════════════════════════════════════════════
# MAIN TIMER LOGIC — 10-second tick driving the state machine
# ══════════════════════════════════════════════════════════════
function Initialize-MainTimer {
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(10)
    $timer.Add_Tick({
        # Skip if overlay is showing or paused or screen locked
        if ($script:OverlayShowing -or $script:Paused -or $script:ScreenLocked) {
            Update-TrayIcon
            return
        }

        # ── Report generation trigger: check for day/week rollover ──
        $todayStr = (Get-Date).ToString('yyyy-MM-dd')
        if ($script:LastReportDate -and $script:LastReportDate -ne $todayStr) {
            # New day detected → generate previous day's report
            try { New-DailyReport -Date $script:LastReportDate } catch { }
            # If today is Monday, generate weekly report for the previous week
            if ((Get-Date).DayOfWeek -eq [DayOfWeek]::Monday) {
                try { New-WeeklyReport -WeekEndDate (Get-Date).AddDays(-1) } catch { }
            }
        }
        $script:LastReportDate = $todayStr

        # Sample audio state every tick (builds sustained detection via grace window)
        Update-MediaActivity

        # If waiting for activity after a break, check if user is back
        if ($script:WaitingForActivity) {
            $idleSec = [NativeMethods]::GetIdleSeconds()
            if ($idleSec -lt 10) {
                # User is active — start the sitting clock now
                $script:WaitingForActivity = $false
                $script:LastBreakTime = [DateTime]::Now
                Update-TrayIcon
                Update-Widget
            }
            return
        }

        # Check for natural break (idle + no recent media → walked away)
        if (Test-NaturalBreak) {
            Write-BreakTimeEvent 'NaturalBreak'
            Reset-SittingTimer
            return
        }

        # Update tray status display
        $sitting = Get-SittingMinutes
        $interval = $script:Settings.BreakIntervalMinutes
        $statusItem = $script:TrayIcon.ContextMenuStrip.Items['StatusItem']
        if ($statusItem) {
            $statusItem.Text = "Sitting: $([int]$sitting) / $interval min"
        }
        Update-TrayIcon

        # State machine
        switch ($script:State) {
            'Tracking' {
                if ($sitting -ge $interval) {
                    if (Test-InMeeting) {
                        Write-BreakTimeEvent 'MeetingDeferred' @{ SittingMinutes = [Math]::Round($sitting, 0) }
                        $script:State = 'Deferred'
                    } else {
                        Show-BreakPrompt -AllowSnooze ($script:SnoozeCount -lt $script:Settings.MaxSnoozes)
                    }
                }
            }
            'Deferred' {
                if (-not (Test-InMeeting)) {
                    $script:MeetingEndedAt = [DateTime]::Now
                    $script:State = 'Buffering'
                }
            }
            'Buffering' {
                $bufferElapsed = ([DateTime]::Now - $script:MeetingEndedAt).TotalMinutes
                if ($bufferElapsed -ge $script:Settings.PostMeetingBufferMinutes) {
                    # Check if another meeting started during buffer
                    if (Test-InMeeting) {
                        $script:State = 'Deferred'
                    } else {
                        Show-BreakPrompt -AllowSnooze ($script:SnoozeCount -lt $script:Settings.MaxSnoozes)
                    }
                }
            }
            'Snoozed' {
                $snoozeElapsed = ([DateTime]::Now - $script:SnoozedAt).TotalMinutes
                if ($snoozeElapsed -ge 3) {
                    if (Test-InMeeting) {
                        $script:State = 'Deferred'
                    } else {
                        Show-BreakPrompt -AllowSnooze ($script:SnoozeCount -lt $script:Settings.MaxSnoozes)
                    }
                }
            }
        }
    })
    $timer.Start()
    return $timer
}

# ══════════════════════════════════════════════════════════════
# ENTRY POINT — Bootstrap the WPF application
# ══════════════════════════════════════════════════════════════
Load-Settings
Initialize-SystemTray

# WPF Application with explicit shutdown (tray controls lifecycle)
$script:App = New-Object System.Windows.Application
$script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

# Initialize widget and main timer once the app event loop is running
$script:App.Add_Startup({
    Write-BreakTimeEvent 'AppStarted' @{ Version = '1.0'; Interval = $script:Settings.BreakIntervalMinutes; Duration = $script:Settings.BreakDurationMinutes }
    Initialize-Widget
    $script:MainTimer = Initialize-MainTimer
    Update-TrayIcon
})

# Run the WPF application event loop (blocks here until Exit)
$script:App.Run() | Out-Null
