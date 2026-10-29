$ErrorActionPreference = 'Stop'
$appPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'BreakTime.ps1'
$tokens = $null
$parseErrors = $null
$appAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $appPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }

Add-Type -AssemblyName PresentationFramework, System.Windows.Forms, UIAutomationClient, UIAutomationTypes
$compile = $appAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'Add-Type' -and $node.Extent.Text -match '-TypeDefinition'
}, $true)
Invoke-Expression $compile.Extent.Text
foreach ($function in $appAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true)) {
    Invoke-Expression $function.Extent.Text
}
foreach ($name in @('sessionSwitchHandler', 'powerModeHandler')) {
    $assignment = $appAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq $name
    }, $true)
    Invoke-Expression $assignment.Extent.Text
}

function Initialize-TestState {
    $script:Now = 1000.0
    $script:Idle = 0.0
    $script:Settings = @{
        BreakIntervalMinutes = 30; IdleThresholdMinutes = 3
        PostMeetingBufferMinutes = 2; MaxSnoozes = 3; BreakDurationMinutes = 3
    }
    $script:SittingElapsedSeconds = 0.0
    $script:SittingResumedAt = $null
    $script:WaitingForActivity = $true
    $script:WaitingSince = $script:Now
    $script:LastPresenceAt = $null
    $script:Paused = $false
    $script:ScreenLocked = $false
    $script:ScreenLockedAt = $null
    $script:LockedPresence = $false
    $script:OnBreak = $false
    $script:SystemSuspendedAt = $null
    $script:OverlayShowing = $false
    $script:PromptWindow = $null
    $script:PromptPending = $false
    $script:State = 'Tracking'
    $script:SnoozeCount = 0
    $script:SnoozedAt = $null
    $script:MeetingEndedAt = $null
    $script:TeamsInCall = $false
    $script:OtherMeetingActive = $false
    $script:LastMeetingDetectedAt = $null
    $script:MeetingGraceSec = 30
    $script:TeamsDetectionReady = $true
    $script:TeamsScanTask = $null
    $script:TeamsScanStartedAt = $null
    $script:NextTeamsScanAt = 0.0
    $script:DetectionWarning = $null
    $script:AudioDetectionFailed = $false
    $script:LastMediaDetectedAt = $null
    $script:MediaGraceSec = 30
}

