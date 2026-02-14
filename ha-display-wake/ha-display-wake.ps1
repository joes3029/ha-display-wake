# ha-display-wake.ps1
# ha-display-wake client for Windows 10/11
#
# Three-tier behaviour:
#   1. User active (recent input)       → ignore wake signal entirely
#   2. User idle, screen still on       → silently reset idle timer (no visible effect)
#   3. Screen off (timed out / DPMS)    → wake the display
#
# First run:  .\ha-display-wake.ps1           → interactive setup
# Reconfigure: .\ha-display-wake.ps1 --setup
# Normal run:  .\ha-display-wake.ps1
#
# Requires: mosquitto_sub (Mosquitto client tools) in PATH.
#
# ── Win32 Interop ─────────────────────────────────────────────────────────────

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

# ── Paths ──────────────────────────────────────────────────────────────────────

$CONFIG_DIR  = Join-Path $env:APPDATA "ha-display-wake"
$CONFIG_FILE = Join-Path $CONFIG_DIR "config.json"
$LOG_FILE    = Join-Path $CONFIG_DIR "ha-display-wake.log"

# ── Logging ────────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Host $line
    Add-Content -Path $LOG_FILE -Value $line -ErrorAction SilentlyContinue
}

function Trim-Log {
    if (Test-Path $LOG_FILE) {
        $lines = Get-Content $LOG_FILE -ErrorAction SilentlyContinue
        if ($lines -and $lines.Count -gt 500) {
            $lines[-500..-1] | Set-Content $LOG_FILE -ErrorAction SilentlyContinue
        }
    }
}

# ── Configuration ──────────────────────────────────────────────────────────────

function Test-BrokerReachable {
    param([string]$Host, [int]$Port = 1883, [int]$TimeoutMs = 2000)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $result = $tcp.BeginConnect($Host, $Port, $null, $null)
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
        if (Test-BrokerReachable -Host $candidate) {
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
            if (Test-BrokerReachable -Host $ip) {
                Write-Host " found!" -ForegroundColor Green
                return $ip
            }
            Write-Host " no"
        }
    }
    catch {}

    Write-Host "  Auto-detection failed — you'll need to enter the address manually." -ForegroundColor Yellow
    return $null
}

