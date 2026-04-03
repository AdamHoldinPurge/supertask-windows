<#
.SYNOPSIS
    SuperTask(TM) Debug Utilities — Shared logging infrastructure for Windows scripts.

.DESCRIPTION
    Provides Write-DebugLog, Initialize-DebugLog, Write-EnvironmentDump,
    Write-ExceptionDetail, Assert-NotNull, and Install-DebugTrap.

    Design principles:
    - NEVER writes to stdout (reserved for pipe-separated config output)
    - All output goes to log file + stderr
    - Every call is crash-safe (internal try/catch)
    - Immediate flush on every write
    - Zero external dependencies (pure PowerShell 5.1)
#>

# ============================================================
#  Session State
# ============================================================
$script:_DebugLogPath  = $null
$script:_DebugSessionId = $null
$script:_DebugStartTime = $null
$script:_DebugInitialized = $false

# ============================================================
#  Initialize-DebugLog
# ============================================================
function Initialize-DebugLog {
    <# Creates or rotates log file, writes session header. #>
    try {
        $script:_DebugLogPath = Join-Path $env:TEMP 'supertask-debug.log'
        $script:_DebugStartTime = [System.Diagnostics.Stopwatch]::StartNew()
        $script:_DebugSessionId = '{0:x6}' -f (Get-Random -Maximum 0xFFFFFF)

        # Rotate if >10MB
        if (Test-Path $script:_DebugLogPath) {
            $size = (Get-Item $script:_DebugLogPath).Length
            if ($size -gt 10485760) {
                $bak = "$($script:_DebugLogPath).bak"
                try { Remove-Item $bak -Force -ErrorAction SilentlyContinue } catch {}
                try { Rename-Item $script:_DebugLogPath $bak -Force } catch {}
            }
        }

        $script:_DebugInitialized = $true

        $header = @"

================================================================================
  SUPERTASK DEBUG SESSION [$($script:_DebugSessionId)]
  Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')
  Script:  $($MyInvocation.ScriptName)
  PID:     $PID
  PS Ver:  $($PSVersionTable.PSVersion)
  OS:      $([Environment]::OSVersion.VersionString)
  CLR:     $([Environment]::Version)
  Arch:    $([Environment]::Is64BitProcess) (64-bit process) / $([Environment]::Is64BitOperatingSystem) (64-bit OS)
  STA:     $([System.Threading.Thread]::CurrentThread.GetApartmentState())
================================================================================
"@
        [System.IO.File]::AppendAllText($script:_DebugLogPath, $header + "`r`n")
    }
    catch {
        # If we can't even initialize logging, write to stderr and continue
        try { [Console]::Error.WriteLine("[SUPERTASK-DEBUG] Failed to initialize log: $_") } catch {}
    }
}

# ============================================================
#  Write-DebugLog
# ============================================================
function Write-DebugLog {
    <#
    .SYNOPSIS
        Core logging function. Writes to file + stderr, never stdout.
    .PARAMETER Level
        TRACE, DEBUG, INFO, WARN, ERROR, or FATAL
    .PARAMETER Message
        The log message
    .PARAMETER Data
        Optional object to serialize as JSON
    #>
    param(
        [string]$Level = 'INFO',
        [string]$Message = '',
        [object]$Data = $null
    )

    try {
        if (-not $script:_DebugInitialized) { return }

        # Timestamp + elapsed
        $ts = Get-Date -Format 'HH:mm:ss.fff'
        $elapsed = if ($script:_DebugStartTime) {
            '{0,8:N0}ms' -f $script:_DebugStartTime.Elapsed.TotalMilliseconds
        } else { '       0ms' }

        # Caller info from call stack
        $caller = '?'
        try {
            $stack = Get-PSCallStack
            if ($stack.Count -gt 1) {
                $frame = $stack[1]
                $fn = if ($frame.FunctionName -and $frame.FunctionName -ne '<ScriptBlock>') {
                    $frame.FunctionName
                } else {
                    'script'
                }
                $ln = $frame.ScriptLineNumber
                $caller = "${fn}:${ln}"
            }
        } catch {}

        # Data serialization
        $dataStr = ''
        if ($null -ne $Data) {
            try {
                $dataStr = ' | ' + ($Data | ConvertTo-Json -Depth 3 -Compress -ErrorAction SilentlyContinue)
            }
            catch {
                $dataStr = " | [serialize-error: $($Data.GetType().Name)]"
            }
        }

        # Format: [time] [+elapsed] [SESSION] [LEVEL] [caller] message | data
        $line = "[$ts] [$elapsed] [$($script:_DebugSessionId)] [$($Level.PadRight(5))] [$caller] $Message$dataStr"

        # Write to file — immediate flush via AppendAllText
        try {
            [System.IO.File]::AppendAllText($script:_DebugLogPath, $line + "`r`n")
        } catch {}

        # Also write to stderr (never stdout!)
        try {
            [Console]::Error.WriteLine($line)
        } catch {}
    }
    catch {
        # Logging itself must NEVER crash the app
    }
}