Describe 'Continuous desk-time tracking' {
    BeforeEach {
        Initialize-TestState
        Mock Get-TrackingSeconds { $script:Now }
        Mock Get-IdleSeconds { $script:Idle }
        Mock Update-MeetingActivity {}
        Mock Update-MediaActivity {}
        Mock Update-SittingDisplays {}
        Mock Update-Widget {}
        Mock Update-TrayIcon {}
        Mock Request-BreakPrompt {}
    }

    It 'does not count startup or time waiting to return after a reset' {
        $script:Now += 600
        $script:Idle = 900
        Invoke-TrackingTick
        Get-SittingSeconds | Should Be 0
        $script:WaitingForActivity | Should Be $true
    }

    It 'starts when keyboard activity resumes and measures real elapsed time' {
        Invoke-TrackingTick
        $script:Now += 12.75
        Get-SittingSeconds | Should Be 12.75
    }

    It 'starts from media without requiring keyboard or mouse activity' {
        $script:Idle = 900
        $script:LastMediaDetectedAt = $script:Now
        Invoke-TrackingTick
        $script:Now += 20
        Get-SittingSeconds | Should Be 20
    }

    It 'starts from a muted call without keyboard activity' {
        $script:Idle = 900
        $script:TeamsInCall = $true
        Invoke-TrackingTick
        $script:Now += 300
        Invoke-TrackingTick
        Get-SittingSeconds | Should Be 300
        $script:WaitingForActivity | Should Be $false
    }

    It 'freezes while paused and continues from the same elapsed value' {
        Invoke-TrackingTick
        $script:Now += 120
        Toggle-Pause
        $script:Now += 600
        Get-SittingSeconds | Should Be 120
        Toggle-Pause
        $script:Now += 10
        Get-SittingSeconds | Should Be 130
    }

    It 'clears a paused session on reset without restoring the old time on resume' {
        Invoke-TrackingTick
        $script:Now += 120
        Toggle-Pause
        Reset-SittingTimer
        Toggle-Pause
        $script:Now += 10
        Get-SittingSeconds | Should Be 0
        Invoke-TrackingTick
        $script:Now += 5
        Get-SittingSeconds | Should Be 5
    }

    It 'does not count the time between reset and new activity' {
        Invoke-TrackingTick
        Reset-SittingTimer
        $script:Now += 600
        $script:Idle = 900
        Invoke-TrackingTick
        Get-SittingText | Should Be '0m 00s'
    }

    It 'does not mistake a silent muted meeting for a natural break' {
        Invoke-TrackingTick
        $script:TeamsInCall = $true
        $script:Now += 600
        $script:Idle = 600
        Invoke-TrackingTick
        Get-SittingSeconds | Should Be 600
    }

    It 'requires the entire inactivity threshold after the last media activity' {
        Invoke-TrackingTick
        $script:Now = 1200
        $script:Idle = 600
        $script:LastMediaDetectedAt = 1190
        Invoke-TrackingTick
        $script:Now = 1369
        $script:Idle = 769
        Invoke-TrackingTick
        Get-SittingSeconds | Should Be 369
        $script:Now = 1370
        $script:Idle = 770
        Invoke-TrackingTick
        Get-SittingSeconds | Should Be 0
    }

    It 'still requests a break during a recording or YouTube playback' {
        Invoke-TrackingTick
        $script:Now += 1800
        $script:Idle = 1800
        $script:LastMediaDetectedAt = $script:Now
        Invoke-TrackingTick
        Assert-MockCalled Request-BreakPrompt -Times 1 -Exactly -Scope It
        $script:State | Should Be 'Tracking'
        Get-SittingSeconds | Should Be 1800
    }

    It 'defers rather than resetting an overdue session during a meeting' {
        Invoke-TrackingTick
        $script:Now += 1800
        $script:Idle = 1800
        $script:TeamsInCall = $true
        Invoke-TrackingTick
        $script:State | Should Be 'Deferred'
        Get-SittingSeconds | Should Be 1800
        Assert-MockCalled Request-BreakPrompt -Times 0 -Scope It
    }

    It 'does not infer a break or interrupt when call detection is unknown' {
        Invoke-TrackingTick
        $script:Now += 1800
        $script:Idle = 1800
        $script:TeamsDetectionReady = $false
        Invoke-TrackingTick
        $script:State | Should Be 'Deferred'
        Get-SittingSeconds | Should Be 1800
        Assert-MockCalled Request-BreakPrompt -Times 0 -Scope It
    }

    It 'does not silently reset when audio detection is unavailable' {
        Invoke-TrackingTick
        $script:Now += 600
        $script:Idle = 600
        $script:AudioDetectionFailed = $true
        Invoke-TrackingTick
        Get-SittingSeconds | Should Be 600
    }

    It 'keeps accruing time during a snooze' {
        Invoke-TrackingTick
        $script:State = 'Snoozed'
        $script:SnoozedAt = $script:Now
        $script:Now += 180
        Get-SittingSeconds | Should Be 180
    }

    It 'uses a 30-second call-end grace before the configured post-meeting buffer' {
        Invoke-TrackingTick
        $script:State = 'Deferred'
        $script:LastMeetingDetectedAt = 1000
        $script:Now = 1029
        Invoke-TrackingTick
        $script:State | Should Be 'Deferred'
        $script:Now = 1030
        Invoke-TrackingTick
        $script:State | Should Be 'Buffering'
        $script:MeetingEndedAt | Should Be 1030
    }

    It 'cancels the post-meeting buffer if another call starts' {
        Invoke-TrackingTick
        $script:State = 'Buffering'
        $script:MeetingEndedAt = 990
        $script:TeamsInCall = $true
        Invoke-TrackingTick
        $script:State | Should Be 'Deferred'
        $script:MeetingEndedAt | Should BeNullOrEmpty
    }

    It 'excludes short screen locks without discarding the sitting session' {
        Invoke-TrackingTick
        $script:Now += 120
        & $sessionSwitchHandler $null ([pscustomobject]@{ Reason = [Microsoft.Win32.SessionSwitchReason]::SessionLock })
        $script:Now += 30
        Get-SittingSeconds | Should Be 120
        & $sessionSwitchHandler $null ([pscustomobject]@{ Reason = [Microsoft.Win32.SessionSwitchReason]::SessionUnlock })
        $script:Now += 10
        Get-SittingSeconds | Should Be 130
    }

    It 'resets after a sufficiently long screen lock' {
        Invoke-TrackingTick
        $script:Now += 120
        & $sessionSwitchHandler $null ([pscustomobject]@{ Reason = [Microsoft.Win32.SessionSwitchReason]::SessionLock })
        $script:Now += 180
        & $sessionSwitchHandler $null ([pscustomobject]@{ Reason = [Microsoft.Win32.SessionSwitchReason]::SessionUnlock })
        Get-SittingSeconds | Should Be 0
        $script:WaitingForActivity | Should Be $true
    }

    It 'does not resume a paused clock after unlocking' {
        Invoke-TrackingTick
        $script:Now += 120
        Toggle-Pause
        & $sessionSwitchHandler $null ([pscustomobject]@{ Reason = [Microsoft.Win32.SessionSwitchReason]::SessionLock })
        $script:Now += 30
        & $sessionSwitchHandler $null ([pscustomobject]@{ Reason = [Microsoft.Win32.SessionSwitchReason]::SessionUnlock })
        $script:Now += 100
        Get-SittingSeconds | Should Be 120
    }

    It 'does not reset or stop counting a live meeting while the screen is locked' {
        Invoke-TrackingTick
        $script:TeamsInCall = $true
        $script:Now += 120
        & $sessionSwitchHandler $null ([pscustomobject]@{ Reason = [Microsoft.Win32.SessionSwitchReason]::SessionLock })
        $script:Now += 300
        Invoke-TrackingTick
        & $sessionSwitchHandler $null ([pscustomobject]@{ Reason = [Microsoft.Win32.SessionSwitchReason]::SessionUnlock })
        Get-SittingSeconds | Should Be 420
    }

    It 'does not reset during playback with a locked screen' {
        Invoke-TrackingTick
        $script:LastMediaDetectedAt = $script:Now
        & $sessionSwitchHandler $null ([pscustomobject]@{ Reason = [Microsoft.Win32.SessionSwitchReason]::SessionLock })
        $script:Now += 300
        $script:LastMediaDetectedAt = $script:Now
        Invoke-TrackingTick
        & $sessionSwitchHandler $null ([pscustomobject]@{ Reason = [Microsoft.Win32.SessionSwitchReason]::SessionUnlock })
        Get-SittingSeconds | Should Be 300
    }

    It 'does not clear an existing meeting session on sleep resume' {
        Invoke-TrackingTick
        $script:TeamsInCall = $true
        $script:Now += 120
        & $powerModeHandler $null ([pscustomobject]@{ Mode = [Microsoft.Win32.PowerModes]::Suspend })
        $script:Now += 600
        & $powerModeHandler $null ([pscustomobject]@{ Mode = [Microsoft.Win32.PowerModes]::Resume })
        $script:Now += 10
        Get-SittingSeconds | Should Be 130
    }

    It 'does not count sleep as sitting and resets after a long sleep' {
        Invoke-TrackingTick
        $script:Now += 120
        & $powerModeHandler $null ([pscustomobject]@{ Mode = [Microsoft.Win32.PowerModes]::Suspend })
        $script:Now += 600
        Get-SittingSeconds | Should Be 120
        & $powerModeHandler $null ([pscustomobject]@{ Mode = [Microsoft.Win32.PowerModes]::Resume })
        Get-SittingSeconds | Should Be 0
    }

    It 'does not round sitting minutes up before a full minute has elapsed' {
        Get-SittingText -Seconds 119.9 | Should Be '1m 59s'
        Get-SittingText -Seconds 120 | Should Be '2m 00s'
    }
}

