# ha-display-wake.ps1
# ha-display-wake client for Windows 10/11
#
# Three-tier behaviour:
#   1. User active (recent input)       - ignore wake signal entirely
#   2. User idle, screen still on       - silently reset idle timer (no visible effect)
#   3. Screen off (timed out / DPMS)    - wake the display
#
# First run:   ha-display-wake.bat             - interactive setup
# Reconfigure: ha-display-wake.bat --setup
# Normal run:  ha-display-wake.bat
#
# Requires: mosquitto_sub (Mosquitto client tools) in PATH.
#
# -- Win32 Interop -----------------------------------------------------------------

try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public struct LASTINPUTINFO
{
    public uint cbSize;
    public uint dwTime;
}

public class DisplayWake
{
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("kernel32.dll")]
    public static extern uint GetTickCount();

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);

    [DllImport("user32.dll")]
    public static extern void mouse_event(
        uint dwFlags, int dx, int dy, uint dwData, IntPtr dwExtraInfo);

    public const uint ES_SYSTEM_REQUIRED  = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED = 0x00000002;
    public const uint MOUSEEVENTF_MOVE    = 0x0001;

    public static uint GetIdleSeconds()
    {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii))
            return 0;
        return (GetTickCount() - lii.dwTime) / 1000;
    }
}
"@
}
catch {
    # Type already loaded from a previous run in this session - that's fine
}

# -- Paths -------------------------------------------------------------------------

$CONFIG_DIR  = Join-Path $env:APPDATA "ha-display-wake"
$CONFIG_FILE = Join-Path $CONFIG_DIR "config.json"
$LOG_FILE    = Join-Path $CONFIG_DIR "ha-display-wake.log"

# -- Logging -----------------------------------------------------------------------

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Host $line
    Add-Content -Path $LOG_FILE -Value $line -ErrorAction SilentlyContinue
}

function Invoke-LogTrim {
    if (Test-Path $LOG_FILE) {
        $lines = Get-Content $LOG_FILE -ErrorAction SilentlyContinue
        if ($lines -and $lines.Count -gt 500) {
            $lines[-500..-1] | Set-Content $LOG_FILE -ErrorAction SilentlyContinue
        }
    }
}

# -- Configuration -----------------------------------------------------------------

function Test-BrokerReachable {
    param([string]$BrokerHost, [int]$Port = 1883, [int]$TimeoutMs = 2000)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $result = $tcp.BeginConnect($BrokerHost, $Port, $null, $null)
        $success = $result.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($success) {
            $tcp.EndConnect($result)
            $tcp.Close()
            return $true
        }
        $tcp.Close()
        return $false
    }
    catch {
        return $false
    }
}

function Find-Broker {
    Write-Host ""
    Write-Host "Searching for MQTT broker..." -ForegroundColor Cyan

    # Try common hostnames
    $candidates = @("homeassistant.local", "homeassistant", "mqtt.local", "mqtt")
    foreach ($candidate in $candidates) {
        Write-Host "  Trying $candidate..." -NoNewline
        if (Test-BrokerReachable -BrokerHost $candidate) {
            Write-Host " found!" -ForegroundColor Green
            return $candidate
        }
        Write-Host " no"
    }

    # Try resolving homeassistant.local to an IP (mDNS may not work but DNS might)
    try {
        $resolved = [System.Net.Dns]::GetHostAddresses("homeassistant.local")
        if ($resolved) {
            $ip = $resolved[0].IPAddressToString
            Write-Host "  Trying $ip (resolved from homeassistant.local)..." -NoNewline
            if (Test-BrokerReachable -BrokerHost $ip) {
                Write-Host " found!" -ForegroundColor Green
                return $ip
            }
            Write-Host " no"
        }
    }
    catch {}

    Write-Host "  Auto-detection failed -- you'll need to enter the address manually." -ForegroundColor Yellow
    return $null
}

function Read-HostWithDefault {
    param([string]$Prompt, [string]$Default)
    if ($Default) {
        $response = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($response)) { return $Default }
        return $response.Trim()
    }
    else {
        $response = Read-Host "$Prompt"
        return $response.Trim()
    }
}

function Find-MosquittoSub {
    <#
    .SYNOPSIS
    Searches for mosquitto_sub.exe in PATH, common install locations, and the
    app's local directory. Returns the full path if found, $null otherwise.
    #>

    # Check PATH first
    $inPath = Get-Command "mosquitto_sub" -ErrorAction SilentlyContinue
    if ($inPath) {
        return $inPath.Source
    }

    # Check common install locations
    $candidates = @(
        "$env:ProgramFiles\mosquitto\mosquitto_sub.exe",
        "${env:ProgramFiles(x86)}\mosquitto\mosquitto_sub.exe",
        "$CONFIG_DIR\mosquitto\mosquitto_sub.exe"
    )

    foreach ($path in $candidates) {
        if (Test-Path $path) {
            return $path
        }
    }

    return $null
}