function Read-HostDefault {
    param([string]$Prompt, [string]$Default)
    if ($Default) {
        $input = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($input)) { return $Default }
        return $input.Trim()
    }
    else {
        $result = Read-Host "$Prompt"
        return $result.Trim()
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

function Run-Setup {
    param([hashtable]$Existing = @{})

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║      ha-display-wake — Setup             ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    # ── Broker ──────────────────────────────────────────
    $detectedBroker = Find-Broker
    $defaultBroker = if ($Existing.broker) { $Existing.broker } elseif ($detectedBroker) { $detectedBroker } else { "" }

    Write-Host ""
    if ($defaultBroker) {
        $broker = Read-HostDefault "MQTT broker address" $defaultBroker
    }
    else {
        $broker = Read-HostDefault "MQTT broker address (IP or hostname)" ""
        while ([string]::IsNullOrWhiteSpace($broker)) {
            Write-Host "  Broker address is required." -ForegroundColor Yellow
            $broker = Read-HostDefault "MQTT broker address (IP or hostname)" ""
        }
    }

    # Verify the chosen broker is reachable
    $defaultPort = if ($Existing.port) { [string]$Existing.port } else { "1883" }
    $port = Read-HostDefault "MQTT port" $defaultPort
    $portInt = [int]$port

    Write-Host ""
    Write-Host "  Testing connection to ${broker}:${port}..." -NoNewline
    if (Test-BrokerReachable -Host $broker -Port $portInt) {
        Write-Host " OK" -ForegroundColor Green
    }
    else {
        Write-Host " unreachable" -ForegroundColor Yellow
        Write-Host "  (The broker may not be running, or the address/port may be wrong.)" -ForegroundColor Yellow
        Write-Host "  You can continue setup and fix this later." -ForegroundColor Yellow
    }

    # ── Auth ────────────────────────────────────────────
    Write-Host ""
    $defaultUser = if ($Existing.username) { $Existing.username } else { "" }
    $username = Read-HostDefault "MQTT username (leave empty if none)" $defaultUser

    $password = ""
    if (-not [string]::IsNullOrWhiteSpace($username)) {
        $defaultPass = if ($Existing.password) { $Existing.password } else { "" }
        $password = Read-HostDefault "MQTT password" $defaultPass
    }

    # ── Room ────────────────────────────────────────────
    Write-Host ""
    $defaultRoom = if ($Existing.room) { $Existing.room } else { "office" }
    $room = Read-HostDefault "Room name (used in MQTT topic)" $defaultRoom
    $topic = "ha-display-wake/$room/command"
    Write-Host "  MQTT topic will be: $topic" -ForegroundColor DarkGray

    # ── Active threshold ────────────────────────────────
    Write-Host ""
    $defaultThreshold = if ($Existing.active_threshold) { [string]$Existing.active_threshold } else { "30" }
    Write-Host "Active threshold: if you've touched the keyboard/mouse within this"
    Write-Host "many seconds, wake signals are ignored (you're already working)."
    $activeThreshold = Read-HostDefault "Active threshold in seconds" $defaultThreshold

    # ── Screen timeout detection ────────────────────────
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
    $screenTimeout = Read-HostDefault "Screen timeout in seconds (used to detect if screen is likely off)" $defaultTimeout

    # ── Save ────────────────────────────────────────────
    $config = @{
        broker           = $broker
        port             = [int]$port
        username         = $username
        password         = $password
        room             = $room
        topic            = $topic
        active_threshold = [int]$activeThreshold
        screen_timeout   = [int]$screenTimeout
    }

    if (-not (Test-Path $CONFIG_DIR)) {
        New-Item -ItemType Directory -Path $CONFIG_DIR -Force | Out-Null
    }

    $config | ConvertTo-Json | Set-Content $CONFIG_FILE -Encoding UTF8
    Write-Host ""
    Write-Host "Configuration saved to: $CONFIG_FILE" -ForegroundColor Green
    Write-Host ""

    # ── Summary ─────────────────────────────────────────
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host "  Broker:           $broker`:$port"
    Write-Host "  Auth:             $(if ($username) { $username } else { '(none)' })"
    Write-Host "  Topic:            $topic"
    Write-Host "  Active threshold: $activeThreshold seconds"
    Write-Host "  Screen timeout:   $screenTimeout seconds"
    Write-Host ""

    return $config
}

function Load-Config {
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

# ── Screen Wake Logic ──────────────────────────────────────────────────────────

function Handle-WakeSignal {
    param([hashtable]$Config)

    $idleSeconds = [DisplayWake]::GetIdleSeconds()
    $activeThreshold = $Config.active_threshold
    $screenTimeout   = $Config.screen_timeout

    # Tier 1: User is actively working — do nothing
    if ($idleSeconds -lt $activeThreshold) {
        # Quiet — don't even log this in normal operation to avoid log spam
        return
    }

    # Tier 3: Screen is likely off (idle time exceeds screen timeout)
    # Handle this before Tier 2 so we use the stronger wake method
    if ($screenTimeout -gt 0 -and $idleSeconds -ge $screenTimeout) {
        Write-Log "Wake signal — idle ${idleSeconds}s (>= timeout ${screenTimeout}s) — waking display"

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

    # Tier 2: Idle but screen is still on — silently reset idle timer
    Write-Log "Wake signal — idle ${idleSeconds}s — resetting idle timer (screen stay-alive)"
    [DisplayWake]::SetThreadExecutionState(
        [DisplayWake]::ES_SYSTEM_REQUIRED -bor [DisplayWake]::ES_DISPLAY_REQUIRED
    ) | Out-Null
}

# ── Main ───────────────────────────────────────────────────────────────────────

# Handle --setup flag
$forceSetup = $args -contains "--setup" -or $args -contains "-setup" -or $args -contains "--reconfigure"

# Load or create config
$config = Load-Config

if ($null -eq $config -or $forceSetup) {
    $existing = if ($config) { $config } else { @{} }
    $config = Run-Setup -Existing $existing

    if ($forceSetup) {
        Write-Host "Setup complete. Restart the script (or the scheduled task) to apply." -ForegroundColor Cyan
        exit 0
    }
}

# Ensure config dir exists for log file
if (-not (Test-Path $CONFIG_DIR)) {
    New-Item -ItemType Directory -Path $CONFIG_DIR -Force | Out-Null
}

Trim-Log

$broker = $config.broker
$port   = [string]$config.port
$topic  = $config.topic

Write-Log "ha-display-wake starting (broker: ${broker}:${port}, topic: $topic)"
Write-Log "  Active threshold: $($config.active_threshold)s, Screen timeout: $($config.screen_timeout)s"

while ($true) {
    try {
        $subArgs = @("-h", $broker, "-p", $port, "-t", $topic)
        if (-not [string]::IsNullOrWhiteSpace($config.username)) {
            $subArgs += @("-u", $config.username, "-P", $config.password)
        }

        Write-Log "Connecting to MQTT broker..."

        & mosquitto_sub @subArgs 2>&1 | ForEach-Object {
            $payload = "$_".Trim()
            if ($payload -eq "wake") {
                Handle-WakeSignal -Config $config
            }
        }

        Write-Log "mosquitto_sub exited, reconnecting in 10 seconds..."
    }
    catch {
        Write-Log "Error: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 10
}