Describe 'Shared live sitting displays' {
    It 'supplies exactly the same elapsed snapshot to the widget and open reminder' {
        Initialize-TestState
        $script:SittingElapsedSeconds = 125.8
        $text = [pscustomobject]@{ Text = '' }
        $script:PromptWindow = [pscustomobject]@{ SittingText = $text }
        $script:PromptWindow | Add-Member ScriptMethod FindName { param($name) return $this.SittingText }
        Mock Update-Widget { $script:RenderedSeconds = $SittingSeconds }
        Mock Update-TrayIcon {}
        Update-SittingDisplays
        $script:RenderedSeconds | Should Be 125.8
        $text.Text | Should Be "You've been sitting for 2m 05s"
        $script:SittingElapsedSeconds = 126.2
        Update-SittingDisplays
        $text.Text | Should Be "You've been sitting for 2m 06s"
    }
}

Describe 'Background call-detection status' {
    BeforeEach {
        Initialize-TestState
        $script:NextTeamsScanAt = 2000
        Mock Get-TrackingSeconds { $script:Now }
        Mock Show-DetectionWarning {}
    }

    It 'uses a completed background call scan' {
        $completion = New-Object 'System.Threading.Tasks.TaskCompletionSource[TeamsCallStatus]'
        $result = New-Object TeamsCallStatus
        $result.InCall = $true
        $completion.SetResult($result)
        $script:TeamsScanTask = $completion.Task
        Update-MeetingActivity
        Test-InMeeting | Should Be $true
        $script:TeamsDetectionReady | Should Be $true
    }

    It 'holds reminders and reports an accessibility error instead of assuming no call' {
        $completion = New-Object 'System.Threading.Tasks.TaskCompletionSource[TeamsCallStatus]'
        $result = New-Object TeamsCallStatus
        $result.Error = 'AccessibilityUnavailable'
        $completion.SetResult($result)
        $script:TeamsScanTask = $completion.Task
        Update-MeetingActivity
        $script:TeamsDetectionReady | Should Be $false
        Assert-MockCalled Show-DetectionWarning -Times 1 -Exactly -Scope It
    }

    It 'times out without spawning more scans or repeating warning balloons' {
        $completion = New-Object 'System.Threading.Tasks.TaskCompletionSource[TeamsCallStatus]'
        $script:TeamsScanTask = $completion.Task
        $script:TeamsScanStartedAt = 980
        Update-MeetingActivity
        Update-MeetingActivity
        $script:TeamsDetectionReady | Should Be $false
        $script:TeamsScanTask | Should Be $completion.Task
        Assert-MockCalled Show-DetectionWarning -Times 1 -Exactly -Scope It
    }
}