function Install-MosquittoClient {
    <#
    .SYNOPSIS
    Walks the user through installing Mosquitto client tools.
    Returns the path to mosquitto_sub.exe if successful, $null if skipped.
    #>

    Write-Host ""
    Write-Host "  mosquitto_sub.exe is required to receive MQTT messages." -ForegroundColor Yellow
    Write-Host "  It's part of the Eclipse Mosquitto project (open source, lightweight)."
    Write-Host "  Only the client tools are needed -- not the full broker."
    Write-Host ""
    Write-Host "  Options:" -ForegroundColor Cyan
    Write-Host "    [1] Install via winget (recommended -- runs in this terminal)"
    Write-Host "    [2] Open the download page in your browser (manual install)"
    Write-Host "    [3] Skip -- I'll install it myself"
    Write-Host ""

    $choice = Read-HostWithDefault "Choose an option" "1"

    switch ($choice) {
        "1" {
            Write-Host ""
            Write-Host "  Running: winget install EclipseFoundation.Mosquitto ..." -ForegroundColor Cyan
            Write-Host "  (The installer will open -- you can deselect the 'Service' component" -ForegroundColor DarkGray
            Write-Host "   if you only want the client tools.)" -ForegroundColor DarkGray
            Write-Host ""

            try {
                $winget = Get-Command "winget" -ErrorAction SilentlyContinue
                if (-not $winget) {
                    Write-Host "  winget not found on this system." -ForegroundColor Yellow
                    Write-Host "  Falling back to browser download." -ForegroundColor Yellow
                    Start-Process "https://mosquitto.org/download/"
                    Write-Host ""
                    Write-Host "  After installing, re-run setup:  ha-display-wake.bat --setup" -ForegroundColor Cyan
                    return $null
                }

                & winget install EclipseFoundation.Mosquitto --accept-source-agreements --accept-package-agreements

                # Give the install a moment, then search again
                Start-Sleep -Seconds 2

                # Refresh PATH for this session (winget/installer may have added it)
                $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
                $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
                $env:Path = "$machinePath;$userPath"

                $found = Find-MosquittoSub
                if ($found) {
                    Write-Host ""
                    Write-Host "  Found: $found" -ForegroundColor Green
                    return $found
                }

                # Check the default install location even if not in PATH yet
                $defaultPath = "$env:ProgramFiles\mosquitto\mosquitto_sub.exe"
                if (Test-Path $defaultPath) {
                    Write-Host ""
                    Write-Host "  Found: $defaultPath" -ForegroundColor Green
                    return $defaultPath
                }

                Write-Host ""
                Write-Host "  Installation completed but mosquitto_sub not found." -ForegroundColor Yellow
                Write-Host "  You may need to restart your terminal or re-run setup." -ForegroundColor Yellow
                Write-Host "  Re-run with:  ha-display-wake.bat --setup" -ForegroundColor Cyan
                return $null
            }
            catch {
                Write-Host "  winget install failed: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "  Falling back to browser download." -ForegroundColor Yellow
                Start-Process "https://mosquitto.org/download/"
                return $null
            }
        }
        "2" {
            Write-Host ""
            Write-Host "  Opening https://mosquitto.org/download/ ..." -ForegroundColor Cyan
            Write-Host "  Download the Windows 64-bit installer. You only need the client tools." -ForegroundColor DarkGray
            Write-Host "  After installing, re-run setup:  ha-display-wake.bat --setup" -ForegroundColor Cyan
            Start-Process "https://mosquitto.org/download/"
            return $null
        }
        default {
            Write-Host ""
            Write-Host "  Skipped. Install mosquitto_sub and ensure it's in your PATH," -ForegroundColor Yellow
            Write-Host "  or install to 'C:\Program Files\mosquitto\' (auto-detected)." -ForegroundColor Yellow
            Write-Host "  Then re-run:  ha-display-wake.bat --setup" -ForegroundColor Cyan
            return $null
        }
    }
}

