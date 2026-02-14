# Setup Guide

## Step 1: Home Assistant

### Add the Automations

Open `ha-automation.yaml` and replace `binary_sensor.office_pir_motion` with your actual sensor entity ID. You can find this in HA under Settings → Devices & Services → Entities.

Add the automations via the HA UI (Settings → Automations → Create → Edit in YAML) or append to your `automations.yaml` file. There are three automations:

1. **Entry wake** — fires on the off → on transition (someone enters the room)
2. **Sustained wake** — fires every 10 minutes while the sensor remains on
3. **Vacant state** — publishes a retained state message when the sensor goes off

Replace `"office"` with your room name in all three automations if using a different room. The room name must match what you configure in the client scripts.

### Test the MQTT Messages

Go to Developer Tools → Services, select `mqtt.publish`, and send:

    Topic: ha-display-wake/office/command
    Payload: wake

If you have MQTT Explorer, you should see the message appear.

### Timing Considerations

The sustained wake automation fires every 10 minutes by default (`minutes: "/10"`). This should be shorter than the shortest screen timeout across your PCs. For 20-minute timeouts, 10 minutes is right — the screen idle timer gets reset every 10 minutes while you're present, so it never reaches the 20-minute threshold.

If your screen timeout is shorter, adjust accordingly (e.g. `minutes: "/5"` for 10-minute timeouts).

### Sensor Occupancy Timeout

Most PIR/mmWave integrations (Zigbee2MQTT, ZHA, ESPHome, etc.) have a configurable occupancy timeout — how long the sensor stays "on" after last detecting motion. If yours drops to "off" too quickly when you're sitting still, increase this timeout in the sensor's device configuration. 2-5 minutes works well for office use.

---

## Step 2: Windows Setup

### Install Mosquitto Client Tools

Download from https://mosquitto.org/download/ (Windows 64-bit) or:

    winget install EclipseFoundation.Mosquitto

You only need the client tools — deselect the Service component during installation. Ensure `C:\Program Files\Mosquitto` is in your PATH:

    mosquitto_sub --help

### First Run — Interactive Setup

    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned   # one-time, if not already set
    .\ha-display-wake.ps1

On first run, the script will:

1. Search for your MQTT broker (tries `homeassistant.local`, common hostnames, DNS resolution)
2. Prompt for broker address, port, and MQTT credentials
3. Test the connection
4. Ask for your room name (used in the MQTT topic)
5. Ask for the active threshold (how recently you must have used the keyboard/mouse to be considered "active")
6. Auto-detect your screen timeout from Windows power settings
7. Save everything to `%APPDATA%\ha-display-wake\config.json`

To re-run setup later:

    .\ha-display-wake.ps1 --setup

### How the Three Tiers Work

The script checks Windows idle time (`GetLastInputInfo`) when a wake signal arrives:

- **Idle < active threshold (default 30s):** You're working. Nothing happens.
- **Idle > active threshold, < screen timeout:** You're away but the screen is still on. The script calls `SetThreadExecutionState(ES_DISPLAY_REQUIRED)` which silently resets the Windows display idle timer. No mouse movement, no visible effect — the screen just doesn't turn off.
- **Idle > screen timeout:** The screen has probably already turned off. The script resets the idle timer AND simulates a tiny mouse movement (1px right then 1px left) to wake the monitor from DPMS standby.

### Set Up as a Scheduled Task

1. Open **Task Scheduler** → **Create Task** (not Basic Task)
2. **General:** Name: `ha-display-wake` / Check "Run only when user is logged on" / Check "Hidden"
3. **Triggers:** New → At log on → your user
4. **Actions:** New → Program: `powershell.exe` / Arguments: `-WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\path\to\ha-display-wake.ps1"`
5. **Conditions:** Uncheck "Start only if on AC power" (important for laptops)
6. **Settings:** Uncheck "Stop the task if it runs longer than..." / Set "If already running": Do not start a new instance
7. Click OK.

Repeat on each Windows machine.

### Verify After Reboot

    Get-ScheduledTask -TaskName "ha-display-wake" | Get-ScheduledTaskInfo

Log: `%APPDATA%\ha-display-wake\ha-display-wake.log`

---

## Step 3: Linux Setup

### Install Dependencies

    sudo apt install xdotool x11-xserver-utils xprintidle
    pip install paho-mqtt --break-system-packages

Note: `xprintidle` is used for idle time detection on X11. If it's unavailable, the script falls back to other methods.

### Check Display Server

    echo $XDG_SESSION_TYPE

The script auto-detects X11 vs Wayland and uses the appropriate methods. Budgie typically uses X11.

### First Run — Interactive Setup

    python3 ha-display-wake.py

On first run, the script will:

1. Check installed dependencies and report any issues
2. Auto-detect session type (X11 / Wayland)
3. Search for your MQTT broker
4. Walk through the same configuration prompts as the Windows version
5. Auto-detect screen timeout from DPMS settings
6. Save to `~/.config/ha-display-wake/config.json`

To re-run setup:

    python3 ha-display-wake.py --setup

### How the Three Tiers Work (Linux)

- **Idle < active threshold:** You're working. Nothing happens.
- **Idle but screen still on:** Calls `xset s reset` (X11) or `SimulateUserActivity` D-Bus method (Wayland) to silently reset the screensaver/DPMS timer. No visible effect.
- **Screen off (DPMS standby/off):** Calls `xset dpms force on` (X11) or `SetActive false` D-Bus method (Wayland) to wake the display.

### Install as Systemd User Service

    # Run setup first if you haven't already
    python3 ~/ha-display-wake.py --setup

    # Install the service
    mkdir -p ~/.config/systemd/user
    cp ha-display-wake.service ~/.config/systemd/user/
    systemctl --user daemon-reload
    systemctl --user enable --now ha-display-wake.service

Enable lingering so the service starts at boot:

    sudo loginctl enable-linger $USER

### Check Status

    systemctl --user status ha-display-wake.service
    journalctl --user -u ha-display-wake.service -f

Log: `~/.config/ha-display-wake/ha-display-wake.log`

---

## Troubleshooting

**Setup can't find the broker:**
Enter the IP address manually. You can find your HA IP in Settings → System → Network, or check your router's DHCP leases.

**mosquitto_sub won't connect:**
Test manually: `mosquitto_sub -h <broker> -u <user> -P <pass> -t "#" -v`
If TLS is required, you'll need to modify the script's mosquitto_sub arguments to include `-p 8883 --cafile /path/to/ca.crt`.

**HA automation doesn't fire:**
Check traces: Settings → Automations → your automation → Traces. Verify the entity ID. Test manually from Developer Tools → Services.

**Windows: "screen likely off" but it isn't:**
The Windows script infers screen state from idle time vs screen timeout. If your actual timeout differs from what was detected (e.g. you have different AC/DC settings, or group policy overrides), re-run `--setup` and enter the correct timeout manually.

**Linux: xset reports "Monitor is On" even when screen is off:**
Some GPU drivers don't report DPMS state accurately. The script also checks idle time as a fallback, but if neither works reliably, please open an issue.

**Linux: service fails after boot:**
Increase the startup delay in the service file:

    ExecStartPre=/bin/sleep 15

Also verify DISPLAY is correct (`echo $DISPLAY`). If it's `:1`, update the service file.

**Screen wakes then turns off again immediately:**
The HA wake interval is longer than your screen timeout. Reduce `minutes: "/10"` in the HA automation to be shorter than your timeout.

**Want to change settings?**
Either edit the config file directly or re-run with `--setup`. On Windows, restart the scheduled task after changing config. On Linux, restart the service: `systemctl --user restart ha-display-wake`.
