<#
.SYNOPSIS
    SuperTask(TM) Windows Launcher
    Equivalent of launcher.sh for Windows.

.DESCRIPTION
    1. Checks for existing running loop
    2. Opens config dialog (config_dialog_win.ps1)
    3. Parses pipe-separated output
    4. Validates settings, confirms launch
    5. Initializes PLAN.md(s) via claude
    6. Starts loop in background
    7. Launches monitor
#>

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginDir = Split-Path -Parent $ScriptDir
$IconPath  = Join-Path $PluginDir 'icon.png'

# --- Debug Infrastructure ---
. "$ScriptDir\debug_utils.ps1"
Initialize-DebugLog
Write-DebugLog 'INFO' 'launcher_win.ps1 starting'
Write-DebugLog 'DEBUG' "ScriptDir=$ScriptDir PluginDir=$PluginDir"
Write-EnvironmentDump

# ============================================================
#  Check for existing running loop
# ============================================================
Write-DebugLog 'DEBUG' 'Checking for existing lock files'
$lockFiles = Get-ChildItem "$env:TEMP\autoloop-*.lock" -ErrorAction SilentlyContinue
Write-DebugLog 'DEBUG' "Found $(@($lockFiles).Count) lock file(s)"
foreach ($lockFile in $lockFiles) {
    Write-DebugLog 'DEBUG' "Lock file: $($lockFile.Name)"
    $pid_val = Get-Content $lockFile.FullName -ErrorAction SilentlyContinue
    if ($pid_val) {
        Write-DebugLog 'DEBUG' "Lock PID: $pid_val"
        try {
            $proc = Get-Process -Id ([int]$pid_val) -ErrorAction SilentlyContinue
            # Verify it's actually a bash process (not a reused PID from a different app)
            Write-DebugLog 'DEBUG' "Process check: alive=$($null -ne $proc) name=$(if($proc){$proc.ProcessName}else{'N/A'})"
            if ($proc -and $proc.ProcessName -match 'bash|git') {
                $dirFile = "$($lockFile.FullName).dir"
                $existingDir = if (Test-Path $dirFile) {
                    (Get-Content $dirFile -Raw).Trim()
                } else { '' }

                if ($existingDir -and (Test-Path $existingDir)) {
                    Add-Type -AssemblyName PresentationFramework
                    $result = [System.Windows.MessageBox]::Show(
                        "A session is already running:`n$existingDir`n`nOpen that session?",
                        'SuperTask',
                        [System.Windows.MessageBoxButton]::YesNo,
                        [System.Windows.MessageBoxImage]::Question)

                    if ($result -eq 'Yes') {
                        # Launch monitor for existing session
                        $pyBin = if (Get-Command 'python' -ErrorAction SilentlyContinue) { 'python' }
                                 elseif (Get-Command 'python3' -ErrorAction SilentlyContinue) { 'python3' }
                                 elseif (Get-Command 'py' -ErrorAction SilentlyContinue) { 'py' }
                                 else { 'python' }
                        & $pyBin "$ScriptDir\monitor.py" "$existingDir" "$pid_val"
                        exit 0
                    }
                }
            }
        }
        catch { Write-DebugLog 'WARN' "Lock file check error: $_" }
    }
}

