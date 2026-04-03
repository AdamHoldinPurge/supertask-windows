<#
.SYNOPSIS
    SuperTask(TM) - Windows Config Dialog (PowerShell + WPF)
    Equivalent of config_dialog.py for Windows.

.DESCRIPTION
    Presents a WPF dialog for configuring autonomous loop sessions.
    Checks plugin status, manages accounts, and outputs pipe-separated
    config values on stdout for launcher_win.ps1 to parse.

    Output format (pipe-separated):
    account_label|config_dir|mission|work_dir|variations|v2_preset|v3_preset|
    max_cycles|max_iters|model|mode|time_limit|website_brief_path

    Exit code 0 = Launch, Exit code 1 = Cancel/Error
#>

# ============================================================
#  Assemblies
# ============================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# --- Debug Infrastructure ---
. "$PSScriptRoot\debug_utils.ps1"
Initialize-DebugLog
Write-DebugLog 'INFO' 'config_dialog_win.ps1 starting'
Write-EnvironmentDump
. (Install-DebugTrap)

# Ensure STA mode for WPF
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-DebugLog 'FATAL' 'Not running in STA mode — WPF will fail'
    Write-Error 'This script must run in STA mode. Use: powershell.exe -STA -File <script>'
    exit 1
}
Write-DebugLog 'DEBUG' 'STA mode confirmed'

# ============================================================
#  Constants
# ============================================================
$script:DEFAULT_CONFIG = Join-Path $env:USERPROFILE '.claude'
$script:CONFIG_BASE    = Join-Path $env:USERPROFILE '.claude-supertask'
$script:ACCOUNTS_FILE  = Join-Path $script:DEFAULT_CONFIG 'plugins\autoloop\accounts\accounts.json'
$script:ICON_PATH      = Join-Path $script:DEFAULT_CONFIG 'plugins\autoloop\icon.png'
$script:PLUGIN_DIR     = Join-Path $script:DEFAULT_CONFIG 'plugins\autoloop'

# Read version for display
$script:VERSION_STRING = '1.10.0'
try {
    $vf = Join-Path $script:PLUGIN_DIR 'VERSION'
    if (Test-Path $vf) { $script:VERSION_STRING = (Get-Content $vf -Raw).Trim() }
} catch {}

$script:PRESET_NAMES = @(
    'Faithful','Hyper-Creative','Ultra-Modern Minimalist',
    'Bold & Maximalist','Dark & Premium','Playful & Energetic',
    'Retro & Nostalgic','Organic & Natural','Corporate & Professional',
    'Avant-Garde & Experimental','Brutalist & Raw','Warm & Inviting'
)

$script:PRESET_DESCRIPTIONS = @{
    'Faithful'                   = 'Execute exactly as described - no creative liberties'
    'Hyper-Creative'             = 'Break conventions, unexpected combos, surprise the viewer'
    'Ultra-Modern Minimalist'    = 'Whitespace, clean lines, Swiss/Scandinavian design'
    'Bold & Maximalist'          = 'Dense, layered, rich detail - more is more'
    'Dark & Premium'             = 'Dark mode, luxury feel, muted golds and silvers'
    'Playful & Energetic'        = 'Bright colors, rounded shapes, bouncy animations'
    'Retro & Nostalgic'          = 'Vintage aesthetics, textures, serif fonts, warm tones'
    'Organic & Natural'          = 'Earth tones, soft curves, nature-inspired'
    'Corporate & Professional'   = 'Clean, trustworthy, blue/grey palette, grid-based'
    'Avant-Garde & Experimental' = 'Push boundaries, unconventional layouts, artistic'
    'Brutalist & Raw'            = 'Raw HTML energy, exposed structure, monospace fonts'
    'Warm & Inviting'            = 'Comfortable, friendly, warm colors, rounded corners'
}

$script:MAX_CYCLES_OPTIONS = @('Infinite','1','2','3','5','10','25','50','100')
$script:MAX_ITERS_OPTIONS  = @('Infinite','1','3','5','8','10','15','20','30','50')
$script:MODEL_OPTIONS      = @('opus','sonnet','haiku')
$script:MODE_OPTIONS       = @('General','Website Builder')
$script:TIME_LIMIT_OPTIONS = @('No limit','30 minutes','1 hour','2 hours','4 hours','8 hours','12 hours','24 hours')

$script:REQUIRED_PLUGINS = @(
    @{id='ralph-loop@claude-plugins-official';       display='Ralph Loop';      type='marketplace';
      install_cmd='/install ralph-loop@claude-plugins-official'}
    @{id='superpowers@claude-plugins-official';      display='Superpowers';     type='marketplace';
      install_cmd='/install superpowers@claude-plugins-official'}
    @{id='playwright@claude-plugins-official';       display='Playwright';      type='marketplace';
      install_cmd='/install playwright@claude-plugins-official'}
    @{id='frontend-design@claude-plugins-official';  display='Frontend Design'; type='marketplace';
      install_cmd='/install frontend-design@claude-plugins-official'}
    @{id='typescript-lsp@claude-plugins-official';   display='TypeScript LSP';  type='marketplace';
      install_cmd='/install typescript-lsp@claude-plugins-official'}
    @{id='hookify@claude-plugins-official';          display='Hookify';         type='marketplace';
      install_cmd='/install hookify@claude-plugins-official'}
    @{id='autoloop@autoloop-local';                  display='AutoLoop';        type='local';
      install_cmd='irm https://raw.githubusercontent.com/AdamHoldinPurge/autoloop-plugin/master/install.ps1 | iex'}
)

# ============================================================
#  Claude Binary Discovery
# ============================================================
function Find-ClaudeBinary {
    Write-DebugLog 'DEBUG' 'Find-ClaudeBinary: entry'

    # 1. In PATH
    $inPath = Get-Command 'claude' -ErrorAction SilentlyContinue
    if ($inPath) { Write-DebugLog 'INFO' "Find-ClaudeBinary: found 'claude' in PATH -> $($inPath.Source)"; return $inPath.Source }
    $inPath = Get-Command 'claude.exe' -ErrorAction SilentlyContinue
    if ($inPath) { Write-DebugLog 'INFO' "Find-ClaudeBinary: found 'claude.exe' in PATH -> $($inPath.Source)"; return $inPath.Source }
    $inPath = Get-Command 'claude.cmd' -ErrorAction SilentlyContinue
    if ($inPath) { Write-DebugLog 'INFO' "Find-ClaudeBinary: found 'claude.cmd' in PATH -> $($inPath.Source)"; return $inPath.Source }
    Write-DebugLog 'DEBUG' 'Find-ClaudeBinary: not found in PATH'

    # 2. Native installer location
    $native = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path $native) { Write-DebugLog 'INFO' "Find-ClaudeBinary: found native -> $native"; return $native }
    Write-DebugLog 'DEBUG' "Find-ClaudeBinary: native not found at $native"

    # 3. npm global (AppData)
    $npmAppData = Join-Path $env:APPDATA 'npm\claude.cmd'
    if (Test-Path $npmAppData) { Write-DebugLog 'INFO' "Find-ClaudeBinary: found npm AppData -> $npmAppData"; return $npmAppData }
    Write-DebugLog 'DEBUG' "Find-ClaudeBinary: npm AppData not found at $npmAppData"

    # 4. npm global (LocalAppData)
    $npmLocal = Join-Path $env:LOCALAPPDATA 'npm\claude.cmd'
    if (Test-Path $npmLocal) { Write-DebugLog 'INFO' "Find-ClaudeBinary: found npm LocalApp -> $npmLocal"; return $npmLocal }
    Write-DebugLog 'DEBUG' "Find-ClaudeBinary: npm LocalApp not found at $npmLocal"

    Write-DebugLog 'WARN' 'Find-ClaudeBinary: NO claude binary found anywhere'
    return $null
}