function Get-ScreenTimeoutSeconds {
    <#
    .SYNOPSIS
    Queries the current power plan for the display timeout value (AC and DC).
    Returns the smaller of the two, in seconds. Falls back to 0 if unreadable.
    #>
    try {
        $output = powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>&1
        $values = @()
        foreach ($line in $output) {
            if ($line -match "Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)") {
                $values += [int]("0x$($Matches[1])")
            }
            if ($line -match "Current DC Power Setting Index:\s+0x([0-9a-fA-F]+)") {
                $values += [int]("0x$($Matches[1])")
            }
        }
        if ($values.Count -gt 0) {
            # Filter out 0 (meaning "never") and return the smallest non-zero
            $nonZero = $values | Where-Object { $_ -gt 0 }
            if ($nonZero) {
                return ($nonZero | Measure-Object -Minimum).Minimum
            }
        }
    }
    catch {}
    return 0
}

function Invoke-Setup {
    param([hashtable]$Existing = @{})

    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "      ha-display-wake -- Setup           " -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host ""

    # -- Mosquitto client tools --------------------------------
    Write-Host "Checking for mosquitto_sub..." -NoNewline
    $existingMosqPath = $Existing.mosquitto_sub_path
    $mosquittoPath = $null

    # Check stored path first (from previous setup)
    if ($existingMosqPath -and (Test-Path $existingMosqPath)) {
        $mosquittoPath = $existingMosqPath
    }

    # Search PATH and common locations
    if (-not $mosquittoPath) {
        $mosquittoPath = Find-MosquittoSub
    }

    if ($mosquittoPath) {
        Write-Host " found!" -ForegroundColor Green
        Write-Host "  $mosquittoPath" -ForegroundColor DarkGray
    }
    else {
        Write-Host " not found" -ForegroundColor Yellow
        $mosquittoPath = Install-MosquittoClient
        if (-not $mosquittoPath) {
            Write-Host ""
            Write-Host "  Continuing setup without mosquitto_sub." -ForegroundColor Yellow
            Write-Host "  The listener won't work until it's installed." -ForegroundColor Yellow
        }
    }

    # -- Broker ------------------------------------------------
    $detectedBroker = Find-Broker
    $defaultBroker = if ($Existing.broker) { $Existing.broker } elseif ($detectedBroker) { $detectedBroker } else { "" }

    Write-Host ""
    if ($defaultBroker) {
        $broker = Read-HostWithDefault "MQTT broker address" $defaultBroker
    }
    else {
        $broker = Read-HostWithDefault "MQTT broker address (IP or hostname)" ""
        while ([string]::IsNullOrWhiteSpace($broker)) {
            Write-Host "  Broker address is required." -ForegroundColor Yellow
            $broker = Read-HostWithDefault "MQTT broker address (IP or hostname)" ""
        }
    }

    # Verify the chosen broker is reachable
    $defaultPort = if ($Existing.port) { [string]$Existing.port } else { "1883" }
    $port = Read-HostWithDefault "MQTT port" $defaultPort
    $portInt = [int]$port

    Write-Host ""
    Write-Host "  Testing connection to ${broker}:${port}..." -NoNewline
    if (Test-BrokerReachable -BrokerHost $broker -Port $portInt) {
        Write-Host " OK" -ForegroundColor Green
    }
    else {
        Write-Host " unreachable" -ForegroundColor Yellow
        Write-Host "  (The broker may not be running, or the address/port may be wrong.)" -ForegroundColor Yellow
        Write-Host "  You can continue setup and fix this later." -ForegroundColor Yellow
    }

    # -- Auth --------------------------------------------------
    Write-Host ""
    $defaultUser = if ($Existing.username) { $Existing.username } else { "" }
    $username = Read-HostWithDefault "MQTT username (leave empty if none)" $defaultUser

    $password = ""
    if (-not [string]::IsNullOrWhiteSpace($username)) {
        $defaultPass = if ($Existing.password) { $Existing.password } else { "" }
        $password = Read-HostWithDefault "MQTT password" $defaultPass
    }

    # -- Room --------------------------------------------------
    Write-Host ""
    $defaultRoom = if ($Existing.room) { $Existing.room } else { "office" }
    $room = Read-HostWithDefault "Room name (used in MQTT topic)" $defaultRoom
    $topic = "ha-display-wake/$room/command"
    Write-Host "  MQTT topic will be: $topic" -ForegroundColor DarkGray

    # -- Active threshold --------------------------------------
    Write-Host ""
    $defaultThreshold = if ($Existing.active_threshold) { [string]$Existing.active_threshold } else { "30" }
    Write-Host "Active threshold: if you've touched the keyboard/mouse within this"
    Write-Host "many seconds, wake signals are ignored (you're already working)."
    $activeThreshold = Read-HostWithDefault "Active threshold in seconds" $defaultThreshold

    # -- Screen timeout detection ------------------------------
    Write-Host ""
    Write-Host "Detecting screen timeout from Windows power settings..." -NoNewline
    $screenTimeout = Get-ScreenTimeoutSeconds
    if ($screenTimeout -gt 0) {
        $mins = [math]::Round($screenTimeout / 60, 1)
        Write-Host " ${mins} minutes" -ForegroundColor Green
    }
    else {
        Write-Host " could not determine (set to 'Never' or unreadable)" -ForegroundColor Yellow
        Write-Host "  Defaulting to 1200 seconds (20 minutes)." -ForegroundColor Yellow
        $screenTimeout = 1200
    }
    $defaultTimeout = [string]$screenTimeout
    $screenTimeout = Read-HostWithDefault "Screen timeout in seconds (used to detect if screen is likely off)" $defaultTimeout

    # -- Save --------------------------------------------------
    $config = @{
        broker             = $broker
        port               = [int]$port
        username           = $username
        password           = $password
        room               = $room
        topic              = $topic
        active_threshold   = [int]$activeThreshold
        screen_timeout     = [int]$screenTimeout
        mosquitto_sub_path = if ($mosquittoPath) { $mosquittoPath } else { "" }
    }

    if (-not (Test-Path $CONFIG_DIR)) {
        New-Item -ItemType Directory -Path $CONFIG_DIR -Force | Out-Null
    }

    $config | ConvertTo-Json | Set-Content $CONFIG_FILE -Encoding UTF8
    Write-Host ""
    Write-Host "Configuration saved to: $CONFIG_FILE" -ForegroundColor Green
    Write-Host ""

    # -- Summary -----------------------------------------------
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host "  Broker:           ${broker}:${port}"
    Write-Host "  Auth:             $(if ($username) { $username } else { '(none)' })"
    Write-Host "  Topic:            $topic"
    Write-Host "  Active threshold: $activeThreshold seconds"
    Write-Host "  Screen timeout:   $screenTimeout seconds"
    Write-Host ""

    return $config
}

