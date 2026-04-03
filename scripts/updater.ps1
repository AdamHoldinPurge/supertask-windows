<#
.SYNOPSIS
    SuperTask(TM) Auto-Update Engine v1.10

.DESCRIPTION
    Stage 1 of the 3-stage boot sequence:
        launcher.bat → updater.ps1 → launcher_win.ps1

    Checks for new versions on GitHub. If an update is available,
    shows a WPF dialog with three choices: Update Now, Remind Me Later,
    or Skip This Version.

    Design principles:
    - NEVER blocks the app from launching (all errors caught)
    - Fast path adds ~0ms overhead when throttled (24-hour check interval)
    - 3-second network timeout — never hangs on slow/no internet
    - accounts/ directory is NEVER touched during updates
    - Full backup + automatic rollback on failure
    - Every step logged via Write-DebugLog

    Exit code 0 = success (whether updated or skipped)
    Exit code 1 = should never happen (all errors caught)
#>

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginDir = Split-Path -Parent $ScriptDir

# --- Debug Infrastructure ---
. "$ScriptDir\debug_utils.ps1"
Initialize-DebugLog
Write-DebugLog 'INFO' 'updater.ps1 starting'
Write-DebugLog 'DEBUG' "ScriptDir=$ScriptDir PluginDir=$PluginDir"

# ============================================================
#  Constants
# ============================================================
$REPO_OWNER    = 'AdamHoldinPurge'
$REPO_NAME     = 'supertask-windows'
$BRANCH        = 'main'
$VERSION_URL   = "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$BRANCH/VERSION"
$ZIP_URL       = "https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/heads/$BRANCH.zip"
$THROTTLE_FILE = Join-Path $env:TEMP 'supertask-update-check.txt'
$SKIP_FILE     = Join-Path $env:TEMP 'supertask-skip-version.txt'
$TIMEOUT_MS    = 3000
$THROTTLE_HOURS = 24
$BACKUP_RETENTION_DAYS = 7

# ============================================================
#  Get-LocalVersion
# ============================================================
function Get-LocalVersion {
    <# Reads VERSION file from plugin root, returns [Version] or 0.0.0 #>
    $versionFile = Join-Path $PluginDir 'VERSION'
    Write-DebugLog 'DEBUG' "Get-LocalVersion: reading $versionFile"

    try {
        if (Test-Path $versionFile) {
            $raw = (Get-Content $versionFile -Raw -ErrorAction Stop).Trim()
            $ver = [Version]$raw
            Write-DebugLog 'INFO' "Get-LocalVersion: $ver"
            return $ver
        }
        Write-DebugLog 'WARN' 'Get-LocalVersion: VERSION file not found, returning 0.0.0'
        return [Version]'0.0.0'
    }
    catch {
        Write-DebugLog 'WARN' "Get-LocalVersion: failed to parse VERSION: $_"
        return [Version]'0.0.0'
    }
}