# ============================================================
#  Run Config Dialog
# ============================================================
Write-DebugLog 'INFO' 'Launching config dialog'
$dialogCmd = "powershell.exe -STA -ExecutionPolicy Bypass -NoProfile -File `"$ScriptDir\config_dialog_win.ps1`""
Write-DebugLog 'DEBUG' "Dialog command: $dialogCmd"
$config = & powershell.exe -STA -ExecutionPolicy Bypass -NoProfile -File "$ScriptDir\config_dialog_win.ps1" 2>$null
Write-DebugLog 'DEBUG' "Config dialog exited: LASTEXITCODE=$LASTEXITCODE config_len=$(if($config){$config.Length}else{0})"
if ($LASTEXITCODE -ne 0 -or -not $config) {
    Write-DebugLog 'INFO' 'Config dialog cancelled or failed, exiting'
    exit 0
}

# ============================================================
#  Parse Config Output
# ============================================================
Write-DebugLog 'DEBUG' "Raw config output: $config"
$fields = $config -split '\|'
Write-DebugLog 'DEBUG' "Parsed $($fields.Count) fields"
if ($fields.Count -lt 13) {
    Write-DebugLog 'ERROR' "Invalid config output: expected 13 fields, got $($fields.Count)"
    Write-Error "Invalid config output: expected 13 fields, got $($fields.Count)"
    exit 1
}

$ACCOUNT_LABEL     = $fields[0]
$SELECTED_CONFIG   = $fields[1]
$MISSION           = $fields[2]
$WORK_DIR          = $fields[3]
$NUM_VARIANTS      = [int]$fields[4]
$V2_PRESET_RAW     = $fields[5]
$V3_PRESET_RAW     = $fields[6]
$MAX_CYCLES        = $fields[7]
$MAX_ITERS         = $fields[8]
$MODEL             = $fields[9]
$MODE              = $fields[10]
$TIME_LIMIT_STR    = $fields[11]
$WEBSITE_BRIEF     = if ($fields.Count -gt 12) { $fields[12] } else { '' }

Write-DebugLog 'INFO' 'Parsed config fields' -Data @{
    Account=$ACCOUNT_LABEL; Config=$SELECTED_CONFIG; WorkDir=$WORK_DIR;
    Variants=$NUM_VARIANTS; V2=$V2_PRESET_RAW; V3=$V3_PRESET_RAW;
    Cycles=$MAX_CYCLES; Iters=$MAX_ITERS; Model=$MODEL; Mode=$MODE;
    TimeLimit=$TIME_LIMIT_STR; Mission=$MISSION.Substring(0, [Math]::Min(100, $MISSION.Length))
}

# Defaults
if (-not $NUM_VARIANTS) { $NUM_VARIANTS = 1 }
if (-not $MODEL) { $MODEL = 'opus' }
if (-not $MODE) { $MODE = 'General' }

if ($MAX_CYCLES -eq 'Infinite' -or -not $MAX_CYCLES) { $MAX_CYCLES = '0' }
if ($MAX_ITERS -eq 'Infinite' -or -not $MAX_ITERS) { $MAX_ITERS = '0' }

# Parse time limit
$TIME_LIMIT_SECS = switch ($TIME_LIMIT_STR) {
    '30 minutes' { 1800 }
    '1 hour'     { 3600 }
    '2 hours'    { 7200 }
    '4 hours'    { 14400 }
    '8 hours'    { 28800 }
    '12 hours'   { 43200 }
    '24 hours'   { 86400 }
    default      { 0 }
}

# Variant presets
$VARIANT_1_PRESET = 'Faithful'
$VARIANT_2_PRESET = if ($V2_PRESET_RAW -and $V2_PRESET_RAW -ne 'N/A') { $V2_PRESET_RAW } else { '' }
$VARIANT_3_PRESET = if ($V3_PRESET_RAW -and $V3_PRESET_RAW -ne 'N/A') { $V3_PRESET_RAW } else { '' }

# ============================================================
#  Validate
# ============================================================
Add-Type -AssemblyName PresentationFramework

if ($NUM_VARIANTS -ge 2 -and -not $VARIANT_2_PRESET) {
    [System.Windows.MessageBox]::Show(
        "You selected $NUM_VARIANTS variations but V2 Preset is N/A.`nPlease pick a creative direction for Variant 2.",
        'SuperTask', 'OK', 'Error')
    exit 0
}

if ($NUM_VARIANTS -ge 3 -and -not $VARIANT_3_PRESET) {
    [System.Windows.MessageBox]::Show(
        "You selected 3 variations but V3 Preset is N/A.`nPlease pick a creative direction for Variant 3.",
        'SuperTask', 'OK', 'Error')
    exit 0
}

