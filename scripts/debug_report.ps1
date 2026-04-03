<#
.SYNOPSIS
    SuperTask(TM) Diagnostic Report Generator

.DESCRIPTION
    Run this script manually when something fails on Windows.
    Collects system info, binary paths, config state, and debug logs
    into a single report file for troubleshooting.

    Usage: powershell.exe -STA -ExecutionPolicy Bypass -NoProfile -File debug_report.ps1

    Output: $env:TEMP\supertask-diagnostic-report.txt
#>

$reportPath = Join-Path $env:TEMP 'supertask-diagnostic-report.txt'
$debugLogPath = Join-Path $env:TEMP 'supertask-debug.log'
$configBase = Join-Path $env:USERPROFILE '.claude'

function Write-Section {
    param([string]$Title, [string]$Content)
    $script:reportLines += ''
    $script:reportLines += ('=' * 72)
    $script:reportLines += "  $Title"
    $script:reportLines += ('=' * 72)
    $script:reportLines += $Content
}

$script:reportLines = @()

$script:reportLines += '###############################################################################'
$script:reportLines += '#                    SUPERTASK DIAGNOSTIC REPORT                              #'
$script:reportLines += "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')                                    #"
$script:reportLines += '###############################################################################'

# ============================================================
#  1. System Info
# ============================================================
$sysInfo = @"
PowerShell Version : $($PSVersionTable.PSVersion)
PSEdition          : $($PSVersionTable.PSEdition)
OS                 : $([Environment]::OSVersion.VersionString)
Platform           : $([Environment]::OSVersion.Platform)
.NET CLR           : $([Environment]::Version)
Architecture       : $(if ([Environment]::Is64BitProcess) {'64-bit'} else {'32-bit'}) process on $(if ([Environment]::Is64BitOperatingSystem) {'64-bit'} else {'32-bit'}) OS
Machine Name       : $([Environment]::MachineName)
User               : $([Environment]::UserName)
Apartment State    : $([System.Threading.Thread]::CurrentThread.GetApartmentState())
Execution Policy   : $(Get-ExecutionPolicy)
Current Directory  : $(Get-Location)
TEMP               : $env:TEMP
USERPROFILE        : $env:USERPROFILE
"@
Write-Section '1. SYSTEM INFO' $sysInfo

# ============================================================
#  2. Claude Binary Discovery
# ============================================================
$binaryReport = @()

# PATH searches
foreach ($name in @('claude','claude.exe','claude.cmd')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) {
        $binaryReport += "  [FOUND] $name in PATH -> $($cmd.Source)"
    } else {
        $binaryReport += "  [-----] $name not in PATH"
    }
}

# Fixed paths
$fixedPaths = @(
    @{Label='Native installer'; Path=(Join-Path $env:USERPROFILE '.local\bin\claude.exe')},
    @{Label='npm AppData';      Path=(Join-Path $env:APPDATA 'npm\claude.cmd')},
    @{Label='npm LocalAppData'; Path=(Join-Path $env:LOCALAPPDATA 'npm\claude.cmd')}
)
foreach ($fp in $fixedPaths) {
    $exists = Test-Path $fp.Path
    $status = if ($exists) { 'FOUND' } else { '-----' }
    $binaryReport += "  [$status] $($fp.Label) -> $($fp.Path)"
}

Write-Section '2. CLAUDE BINARY DISCOVERY' ($binaryReport -join "`n")

# ============================================================
#  3. Git Bash Discovery
# ============================================================
$gitReport = @()

$gitCandidates = @(
    'C:\Program Files\Git\bin\bash.exe',
    'C:\Program Files (x86)\Git\bin\bash.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
)

# Registry
try {
    $regPath = Get-ItemProperty 'HKLM:\SOFTWARE\GitForWindows' -Name InstallPath -ErrorAction SilentlyContinue
    if ($regPath) {
        $regBash = Join-Path $regPath.InstallPath 'bin\bash.exe'
        $gitCandidates += $regBash
        $gitReport += "  Registry GitForWindows: $($regPath.InstallPath)"
    } else {
        $gitReport += '  Registry GitForWindows: (not found)'
    }
} catch {
    $gitReport += "  Registry GitForWindows: (error: $_)"
}