Describe 'Queued reminders' {
    BeforeEach {
        Initialize-TestState
        $script:WaitingForActivity = $false
        $script:SittingElapsedSeconds = 1800
        $dispatcher = New-Object PSObject
        $dispatcher | Add-Member ScriptMethod BeginInvoke { param($callback) $script:QueuedPrompt = $callback }
        $script:App = [pscustomobject]@{ Dispatcher = $dispatcher }
        Mock Show-BreakPrompt {}
    }

    It 'does not show a queued reminder if a call starts before it opens' {
        Request-BreakPrompt
        $script:TeamsInCall = $true
        $script:QueuedPrompt.Invoke()
        Assert-MockCalled Show-BreakPrompt -Times 0 -Scope It
    }

    It 'opens a valid reminder outside the heartbeat callback' {
        Request-BreakPrompt
        Assert-MockCalled Show-BreakPrompt -Times 0 -Scope It
        $script:QueuedPrompt.Invoke()
        Assert-MockCalled Show-BreakPrompt -Times 1 -Exactly -Scope It
    }
}

Describe 'Application window markup' {
    It 'loads the widget, live reminder, break countdown and settings markup' {
        Initialize-TestState
        $snoozeVisibility = 'Visible'
        $closeVisibility = 'Visible'
        $mandatoryNote = ''
        foreach ($name in @('Initialize-Widget', 'Show-BreakPrompt', 'Show-BreakCountdown', 'Show-SettingsWindow')) {
            $definition = $appAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            $markup = $definition.Find({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -eq 'xaml'
            }, $true)
            $xaml = Invoke-Expression $markup.Right.Extent.Text
            $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
            try {
                $window = [System.Windows.Markup.XamlReader]::Load($reader)
                $window.Close()
            } finally {
                $reader.Dispose()
            }
        }
    }
}

    function Test-CallControlFixture {
        param([string[]]$ControlIds, [switch]$Minimised)
        $window = New-Object System.Windows.Window
        $window.Title = 'Synthetic meeting recording fixture'
        $window.Width = 100
        $window.Height = 100
        $window.Left = -10000
        $window.Top = -10000
        $window.ShowActivated = $false
        $window.ShowInTaskbar = $false
        $panel = New-Object System.Windows.Controls.StackPanel
        foreach ($id in $ControlIds) {
            $control = if ($id -eq 'call-duration-custom') {
                New-Object System.Windows.Controls.TextBlock
            } else {
                New-Object System.Windows.Controls.Button
            }
            [System.Windows.Automation.AutomationProperties]::SetAutomationId($control, $id)
            $panel.Children.Add($control) | Out-Null
        }
        $window.Content = $panel
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = 'MTA'
        $runspace.Open()
        $pipeline = [powershell]::Create()
        $pipeline.Runspace = $runspace
        try {
            $window.Show()
            if ($Minimised) { $window.WindowState = [System.Windows.WindowState]::Minimized }
            $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
            $pipeline.AddScript({
                param($handle)
                [TeamsCallDetector]::IsCallWindow(
                    [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$handle))
            }).AddArgument($handle.ToInt64()) | Out-Null
            $pending = $pipeline.BeginInvoke()
            $timeout = [Diagnostics.Stopwatch]::StartNew()
            while (-not $pending.IsCompleted -and $timeout.Elapsed.TotalSeconds -lt 10) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 10
            }
            if (-not $pending.IsCompleted) { throw 'Synthetic call-control detection timed out.' }
            $result = $pipeline.EndInvoke($pending)
            if ($pipeline.HadErrors) { throw ($pipeline.Streams.Error | Out-String) }
            return [bool]$result[0]
        } finally {
            $window.Close()
            $pipeline.Dispose()
            $runspace.Dispose()
        }
    }

    Describe 'Call-specific accessibility detection' {
        It 'recognises connected call controls without reading names or media activity' {
            Test-CallControlFixture @('hangup-button', 'microphone-button', 'call-duration-custom') | Should Be $true
        }

        It 'recognises the same controls when the window is minimised' {
            Test-CallControlFixture @('hangup-button', 'microphone-button', 'call-duration-custom') -Minimised | Should Be $true
        }

        It 'does not classify a recording player as a live call based on its title' {
            Test-CallControlFixture @('play-button', 'pause-button', 'video-button') | Should Be $false
        }

        It 'does not classify synthetic pre-join controls as a connected call' {
            Test-CallControlFixture @('microphone-button', 'video-button', 'join-button') | Should Be $false
        }

        It 'requires call-duration evidence in addition to microphone and leave buttons' {
            Test-CallControlFixture @('hangup-button', 'microphone-button') | Should Be $false
        }
    }