# Auto-upgrade variant count
if ($NUM_VARIANTS -eq 1 -and $VARIANT_2_PRESET) { $NUM_VARIANTS = 2 }
if ($NUM_VARIANTS -le 2 -and $VARIANT_3_PRESET) { $NUM_VARIANTS = 3 }

# Working directory
if (-not $WORK_DIR) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Pick your project directory'
    $dialog.SelectedPath = [Environment]::GetFolderPath('Desktop')
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        exit 0
    }
    $WORK_DIR = $dialog.SelectedPath
}

if (-not (Test-Path $WORK_DIR)) {
    [System.Windows.MessageBox]::Show(
        "Directory does not exist: $WORK_DIR",
        'SuperTask', 'OK', 'Error')
    exit 1
}

# Mission
if (-not $MISSION) {
    # Simple input dialog
    $inputWin = New-Object System.Windows.Window
    $inputWin.Title = 'Enter your mission'
    $inputWin.Width = 500
    $inputWin.Height = 300
    $inputWin.WindowStartupLocation = 'CenterScreen'

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = '16'
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = 'Describe what you want Claude to work on autonomously...'
    $label.Margin = '0,0,0,8'
    $panel.Children.Add($label) | Out-Null

    $textBox = New-Object System.Windows.Controls.TextBox
    $textBox.AcceptsReturn = $true
    $textBox.TextWrapping = 'Wrap'
    $textBox.VerticalScrollBarVisibility = 'Auto'
    $textBox.Height = 180
    $panel.Children.Add($textBox) | Out-Null

    $okBtn = New-Object System.Windows.Controls.Button
    $okBtn.Content = 'OK'
    $okBtn.HorizontalAlignment = 'Right'
    $okBtn.Padding = '16,4'
    $okBtn.Margin = '0,8,0,0'
    $okBtn.Add_Click({ $inputWin.DialogResult = $true; $inputWin.Close() })
    $panel.Children.Add($okBtn) | Out-Null

    $inputWin.Content = $panel
    $result = $inputWin.ShowDialog()

    if (-not $result -or -not $textBox.Text.Trim()) {
        exit 0
    }
    $MISSION = $textBox.Text.Trim()
}

# ============================================================
#  Mode label
# ============================================================
$MODE_LABEL = if ($MODE -eq 'Website Builder') { 'Website Builder (Playwright + localhost)' } else { 'General' }

# ============================================================
#  Variant summary
# ============================================================
$VARIANT_SUMMARY = ''
if ($NUM_VARIANTS -eq 1) {
    $VARIANT_SUMMARY = "Variations: 1 (Faithful)"
}
else {
    $VARIANT_SUMMARY = "Variations: $NUM_VARIANTS`n  V1: Faithful to prompt`n  V2: $VARIANT_2_PRESET"
    if ($NUM_VARIANTS -eq 3) {
        $VARIANT_SUMMARY += "`n  V3: $VARIANT_3_PRESET"
    }
}

# ============================================================
#  Confirm
# ============================================================
$missionPreview = $MISSION
if ($missionPreview.Length -gt 200) {
    $missionPreview = $missionPreview.Substring(0, 200) + '...'
}

$cyclesDisplay = if ($MAX_CYCLES -eq '0') { 'Infinite' } else { $MAX_CYCLES }
$itersDisplay  = if ($MAX_ITERS -eq '0') { 'Infinite' } else { $MAX_ITERS }
$timeDisplay   = if ($TIME_LIMIT_SECS -eq 0) { 'No limit' } else { $TIME_LIMIT_STR }

$confirmText = @"
Account: $ACCOUNT_LABEL
Mission: $missionPreview

Directory: $WORK_DIR
Model: $MODEL
Mode: $MODE_LABEL
$VARIANT_SUMMARY
Max cycles: $cyclesDisplay
Max iterations: $itersDisplay
Time limit: $timeDisplay