function Get-SavedConfig {
    if (Test-Path $CONFIG_FILE) {
        try {
            $json = Get-Content $CONFIG_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
            $config = @{}
            $json.PSObject.Properties | ForEach-Object { $config[$_.Name] = $_.Value }
            return $config
        }
        catch {
            Write-Host "Warning: Could not parse config file, running setup." -ForegroundColor Yellow
            return $null
        }
    }
    return $null
}

# -- Screen Wake Logic -------------------------------------------------------------

function Invoke-WakeIfNeeded {
    param([hashtable]$Config)

    $idleSeconds = [DisplayWake]::GetIdleSeconds()
    $activeThreshold = $Config.active_threshold
    $screenTimeout   = $Config.screen_timeout

    # Tier 1: User is actively working -- do nothing
    if ($idleSeconds -lt $activeThreshold) {
        # Quiet -- don't even log this in normal operation to avoid log spam
        return
    }

    # Tier 3: Screen is likely off (idle time exceeds screen timeout)
    # Handle this before Tier 2 so we use the stronger wake method
    if ($screenTimeout -gt 0 -and $idleSeconds -ge $screenTimeout) {
        Write-Log "Wake signal -- idle ${idleSeconds}s (>= timeout ${screenTimeout}s) -- waking display"

        # Reset idle timer
        [DisplayWake]::SetThreadExecutionState(
            [DisplayWake]::ES_SYSTEM_REQUIRED -bor [DisplayWake]::ES_DISPLAY_REQUIRED
        ) | Out-Null

        # Mouse jiggle to wake a DPMS-off monitor
        [DisplayWake]::mouse_event([DisplayWake]::MOUSEEVENTF_MOVE, 1, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 50
        [DisplayWake]::mouse_event([DisplayWake]::MOUSEEVENTF_MOVE, -1, 0, 0, [IntPtr]::Zero)
        return
    }

    # Tier 2: Idle but screen is still on -- silently reset idle timer
    Write-Log "Wake signal -- idle ${idleSeconds}s -- resetting idle timer (screen stay-alive)"
    [DisplayWake]::SetThreadExecutionState(
        [DisplayWake]::ES_SYSTEM_REQUIRED -bor [DisplayWake]::ES_DISPLAY_REQUIRED
    ) | Out-Null
}

# -- Main --------------------------------------------------------------------------

# Handle --setup flag
$forceSetup = $args -contains "--setup" -or $args -contains "-setup" -or $args -contains "--reconfigure"

# Load or create config
$config = Get-SavedConfig

if ($null -eq $config -or $forceSetup) {
    $existing = if ($config) { $config } else { @{} }
    $config = Invoke-Setup -Existing $existing

    if ($forceSetup) {
        Write-Host "Setup complete. Restart the script (or the scheduled task) to apply." -ForegroundColor Cyan
        exit 0
    }
}

# Ensure config dir exists for log file
if (-not (Test-Path $CONFIG_DIR)) {
    New-Item -ItemType Directory -Path $CONFIG_DIR -Force | Out-Null
}

Invoke-LogTrim

$broker = $config.broker
$port   = [string]$config.port
$topic  = $config.topic

# Resolve mosquitto_sub path: config value, then search, then fail gracefully
$mosquittoSubExe = $config.mosquitto_sub_path
if (-not $mosquittoSubExe -or -not (Test-Path $mosquittoSubExe)) {
    $mosquittoSubExe = Find-MosquittoSub
}
if (-not $mosquittoSubExe -or -not (Test-Path $mosquittoSubExe)) {
    # Last resort: maybe it's in PATH but wasn't at setup time
    $inPath = Get-Command "mosquitto_sub" -ErrorAction SilentlyContinue
    if ($inPath) {
        $mosquittoSubExe = $inPath.Source
    }
}

if (-not $mosquittoSubExe) {
    Write-Log "ERROR: mosquitto_sub not found. Install Mosquitto client tools and re-run: ha-display-wake.bat --setup"
    Write-Host ""
    Write-Host "mosquitto_sub.exe could not be found." -ForegroundColor Red
    Write-Host "Install it via:  winget install EclipseFoundation.Mosquitto" -ForegroundColor Yellow
    Write-Host "Or download from: https://mosquitto.org/download/" -ForegroundColor Yellow
    Write-Host "Then re-run:  ha-display-wake.bat --setup" -ForegroundColor Cyan
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Log "ha-display-wake starting (broker: ${broker}:${port}, topic: $topic)"
Write-Log "  mosquitto_sub: $mosquittoSubExe"
Write-Log "  Active threshold: $($config.active_threshold)s, Screen timeout: $($config.screen_timeout)s"

# -- Pre-flight connection test ----------------------------------------------------
# Run mosquitto_sub with a short timeout to verify the broker is reachable.
# Exit code 27 = timeout (connected fine, just no messages) = success.
# Any other non-zero = connection failure.

Write-Host ""
Write-Host "Testing MQTT broker connection..." -NoNewline

$testArgs = "-h $broker -p $port -t ha-display-wake/connection-test -W 3 -C 1"
if (-not [string]::IsNullOrWhiteSpace($config.username)) {
    $testArgs += " -u $($config.username) -P $($config.password)"
}

$testProc = Start-Process -FilePath $mosquittoSubExe -ArgumentList $testArgs -Wait -PassThru -WindowStyle Hidden
$testExit = $testProc.ExitCode

# Exit code 27 = timed out waiting for messages (but connected OK)
# Exit code 0  = received a message (connected OK)
if ($testExit -eq 27 -or $testExit -eq 0) {
    Write-Host " connected!" -ForegroundColor Green
    Write-Log "Broker connection test: OK"
}
else {
    Write-Host " failed (exit code: $testExit)" -ForegroundColor Red
    Write-Log "Broker connection test: FAILED (exit code: $testExit)"
    Write-Host ""
    Write-Host "Could not connect to MQTT broker at ${broker}:${port}." -ForegroundColor Yellow
    Write-Host "Check that the broker is running and credentials are correct." -ForegroundColor Yellow
    Write-Host "Re-run setup with:  ha-display-wake.bat --setup" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "The script will keep trying to connect in the background." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Listening for wake signals on topic: $topic" -ForegroundColor Cyan
Write-Host "This window will stay open (or run as a scheduled task for background operation)." -ForegroundColor DarkGray
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

while ($true) {
    try {
        $subArgs = @("-h", $broker, "-p", $port, "-t", $topic)
        if (-not [string]::IsNullOrWhiteSpace($config.username)) {
            $subArgs += @("-u", $config.username, "-P", $config.password)
        }

        Write-Log "Subscribing to $topic..."

        & $mosquittoSubExe @subArgs 2>&1 | ForEach-Object {
            $payload = "$_".Trim()
            if ($payload -eq "wake") {
                Invoke-WakeIfNeeded -Config $config
            }
        }

        Write-Log "Connection lost, reconnecting in 10 seconds..."
    }
    catch {
        Write-Log "Error: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 10
}