foreach ($candidate in $gitCandidates) {
    $exists = Test-Path $candidate
    $status = if ($exists) { 'FOUND' } else { '-----' }
    $gitReport += "  [$status] $candidate"
}

# PATH bash
$bashInPath = Get-Command 'bash' -ErrorAction SilentlyContinue
if ($bashInPath) {
    $isWSL = $bashInPath.Source -match 'System32|WindowsApps'
    $gitReport += "  PATH bash: $($bashInPath.Source) (WSL=$isWSL)"
} else {
    $gitReport += '  PATH bash: (not found)'
}

Write-Section '3. GIT BASH DISCOVERY' ($gitReport -join "`n")

# ============================================================
#  4. Python Discovery
# ============================================================
$pyReport = @()
foreach ($pyName in @('python','python3','py')) {
    $pyCmd = Get-Command $pyName -ErrorAction SilentlyContinue
    if ($pyCmd) {
        $pyVer = ''
        try { $pyVer = (& $pyCmd.Source --version 2>&1) } catch {}
        $pyReport += "  [FOUND] $pyName -> $($pyCmd.Source) ($pyVer)"
    } else {
        $pyReport += "  [-----] $pyName not found"
    }
}
Write-Section '4. PYTHON DISCOVERY' ($pyReport -join "`n")

# ============================================================
#  5. Config Directory Listing
# ============================================================
$configReport = @()
if (Test-Path $configBase) {
    try {
        $items = Get-ChildItem $configBase -Recurse -Depth 2 -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            $rel = $item.FullName.Substring($configBase.Length)
            $size = if ($item.PSIsContainer) { '<DIR>' } else { "$($item.Length) bytes" }
            $configReport += "  $rel  ($size)"
        }
    } catch {
        $configReport += "  Error listing: $_"
    }
} else {
    $configReport += "  $configBase does NOT exist!"
}
Write-Section '5. CONFIG DIRECTORY LISTING' ($configReport -join "`n")

# ============================================================
#  6. Plugin Files Content
# ============================================================
$pluginReport = @()
$pluginFiles = @(
    @{Label='installed_plugins.json'; Path=(Join-Path $configBase 'plugins\installed_plugins.json')},
    @{Label='settings.json';          Path=(Join-Path $configBase 'settings.json')},
    @{Label='known_marketplaces.json'; Path=(Join-Path $configBase 'plugins\known_marketplaces.json')}
)
foreach ($pf in $pluginFiles) {
    $pluginReport += ''
    $pluginReport += "  --- $($pf.Label) ---"
    if (Test-Path $pf.Path) {
        try {
            $content = Get-Content $pf.Path -Raw -ErrorAction SilentlyContinue
            if ($content.Length -gt 5000) {
                $pluginReport += "  (truncated to 5000 chars, actual size: $($content.Length))"
                $content = $content.Substring(0, 5000) + '...'
            }
            $pluginReport += $content
        } catch {
            $pluginReport += "  Error reading: $_"
        }
    } else {
        $pluginReport += '  (file does not exist)'
    }
}
Write-Section '6. PLUGIN FILES CONTENT' ($pluginReport -join "`n")

# ============================================================
#  7. Accounts File
# ============================================================
$acctReport = @()
$acctFile = Join-Path $configBase 'plugins\autoloop\accounts\accounts.json'
$acctReport += "  Path: $acctFile"
if (Test-Path $acctFile) {
    try {
        $acctContent = Get-Content $acctFile -Raw -ErrorAction SilentlyContinue
        $acctReport += $acctContent
    } catch {
        $acctReport += "  Error reading: $_"
    }
} else {
    $acctReport += '  (file does not exist)'
}
Write-Section '7. ACCOUNTS FILE' ($acctReport -join "`n")