Ready to launch?
"@

Write-DebugLog 'DEBUG' 'Showing confirmation dialog'
$confirmResult = [System.Windows.MessageBox]::Show(
    $confirmText,
    'SuperTask',
    [System.Windows.MessageBoxButton]::OKCancel,
    [System.Windows.MessageBoxImage]::Question)

Write-DebugLog 'INFO' "Confirm dialog result: $confirmResult"
if ($confirmResult -ne 'OK') {
    Write-DebugLog 'INFO' 'User cancelled at confirmation, exiting'
    exit 0
}

# ============================================================
#  Set environment
# ============================================================
Write-DebugLog 'DEBUG' 'Setting environment variables'
$env:CLAUDE_CONFIG_DIR           = $SELECTED_CONFIG
$env:AUTOLOOP_ACCOUNT            = $ACCOUNT_LABEL
$env:AUTOLOOP_DIR                = $WORK_DIR
$env:AUTOLOOP_INTERVAL           = '30'
$env:AUTOLOOP_TIMEOUT            = '1800'
$env:AUTOLOOP_MODEL              = $MODEL
$env:AUTOLOOP_MAX_CYCLES         = $MAX_CYCLES
$env:AUTOLOOP_MAX_ITERS          = $MAX_ITERS
$env:AUTOLOOP_MODE               = $MODE
$env:AUTOLOOP_WEBSITE_BRIEF      = $WEBSITE_BRIEF
$env:AUTOLOOP_TIME_LIMIT         = $TIME_LIMIT_SECS
$env:AUTOLOOP_NUM_VARIANTS       = $NUM_VARIANTS
$env:AUTOLOOP_VARIANT_1_PRESET   = $VARIANT_1_PRESET
$env:AUTOLOOP_VARIANT_2_PRESET   = $VARIANT_2_PRESET
$env:AUTOLOOP_VARIANT_3_PRESET   = $VARIANT_3_PRESET

# ============================================================
#  Setup directories
# ============================================================
Write-DebugLog 'DEBUG' "Setting up directories in $WORK_DIR"
$logsDir = Join-Path $WORK_DIR 'autoloop-logs'
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