# ============================================================
#  Test-ThrottleExpired
# ============================================================
function Test-ThrottleExpired {
    <# Returns $true if last check was more than 24 hours ago (or never). #>

    try {
        if (-not (Test-Path $THROTTLE_FILE)) {
            Write-DebugLog 'DEBUG' 'Test-ThrottleExpired: no throttle file, returning $true'
            return $true
        }

        $raw = (Get-Content $THROTTLE_FILE -Raw -ErrorAction Stop).Trim()
        $lastCheck = [long]$raw
        $now = [long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        $elapsed = $now - $lastCheck
        $thresholdSecs = $THROTTLE_HOURS * 3600
        $expired = $elapsed -ge $thresholdSecs

        Write-DebugLog 'DEBUG' "Test-ThrottleExpired: lastCheck=$lastCheck now=$now elapsed=${elapsed}s threshold=${thresholdSecs}s expired=$expired"
        return $expired
    }
    catch {
        Write-DebugLog 'WARN' "Test-ThrottleExpired: error reading throttle file: $_"
        return $true
    }
}

# ============================================================
#  Update-ThrottleTimestamp
# ============================================================
function Update-ThrottleTimestamp {
    <# Writes current epoch to throttle file. #>
    try {
        $now = [long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        [System.IO.File]::WriteAllText($THROTTLE_FILE, $now.ToString())
        Write-DebugLog 'DEBUG' "Update-ThrottleTimestamp: wrote $now"
    }
    catch {
        Write-DebugLog 'WARN' "Update-ThrottleTimestamp: failed: $_"
    }
}

# ============================================================
#  Clear-ThrottleTimestamp
# ============================================================
function Clear-ThrottleTimestamp {
    <# Removes throttle file so next launch checks again. #>
    try {
        Remove-Item $THROTTLE_FILE -Force -ErrorAction SilentlyContinue
        Write-DebugLog 'DEBUG' 'Clear-ThrottleTimestamp: throttle cleared'
    }
    catch {
        Write-DebugLog 'WARN' "Clear-ThrottleTimestamp: failed: $_"
    }
}

# ============================================================
#  Get-RemoteVersion
# ============================================================
function Get-RemoteVersion {
    <# Fetches VERSION from GitHub with 3-second timeout. Returns [Version] or $null. #>

    Write-DebugLog 'DEBUG' "Get-RemoteVersion: fetching $VERSION_URL (timeout=${TIMEOUT_MS}ms)"

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

        $request = [System.Net.HttpWebRequest]::Create($VERSION_URL)
        $request.Method = 'GET'
        $request.Timeout = $TIMEOUT_MS
        $request.ReadWriteTimeout = $TIMEOUT_MS
        $request.UserAgent = 'SuperTask-Updater/1.0'

        $response = $request.GetResponse()
        $raw = $null
        try {
            $stream = $response.GetResponseStream()
            try {
                $reader = New-Object System.IO.StreamReader($stream)
                try {
                    $raw = $reader.ReadToEnd().Trim()
                }
                finally { $reader.Close() }
            }
            finally { $stream.Close() }
        }
        finally { $response.Close() }

        $ver = [Version]$raw
        Write-DebugLog 'INFO' "Get-RemoteVersion: $ver"
        return $ver
    }
    catch [System.Net.WebException] {
        $status = if ($_.Exception.Status) { $_.Exception.Status.ToString() } else { 'Unknown' }
        Write-DebugLog 'WARN' "Get-RemoteVersion: WebException status=$status message=$($_.Exception.Message)"
        return $null
    }
    catch {
        Write-DebugLog 'WARN' "Get-RemoteVersion: failed: $_"
        return $null
    }
}

# ============================================================
#  Test-VersionSkipped
# ============================================================
function Test-VersionSkipped {
    param([Version]$RemoteVersion)

    <# Returns $true if the user chose to skip this exact version. #>
    try {
        if (-not (Test-Path $SKIP_FILE)) { return $false }

        $skippedStr = (Get-Content $SKIP_FILE -Raw -ErrorAction Stop).Trim()
        $skipped = [Version]$skippedStr
        $isSkipped = $skipped -eq $RemoteVersion

        Write-DebugLog 'DEBUG' "Test-VersionSkipped: skipped=$skipped remote=$RemoteVersion isSkipped=$isSkipped"
        return $isSkipped
    }
    catch {
        Write-DebugLog 'WARN' "Test-VersionSkipped: error: $_"
        return $false
    }
}

# ============================================================
#  Save-SkippedVersion
# ============================================================
function Save-SkippedVersion {
    param([Version]$VersionToSkip)

    try {
        [System.IO.File]::WriteAllText($SKIP_FILE, $VersionToSkip.ToString())
        Write-DebugLog 'INFO' "Save-SkippedVersion: saved $VersionToSkip"
    }
    catch {
        Write-DebugLog 'WARN' "Save-SkippedVersion: failed: $_"
    }
}

# ============================================================
#  Show-UpdateDialog
# ============================================================
function Show-UpdateDialog {
    param(
        [Version]$LocalVersion,
        [Version]$RemoteVersion
    )

    <#
    Shows WPF update dialog with 3 buttons.
    Returns: 'Update', 'Later', or 'Skip'
    #>

    Write-DebugLog 'INFO' "Show-UpdateDialog: $LocalVersion -> $RemoteVersion"

    try {
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        $resultRef = @{ Value = 'Later' }

        $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SuperTask — Update Available"
        Width="460" Height="280" WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize" Topmost="True"
        Background="#FAFAFA" FontFamily="Segoe UI" FontSize="13">
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Title -->
        <TextBlock Grid.Row="0" FontSize="18" FontWeight="SemiBold" Foreground="#333333"
                   Text="Update Available" Margin="0,0,0,8"/>

        <!-- Version info -->
        <TextBlock Grid.Row="1" FontSize="13" Foreground="#666666" Margin="0,0,0,4">
            <Run Text="SuperTask v$($LocalVersion.ToString())"/>
            <Run Text=" &#x2192; " Foreground="#999999"/>
            <Run Text="v$($RemoteVersion.ToString())" FontWeight="SemiBold" Foreground="#2196F3"/>
        </TextBlock>

        <!-- Description -->
        <TextBlock Grid.Row="2" FontSize="12" Foreground="#888888" TextWrapping="Wrap" Margin="0,4,0,16"
                   Text="A new version of SuperTask is available. Update now to get the latest features and fixes."/>

        <!-- Buttons -->
        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="SkipBtn" Content="Skip This Version" Padding="12,6" Margin="0,0,8,0"
                    Background="#E0E0E0" Foreground="#666666" BorderBrush="#CCCCCC" FontSize="12"/>
            <Button x:Name="LaterBtn" Content="Remind Me Later" Padding="12,6" Margin="0,0,8,0"
                    Background="#E0E0E0" Foreground="#333333" BorderBrush="#CCCCCC" FontSize="12"/>
            <Button x:Name="UpdateBtn" Content="Update Now" Padding="16,6"
                    Background="#4CAF50" Foreground="White" BorderBrush="#388E3C" FontSize="13" FontWeight="SemiBold"/>
        </StackPanel>
    </Grid>
</Window>
"@

        $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)

        $updateBtn = $window.FindName('UpdateBtn')
        $laterBtn  = $window.FindName('LaterBtn')
        $skipBtn   = $window.FindName('SkipBtn')

        $updateBtn.Add_Click({
            $resultRef.Value = 'Update'
            $window.Close()
        }.GetNewClosure())

        $laterBtn.Add_Click({
            $resultRef.Value = 'Later'
            $window.Close()
        }.GetNewClosure())

        $skipBtn.Add_Click({
            $resultRef.Value = 'Skip'
            $window.Close()
        }.GetNewClosure())

        # Check STA mode — WPF ShowDialog requires it
        $apartmentState = [System.Threading.Thread]::CurrentThread.GetApartmentState()
        Write-DebugLog 'DEBUG' "Show-UpdateDialog: ApartmentState=$apartmentState"

        if ($apartmentState -eq 'STA') {
            $window.ShowDialog() | Out-Null
        }
        else {
            # If not STA (shouldn't happen with launcher.bat -STA), fall back
            Write-DebugLog 'WARN' 'Show-UpdateDialog: not STA, using Dispatcher trick'
            $window.Add_Closed({
                [System.Windows.Threading.Dispatcher]::ExitAllFrames()
            }.GetNewClosure())
            $window.Show()
            [System.Windows.Threading.Dispatcher]::Run()
        }

        Write-DebugLog 'INFO' "Show-UpdateDialog: user chose '$($resultRef.Value)'"
        return $resultRef.Value
    }
    catch {
        Write-DebugLog 'ERROR' "Show-UpdateDialog: failed: $_"
        Write-ExceptionDetail $_
        return 'Later'
    }
}