# ============================================================
#  Write-EnvironmentDump
# ============================================================
function Write-EnvironmentDump {
    <# Logs comprehensive environment snapshot at session start. #>

    Write-DebugLog 'INFO' '=== ENVIRONMENT DUMP ==='

    # PowerShell version table
    try {
        $psVer = @{}
        foreach ($key in $PSVersionTable.Keys) {
            $psVer[$key] = $PSVersionTable[$key].ToString()
        }
        Write-DebugLog 'INFO' 'PSVersionTable' -Data $psVer
    } catch { Write-DebugLog 'WARN' "PSVersionTable dump failed: $_" }

    # OS details
    Write-DebugLog 'INFO' "OS: $([Environment]::OSVersion.VersionString)"
    Write-DebugLog 'INFO' "MachineName: $([Environment]::MachineName)"
    Write-DebugLog 'INFO' "UserName: $([Environment]::UserName)"
    Write-DebugLog 'INFO' "CurrentDirectory: $([Environment]::CurrentDirectory)"

    # Thread state
    Write-DebugLog 'INFO' "ApartmentState: $([System.Threading.Thread]::CurrentThread.GetApartmentState())"

    # Loaded assemblies (just the key WPF ones)
    try {
        $wpfAssemblies = @('PresentationFramework','PresentationCore','WindowsBase','System.Windows.Forms')
        foreach ($name in $wpfAssemblies) {
            $loaded = [System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $name }
            if ($loaded) {
                Write-DebugLog 'INFO' "Assembly loaded: $name v$($loaded.GetName().Version)"
            } else {
                Write-DebugLog 'WARN' "Assembly NOT loaded: $name"
            }
        }
    } catch { Write-DebugLog 'WARN' "Assembly check failed: $_" }

    # Key environment variables
    $envVars = @(
        'CLAUDECODE', 'CLAUDE_CONFIG_DIR', 'USERPROFILE', 'TEMP', 'APPDATA',
        'LOCALAPPDATA', 'PATH', 'AUTOLOOP_DIR', 'AUTOLOOP_MODEL', 'AUTOLOOP_MODE'
    )
    foreach ($var in $envVars) {
        $val = [Environment]::GetEnvironmentVariable($var)
        if ($var -eq 'PATH') {
            # PATH is very long — just log length + first 3 entries
            if ($val) {
                $entries = $val -split ';'
                Write-DebugLog 'DEBUG' "ENV PATH: $($entries.Count) entries, first 3: $($entries[0..2] -join '; ')"
            } else {
                Write-DebugLog 'WARN' 'ENV PATH: (empty!)'
            }
        }
        else {
            $display = if ($null -eq $val) { '(not set)' }
                       elseif ($val -eq '') { '(empty string)' }
                       else { $val }
            Write-DebugLog 'DEBUG' "ENV ${var}: $display"
        }
    }

    # Config paths existence
    $configPaths = @{
        'DEFAULT_CONFIG'  = Join-Path $env:USERPROFILE '.claude'
        'ACCOUNTS_FILE'   = Join-Path $env:USERPROFILE '.claude\plugins\autoloop\accounts\accounts.json'
        'ICON_PATH'       = Join-Path $env:USERPROFILE '.claude\plugins\autoloop\icon.png'
        'PLUGIN_DIR'      = Join-Path $env:USERPROFILE '.claude\plugins\autoloop'
        'INSTALLED_PLUGINS' = Join-Path $env:USERPROFILE '.claude\plugins\installed_plugins.json'
        'SETTINGS'        = Join-Path $env:USERPROFILE '.claude\settings.json'
    }
    foreach ($name in $configPaths.Keys) {
        $p = $configPaths[$name]
        $exists = Test-Path $p
        Write-DebugLog 'DEBUG' "Path $name : $p [exists=$exists]"
    }

    # Claude binary search
    $binaryPaths = @(
        @{Name='PATH claude';     Path=(Get-Command 'claude' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)},
        @{Name='PATH claude.exe'; Path=(Get-Command 'claude.exe' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)},
        @{Name='PATH claude.cmd'; Path=(Get-Command 'claude.cmd' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)},
        @{Name='Native';          Path=(Join-Path $env:USERPROFILE '.local\bin\claude.exe')},
        @{Name='npm AppData';     Path=(Join-Path $env:APPDATA 'npm\claude.cmd')},
        @{Name='npm LocalApp';    Path=(Join-Path $env:LOCALAPPDATA 'npm\claude.cmd')}
    )
    foreach ($b in $binaryPaths) {
        $exists = if ($b.Path) { Test-Path $b.Path } else { $false }
        Write-DebugLog 'DEBUG' "Claude binary [$($b.Name)]: $($b.Path) [exists=$exists]"
    }

    Write-DebugLog 'INFO' '=== END ENVIRONMENT DUMP ==='
}

