# Setup Guide

This guide walks through setting up ha-display-wake step by step. You'll need the files from the repo — see the [README](README.md) for the file list and what each one does.

## Step 1: Home Assistant

### Add the Automations

Open [`ha-automation.yaml`](ha-automation.yaml) and replace `binary_sensor.office_pir_motion` with your actual sensor entity ID (it appears three times — once per automation). You can find your sensor's entity ID in HA under Settings → Devices & Services → Entities.

There are two ways to install the automations:

**Option A — Append to automations.yaml:** Paste the entire file contents into your `automations.yaml` (or `configuration.yaml` if that's where your automations live) and restart HA. This is the simplest approach if you're comfortable editing config files.

**Option B — Use the HA UI:** For each of the three automations:

1. Go to Settings → Automations → Create Automation → Create new automation
2. Click the three-dot menu (⋮) top right → Edit in YAML
3. Paste the automation block — everything from `alias:` through to just before the next comment separator. **Do not include the leading `- `** (the UI handles each automation as a single object, not a list item).
4. Click Save.

The three automations are:

1. **Entry wake** — fires on the off → on transition (someone enters the room)
2. **Sustained wake** — fires every 10 minutes while the sensor remains on
3. **Vacant state** — publishes a retained state message when the sensor goes off

If you're using a room name other than "office", also replace `"office"` in the MQTT topic strings and automation aliases. The room name must match what you configure in the client scripts.

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

### What You Need

Nothing — the setup script handles everything. It will detect and offer to install the Mosquitto client tools via `winget` if they're not already present, configure the MQTT connection, and install a Scheduled Task for auto-start at login.

If you prefer to install Mosquitto ahead of time:

    winget install EclipseFoundation.Mosquitto

Or download from https://mosquitto.org/download/ (Windows 64-bit). You only need the client tools — deselect the Service component during installation.

### First Run — Interactive Setup

Double-click `ha-display-wake.bat`, or from a terminal:

    ha-display-wake.bat

The `.bat` launcher handles PowerShell execution policy automatically — no need to change system settings or unblock downloaded files. On first run, the setup wizard will:

1. **Check for mosquitto_sub** — if not found, offers to install via `winget`, open the download page, or skip
2. **Find your MQTT broker** — tries `homeassistant.local`, common hostnames, DNS resolution
3. **Prompt for connection details** — broker address, port, MQTT credentials
4. **Test the connection** — verifies the broker is reachable before continuing
5. **Configure the room** — room name (used in the MQTT topic)
6. **Set the active threshold** — how recently you must have used the keyboard/mouse to be considered "active" (default: 30 seconds)
7. **Auto-detect screen timeout** — reads your Windows power plan settings
8. **Save configuration** — to `%APPDATA%\ha-display-wake\config.json`
9. **Offer auto-start** — creates a hidden Scheduled Task that runs at login

After setup, the script tests the MQTT broker connection and begins listening for wake signals.

To re-run setup later:

    ha-display-wake.bat --setup

### How the Three Tiers Work

The script checks Windows idle time (`GetLastInputInfo`) when a wake signal arrives:

- **Idle < active threshold (default 30s):** You're working. Nothing happens.
- **Idle > active threshold, < screen timeout:** You're away but the screen is still on. The script calls `SetThreadExecutionState(ES_DISPLAY_REQUIRED)` which silently resets the Windows display idle timer. No mouse movement, no visible effect — the screen just doesn't turn off.
- **Idle > screen timeout:** The screen has probably already turned off. The script resets the idle timer AND simulates a tiny mouse movement (1px right then 1px left) to wake the monitor from DPMS standby.

### Auto-Start at Login

At the end of setup, the script offers to create a Windows Scheduled Task that runs ha-display-wake hidden in the background whenever you log in. This is the recommended approach — no console window, no manual intervention, survives reboots.

If you skipped this step during setup:

    ha-display-wake.bat --install

To remove it:

    ha-display-wake.bat --uninstall

#### Manual Task Scheduler Setup

If you prefer to configure the task yourself (or the automated approach didn't work):

1. Open **Task Scheduler** --> **Create Task** (not Basic Task)
2. **General:** Name: `ha-display-wake` / Check "Run only when user is logged on" / Check "Hidden"
3. **Triggers:** New --> At log on --> your user
4. **Actions:** New --> Program: `powershell.exe` / Arguments: `-WindowStyle Hidden -ExecutionPolicy Bypass -NoProfile -File "C:\path\to\ha-display-wake.ps1"`
5. **Conditions:** Uncheck "Start only if on AC power" (important for laptops)
6. **Settings:** Uncheck "Stop the task if it runs longer than..." / Set "If already running": Do not start a new instance
7. Click OK.

Repeat on each Windows machine.

### Verify After Reboot

    Get-ScheduledTask -TaskName "ha-display-wake" | Get-ScheduledTaskInfo

Log: `%APPDATA%\ha-display-wake\ha-display-wake.log`

---

## Step 3: Linux Setup

### What You Need

Python 3 (pre-installed on most Linux distributions). Everything else is handled during setup:

- **paho-mqtt** — the MQTT client library. If not installed, the script offers to install it via `pip` on first run.
- **xdotool, x11-xserver-utils, xprintidle** — display management tools for X11. The setup wizard checks for these and reports which are missing.

If you prefer to install dependencies ahead of time:

    sudo apt install xdotool x11-xserver-utils xprintidle
    pip install paho-mqtt --break-system-packages

On Wayland/GNOME, only paho-mqtt is needed — display management uses D-Bus calls.

### Check Display Server

    echo $XDG_SESSION_TYPE

The script auto-detects X11 vs Wayland and uses the appropriate methods. Most Ubuntu desktop variants (including Budgie, XFCE, MATE) use X11 by default; Ubuntu with GNOME 22.04+ may use Wayland.

### First Run — Interactive Setup

    python3 ha-display-wake.py

On first run, the setup wizard will:

1. **Check for paho-mqtt** — if not installed, offers to install via `pip`
2. **Check X11 tools** — reports any missing packages (`xdotool`, `xprintidle`, etc.)
3. **Auto-detect session type** — X11 or Wayland
4. **Find your MQTT broker** — same auto-detection as the Windows version
5. **Prompt for connection details** — broker address, port, MQTT credentials
6. **Test the connection** — verifies the broker is reachable
7. **Configure the room** — room name and active threshold
8. **Auto-detect screen timeout** — reads DPMS settings from `xset q`
9. **Save configuration** — to `~/.config/ha-display-wake/config.json`
10. **Offer auto-start** — creates and enables a systemd user service

To re-run setup:

    python3 ha-display-wake.py --setup

### How the Three Tiers Work (Linux)

- **Idle < active threshold:** You're working. Nothing happens.
- **Idle but screen still on:** Calls `xset s reset` (X11) or `SimulateUserActivity` D-Bus method (Wayland) to silently reset the screensaver/DPMS timer. No visible effect.
- **Screen off (DPMS standby/off):** Calls `xset dpms force on` (X11) or `SetActive false` D-Bus method (Wayland) to wake the display.

### Auto-Start at Login

At the end of setup, the script offers to create a systemd user service. The service file is generated automatically with the correct paths for your Python interpreter, script location, and DISPLAY variable — no manual editing needed.

If you skipped this step during setup:

    python3 ha-display-wake.py --install

To remove it:

    python3 ha-display-wake.py --uninstall

#### Manual Systemd Setup

If you prefer to set up the service yourself, a template service file ([`ha-display-wake.service`](ha-display-wake.service)) is included in the repo. You'll need to edit the `ExecStart` path to match your system:

    mkdir -p ~/.config/systemd/user
    cp ha-display-wake.service ~/.config/systemd/user/
    # Edit ExecStart= to point to your python3 and script paths
    systemctl --user daemon-reload
    systemctl --user enable --now ha-display-wake.service

Enable lingering so the service starts at boot (before desktop login):

    sudo loginctl enable-linger $USER

### Check Status

    systemctl --user status ha-display-wake.service
    journalctl --user -u ha-display-wake.service -f

Log: `~/.config/ha-display-wake/ha-display-wake.log`

---

## Troubleshooting

**Setup can't find the broker:**
Enter the IP address manually. You can find your HA IP in Settings → System → Network, or check your router's DHCP leases.

**Windows: mosquitto_sub not found after install:**
If you installed Mosquitto via `winget` or the MSI installer but the script still can't find it, the PATH change may not have taken effect yet. Close all terminal windows and re-run `ha-display-wake.bat --setup`. The script also checks `C:\Program Files\mosquitto\` directly, so it should find it there.

**mosquitto_sub won't connect:**
Test manually: `mosquitto_sub -h <broker> -u <user> -P <pass> -t "#" -v`
If TLS is required, you'll need to modify the script's mosquitto_sub arguments to include `-p 8883 --cafile /path/to/ca.crt`.

**HA automation doesn't fire:**
Check traces: Settings → Automations → your automation → Traces. Verify the entity ID. Test manually from Developer Tools → Services.

**Windows: "screen likely off" but it isn't:**
The Windows script infers screen state from idle time vs screen timeout. If your actual timeout differs from what was detected (e.g. you have different AC/DC settings, or group policy overrides), re-run `--setup` and enter the correct timeout manually.

**Linux: paho-mqtt install fails:**
On newer Ubuntu/Debian systems (23.04+), pip requires `--break-system-packages`. The script tries this automatically, but if it fails, install the system package instead: `sudo apt install python3-paho-mqtt`.

**Linux: xset reports "Monitor is On" even when screen is off:**
Some GPU drivers don't report DPMS state accurately. The script also checks idle time as a fallback, but if neither works reliably, please open an issue.

**Linux: service fails after boot:**
The auto-generated service file includes a 5-second startup delay. If that isn't enough (e.g. on slower hardware or if the network takes longer), edit the service file and increase it:

    ExecStartPre=/bin/sleep 15

Also verify DISPLAY is correct (`echo $DISPLAY`). If it's `:1`, update the service file's `Environment=DISPLAY=` line.

**Screen wakes then turns off again immediately:**
The HA wake interval is longer than your screen timeout. Reduce `minutes: "/10"` in the HA automation to be shorter than your timeout.

**Want to change settings?**
Re-run setup with `--setup`. On Windows, the scheduled task will automatically use the new config on next login (or restart the task). On Linux, restart the service: `systemctl --user restart ha-display-wake`.