# ============================================================
#  Invoke-Update
# ============================================================
function Invoke-Update {
    param(
        [Version]$FromVersion,
        [Version]$ToVersion
    )

    <#
    Downloads latest from GitHub, backs up current plugin, applies update.
    Returns $true on success, $false on failure (with automatic rollback).
    #>

    Write-DebugLog 'INFO' "Invoke-Update: $FromVersion -> $ToVersion"

    $timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $zipPath    = Join-Path $env:TEMP 'supertask-update.zip'
    $extractDir = Join-Path $env:TEMP 'supertask-update-extract'
    $backupDir  = Join-Path $env:TEMP "supertask-backup-$timestamp"

    try {
        # ---- Step 1: Clean old backups (>7 days) ----
        Write-DebugLog 'DEBUG' 'Invoke-Update: cleaning old backups'
        try {
            $oldBackups = Get-ChildItem "$env:TEMP\supertask-backup-*" -Directory -ErrorAction SilentlyContinue
            $cutoff = (Get-Date).AddDays(-$BACKUP_RETENTION_DAYS)
            foreach ($old in $oldBackups) {
                if ($old.LastWriteTime -lt $cutoff) {
                    Write-DebugLog 'DEBUG' "Invoke-Update: removing old backup $($old.Name)"
                    Remove-Item $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        catch { Write-DebugLog 'WARN' "Invoke-Update: cleanup failed (non-fatal): $_" }

        # ---- Step 2: Backup current plugin (skip accounts/) ----
        Write-DebugLog 'INFO' "Invoke-Update: backing up to $backupDir"
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

        Get-ChildItem $PluginDir -ErrorAction Stop | ForEach-Object {
            if ($_.Name -eq 'accounts' -or $_.Name -eq '.git' -or $_.Name -eq '__pycache__') {
                Write-DebugLog 'DEBUG' "Invoke-Update: SKIPPING $($_.Name) in backup (preserved)"
                return  # Skip user data, git state, and build cache
            }
            $dest = Join-Path $backupDir $_.Name
            if ($_.PSIsContainer) {
                Copy-Item $_.FullName $dest -Recurse -Force
            }
            else {
                Copy-Item $_.FullName $dest -Force
            }
        }
        Write-DebugLog 'DEBUG' "Invoke-Update: backup complete"

        # ---- Step 3: Download zip (with timeout) ----
        Write-DebugLog 'INFO' "Invoke-Update: downloading $ZIP_URL"
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

        $dlRequest = [System.Net.HttpWebRequest]::Create($ZIP_URL)
        $dlRequest.Method = 'GET'
        $dlRequest.Timeout = 60000           # 60s connection timeout
        $dlRequest.ReadWriteTimeout = 60000  # 60s read timeout
        $dlRequest.UserAgent = 'SuperTask-Updater/1.0'
        $dlRequest.AllowAutoRedirect = $true

        $dlResponse = $dlRequest.GetResponse()
        try {
            $dlStream = $dlResponse.GetResponseStream()
            try {
                $fileStream = [System.IO.File]::Create($zipPath)
                try {
                    $dlStream.CopyTo($fileStream)
                }
                finally { $fileStream.Close() }
            }
            finally { $dlStream.Close() }
        }
        finally { $dlResponse.Close() }

        $zipSize = (Get-Item $zipPath).Length
        Write-DebugLog 'INFO' "Invoke-Update: downloaded $zipSize bytes"

        # ---- Step 4: Extract ----
        Write-DebugLog 'DEBUG' "Invoke-Update: extracting to $extractDir"
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)

        # Find the extracted root folder (e.g., supertask-windows-main/)
        $extractedRoot = Get-ChildItem $extractDir -Directory | Select-Object -First 1
        if (-not $extractedRoot) {
            throw 'No root directory found in downloaded zip'
        }
        Write-DebugLog 'DEBUG' "Invoke-Update: extracted root=$($extractedRoot.Name)"

        # ---- Step 5: Apply update (skip accounts/) ----
        Write-DebugLog 'INFO' 'Invoke-Update: applying update files'
        Get-ChildItem $extractedRoot.FullName -ErrorAction Stop | ForEach-Object {
            if ($_.Name -eq 'accounts' -or $_.Name -eq '.git' -or $_.Name -eq '__pycache__') {
                Write-DebugLog 'DEBUG' "Invoke-Update: SKIPPING $($_.Name) in apply (preserved)"
                return  # Never overwrite user data, git state, or build cache
            }
            $dest = Join-Path $PluginDir $_.Name
            if ($_.PSIsContainer) {
                # Remove old directory content, copy new
                if (Test-Path $dest) {
                    Remove-Item $dest -Recurse -Force
                }
                Copy-Item $_.FullName $dest -Recurse -Force
            }
            else {
                Copy-Item $_.FullName $dest -Force
            }
        }
        Write-DebugLog 'DEBUG' 'Invoke-Update: files applied'

        # ---- Step 6: Verify ----
        $newVersionFile = Join-Path $PluginDir 'VERSION'
        if (-not (Test-Path $newVersionFile)) {
            throw 'VERSION file missing after update — corrupted download?'
        }
        $newVer = [Version]((Get-Content $newVersionFile -Raw).Trim())
        if ($newVer -lt $ToVersion) {
            throw "VERSION after update is $newVer, expected >= $ToVersion"
        }
        Write-DebugLog 'INFO' "Invoke-Update: verified new VERSION=$newVer"

        # ---- Step 7: Cleanup ----
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

        # Clear skip file — new version means the old skip is irrelevant
        Remove-Item $SKIP_FILE -Force -ErrorAction SilentlyContinue

        Write-DebugLog 'INFO' "Invoke-Update: SUCCESS ($FromVersion -> $newVer)"
        return $true
    }
    catch {
        $updateError = $_  # Save immediately — nested catch blocks overwrite $_
        Write-DebugLog 'ERROR' "Invoke-Update: FAILED: $updateError"
        Write-ExceptionDetail $updateError

        # ---- Rollback ----
        Write-DebugLog 'WARN' 'Invoke-Update: ROLLING BACK from backup'
        try {
            if (Test-Path $backupDir) {
                # First, remove any files/dirs added by the failed update (except accounts/)
                Get-ChildItem $PluginDir -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($_.Name -eq 'accounts' -or $_.Name -eq '.git' -or $_.Name -eq '__pycache__') { return }
                    $dest = Join-Path $backupDir $_.Name
                    if (-not (Test-Path $dest)) {
                        Write-DebugLog 'DEBUG' "Invoke-Update: rollback removing stale item: $($_.Name)"
                        Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
                # Then restore from backup
                Get-ChildItem $backupDir -ErrorAction Stop | ForEach-Object {
                    $dest = Join-Path $PluginDir $_.Name
                    if ($_.PSIsContainer) {
                        if (Test-Path $dest) {
                            Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
                        }
                        Copy-Item $_.FullName $dest -Recurse -Force
                    }
                    else {
                        Copy-Item $_.FullName $dest -Force
                    }
                }
                Write-DebugLog 'INFO' 'Invoke-Update: rollback complete'
            }
            else {
                Write-DebugLog 'ERROR' 'Invoke-Update: backup dir missing, cannot rollback!'
            }
        }
        catch {
            Write-DebugLog 'ERROR' "Invoke-Update: rollback ALSO failed: $_"
        }

        # Show error to user (use $updateError, not $_ which may be clobbered)
        try {
            Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
            [System.Windows.MessageBox]::Show(
                "Update failed and was rolled back.`n`nError: $($updateError.Exception.Message)`n`nSuperTask will continue with the current version.",
                'SuperTask — Update Error',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning)
        }
        catch { Write-DebugLog 'WARN' "Invoke-Update: couldn't show error dialog: $_" }

        # Cleanup
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

        return $false
    }
}

# ============================================================
#  Main Update Flow
# ============================================================
try {
    # 1. Get local version
    $localVersion = Get-LocalVersion

    # 2. Check throttle — fast path
    if (-not (Test-ThrottleExpired)) {
        Write-DebugLog 'INFO' "Throttled — last check within ${THROTTLE_HOURS}h, skipping update check"
        exit 0
    }

    # 3. Fetch remote version
    $remoteVersion = Get-RemoteVersion
    if (-not $remoteVersion) {
        Write-DebugLog 'INFO' 'Could not fetch remote version (network issue?), skipping'
        exit 0
    }

    # 4. Record successful check time (only after network succeeds, so failures retry next launch)
    Update-ThrottleTimestamp

    # 5. Compare versions
    if ($remoteVersion -le $localVersion) {
        Write-DebugLog 'INFO' "Up to date: local=$localVersion remote=$remoteVersion"
        exit 0
    }

    Write-DebugLog 'INFO' "Update available: $localVersion -> $remoteVersion"

    # 6. Check if user skipped this version
    if (Test-VersionSkipped -RemoteVersion $remoteVersion) {
        Write-DebugLog 'INFO' "User previously skipped v$remoteVersion, not prompting"
        exit 0
    }

    # 7. Show update dialog
    $choice = Show-UpdateDialog -LocalVersion $localVersion -RemoteVersion $remoteVersion

    switch ($choice) {
        'Update' {
            Write-DebugLog 'INFO' 'User chose: Update Now'
            $success = Invoke-Update -FromVersion $localVersion -ToVersion $remoteVersion
            if ($success) {
                Write-DebugLog 'INFO' 'Update applied successfully'
                # Show success message
                try {
                    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
                    [System.Windows.MessageBox]::Show(
                        "SuperTask has been updated to v$remoteVersion!",
                        'SuperTask — Updated',
                        [System.Windows.MessageBoxButton]::OK,
                        [System.Windows.MessageBoxImage]::Information)
                }
                catch {}
            }
        }
        'Later' {
            Write-DebugLog 'INFO' 'User chose: Remind Me Later'
            Clear-ThrottleTimestamp  # So next launch will prompt again
        }
        'Skip' {
            Write-DebugLog 'INFO' "User chose: Skip v$remoteVersion"
            Save-SkippedVersion -VersionToSkip $remoteVersion
        }
    }

    exit 0
}
catch {
    # Absolute last-resort catch — updater must NEVER prevent app launch
    Write-DebugLog 'FATAL' "Updater unhandled exception: $_"
    try { Write-ExceptionDetail $_ } catch {}
    exit 0  # Exit 0 so launcher.bat continues to the main app
}