# ============================================================
#  Write-ExceptionDetail
# ============================================================
function Write-ExceptionDetail {
    <# Logs full exception chain with PowerShell ErrorRecord details. #>
    param([object]$ErrorRecord)

    try {
        if (-not $ErrorRecord) {
            Write-DebugLog 'ERROR' 'Write-ExceptionDetail called with null ErrorRecord'
            return
        }

        # PowerShell ErrorRecord details
        if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
            $inv = $ErrorRecord.InvocationInfo
            Write-DebugLog 'ERROR' "ErrorRecord: $($ErrorRecord.ToString())"
            Write-DebugLog 'ERROR' "Category: $($ErrorRecord.CategoryInfo.Category)"
            if ($inv) {
                Write-DebugLog 'ERROR' "ScriptName: $($inv.ScriptName)"
                Write-DebugLog 'ERROR' "ScriptLine: $($inv.ScriptLineNumber)"
                Write-DebugLog 'ERROR' "OffendingLine: $($inv.Line.Trim())"
                Write-DebugLog 'ERROR' "PositionMessage: $($inv.PositionMessage)"
            }
        }

        # Exception chain
        $ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
            $ErrorRecord.Exception
        } elseif ($ErrorRecord -is [System.Exception]) {
            $ErrorRecord
        } else {
            Write-DebugLog 'ERROR' "Unknown error type: $($ErrorRecord.GetType().FullName) — $ErrorRecord"
            return
        }

        $depth = 0
        while ($ex -and $depth -lt 5) {
            $prefix = if ($depth -eq 0) { 'Exception' } else { "InnerException[$depth]" }
            Write-DebugLog 'ERROR' "$prefix Type: $($ex.GetType().FullName)"
            Write-DebugLog 'ERROR' "$prefix Message: $($ex.Message)"
            if ($ex.StackTrace) {
                # Log first 5 lines of stack trace
                $stackLines = $ex.StackTrace -split "`n" | Select-Object -First 5
                foreach ($sl in $stackLines) {
                    Write-DebugLog 'ERROR' "$prefix Stack: $($sl.Trim())"
                }
            }
            $ex = $ex.InnerException
            $depth++
        }
    }
    catch {
        try { Write-DebugLog 'ERROR' "Write-ExceptionDetail itself failed: $_" } catch {}
    }
}

# ============================================================
#  Assert-NotNull
# ============================================================
function Assert-NotNull {
    <#
    .SYNOPSIS
        Guard function. Logs WARN if value is $null, TRACE if non-null.
    .RETURNS
        $true if non-null, $false if null
    #>
    param(
        [string]$Name,
        [object]$Value,
        [string]$Context = ''
    )

    try {
        $ctx = if ($Context) { " ($Context)" } else { '' }
        if ($null -eq $Value) {
            Write-DebugLog 'WARN' "ASSERT FAILED: '$Name' is NULL$ctx"
            return $false
        }
        Write-DebugLog 'TRACE' "Assert OK: '$Name' is non-null$ctx [$($Value.GetType().Name)]"
        return $true
    }
    catch {
        try { Write-DebugLog 'WARN' "Assert-NotNull failed for '$Name': $_" } catch {}
        return $false
    }
}

# ============================================================
#  Install-DebugTrap
# ============================================================
function Install-DebugTrap {
    <#
    .SYNOPSIS
        Installs a global trap to catch unhandled errors and log them.
        NOTE: trap must be installed in the CALLER's scope, so this function
        returns a scriptblock that the caller should invoke with . (dot-source).

        Usage: . (Install-DebugTrap)
    #>

    # Return a scriptblock that installs the trap when dot-sourced
    return {
        trap {
            Write-DebugLog 'ERROR' "UNHANDLED EXCEPTION: $_"
            Write-ExceptionDetail $_
            continue
        }
    }
}

# ============================================================
#  Get-DebugLogPath
# ============================================================
function Get-DebugLogPath {
    <# Returns the current debug log file path. #>
    return $script:_DebugLogPath
}

# ============================================================
#  Get-DebugSessionId
# ============================================================
function Get-DebugSessionId {
    <# Returns the current session ID. #>
    return $script:_DebugSessionId
}