# ============================================================
#  8. Lock Files
# ============================================================
$lockReport = @()
$lockFiles = Get-ChildItem "$env:TEMP\autoloop-*.lock" -ErrorAction SilentlyContinue
if ($lockFiles) {
    foreach ($lf in $lockFiles) {
        $lockReport += "  Lock file: $($lf.Name)"
        try {
            $pidVal = (Get-Content $lf.FullName -Raw).Trim()
            $lockReport += "    PID: $pidVal"
            try {
                $proc = Get-Process -Id ([int]$pidVal) -ErrorAction SilentlyContinue
                if ($proc) {
                    $lockReport += "    Process alive: YES ($($proc.ProcessName))"
                } else {
                    $lockReport += '    Process alive: NO (stale lock)'
                }
            } catch {
                $lockReport += '    Process alive: NO (invalid PID)'
            }
        } catch {
            $lockReport += "    Error reading: $_"
        }

        # .dir file
        $dirFile = "$($lf.FullName).dir"
        if (Test-Path $dirFile) {
            try {
                $lockReport += "    Dir: $((Get-Content $dirFile -Raw).Trim())"
            } catch {}
        }
    }
} else {
    $lockReport += '  No lock files found'
}
Write-Section '8. LOCK FILES' ($lockReport -join "`n")

# ============================================================
#  9. Environment Variables
# ============================================================
$envReport = @()
$allEnv = Get-ChildItem Env: | Sort-Object Name
foreach ($e in $allEnv) {
    if ($e.Name -match '^(AUTOLOOP_|CLAUDE|SUPERTASK)') {
        $envReport += "  $($e.Name) = $($e.Value)"
    }
}
$envReport += ''
$envReport += '  PATH entries:'
$pathEntries = $env:PATH -split ';'
$idx = 0
foreach ($pe in $pathEntries) {
    $envReport += "    [$idx] $pe"
    $idx++
}
Write-Section '9. ENVIRONMENT VARIABLES' ($envReport -join "`n")

# ============================================================
#  10. Debug Log Tail
# ============================================================
$logReport = @()
if (Test-Path $debugLogPath) {
    $logSize = (Get-Item $debugLogPath).Length
    $logReport += "  Log file: $debugLogPath ($logSize bytes)"
    try {
        $lines = Get-Content $debugLogPath -Tail 500 -ErrorAction SilentlyContinue
        if ($lines) {
            $logReport += "  (last 500 lines):"
            $logReport += $lines
        }
    } catch {
        $logReport += "  Error reading: $_"
    }
} else {
    $logReport += "  No debug log found at: $debugLogPath"
}
Write-Section '10. DEBUG LOG (LAST 500 LINES)' ($logReport -join "`n")

# ============================================================
#  11. Loaded Assemblies
# ============================================================
$asmReport = @()
try {
    $assemblies = [System.AppDomain]::CurrentDomain.GetAssemblies() | Sort-Object { $_.GetName().Name }
    foreach ($asm in $assemblies) {
        $asmName = $asm.GetName()
        $asmReport += "  $($asmName.Name) v$($asmName.Version)"
    }
} catch {
    $asmReport += "  Error listing assemblies: $_"
}
Write-Section '11. LOADED .NET ASSEMBLIES' ($asmReport -join "`n")

# ============================================================
#  12. Temp Files
# ============================================================
$tempReport = @()
$tempFiles = Get-ChildItem "$env:TEMP\supertask-*" -ErrorAction SilentlyContinue
if ($tempFiles) {
    foreach ($tf in $tempFiles) {
        $tempReport += "  $($tf.Name) ($($tf.Length) bytes, modified $($tf.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))"
    }
} else {
    $tempReport += '  No supertask temp files found'
}
# Also check for autoloop temp files
$autoloopTemp = Get-ChildItem "$env:TEMP\autoloop-*" -ErrorAction SilentlyContinue
if ($autoloopTemp) {
    $tempReport += ''
    $tempReport += '  Autoloop temp files:'
    foreach ($at in $autoloopTemp) {
        $tempReport += "  $($at.Name) ($($at.Length) bytes, modified $($at.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))"
    }
}
Write-Section '12. TEMP FILES' ($tempReport -join "`n")

# ============================================================
#  Write report
# ============================================================
$script:reportLines += ''
$script:reportLines += ('=' * 72)
$script:reportLines += '  END OF DIAGNOSTIC REPORT'
$script:reportLines += ('=' * 72)

$fullReport = $script:reportLines -join "`r`n"
[System.IO.File]::WriteAllText($reportPath, $fullReport, [System.Text.UTF8Encoding]::new($false))

Write-Host "Diagnostic report saved to: $reportPath"
Write-Host "Debug log at: $debugLogPath"