# ============================================================
#  Plugin Detection — Primary: CLI
# ============================================================
function Start-ClaudeProcess {
    <# Helper: launch claude binary with proper .cmd/.exe handling #>
    param([string]$ClaudeBin, [string]$Arguments, [string]$ConfigDir, [int]$TimeoutMs = 15000)

    Write-DebugLog 'DEBUG' "Start-ClaudeProcess: entry" -Data @{Binary=$ClaudeBin; Args=$Arguments; ConfigDir=$ConfigDir; Timeout=$TimeoutMs}

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        # .cmd files need cmd.exe /c wrapper when UseShellExecute=$false
        if ($ClaudeBin -match '\.cmd$') {
            $psi.FileName = 'cmd.exe'
            $psi.Arguments = "/c `"$ClaudeBin`" $Arguments"
            Write-DebugLog 'DEBUG' "Start-ClaudeProcess: .cmd detected, wrapping with cmd.exe /c"
        }
        else {
            $psi.FileName = $ClaudeBin
            $psi.Arguments = $Arguments
            Write-DebugLog 'DEBUG' "Start-ClaudeProcess: direct .exe invocation"
        }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $false  # Do NOT redirect stderr — avoids deadlock
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $env:TEMP

        # Prevent nested session detection — remove entirely so it does not exist
        $removed = $psi.EnvironmentVariables.Remove('CLAUDECODE')
        Write-DebugLog 'DEBUG' "Start-ClaudeProcess: CLAUDECODE removed=$removed"
        if ($ConfigDir) {
            $psi.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = $ConfigDir
        }

        Write-DebugLog 'DEBUG' "Start-ClaudeProcess: launching process FileName=$($psi.FileName)"
        $proc = [System.Diagnostics.Process]::Start($psi)
        Write-DebugLog 'DEBUG' "Start-ClaudeProcess: process started PID=$($proc.Id)"
        # Read stdout async to allow timeout to work
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $exited = $proc.WaitForExit($TimeoutMs)

        if (-not $exited) {
            Write-DebugLog 'WARN' "Start-ClaudeProcess: TIMEOUT after ${TimeoutMs}ms, killing PID=$($proc.Id)"
            try { $proc.Kill() } catch {}
            return $null
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        Write-DebugLog 'DEBUG' "Start-ClaudeProcess: exited code=$($proc.ExitCode) stdout_len=$($stdout.Length)"
        if ($proc.ExitCode -eq 0 -and $stdout.Trim()) {
            return $stdout
        }
        Write-DebugLog 'WARN' "Start-ClaudeProcess: non-zero exit or empty stdout (exit=$($proc.ExitCode))"
    }
    catch {
        Write-DebugLog 'ERROR' "Start-ClaudeProcess: exception: $_"
        Write-ExceptionDetail $_
    }

    return $null
}

function Invoke-ClaudePluginList {
    param([string]$ClaudeBin, [string]$ConfigDir)

    Write-DebugLog 'DEBUG' "Invoke-ClaudePluginList: entry ConfigDir=$ConfigDir"

    $stdout = Start-ClaudeProcess -ClaudeBin $ClaudeBin -Arguments 'plugin list --json' `
        -ConfigDir $ConfigDir -TimeoutMs 15000

    if ($stdout) {
        Write-DebugLog 'DEBUG' "Invoke-ClaudePluginList: got stdout ($($stdout.Length) chars)"
        try {
            # @() ensures single-element JSON arrays aren't unwrapped to scalars (PS 5.1 pitfall)
            $result = @($stdout | ConvertFrom-Json)
            Write-DebugLog 'INFO' "Invoke-ClaudePluginList: parsed $($result.Count) plugins from CLI"
            return $result
        } catch {
            Write-DebugLog 'ERROR' "Invoke-ClaudePluginList: ConvertFrom-Json failed: $_"
            Write-DebugLog 'DEBUG' "Invoke-ClaudePluginList: raw stdout first 500 chars: $($stdout.Substring(0, [Math]::Min(500, $stdout.Length)))"
        }
    } else {
        Write-DebugLog 'WARN' 'Invoke-ClaudePluginList: no stdout returned from CLI'
    }
    return $null
}

function Check-PluginsCli {
    param($CliPlugins, [string]$ConfigDir)

    Write-DebugLog 'DEBUG' "Check-PluginsCli: entry with $($CliPlugins.Count) CLI plugins"

    $cliMap = @{}
    foreach ($p in $CliPlugins) {
        $cliMap[$p.id] = $p
    }

    $results = @{}
    foreach ($plugin in $script:REQUIRED_PLUGINS) {
        $pluginId = $plugin.id
        $entry = $cliMap[$pluginId]

        if (-not $entry) {
            Write-DebugLog 'WARN' "Check-PluginsCli: '$pluginId' NOT in CLI output"
            $results[$pluginId] = @{ok = $false; reason = 'Not installed'}
            continue
        }

        # Check for errors — force array wrap to handle PS 5.1 single-element unwrapping
        $errors = @($entry.errors)
        if ($errors -and $errors.Count -gt 0 -and $errors[0]) {
            $err = $errors[0].ToString()
            Write-DebugLog 'WARN' "Check-PluginsCli: '$pluginId' has error: $err"
            if ($err -match 'not found in marketplace') {
                $err = 'Marketplace cache stale - reinstall'
            }
            $results[$pluginId] = @{ok = $false; reason = $err}
            continue
        }

        # Check enabled
        if (-not $entry.enabled) {
            Write-DebugLog 'WARN' "Check-PluginsCli: '$pluginId' is disabled"
            $results[$pluginId] = @{ok = $false; reason = 'Disabled'}
            continue
        }

        # For local plugins, verify files exist
        if ($plugin.type -eq 'local') {
            $srcJson = Join-Path $script:DEFAULT_CONFIG 'plugins\autoloop\.claude-plugin\plugin.json'
            $installPath = $entry.installPath
            $cacheJson = if ($installPath) {
                Join-Path $installPath '.claude-plugin\plugin.json'
            } else { '' }

            Write-DebugLog 'DEBUG' "Check-PluginsCli: local plugin '$pluginId' srcJson=$srcJson (exists=$(Test-Path $srcJson)) cacheJson=$cacheJson"
            if (-not (Test-Path $srcJson) -and -not ($cacheJson -and (Test-Path $cacheJson))) {
                Write-DebugLog 'WARN' "Check-PluginsCli: '$pluginId' files missing"
                $results[$pluginId] = @{ok = $false; reason = 'Files missing'}
                continue
            }
        }

        Write-DebugLog 'DEBUG' "Check-PluginsCli: '$pluginId' OK"
        $results[$pluginId] = @{ok = $true; reason = ''}
    }

    $okCount = ($results.Values | Where-Object { $_.ok }).Count
    Write-DebugLog 'INFO' "Check-PluginsCli: result $okCount/$($results.Count) OK"
    return $results
}

# ============================================================
#  Plugin Detection — Fallback: File System
# ============================================================
function Check-PluginsFiles {
    param([string]$ConfigDir)

    Write-DebugLog 'DEBUG' "Check-PluginsFiles: entry ConfigDir=$ConfigDir"

    $results = @{}

    # Read installed_plugins.json
    $installed = @{}
    $ipFile = Join-Path $ConfigDir 'plugins\installed_plugins.json'
    Write-DebugLog 'DEBUG' "Check-PluginsFiles: reading $ipFile (exists=$(Test-Path $ipFile))"
    if (Test-Path $ipFile) {
        try {
            $data = Get-Content $ipFile -Raw | ConvertFrom-Json
            $pd = if ($data.plugins) { $data.plugins } else { $data }
            foreach ($prop in $pd.PSObject.Properties) {
                if ($prop.Name -notmatch '^_' -and $prop.Name -ne 'version') {
                    $installed[$prop.Name] = $prop.Value
                }
            }
            Write-DebugLog 'DEBUG' "Check-PluginsFiles: installed_plugins has $($installed.Count) entries"
        }
        catch { Write-DebugLog 'WARN' "Check-PluginsFiles: failed to parse installed_plugins.json: $_" }
    }

    # Read settings.json (from default config — shared via hard link)
    $enabled = @{}
    $settingsFile = Join-Path $script:DEFAULT_CONFIG 'settings.json'
    Write-DebugLog 'DEBUG' "Check-PluginsFiles: reading $settingsFile (exists=$(Test-Path $settingsFile))"
    if (Test-Path $settingsFile) {
        try {
            $s = Get-Content $settingsFile -Raw | ConvertFrom-Json
            if ($s.enabledPlugins) {
                foreach ($prop in $s.enabledPlugins.PSObject.Properties) {
                    $enabled[$prop.Name] = $prop.Value
                }
            }
            Write-DebugLog 'DEBUG' "Check-PluginsFiles: settings has $($enabled.Count) enabled plugins"
        }
        catch { Write-DebugLog 'WARN' "Check-PluginsFiles: failed to parse settings.json: $_" }
    }

    # Read known_marketplaces.json
    $knownMkts = @{}
    $kmFile = Join-Path $ConfigDir 'plugins\known_marketplaces.json'
    Write-DebugLog 'DEBUG' "Check-PluginsFiles: reading $kmFile (exists=$(Test-Path $kmFile))"
    if (Test-Path $kmFile) {
        try {
            $km = Get-Content $kmFile -Raw | ConvertFrom-Json
            foreach ($prop in $km.PSObject.Properties) {
                $knownMkts[$prop.Name] = $true
            }
            Write-DebugLog 'DEBUG' "Check-PluginsFiles: known_marketplaces has $($knownMkts.Count) entries"
        }
        catch { Write-DebugLog 'WARN' "Check-PluginsFiles: failed to parse known_marketplaces.json: $_" }
    }

    foreach ($plugin in $script:REQUIRED_PLUGINS) {
        $pluginId = $plugin.id
        # Force array wrap to handle PS 5.1 single-element JSON unwrapping
        $val = $installed[$pluginId]
        $inReg = $installed.ContainsKey($pluginId) -and ($null -ne $val) -and (@($val).Count -gt 0)
        $isOn = $enabled.ContainsKey($pluginId) -and ($enabled[$pluginId] -eq $true)

        if ($plugin.type -eq 'local') {
            $pDir = Join-Path $script:DEFAULT_CONFIG 'plugins\autoloop'
            $pJson = Join-Path $pDir '.claude-plugin\plugin.json'
            $hasMkt = $knownMkts.ContainsKey('autoloop-local')

            if (-not (Test-Path $pDir) -or -not (Test-Path $pJson)) {
                $results[$pluginId] = @{ok = $false; reason = 'Files missing'}
            }
            elseif (-not $hasMkt) {
                $results[$pluginId] = @{ok = $false; reason = 'Marketplace not registered'}
            }
            elseif (-not $inReg) {
                $results[$pluginId] = @{ok = $false; reason = 'Not in plugin registry'}
            }
            elseif (-not $isOn) {
                $results[$pluginId] = @{ok = $false; reason = 'Disabled'}
            }
            else {
                $results[$pluginId] = @{ok = $true; reason = ''}
            }
        }
        else {
            $mkt = if ($pluginId -match '@(.+)$') { $Matches[1] } else { '' }
            $hasMkt = $knownMkts.ContainsKey($mkt)

            if (-not $inReg) {
                $results[$pluginId] = @{ok = $false; reason = 'Not installed'}
            }
            elseif (-not $isOn) {
                $results[$pluginId] = @{ok = $false; reason = 'Disabled'}
            }
            elseif (-not $hasMkt) {
                $results[$pluginId] = @{ok = $false; reason = 'Marketplace missing - may fail'}
            }
            else {
                Write-DebugLog 'DEBUG' "Check-PluginsFiles: '$pluginId' OK"
                $results[$pluginId] = @{ok = $true; reason = ''}
            }
        }
    }

    $okCount = ($results.Values | Where-Object { $_.ok }).Count
    Write-DebugLog 'INFO' "Check-PluginsFiles: result $okCount/$($results.Count) OK"
    return $results
}

# ============================================================
#  Plugin Detection — Main Entry Point
# ============================================================
function Check-Plugins {
    param([string]$ConfigDir = $script:DEFAULT_CONFIG)

    Write-DebugLog 'INFO' "Check-Plugins: entry ConfigDir=$ConfigDir"
    $claudeBin = Find-ClaudeBinary

    # Primary: CLI
    if ($claudeBin) {
        Write-DebugLog 'DEBUG' "Check-Plugins: trying CLI path with $claudeBin"
        $cliPlugins = Invoke-ClaudePluginList -ClaudeBin $claudeBin -ConfigDir $ConfigDir
        if ($null -ne $cliPlugins) {
            Write-DebugLog 'INFO' 'Check-Plugins: using CLI results (primary path)'
            return Check-PluginsCli -CliPlugins $cliPlugins -ConfigDir $ConfigDir
        }
        Write-DebugLog 'WARN' 'Check-Plugins: CLI returned null, falling back to file system'
    } else {
        Write-DebugLog 'WARN' 'Check-Plugins: no claude binary found, using file system fallback'
    }

    # Fallback: File system
    Write-DebugLog 'INFO' 'Check-Plugins: using file system fallback'
    return Check-PluginsFiles -ConfigDir $ConfigDir
}

# ============================================================
#  Account Management
# ============================================================
function Invoke-ClaudeAuthStatus {
    param([string]$ClaudeBin, [string]$ConfigDir)

    Write-DebugLog 'DEBUG' "Invoke-ClaudeAuthStatus: entry ConfigDir=$ConfigDir"

    $stdout = Start-ClaudeProcess -ClaudeBin $ClaudeBin -Arguments 'auth status --json' `
        -ConfigDir $ConfigDir -TimeoutMs 10000

    if ($stdout) {
        try {
            $result = $stdout | ConvertFrom-Json
            Write-DebugLog 'DEBUG' "Invoke-ClaudeAuthStatus: loggedIn=$($result.loggedIn) email=$($result.email)"
            return $result
        } catch {
            Write-DebugLog 'WARN' "Invoke-ClaudeAuthStatus: ConvertFrom-Json failed: $_"
        }
    } else {
        Write-DebugLog 'WARN' 'Invoke-ClaudeAuthStatus: no stdout'
    }
    return $null
}

function Get-Accounts {
    Write-DebugLog 'DEBUG' 'Get-Accounts: entry'
    $accounts = [System.Collections.ArrayList]::new()
    $claudeBin = Find-ClaudeBinary

    # Default account
    if ($claudeBin) {
        $data = Invoke-ClaudeAuthStatus -ClaudeBin $claudeBin -ConfigDir $script:DEFAULT_CONFIG
        if ($data -and $data.loggedIn) {
            [void]$accounts.Add(@{
                email      = if ($data.email) { $data.email } else { 'unknown' }
                plan       = if ($data.subscriptionType) { $data.subscriptionType } else { '' }
                config_dir = $script:DEFAULT_CONFIG
            })
            Write-DebugLog 'DEBUG' "Get-Accounts: default account found email=$($data.email)"
        } else {
            Write-DebugLog 'WARN' 'Get-Accounts: default account not logged in'
        }
    }

    # Supertask accounts
    Write-DebugLog 'DEBUG' "Get-Accounts: checking ACCOUNTS_FILE=$($script:ACCOUNTS_FILE) exists=$(Test-Path $script:ACCOUNTS_FILE)"
    if (Test-Path $script:ACCOUNTS_FILE) {
        try {
            $stored = @(Get-Content $script:ACCOUNTS_FILE -Raw | ConvertFrom-Json)
            Write-DebugLog 'DEBUG' "Get-Accounts: found $($stored.Count) stored accounts"
            $sorted = $stored | Sort-Object { $_.slot }
            foreach ($a in $sorted) {
                $cd = $a.config_dir
                if (-not $cd -or $cd -eq $script:DEFAULT_CONFIG) { continue }
                if ($claudeBin) {
                    $data = Invoke-ClaudeAuthStatus -ClaudeBin $claudeBin -ConfigDir $cd
                    if ($data -and $data.loggedIn) {
                        [void]$accounts.Add(@{
                            email      = if ($data.email) { $data.email } else { 'unknown' }
                            plan       = if ($data.subscriptionType) { $data.subscriptionType } else { '' }
                            config_dir = $cd
                        })
                        Write-DebugLog 'DEBUG' "Get-Accounts: supertask account found email=$($data.email) config=$cd"
                    }
                }
            }
        }
        catch { Write-DebugLog 'WARN' "Get-Accounts: error reading accounts file: $_" }
    }

    Write-DebugLog 'INFO' "Get-Accounts: returning $($accounts.Count) accounts"
    return $accounts
}

function Find-NextSlot {
    Write-DebugLog 'DEBUG' 'Find-NextSlot: entry'
    $used = @{}
    if (Test-Path $script:ACCOUNTS_FILE) {
        try {
            $stored = @(Get-Content $script:ACCOUNTS_FILE -Raw | ConvertFrom-Json)
            foreach ($a in $stored) {
                # Cast to [int] — ConvertFrom-Json returns Int64, hashtable keys need matching types
                $used[[int]$a.slot] = $true
            }
            Write-DebugLog 'DEBUG' "Find-NextSlot: used slots: $($used.Keys -join ',')"
        }
        catch { Write-DebugLog 'WARN' "Find-NextSlot: error reading accounts: $_" }
    }
    for ($i = 1; $i -lt 20; $i++) {
        if (-not $used.ContainsKey($i)) {
            Write-DebugLog 'DEBUG' "Find-NextSlot: returning slot $i"
            return $i
        }
    }
    Write-DebugLog 'WARN' 'Find-NextSlot: all slots 1-19 used, returning 99'
    return 99
}

function Save-Account {
    param([int]$Slot, [string]$Email, [string]$Plan, [string]$ConfigDir)

    Write-DebugLog 'INFO' "Save-Account: slot=$Slot email=$Email plan=$Plan configDir=$ConfigDir"

    $dir = Split-Path $script:ACCOUNTS_FILE -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-DebugLog 'DEBUG' "Save-Account: created directory $dir"
    }

    $accounts = @()
    if (Test-Path $script:ACCOUNTS_FILE) {
        try {
            $accounts = @(Get-Content $script:ACCOUNTS_FILE -Raw | ConvertFrom-Json)
        }
        catch {
            Write-DebugLog 'WARN' "Save-Account: error reading existing accounts: $_"
            $accounts = @()
        }
    }

    $accounts = @($accounts | Where-Object { $_.slot -ne $Slot })
    $accounts += @{
        slot       = $Slot
        email      = $Email
        plan       = $Plan
        config_dir = $ConfigDir
        label      = "Account $Slot"
    }
    $accounts = @($accounts | Sort-Object { $_.slot })

    # Use -InputObject to prevent pipeline unwrapping single-element arrays
    # Write UTF-8 without BOM to avoid breaking JSON parsers
    $json = ConvertTo-Json -InputObject $accounts -Depth 5
    try {
        [System.IO.File]::WriteAllText($script:ACCOUNTS_FILE, $json, [System.Text.UTF8Encoding]::new($false))
        Write-DebugLog 'INFO' "Save-Account: wrote $($accounts.Count) accounts to $($script:ACCOUNTS_FILE)"
    } catch {
        Write-DebugLog 'ERROR' "Save-Account: failed to write file: $_"
        Write-ExceptionDetail $_
    }
}

# ============================================================
#  WPF XAML — Main Window
# ============================================================
$script:MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SuperTask&#x2122;" Width="580" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#FAFAFA" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style x:Key="DimLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#888888"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
    </Style>
  </Window.Resources>

  <Grid Margin="20,12,20,12">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="120"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Row 0: Title -->
    <TextBlock Grid.Row="0" Grid.ColumnSpan="2"
               Text="Configure your autonomous session"
               FontWeight="Bold" FontSize="14" Margin="0,0,0,12"/>

    <!-- Row 1: Account -->
    <TextBlock Grid.Row="1" Grid.Column="0" Style="{StaticResource DimLabel}" Text="Account"/>
    <ComboBox  Grid.Row="1" Grid.Column="1" x:Name="AccountCombo" Margin="0,2,0,6"/>

    <!-- Row 2: Plugins -->
    <TextBlock Grid.Row="2" Grid.Column="0" Style="{StaticResource DimLabel}"
               Text="Plugins" VerticalAlignment="Top" Margin="0,4,10,0"/>
    <StackPanel Grid.Row="2" Grid.Column="1" x:Name="PluginsPanel" Margin="0,2,0,6">
      <StackPanel x:Name="PluginListPanel" Margin="0,0,0,4"/>
      <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
        <Button x:Name="RefreshBtn" Content="Refresh" Padding="10,3" Margin="0,0,8,0"/>
        <TextBlock x:Name="PluginSummary" VerticalAlignment="Center"
                   TextWrapping="Wrap" MaxWidth="320"/>
      </StackPanel>
    </StackPanel>

    <!-- Row 3: Mission -->
    <TextBlock Grid.Row="3" Grid.Column="0" Style="{StaticResource DimLabel}"
               Text="Mission" VerticalAlignment="Top" Margin="0,4,10,0"/>
    <TextBox   Grid.Row="3" Grid.Column="1" x:Name="MissionBox"
               AcceptsReturn="True" TextWrapping="Wrap"
               VerticalScrollBarVisibility="Auto"
               MinHeight="32" MaxHeight="120"
               Margin="0,2,0,6" Padding="4,3"/>

    <!-- Row 4: Working Directory -->
    <TextBlock Grid.Row="4" Grid.Column="0" Style="{StaticResource DimLabel}" Text="Working Directory"/>
    <DockPanel Grid.Row="4" Grid.Column="1" Margin="0,2,0,6">
      <Button x:Name="BrowseBtn" Content="Browse" DockPanel.Dock="Right"
              Padding="10,3" Margin="6,0,0,0"/>
      <TextBox x:Name="DirEntry" Padding="4,3"/>
    </DockPanel>

    <!-- Row 5: Separator -->
    <Separator Grid.Row="5" Grid.ColumnSpan="2" Margin="0,4,0,4"/>

    <!-- Row 6: Variations -->
    <TextBlock Grid.Row="6" Grid.Column="0" Style="{StaticResource DimLabel}" Text="Variations"/>
    <ComboBox  Grid.Row="6" Grid.Column="1" x:Name="VariationsCombo" Margin="0,2,0,6"/>

    <!-- Row 7: Variation 1 (hidden) -->
    <TextBlock Grid.Row="7" Grid.Column="0" Style="{StaticResource DimLabel}"
               x:Name="V1Label" Text="Variation 1" Visibility="Collapsed"/>
    <DockPanel Grid.Row="7" Grid.Column="1" x:Name="V1Panel"
               Visibility="Collapsed" Margin="0,2,0,6">
      <Button x:Name="V1PresetBtn" Content="Presets" DockPanel.Dock="Right"
              Padding="10,3" Margin="6,0,0,0"/>
      <TextBox x:Name="V1Entry" Padding="4,3"/>
    </DockPanel>

    <!-- Row 8: Variation 2 (hidden) -->
    <TextBlock Grid.Row="8" Grid.Column="0" Style="{StaticResource DimLabel}"
               x:Name="V2Label" Text="Variation 2" Visibility="Collapsed"/>
    <DockPanel Grid.Row="8" Grid.Column="1" x:Name="V2Panel"
               Visibility="Collapsed" Margin="0,2,0,6">
      <Button x:Name="V2PresetBtn" Content="Presets" DockPanel.Dock="Right"
              Padding="10,3" Margin="6,0,0,0"/>
      <TextBox x:Name="V2Entry" Padding="4,3"/>
    </DockPanel>

    <!-- Row 9: Separator -->
    <Separator Grid.Row="9" Grid.ColumnSpan="2" Margin="0,4,0,4"/>

    <!-- Row 10: Max Cycles -->
    <TextBlock Grid.Row="10" Grid.Column="0" Style="{StaticResource DimLabel}" Text="Max Cycles"/>
    <ComboBox  Grid.Row="10" Grid.Column="1" x:Name="CyclesCombo" Margin="0,2,0,6"/>

    <!-- Row 11: Max Iterations -->
    <TextBlock Grid.Row="11" Grid.Column="0" Style="{StaticResource DimLabel}" Text="Max Iterations"/>
    <ComboBox  Grid.Row="11" Grid.Column="1" x:Name="ItersCombo" Margin="0,2,0,6"/>

    <!-- Row 12: Model -->
    <TextBlock Grid.Row="12" Grid.Column="0" Style="{StaticResource DimLabel}" Text="Model"/>
    <ComboBox  Grid.Row="12" Grid.Column="1" x:Name="ModelCombo" Margin="0,2,0,6"/>

    <!-- Row 13: Mode -->
    <TextBlock Grid.Row="13" Grid.Column="0" Style="{StaticResource DimLabel}" Text="Mode"/>
    <ComboBox  Grid.Row="13" Grid.Column="1" x:Name="ModeCombo" Margin="0,2,0,6"/>

    <!-- Row 14: Website Brief (hidden) -->
    <TextBlock Grid.Row="14" Grid.Column="0" Style="{StaticResource DimLabel}"
               x:Name="WbLabel" Text="Website Brief" Visibility="Collapsed"/>
    <StackPanel Grid.Row="14" Grid.Column="1" x:Name="WbPanel"
                Orientation="Horizontal" Visibility="Collapsed" Margin="0,2,0,6">
      <Button x:Name="WbBtn" Content="Open Website Brief..." Padding="10,3" Margin="0,0,8,0"/>
      <TextBlock x:Name="WbStatus" Text="Not configured"
                 Foreground="#888" VerticalAlignment="Center" FontSize="11"/>
    </StackPanel>

    <!-- Row 15: Time Limit -->
    <TextBlock Grid.Row="15" Grid.Column="0" Style="{StaticResource DimLabel}" Text="Time Limit"/>
    <ComboBox  Grid.Row="15" Grid.Column="1" x:Name="TimeCombo" Margin="0,2,0,6"/>

    <!-- Row 16: Buttons -->
    <StackPanel Grid.Row="16" Grid.ColumnSpan="2" Orientation="Horizontal"
                HorizontalAlignment="Right" Margin="0,14,0,4">
      <Button x:Name="CancelBtn" Content="Cancel" Width="90" Padding="4,6" Margin="0,0,8,0"/>
      <Button x:Name="LaunchBtn" Content="Launch" Width="90" Padding="4,6"
              IsEnabled="False" FontWeight="Bold"
              Background="#2196F3" Foreground="White" BorderBrush="#1976D2"/>
    </StackPanel>
  </Grid>
</Window>
'@

# ============================================================
#  WPF XAML — Preset Picker Window
# ============================================================
$script:PresetXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Pick a Creative Direction" Width="480" Height="440"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        FontFamily="Segoe UI" FontSize="13">
  <DockPanel Margin="16,12,16,8">
    <TextBlock DockPanel.Dock="Top" FontWeight="Bold" Margin="0,0,0,10"
               Text="Choose a preset or type your own direction"/>
    <Button DockPanel.Dock="Bottom" x:Name="PresetCancelBtn" Content="Cancel"
            HorizontalAlignment="Right" Padding="12,4" Margin="0,8,0,0"/>
    <ScrollViewer VerticalScrollBarVisibility="Auto">
      <StackPanel x:Name="PresetList"/>
    </ScrollViewer>
  </DockPanel>
</Window>
'@

# ============================================================
#  XAML Loader Helper
# ============================================================
function Load-Xaml {
    param([string]$XamlString)
    Write-DebugLog 'DEBUG' "Load-Xaml: parsing XAML ($($XamlString.Length) chars)"
    $sr = [System.IO.StringReader]::new($XamlString)
    try {
        $reader = [System.Xml.XmlReader]::Create($sr)
        try {
            $result = [System.Windows.Markup.XamlReader]::Load($reader)
            Write-DebugLog 'INFO' "Load-Xaml: SUCCESS — created $($result.GetType().Name)"
            return $result
        }
        catch {
            Write-DebugLog 'FATAL' "Load-Xaml: XAML PARSE FAILED: $_"
            Write-ExceptionDetail $_
            throw
        }
        finally { $reader.Close() }
    }
    finally { $sr.Dispose() }
}

# ============================================================
#  Preset Picker Dialog
# ============================================================
function Show-PresetPicker {
    param([System.Windows.Window]$Owner)

    Write-DebugLog 'DEBUG' 'Show-PresetPicker: entry'

    $pWin = Load-Xaml $script:PresetXaml
    $pWin.Owner = $Owner

    $presetList = $pWin.FindName('PresetList')
    $cancelBtn  = $pWin.FindName('PresetCancelBtn')

    Assert-NotNull 'PresetList' $presetList 'Show-PresetPicker' | Out-Null
    Assert-NotNull 'PresetCancelBtn' $cancelBtn 'Show-PresetPicker' | Out-Null

    # Use window Tag to pass selection back — $script: inside .GetNewClosure() refers
    # to the closure's dynamic module scope, NOT the calling script's scope.
    $pWin.Tag = $null

    foreach ($name in $script:PRESET_NAMES) {
        if ($name -eq 'Faithful') { continue }

        $row = New-Object System.Windows.Controls.DockPanel
        $row.Margin = '0,3,0,3'

        $selectBtn = New-Object System.Windows.Controls.Button
        $selectBtn.Content = 'Select'
        $selectBtn.Padding = '10,3'
        $selectBtn.Margin = '8,0,0,0'
        [System.Windows.Controls.DockPanel]::SetDock($selectBtn, 'Right')
        $selectBtn.Tag = $name
        $selectBtn.Add_Click({
            param($sender, $e)
            Write-DebugLog 'DEBUG' "PresetPicker closure: selected '$($sender.Tag)', pWin.Tag type=$($pWin.GetType().Name)"
            $pWin.Tag = $sender.Tag
            $pWin.DialogResult = $true
            $pWin.Close()
        }.GetNewClosure())
        $row.Children.Add($selectBtn) | Out-Null

        $textPanel = New-Object System.Windows.Controls.StackPanel
        $textPanel.Margin = '4,0,0,0'

        $nameLbl = New-Object System.Windows.Controls.TextBlock
        $nameLbl.Text = $name
        $nameLbl.FontWeight = 'Bold'
        $textPanel.Children.Add($nameLbl) | Out-Null

        $desc = $script:PRESET_DESCRIPTIONS[$name]
        if ($desc) {
            $descLbl = New-Object System.Windows.Controls.TextBlock
            $descLbl.Text = $desc
            $descLbl.Foreground = '#888888'
            $descLbl.TextWrapping = 'Wrap'
            $descLbl.MaxWidth = 320
            $textPanel.Children.Add($descLbl) | Out-Null
        }

        $row.Children.Add($textPanel) | Out-Null
        $presetList.Children.Add($row) | Out-Null
    }

    $cancelBtn.Add_Click({
        Write-DebugLog 'DEBUG' 'PresetPicker: cancel clicked'
        $pWin.DialogResult = $false
        $pWin.Close()
    }.GetNewClosure())

    Write-DebugLog 'DEBUG' 'Show-PresetPicker: showing dialog'
    $result = $pWin.ShowDialog()
    Write-DebugLog 'DEBUG' "Show-PresetPicker: dialog closed result=$result tag=$($pWin.Tag)"
    if ($result) {
        Write-DebugLog 'INFO' "Show-PresetPicker: returning '$($pWin.Tag)'"
        return $pWin.Tag
    }
    Write-DebugLog 'DEBUG' 'Show-PresetPicker: cancelled, returning null'
    return $null
}

# ============================================================
#  Main Dialog Logic
# ============================================================
function Show-ConfigDialog {

    Write-DebugLog 'INFO' 'Show-ConfigDialog: entry'

    # --- Load window ---
    $window = Load-Xaml $script:MainXaml
    $window.Title = "SuperTask$([char]0x2122) v$($script:VERSION_STRING)"
    Write-DebugLog 'DEBUG' "Show-ConfigDialog: main window loaded (title=$($window.Title))"

    # --- Set icon ---
    if (Test-Path $script:ICON_PATH) {
        try {
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.UriSource = New-Object Uri($script:ICON_PATH, [UriKind]::Absolute)
            $bitmap.EndInit()
            $window.Icon = $bitmap
            Write-DebugLog 'DEBUG' 'Show-ConfigDialog: icon loaded'
        }
        catch {
            Write-DebugLog 'WARN' "Show-ConfigDialog: icon load failed: $_"
        }
    } else {
        Write-DebugLog 'DEBUG' "Show-ConfigDialog: icon not found at $($script:ICON_PATH)"
    }

    # --- Find named elements ---
    Write-DebugLog 'DEBUG' 'Show-ConfigDialog: resolving named elements via FindName'
    $accountCombo    = $window.FindName('AccountCombo')
    $pluginListPanel = $window.FindName('PluginListPanel')
    $refreshBtn      = $window.FindName('RefreshBtn')
    $pluginSummary   = $window.FindName('PluginSummary')
    $missionBox      = $window.FindName('MissionBox')
    $dirEntry        = $window.FindName('DirEntry')
    $browseBtn       = $window.FindName('BrowseBtn')
    $variationsCombo = $window.FindName('VariationsCombo')
    $v1Label         = $window.FindName('V1Label')
    $v1Panel         = $window.FindName('V1Panel')
    $v1Entry         = $window.FindName('V1Entry')
    $v1PresetBtn     = $window.FindName('V1PresetBtn')
    $v2Label         = $window.FindName('V2Label')
    $v2Panel         = $window.FindName('V2Panel')
    $v2Entry         = $window.FindName('V2Entry')
    $v2PresetBtn     = $window.FindName('V2PresetBtn')
    $cyclesCombo     = $window.FindName('CyclesCombo')
    $itersCombo      = $window.FindName('ItersCombo')
    $modelCombo      = $window.FindName('ModelCombo')
    $modeCombo       = $window.FindName('ModeCombo')
    $wbLabel         = $window.FindName('WbLabel')
    $wbPanel         = $window.FindName('WbPanel')
    $wbBtn           = $window.FindName('WbBtn')
    $wbStatus        = $window.FindName('WbStatus')
    $timeCombo       = $window.FindName('TimeCombo')
    $cancelBtn       = $window.FindName('CancelBtn')
    $launchBtn       = $window.FindName('LaunchBtn')

    # Assert all named elements were found
    $elementNames = @{
        AccountCombo=$accountCombo; PluginListPanel=$pluginListPanel; RefreshBtn=$refreshBtn;
        PluginSummary=$pluginSummary; MissionBox=$missionBox; DirEntry=$dirEntry;
        BrowseBtn=$browseBtn; VariationsCombo=$variationsCombo; V1Label=$v1Label;
        V1Panel=$v1Panel; V1Entry=$v1Entry; V1PresetBtn=$v1PresetBtn;
        V2Label=$v2Label; V2Panel=$v2Panel; V2Entry=$v2Entry; V2PresetBtn=$v2PresetBtn;
        CyclesCombo=$cyclesCombo; ItersCombo=$itersCombo; ModelCombo=$modelCombo;
        ModeCombo=$modeCombo; WbLabel=$wbLabel; WbPanel=$wbPanel; WbBtn=$wbBtn;
        WbStatus=$wbStatus; TimeCombo=$timeCombo; CancelBtn=$cancelBtn; LaunchBtn=$launchBtn
    }
    $nullCount = 0
    foreach ($eName in $elementNames.Keys) {
        if (-not (Assert-NotNull $eName $elementNames[$eName] 'FindName')) { $nullCount++ }
    }
    if ($nullCount -gt 0) {
        Write-DebugLog 'ERROR' "Show-ConfigDialog: $nullCount elements returned NULL from FindName — XAML may be broken"
    } else {
        Write-DebugLog 'INFO' "Show-ConfigDialog: all 27 named elements resolved successfully"
    }

    # --- Populate dropdowns ---
    foreach ($opt in @('1','2','3')) {
        $variationsCombo.Items.Add($opt) | Out-Null
    }
    $variationsCombo.SelectedIndex = 0

    foreach ($opt in $script:MAX_CYCLES_OPTIONS)  { $cyclesCombo.Items.Add($opt) | Out-Null }
    foreach ($opt in $script:MAX_ITERS_OPTIONS)   { $itersCombo.Items.Add($opt)  | Out-Null }
    foreach ($opt in $script:MODEL_OPTIONS)        { $modelCombo.Items.Add($opt)  | Out-Null }
    foreach ($opt in $script:MODE_OPTIONS)         { $modeCombo.Items.Add($opt)   | Out-Null }
    foreach ($opt in $script:TIME_LIMIT_OPTIONS)   { $timeCombo.Items.Add($opt)   | Out-Null }

    $cyclesCombo.SelectedIndex = 0
    $itersCombo.SelectedIndex  = 0
    $modelCombo.SelectedIndex  = 0
    $modeCombo.SelectedIndex   = 0
    $timeCombo.SelectedIndex   = 0

    # --- Accounts ---
    Write-DebugLog 'DEBUG' 'Show-ConfigDialog: loading accounts'
    $script:accounts = @(Get-Accounts)
    Write-DebugLog 'INFO' "Show-ConfigDialog: $($script:accounts.Count) accounts loaded"

    function Populate-AccountCombo {
        Write-DebugLog 'DEBUG' 'Populate-AccountCombo: refreshing'
        $accountCombo.Items.Clear()
        foreach ($acct in $script:accounts) {
            $display = if ($acct.plan) { "$($acct.email) ($($acct.plan))" } else { $acct.email }
            $accountCombo.Items.Add($display) | Out-Null
        }
        $accountCombo.Items.Add('+ Add Account...') | Out-Null
        if ($script:accounts.Count -gt 0) {
            $accountCombo.SelectedIndex = 0
        }
        Write-DebugLog 'DEBUG' "Populate-AccountCombo: $($accountCombo.Items.Count) items"
    }

    function Get-SelectedConfigDir {
        $idx = $accountCombo.SelectedIndex
        if ($idx -ge 0 -and $idx -lt $script:accounts.Count) {
            return $script:accounts[$idx].config_dir
        }
        return $script:DEFAULT_CONFIG
    }

    function Get-AccountLabel {
        $text = $accountCombo.SelectedItem
        if ($text -and $text -ne '+ Add Account...') {
            return $text.ToString()
        }
        if ($script:accounts.Count -gt 0) {
            $a = $script:accounts[0]
            return if ($a.plan) { "$($a.email) ($($a.plan))" } else { $a.email }
        }
        return 'Default'
    }

    # --- Plugin Refresh ---
    function Refresh-PluginStatus {
        Write-DebugLog 'INFO' 'Refresh-PluginStatus: starting'
        $pluginListPanel.Children.Clear()
        $configDir = Get-SelectedConfigDir
        Write-DebugLog 'DEBUG' "Refresh-PluginStatus: configDir=$configDir"
        $statuses = Check-Plugins -ConfigDir $configDir
        $installedCount = 0
        $total = $script:REQUIRED_PLUGINS.Count

        foreach ($plugin in $script:REQUIRED_PLUGINS) {
            $pluginId = $plugin.id
            $info = $statuses[$pluginId]
            if (-not $info) { $info = @{ok = $false; reason = 'Unknown'} }
            $isOk = $info.ok

            $row = New-Object System.Windows.Controls.StackPanel
            $row.Orientation = 'Horizontal'
            $row.Margin = '0,1,0,1'

            # Icon
            $icon = New-Object System.Windows.Controls.TextBlock
            if ($isOk) {
                $icon.Text = [char]0x2713  # checkmark
                $icon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4CAF50')
                $installedCount++
            }
            else {
                $icon.Text = [char]0x2717  # cross
                $icon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F44336')
            }
            $icon.FontWeight = 'Bold'
            $icon.Margin = '0,0,6,0'
            $icon.VerticalAlignment = 'Center'
            $row.Children.Add($icon) | Out-Null

            # Name
            $nameLbl = New-Object System.Windows.Controls.TextBlock
            $nameLbl.Text = $plugin.display
            $nameLbl.VerticalAlignment = 'Center'
            $row.Children.Add($nameLbl) | Out-Null

            if (-not $isOk) {
                # Reason
                if ($info.reason) {
                    $reasonLbl = New-Object System.Windows.Controls.TextBlock
                    $reasonLbl.Text = "($($info.reason))"
                    $reasonLbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#999999')
                    $reasonLbl.FontSize = 11
                    $reasonLbl.Margin = '6,0,6,0'
                    $reasonLbl.VerticalAlignment = 'Center'
                    $row.Children.Add($reasonLbl) | Out-Null
                }

                # Copy or Install button
                if ($plugin.type -eq 'local') {
                    $installBtn = New-Object System.Windows.Controls.Button
                    $installBtn.Content = 'Install'
                    $installBtn.Padding = '8,2'
                    $installBtn.Margin = '4,0,0,0'
                    $installBtn.Add_Click({
                        Install-Autoloop -Button $this
                    }.GetNewClosure())
                    $row.Children.Add($installBtn) | Out-Null
                }
                else {
                    $copyBtn = New-Object System.Windows.Controls.Button
                    $copyBtn.Content = 'Copy'
                    $copyBtn.ToolTip = "Copy install command to clipboard: $($plugin.install_cmd)"
                    $copyBtn.Padding = '8,2'
                    $copyBtn.Margin = '4,0,0,0'
                    $cmdText = $plugin.install_cmd
                    $copyBtn.Add_Click({
                        Write-DebugLog 'DEBUG' "CopyBtn closure: copying '$cmdText'"
                        try { [System.Windows.Clipboard]::SetText($cmdText) }
                        catch { Write-DebugLog 'WARN' "Clipboard copy failed: $_" }
                    }.GetNewClosure())
                    $row.Children.Add($copyBtn) | Out-Null
                }
            }

            $pluginListPanel.Children.Add($row) | Out-Null
        }

        # Summary
        if ($installedCount -eq $total) {
            $pluginSummary.Text = "$installedCount/$total installed"
            $pluginSummary.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4CAF50')
            $pluginSummary.FontWeight = 'Bold'
        }
        else {
            $missing = $total - $installedCount
            $pluginSummary.Text = "$missing missing - install in Claude Code, then click Refresh"
            $pluginSummary.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F44336')
            $pluginSummary.FontWeight = 'Bold'
        }

        # Launch button
        $launchBtn.IsEnabled = ($installedCount -eq $total)
        if (-not $launchBtn.IsEnabled) {
            $launchBtn.ToolTip = 'Install all required plugins first'
        }
        else {
            $launchBtn.ToolTip = $null
        }
        Write-DebugLog 'INFO' "Refresh-PluginStatus: $installedCount/$total installed, LaunchBtn.IsEnabled=$($launchBtn.IsEnabled)"
    }

    # --- Install AutoLoop ---
    function Install-Autoloop {
        param($Button)

        Write-DebugLog 'INFO' 'Install-Autoloop: starting'
        $Button.IsEnabled = $false
        $Button.Content = 'Installing...'
        $window.Cursor = [System.Windows.Input.Cursors]::Wait

        # Force UI update before blocking — WPF-safe dispatcher pump (NOT WinForms DoEvents)
        $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)

        $target = Join-Path $script:DEFAULT_CONFIG 'plugins\autoloop'
        $claudeBin = Find-ClaudeBinary

        try {
            $zipUrl = 'https://github.com/AdamHoldinPurge/autoloop-plugin/archive/refs/heads/master.zip'
            $zipPath = Join-Path $env:TEMP 'autoloop-master.zip'
            $extractPath = Join-Path $env:TEMP 'autoloop-extract'

            # Download
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile($zipUrl, $zipPath)

            # Extract
            if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractPath)

            # Find extracted folder (autoloop-plugin-master)
            $extracted = Get-ChildItem $extractPath -Directory | Select-Object -First 1
            if ($extracted) {
                if (-not (Test-Path $target)) {
                    New-Item -ItemType Directory -Path $target -Force | Out-Null
                }
                Get-ChildItem $extracted.FullName | ForEach-Object {
                    $dest = Join-Path $target $_.Name
                    if ($_.PSIsContainer) {
                        Copy-Item $_.FullName $dest -Recurse -Force
                    }
                    else {
                        Copy-Item $_.FullName $dest -Force
                    }
                }
            }

            # Write marketplace.json
            $mktDir = Join-Path $target '.claude-plugin'
            if (-not (Test-Path $mktDir)) {
                New-Item -ItemType Directory -Path $mktDir -Force | Out-Null
            }
            $mktData = @{
                name        = 'autoloop-local'
                description = 'Local marketplace for autoloop'
                owner       = @{name = 'Adam'; email = 'admin@purgedigital.com.au'}
                plugins     = @(@{
                    name        = 'autoloop'
                    description = 'Self-planning autonomous loop.'
                    version     = '1.10.0'
                    source      = @{
                        source = 'github'
                        repo   = 'AdamHoldinPurge/autoloop-plugin'
                        ref    = 'master'
                    }
                })
            }
            # Write UTF-8 without BOM
            $mktJson = $mktData | ConvertTo-Json -Depth 5
            $mktFile = Join-Path $mktDir 'marketplace.json'
            [System.IO.File]::WriteAllText($mktFile, $mktJson, [System.Text.UTF8Encoding]::new($false))

            # Register marketplace + install via CLI
            if ($claudeBin) {
                Start-ClaudeProcess -ClaudeBin $claudeBin `
                    -Arguments "plugin marketplace add `"$target`"" `
                    -ConfigDir $script:DEFAULT_CONFIG -TimeoutMs 30000 | Out-Null
                Start-ClaudeProcess -ClaudeBin $claudeBin `
                    -Arguments 'plugin install autoloop@autoloop-local' `
                    -ConfigDir $script:DEFAULT_CONFIG -TimeoutMs 30000 | Out-Null

                # Hard-link settings + junction marketplaces for supertask accounts
                if (Test-Path $script:ACCOUNTS_FILE) {
                    try {
                        $accts = @(Get-Content $script:ACCOUNTS_FILE -Raw | ConvertFrom-Json)
                        foreach ($a in $accts) {
                            $cd = $a.config_dir
                            if (-not $cd -or $cd -eq $script:DEFAULT_CONFIG) { continue }
                            $pluginsDir = Join-Path $cd 'plugins'
                            if (-not (Test-Path $pluginsDir)) {
                                New-Item -ItemType Directory -Path $pluginsDir -Force | Out-Null
                            }

                            # Hard-link known_marketplaces.json
                            $kmSrc = Join-Path $script:DEFAULT_CONFIG 'plugins\known_marketplaces.json'
                            $kmDst = Join-Path $pluginsDir 'known_marketplaces.json'
                            if ((Test-Path $kmSrc) -and -not (Test-Path $kmDst)) {
                                cmd /c "mklink /H `"$kmDst`" `"$kmSrc`"" 2>$null | Out-Null
                            }

                            # Junction for marketplaces dir
                            $mktSrc = Join-Path $script:DEFAULT_CONFIG 'plugins\marketplaces'
                            $mktDst = Join-Path $pluginsDir 'marketplaces'
                            if ((Test-Path $mktSrc) -and -not (Test-Path $mktDst)) {
                                cmd /c "mklink /J `"$mktDst`" `"$mktSrc`"" 2>$null | Out-Null
                            }

                            # Install for this account too
                            Start-ClaudeProcess -ClaudeBin $claudeBin `
                                -Arguments 'plugin install autoloop@autoloop-local' `
                                -ConfigDir $cd -TimeoutMs 30000 | Out-Null
                        }
                    }
                    catch { Write-DebugLog 'WARN' "Install-Autoloop: error linking to supertask accounts: $_" }
                }
            }

            # Cleanup
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue

            Write-DebugLog 'INFO' 'Install-Autoloop: install complete, refreshing plugin status'
            Refresh-PluginStatus
        }
        catch {
            Write-DebugLog 'ERROR' "Install-Autoloop: failed: $_"
            Write-ExceptionDetail $_
            [System.Windows.MessageBox]::Show(
                "Install failed: $($_.Exception.Message)",
                'SuperTask',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
            $Button.IsEnabled = $true
            $Button.Content = 'Install'
        }
        finally {
            $window.Cursor = $null
        }
    }

    # --- Event Handlers ---

    # Account changed
    $accountCombo.Add_SelectionChanged({
        Write-DebugLog 'DEBUG' "AccountCombo.SelectionChanged closure: firing"
        $text = $accountCombo.SelectedItem
        if ($null -eq $text) { return }
        Write-DebugLog 'DEBUG' "AccountCombo.SelectionChanged: selected='$text'"
        if ($text.ToString() -ne '+ Add Account...') {
            Refresh-PluginStatus
            return
        }

        Write-DebugLog 'INFO' 'AccountCombo: Add Account selected'
        # Block handler to prevent re-entry
        $accountCombo.IsEnabled = $false

        $slot = Find-NextSlot
        $configDir = "$($script:CONFIG_BASE)-$slot"
        Write-DebugLog 'DEBUG' "Add Account: slot=$slot configDir=$configDir"
        if (-not (Test-Path $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }

        # Hard-link shared settings
        foreach ($sf in @('settings.json','settings.local.json')) {
            $src = Join-Path $script:DEFAULT_CONFIG $sf
            $dst = Join-Path $configDir $sf
            if ((Test-Path $src) -and -not (Test-Path $dst)) {
                try {
                    cmd /c "mklink /H `"$dst`" `"$src`"" 2>$null | Out-Null
                    Write-DebugLog 'DEBUG' "Add Account: hard-linked $sf"
                }
                catch {
                    Write-DebugLog 'WARN' "Add Account: mklink failed for $sf, falling back to copy: $_"
                    try { Copy-Item $src $dst -Force } catch { Write-DebugLog 'WARN' "Add Account: copy also failed: $_" }
                }
            }
        }

        # Open cmd window for login
        $claudeBin = Find-ClaudeBinary
        if (-not $claudeBin) {
            [System.Windows.MessageBox]::Show(
                'Claude Code binary not found. Install Claude Code first.',
                'SuperTask', 'OK', 'Error')
            $accountCombo.IsEnabled = $true
            if ($script:accounts.Count -gt 0) { $accountCombo.SelectedIndex = 0 }
            return
        }

        $loginStatusFile = Join-Path $env:TEMP "supertask-login-$slot.status"
        Remove-Item $loginStatusFile -Force -ErrorAction SilentlyContinue

        $batContent = @"
@echo off
echo ============================================
echo   SuperTask - Add Account
echo ============================================
echo.
echo Your browser will open. Sign in with the
echo account you want to add.
echo.
set "CLAUDECODE="
set "CLAUDE_CONFIG_DIR=$configDir"
"$claudeBin" auth login
echo.
set "CLAUDECODE="
set "CLAUDE_CONFIG_DIR=$configDir"
"$claudeBin" auth status --json > "%TEMP%\st-auth-$slot.json" 2>nul
powershell -NoProfile -Command "try { `$d = Get-Content '%TEMP%\st-auth-$slot.json' -Raw | ConvertFrom-Json; if (`$d.loggedIn) { 'LOGIN_OK' | Out-File -FilePath '$loginStatusFile' -Encoding ascii } else { 'LOGIN_FAIL' | Out-File -FilePath '$loginStatusFile' -Encoding ascii } } catch { 'LOGIN_FAIL' | Out-File -FilePath '$loginStatusFile' -Encoding ascii }"
echo.
echo This window will close in 3 seconds...
timeout /t 3 >nul
"@
        $tempBat = Join-Path $env:TEMP "supertask-login-$slot.bat"
        $batContent | Out-File $tempBat -Encoding ascii
        Start-Process 'cmd.exe' -ArgumentList "/c `"$tempBat`""

        # Show waiting dialog
        $waitWin = New-Object System.Windows.Window
        $waitWin.Title = 'Logging in...'
        $waitWin.Width = 400
        $waitWin.Height = 180
        $waitWin.WindowStartupLocation = 'CenterOwner'
        $waitWin.Owner = $window
        $waitWin.ResizeMode = 'NoResize'

        $waitPanel = New-Object System.Windows.Controls.StackPanel
        $waitPanel.Margin = '20'
        $waitText = New-Object System.Windows.Controls.TextBlock
        $waitText.Text = "Complete the login in the terminal window that opened.`nYour browser should have opened automatically.`n`nThis dialog will close when login completes."
        $waitText.TextWrapping = 'Wrap'
        $waitPanel.Children.Add($waitText) | Out-Null

        $doneBtn = New-Object System.Windows.Controls.Button
        $doneBtn.Content = 'Done'
        $doneBtn.HorizontalAlignment = 'Right'
        $doneBtn.Padding = '16,4'
        $doneBtn.Margin = '0,12,0,0'
        $doneBtn.Add_Click({ $waitWin.Close() }.GetNewClosure())
        $waitPanel.Children.Add($doneBtn) | Out-Null

        $waitWin.Content = $waitPanel

        # Poll timer
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(500)
        $timer.Add_Tick({
            if (Test-Path $loginStatusFile) {
                $timer.Stop()
                $waitWin.Close()
            }
        }.GetNewClosure())
        $timer.Start()

        $waitWin.ShowDialog() | Out-Null
        $timer.Stop()

        # Check result
        $loginOk = $false
        if (Test-Path $loginStatusFile) {
            try {
                $result = (Get-Content $loginStatusFile -Raw).Trim()
                $loginOk = ($result -eq 'LOGIN_OK')
                Write-DebugLog 'DEBUG' "Add Account: login status file result='$result' loginOk=$loginOk"
            }
            catch { Write-DebugLog 'WARN' "Add Account: error reading login status: $_" }
            Remove-Item $loginStatusFile -Force -ErrorAction SilentlyContinue
        } else {
            Write-DebugLog 'WARN' 'Add Account: login status file not found (user closed wait dialog manually?)'
        }

        if ($loginOk) {
            Write-DebugLog 'INFO' 'Add Account: login successful'
            $data = Invoke-ClaudeAuthStatus -ClaudeBin $claudeBin -ConfigDir $configDir
            $newEmail = if ($data -and $data.email) { $data.email } else { 'unknown' }
            $newPlan = if ($data -and $data.subscriptionType) { $data.subscriptionType } else { '' }

            Save-Account -Slot $slot -Email $newEmail -Plan $newPlan -ConfigDir $configDir
            $script:accounts += @{email = $newEmail; plan = $newPlan; config_dir = $configDir}
            Populate-AccountCombo
            $accountCombo.SelectedIndex = $script:accounts.Count - 1

            [System.Windows.MessageBox]::Show(
                "Account added: $newEmail ($newPlan)",
                'SuperTask', 'OK', 'Information')
        }
        else {
            Write-DebugLog 'WARN' 'Add Account: login failed or cancelled'
            if ($script:accounts.Count -gt 0) {
                $accountCombo.SelectedIndex = 0
            }
            [System.Windows.MessageBox]::Show(
                "Login was cancelled or failed.`nSelect '+ Add Account...' to try again.",
                'SuperTask', 'OK', 'Error')
        }

        $accountCombo.IsEnabled = $true
        Refresh-PluginStatus

        # Cleanup temp files
        Remove-Item $tempBat -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $env:TEMP "st-auth-$slot.json") -Force -ErrorAction SilentlyContinue
    }.GetNewClosure())

    # Refresh button
    $refreshBtn.Add_Click({
        Write-DebugLog 'DEBUG' 'RefreshBtn closure: clicked'
        Refresh-PluginStatus
    }.GetNewClosure())
    Write-DebugLog 'TRACE' 'Event handler registered: RefreshBtn.Click'

    # Browse button
    $browseBtn.Add_Click({
        Write-DebugLog 'DEBUG' 'BrowseBtn closure: clicked'
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Pick your project directory'
        $dialog.SelectedPath = [Environment]::GetFolderPath('Desktop')
        $dialog.ShowNewFolderButton = $true
        # Parent to WPF window so dialog doesn't appear behind it
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $owner = New-Object System.Windows.Forms.NativeWindow
        $owner.AssignHandle($helper.Handle)
        Write-DebugLog 'DEBUG' "BrowseBtn: showing FolderBrowserDialog (owner handle=$($helper.Handle))"
        if ($dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
            $dirEntry.Text = $dialog.SelectedPath
            Write-DebugLog 'DEBUG' "BrowseBtn: selected '$($dialog.SelectedPath)'"
        } else {
            Write-DebugLog 'DEBUG' 'BrowseBtn: cancelled'
        }
        $owner.ReleaseHandle()
    }.GetNewClosure())
    Write-DebugLog 'TRACE' 'Event handler registered: BrowseBtn.Click'

    # Variations changed
    $variationsCombo.Add_SelectionChanged({
        $n = 0
        try { $n = [int]$variationsCombo.SelectedItem.ToString() } catch { $n = 1 }
        Write-DebugLog 'DEBUG' "VariationsCombo closure: n=$n"

        if ($n -ge 2) {
            $v1Label.Visibility = 'Visible'
            $v1Panel.Visibility = 'Visible'
        }
        else {
            $v1Label.Visibility = 'Collapsed'
            $v1Panel.Visibility = 'Collapsed'
            $v1Entry.Text = ''
        }

        if ($n -ge 3) {
            $v2Label.Visibility = 'Visible'
            $v2Panel.Visibility = 'Visible'
        }
        else {
            $v2Label.Visibility = 'Collapsed'
            $v2Panel.Visibility = 'Collapsed'
            $v2Entry.Text = ''
        }
    }.GetNewClosure())
    Write-DebugLog 'TRACE' 'Event handler registered: VariationsCombo.SelectionChanged'

    # Mode changed
    $modeCombo.Add_SelectionChanged({
        $mode = $modeCombo.SelectedItem
        if ($null -eq $mode) { return }
        Write-DebugLog 'DEBUG' "ModeCombo closure: mode='$($mode.ToString())'"
        if ($mode.ToString() -eq 'Website Builder') {
            $wbLabel.Visibility = 'Visible'
            $wbPanel.Visibility = 'Visible'
        }
        else {
            $wbLabel.Visibility = 'Collapsed'
            $wbPanel.Visibility = 'Collapsed'
        }
    }.GetNewClosure())
    Write-DebugLog 'TRACE' 'Event handler registered: ModeCombo.SelectionChanged'

    # Preset buttons
    $v1PresetBtn.Add_Click({
        Write-DebugLog 'DEBUG' 'V1PresetBtn closure: clicked'
        $preset = Show-PresetPicker -Owner $window
        if ($preset) {
            $v1Entry.Text = $preset
            Write-DebugLog 'DEBUG' "V1PresetBtn: set to '$preset'"
        }
    }.GetNewClosure())
    Write-DebugLog 'TRACE' 'Event handler registered: V1PresetBtn.Click'

    $v2PresetBtn.Add_Click({
        Write-DebugLog 'DEBUG' 'V2PresetBtn closure: clicked'
        $preset = Show-PresetPicker -Owner $window
        if ($preset) {
            $v2Entry.Text = $preset
            Write-DebugLog 'DEBUG' "V2PresetBtn: set to '$preset'"
        }
    }.GetNewClosure())
    Write-DebugLog 'TRACE' 'Event handler registered: V2PresetBtn.Click'

    # Website Brief button (placeholder — full dialog out of scope)
    $wbBtn.Add_Click({
        Write-DebugLog 'DEBUG' 'WbBtn closure: clicked (not implemented)'
        [System.Windows.MessageBox]::Show(
            'Website Builder Brief dialog is not yet available on Windows.',
            'SuperTask', 'OK', 'Information')
    }.GetNewClosure())
    Write-DebugLog 'TRACE' 'Event handler registered: WbBtn.Click'

    # Cancel / Launch — use a mutable reference object instead of $script: scope,
    # because .GetNewClosure() creates a dynamic module where $script: refers to
    # the module's scope, NOT the calling script's scope.
    $resultRef = @{Value = 'Cancel'}
    $cancelBtn.Add_Click({
        Write-DebugLog 'INFO' "CancelBtn closure: clicked, resultRef type=$($resultRef.GetType().Name)"
        $resultRef.Value = 'Cancel'
        $window.Close()
    }.GetNewClosure())
    Write-DebugLog 'TRACE' 'Event handler registered: CancelBtn.Click'

    $launchBtn.Add_Click({
        Write-DebugLog 'INFO' "LaunchBtn closure: clicked, resultRef type=$($resultRef.GetType().Name)"
        $resultRef.Value = 'OK'
        $window.Close()
    }.GetNewClosure())
    Write-DebugLog 'TRACE' 'Event handler registered: LaunchBtn.Click'

    # --- Initial load ---
    Write-DebugLog 'INFO' 'Show-ConfigDialog: performing initial load'
    Populate-AccountCombo
    Refresh-PluginStatus

    # --- Show dialog ---
    Write-DebugLog 'INFO' 'Show-ConfigDialog: calling ShowDialog()'
    $window.ShowDialog() | Out-Null
    Write-DebugLog 'INFO' "Show-ConfigDialog: dialog closed, resultRef.Value='$($resultRef.Value)'"

    # --- Collect output ---
    if ($resultRef.Value -ne 'OK') {
        Write-DebugLog 'INFO' 'Show-ConfigDialog: user cancelled, exiting with code 1'
        exit 1
    }

    $v1Text = $v1Entry.Text.Trim()
    $v2Text = $v2Entry.Text.Trim()

    function Sanitize([string]$s) {
        return ($s -replace '\|', ' - ' -replace '\r?\n', ' ' -replace '\r', '')
    }

    $parts = @(
        (Sanitize (Get-AccountLabel)),
        (Get-SelectedConfigDir),
        (Sanitize $missionBox.Text.Trim()),
        $dirEntry.Text.Trim(),
        "$($variationsCombo.SelectedItem)",
        (Sanitize $(if ($v1Text) { $v1Text } else { 'N/A' })),
        (Sanitize $(if ($v2Text) { $v2Text } else { 'N/A' })),
        "$($cyclesCombo.SelectedItem)",
        "$($itersCombo.SelectedItem)",
        "$($modelCombo.SelectedItem)",
        "$($modeCombo.SelectedItem)",
        "$($timeCombo.SelectedItem)",
        ''  # website_brief_path (not yet supported on Windows)
    )

    # Output pipe-separated values on stdout
    $outputLine = $parts -join '|'
    Write-DebugLog 'INFO' "Show-ConfigDialog: emitting output ($($outputLine.Length) chars): $($outputLine.Substring(0, [Math]::Min(200, $outputLine.Length)))..."
    Write-Output $outputLine
    Write-DebugLog 'INFO' 'Show-ConfigDialog: exiting with code 0 (launch)'
    exit 0
}

# ============================================================
#  Entry Point
# ============================================================
Write-DebugLog 'INFO' 'Entry point: calling Show-ConfigDialog'
Show-ConfigDialog