# ============================================================
#  Archive old session
# ============================================================
Write-DebugLog 'DEBUG' 'Checking for old session to archive'
if ($MISSION) {
    $needsArchive = $false
    if (Test-Path (Join-Path $WORK_DIR 'PLAN.md')) { $needsArchive = $true }
    $varDirs = Get-ChildItem -LiteralPath $WORK_DIR -Filter 'variant_*' -Directory -ErrorAction SilentlyContinue
    if ($varDirs) { $needsArchive = $true }

    if ($needsArchive) {
        $archive = Join-Path $logsDir "archive_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Write-DebugLog 'INFO' "Archiving old session to $archive"
        New-Item -ItemType Directory -Path $archive -Force | Out-Null

        $planFile = Join-Path $WORK_DIR 'PLAN.md'
        if (Test-Path $planFile) { Move-Item $planFile $archive -Force -ErrorAction SilentlyContinue }

        foreach ($vdir in $varDirs) {
            Move-Item $vdir.FullName $archive -Force -ErrorAction SilentlyContinue
        }

        $historyLog = Join-Path $logsDir 'history.log'
        $loopLog    = Join-Path $logsDir 'loop.log'
        if (Test-Path $historyLog) { Move-Item $historyLog $archive -Force -ErrorAction SilentlyContinue }
        if (Test-Path $loopLog)    { Move-Item $loopLog $archive -Force -ErrorAction SilentlyContinue }

        foreach ($f in @('STATUS','SESSION','STOP_SIGNAL','ralph_signal.txt','CURRENT_VARIANT')) {
            Remove-Item (Join-Path $logsDir $f) -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================
#  Find claude binary
# ============================================================
Write-DebugLog 'DEBUG' 'Searching for claude binary'
$claudeBin = $null
$candidates = @(
    (Get-Command 'claude' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
    (Get-Command 'claude.exe' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
    (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
    (Join-Path $env:APPDATA 'npm\claude.cmd')
)
foreach ($c in $candidates) {
    $exists = if ($c) { Test-Path $c } else { $false }
    Write-DebugLog 'DEBUG' "Claude candidate: '$c' exists=$exists"
    if ($c -and $exists) {
        $claudeBin = $c
        break
    }
}
Write-DebugLog 'INFO' "Claude binary: $(if($claudeBin){"$claudeBin"}else{'NOT FOUND'})"

if (-not $claudeBin) {
    [System.Windows.MessageBox]::Show(
        'Claude Code binary not found. Cannot initialize.',
        'SuperTask', 'OK', 'Error')
    exit 1
}

# ============================================================
#  Initialize PLAN.md(s) if needed
# ============================================================
function Initialize-Variant {
    param([int]$VNum, [string]$VDir, [string]$VPreset)

    Write-DebugLog 'INFO' "Initialize-Variant: V$VNum dir=$VDir preset=$VPreset"
    $planFile = Join-Path $VDir 'PLAN.md'
    if (Test-Path $planFile) {
        Write-DebugLog 'DEBUG' "Initialize-Variant: PLAN.md already exists, skipping"
        return
    }

    $vLogsDir = Join-Path $VDir 'autoloop-logs'
    New-Item -ItemType Directory -Path $vLogsDir -Force | Out-Null

    $creativeAddon = ''
    if ($VPreset -ne 'Faithful' -and $VPreset) {
        $creativeAddon = @"

IMPORTANT - CREATIVE DIRECTION FOR THIS VARIANT:
$VPreset

You MUST incorporate this creative direction into every aspect of your plan.
"@
    }

    $variantLabel = ''
    if ($NUM_VARIANTS -gt 1) {
        $variantLabel = " (Variant $VNum - $VPreset)"
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $initPrompt = @"
You are initializing an autonomous loop.$variantLabel Mission: "$MISSION"
$creativeAddon

CRITICAL RULE: You MUST write PLAN.md to disk BEFORE doing anything else.

STEP 1 - WRITE PLAN.md NOW with this structure:

# Autonomous Plan

## Mission
$MISSION

## Creative Direction
$VPreset

## Context
[Quick scan of the current directory only. Write 5-15 bullet points.]

## Active Tasks (Priority Order)
1. [ ] First task
2. [ ] Second task

## Completed
(none yet)

## Discoveries
(none yet)

## Meta
- Cycles: 0
- Iterations: 0
- Tasks completed: 0
- Variant: $VNum of $NUM_VARIANTS ($VPreset)
- Last replanned: $timestamp
- Last updated: $timestamp
- Mission started: $timestamp

STEP 2 - Verify PLAN.md exists on disk.
STEP 3 - Create autoloop-logs/ directory if it doesn't exist.

Your ONLY job is to create a solid starting plan. Do NOT execute any tasks.
"@

    $initLog = Join-Path $vLogsDir 'init.log'

    # Properly escape the prompt for CommandLineToArgvW:
    # 1. Escape backslashes before quotes: \" → \\\", \\" → \\\\\\"
    # 2. Escape standalone quotes: " → \"
    # 3. Escape trailing backslashes (they'd escape the closing quote)
    $escapedPrompt = $initPrompt -replace '(\\*)"', '$1$1\"'
    $escapedPrompt = $escapedPrompt -replace '(\\+)$', '$1$1'

    $initArgs = "-p --dangerously-skip-permissions --model $MODEL --max-turns 50 `"$escapedPrompt`""

    Write-DebugLog 'DEBUG' "Initialize-Variant: prompt length=$($initPrompt.Length) escaped_length=$($escapedPrompt.Length)"
    Write-DebugLog 'DEBUG' "Initialize-Variant: prompt first 200 chars: $($initPrompt.Substring(0, [Math]::Min(200, $initPrompt.Length)))"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    # Handle .cmd files (npm install) vs .exe (native install)
    if ($claudeBin -match '\.cmd$') {
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = "/c `"$claudeBin`" $initArgs"
        Write-DebugLog 'DEBUG' 'Initialize-Variant: using cmd.exe /c wrapper for .cmd binary'
    }
    else {
        $psi.FileName = $claudeBin
        $psi.Arguments = $initArgs
        Write-DebugLog 'DEBUG' 'Initialize-Variant: direct .exe invocation'
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $false  # Do NOT redirect stderr — avoids deadlock
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $VDir
    $psi.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = $SELECTED_CONFIG
    $psi.EnvironmentVariables.Remove('CLAUDECODE')  # Remove entirely, not just empty

    Write-DebugLog 'INFO' "Initialize-Variant: launching claude process (FileName=$($psi.FileName) WorkDir=$VDir)"
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        Write-DebugLog 'DEBUG' "Initialize-Variant: process started PID=$($proc.Id)"
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        # 10 minute timeout — init can take a while on large projects
        $exited = $proc.WaitForExit(600000)
        if (-not $exited) {
            Write-DebugLog 'ERROR' "Initialize-Variant: TIMEOUT after 10 minutes, killing PID=$($proc.Id)"
            try { $proc.Kill() } catch {}
            "ERROR: Init timed out after 10 minutes" | Out-File $initLog -Encoding utf8
        }
        else {
            $output = $stdoutTask.GetAwaiter().GetResult()
            Write-DebugLog 'INFO' "Initialize-Variant: process exited code=$($proc.ExitCode) stdout_len=$($output.Length)"
            $output | Out-File $initLog -Encoding utf8
        }
        # Check if PLAN.md was created
        $planCreated = Test-Path $planFile
        Write-DebugLog 'INFO' "Initialize-Variant: PLAN.md created=$planCreated"
    }
    catch {
        Write-DebugLog 'ERROR' "Initialize-Variant: exception: $_"
        Write-ExceptionDetail $_
        "ERROR: $($_.Exception.Message)" | Out-File $initLog -Encoding utf8
    }
}

$initNeeded = $false
if ($NUM_VARIANTS -eq 1) {
    if (-not (Test-Path (Join-Path $WORK_DIR 'PLAN.md'))) { $initNeeded = $true }
}
else {
    for ($v = 1; $v -le $NUM_VARIANTS; $v++) {
        if (-not (Test-Path (Join-Path $WORK_DIR "variant_$v\PLAN.md"))) {
            $initNeeded = $true
            break
        }
    }
}

Write-DebugLog 'DEBUG' "initNeeded=$initNeeded"
if ($initNeeded) {
    Write-DebugLog 'INFO' "Initializing $NUM_VARIANTS variant(s)"
    # Show progress window
    $progressWin = New-Object System.Windows.Window
    $progressWin.Title = 'SuperTask - Initializing'
    $progressWin.Width = 400
    $progressWin.Height = 120
    $progressWin.WindowStartupLocation = 'CenterScreen'
    $progressWin.ResizeMode = 'NoResize'

    $progressText = New-Object System.Windows.Controls.TextBlock
    $progressText.Text = if ($NUM_VARIANTS -gt 1) {
        "Initializing $NUM_VARIANTS variants - creating plans..."
    } else {
        'Initializing - scanning project and creating plan...'
    }
    $progressText.Margin = '20'
    $progressText.TextWrapping = 'Wrap'
    $progressWin.Content = $progressText
    $progressWin.Show()

    # Run init
    if ($NUM_VARIANTS -eq 1) {
        Initialize-Variant -VNum 1 -VDir $WORK_DIR -VPreset 'Faithful'
    }
    else {
        for ($v = 1; $v -le $NUM_VARIANTS; $v++) {
            $vPreset = switch ($v) {
                1 { $VARIANT_1_PRESET }
                2 { $VARIANT_2_PRESET }
                3 { $VARIANT_3_PRESET }
            }
            $vDir = Join-Path $WORK_DIR "variant_$v"
            New-Item -ItemType Directory -Path $vDir -Force | Out-Null
            Initialize-Variant -VNum $v -VDir $vDir -VPreset $vPreset
        }
    }

    $progressWin.Close()

    # Verify plans were created
    $missingPlans = @()
    if ($NUM_VARIANTS -eq 1) {
        if (-not (Test-Path (Join-Path $WORK_DIR 'PLAN.md'))) {
            $missingPlans += 'PLAN.md'
        }
    }
    else {
        for ($v = 1; $v -le $NUM_VARIANTS; $v++) {
            if (-not (Test-Path (Join-Path $WORK_DIR "variant_$v\PLAN.md"))) {
                $missingPlans += "variant_$v\PLAN.md"
            }
        }
    }

    Write-DebugLog 'DEBUG' "Missing plans: $($missingPlans.Count) — $($missingPlans -join ', ')"
    if ($missingPlans.Count -gt 0) {
        $initLog = ''
        if ($NUM_VARIANTS -eq 1) {
            $initLog = Join-Path $WORK_DIR 'autoloop-logs\init.log'
        }
        else {
            $initLog = Join-Path $WORK_DIR "variant_1\autoloop-logs\init.log"
        }

        $tailLog = ''
        if (Test-Path $initLog) {
            $lines = Get-Content $initLog -Tail 15 -ErrorAction SilentlyContinue
            if ($lines) { $tailLog = $lines -join "`n" }
        }

        [System.Windows.MessageBox]::Show(
            "Plan(s) not created: $($missingPlans -join ', ')`n`nClaude may have had an issue during initialization.`n`nInit log (last lines):`n$tailLog`n`nCheck: $initLog",
            'SuperTask - Init Failed', 'OK', 'Error')
        exit 1
    }
}

# ============================================================
#  Clean stale signals
# ============================================================
foreach ($f in @('STOP_SIGNAL','ralph_signal.txt','CURRENT_VARIANT')) {
    Remove-Item (Join-Path $logsDir $f) -Force -ErrorAction SilentlyContinue
}

if ($NUM_VARIANTS -gt 1) {
    for ($v = 1; $v -le $NUM_VARIANTS; $v++) {
        $vSignal = Join-Path $WORK_DIR "variant_$v\autoloop-logs\ralph_signal.txt"
        Remove-Item $vSignal -Force -ErrorAction SilentlyContinue
    }
}

'Starting...' | Out-File (Join-Path $logsDir 'STATUS') -Encoding utf8

# ============================================================
#  Start loop in background
# ============================================================
$loopScript = Join-Path $ScriptDir 'loop.sh'
$termLog = Join-Path $logsDir 'terminal.log'

# The loop.sh is a bash script — on Windows we need Git Bash
Write-DebugLog 'DEBUG' 'Searching for Git Bash'
$gitBash = $null

# Check known Git Bash locations FIRST (before PATH, to avoid picking up WSL bash)
$gitBashCandidates = @(
    'C:\Program Files\Git\bin\bash.exe',
    'C:\Program Files (x86)\Git\bin\bash.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
)
# Also try registry for non-standard installs
try {
    $regPath = Get-ItemProperty 'HKLM:\SOFTWARE\GitForWindows' -Name InstallPath -ErrorAction SilentlyContinue
    if ($regPath) {
        $regBashPath = Join-Path $regPath.InstallPath 'bin\bash.exe'
        $gitBashCandidates += $regBashPath
        Write-DebugLog 'DEBUG' "Git Bash registry path: $regBashPath"
    } else {
        Write-DebugLog 'DEBUG' 'Git Bash registry key not found'
    }
} catch { Write-DebugLog 'DEBUG' "Git Bash registry check failed: $_" }

foreach ($candidate in $gitBashCandidates) {
    $exists = Test-Path $candidate
    Write-DebugLog 'DEBUG' "Git Bash candidate: '$candidate' exists=$exists"
    if ($exists) {
        $gitBash = $candidate
        break
    }
}

# Fall back to PATH only if no known Git Bash found — exclude WSL/System32 bash
if (-not $gitBash) {
    $bashInPath = Get-Command 'bash' -ErrorAction SilentlyContinue
    if ($bashInPath) {
        $isWSL = $bashInPath.Source -match 'System32|WindowsApps'
        Write-DebugLog 'DEBUG' "PATH bash: $($bashInPath.Source) isWSL=$isWSL"
        if (-not $isWSL) {
            $gitBash = $bashInPath.Source
        }
    } else {
        Write-DebugLog 'DEBUG' 'No bash found in PATH'
    }
}

Write-DebugLog 'INFO' "Git Bash: $(if($gitBash){"$gitBash"}else{'NOT FOUND'})"
if (-not $gitBash) {
    [System.Windows.MessageBox]::Show(
        "Git Bash not found. The autonomous loop requires bash.`nInstall Git for Windows: https://git-scm.com/downloads/win",
        'SuperTask', 'OK', 'Error')
    exit 1
}

# Convert Windows paths to Unix-style for bash (handle both upper and lowercase drive letters)
$unixLoopScript = ($loopScript -replace '\\', '/') -replace '^([A-Za-z]):', '/$1'
$unixTermLog = ($termLog -replace '\\', '/') -replace '^([A-Za-z]):', '/$1'
Write-DebugLog 'DEBUG' "Path conversion: loopScript='$loopScript' -> '$unixLoopScript'"
Write-DebugLog 'DEBUG' "Path conversion: termLog='$termLog' -> '$unixTermLog'"
# Escape any single quotes in paths for bash -c argument safety
$escapedScript = $unixLoopScript -replace "'", "'\\'''"
$escapedLog = $unixTermLog -replace "'", "'\\'''"
$bashArgs = "-c `"'$escapedScript' > '$escapedLog' 2>&1`""
Write-DebugLog 'INFO' "Starting loop: $gitBash $bashArgs"
$loopProcess = Start-Process -FilePath $gitBash -ArgumentList $bashArgs `
    -WindowStyle Hidden -PassThru
Write-DebugLog 'INFO' "Loop process started: PID=$($loopProcess.Id)"

# Write lock file
$lockFile = Join-Path $env:TEMP "autoloop-$($loopProcess.Id).lock"
$loopProcess.Id | Out-File $lockFile -Encoding ascii
$WORK_DIR | Out-File "$lockFile.dir" -Encoding ascii
Write-DebugLog 'DEBUG' "Lock file written: $lockFile"

# Register cleanup so lock file is removed when this script exits
Register-EngineEvent PowerShell.Exiting -Action {
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
    Remove-Item "$lockFile.dir" -Force -ErrorAction SilentlyContinue
} | Out-Null

Start-Sleep -Seconds 1

# ============================================================
#  Launch Monitor
# ============================================================
# Windows uses 'python' not 'python3'
$pyBin = if (Get-Command 'python' -ErrorAction SilentlyContinue) { 'python' }
         elseif (Get-Command 'python3' -ErrorAction SilentlyContinue) { 'python3' }
         elseif (Get-Command 'py' -ErrorAction SilentlyContinue) { 'py' }
         else { 'python' }
Write-DebugLog 'INFO' "Launching monitor: $pyBin `"$ScriptDir\monitor.py`" `"$WORK_DIR`" $($loopProcess.Id)"
& $pyBin "$ScriptDir\monitor.py" "$WORK_DIR" "$($loopProcess.Id)"
Write-DebugLog 'INFO' 'Monitor exited, launcher complete'
