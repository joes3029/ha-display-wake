# ha-display-wake

*Your screens should just know you're there.*

You walk into your office. You sit down. Every screen is dark. You reach for a mouse — or worse, you reach for *three* mice — and jiggle each one. It's a tiny thing. It takes five seconds. And it happens every single time.

**ha-display-wake** makes that go away.

A PIR motion sensor in your room tells Home Assistant you've arrived. HA publishes a quiet MQTT message. Lightweight scripts on your PCs hear it and wake your screens — or keep them from turning off in the first place, if you're just sitting across the room reading or on a call. If you're actively working at a machine, the scripts do absolutely nothing. No mouse cursor jumping. No phantom inputs. Just screens that stay on when you're present and wake up when you walk in.

It's the kind of thing you set up once, forget about, and then one day realise you haven't touched a mouse to wake a screen in months.

## What You Need

- **[Home Assistant](https://www.home-assistant.io/)** with an MQTT broker (most people use the [Mosquitto add-on](https://github.com/home-assistant/addons/blob/master/mosquitto/DOCS.md))
- **A presence sensor** in the room — a PIR motion sensor is the most common and cheapest option (Zigbee, Z-Wave, ESPHome, Wi-Fi — anything HA can see as a binary sensor). mmWave sensors work great too, especially for detecting someone sitting still
- **One or more PCs** running Windows 10/11 or Linux

That's it. No custom HA integrations, no cloud services, no accounts, no subscriptions. Just MQTT messages and small scripts.

## How It Works

```
Motion sensor detects presence
        │
        ▼
Home Assistant (decides: occupied or vacant?)
        │
        ├─ Room just became occupied → publish "wake"
        └─ Room still occupied, periodic check → publish "wake"
        │
        ▼
MQTT: ha-display-wake/{room}/command → "wake"
        │
        ├──► Windows PC ──► active? ignore │ idle? reset timer │ screen off? wake it
        ├──► Windows Laptop ──► same
        └──► Linux PC ──► same
```

Each client script has three tiers of behaviour:

| Your state | What the script does | Visible effect |
|---|---|---|
| Actively working (keyboard/mouse recently used) | Nothing at all | None |
| Idle, but screen still on (reading, on a call) | Silently resets the display idle timer | None — screen just doesn't turn off |
| Screen already off (you walked away and came back) | Wakes the display | Screen turns on |

The key insight: **HA handles the "is someone in the room?" question, and each PC handles the "what should I do about it?" question.** HA is good at sensor fusion and occupancy logic. Your PC is good at knowing whether its own screen is on.

## Quick Start

### 0. Get the Files

```bash
git clone https://github.com/YOUR_USERNAME/ha-display-wake.git
```

Or download and extract the [latest release](../../releases). Here's what's in the repo:

| File | What it is | Where it goes |
|------|-----------|---------------|
| [`ha-automation.yaml`](ha-automation.yaml) | Home Assistant automations | Copy into your HA automations config |
| [`ha-display-wake.bat`](ha-display-wake.bat) | Windows launcher (double-click to run) | Same folder as the .ps1 on your Windows PC(s) |
| [`ha-display-wake.ps1`](ha-display-wake.ps1) | Windows client script | Any folder on your Windows PC(s) |
| [`ha-display-wake.py`](ha-display-wake.py) | Linux client script | Your home directory on your Linux PC(s) |
| [`ha-display-wake.service`](ha-display-wake.service) | Systemd unit file (Linux) | `~/.config/systemd/user/` |

### 1. Home Assistant

Open [`ha-automation.yaml`](ha-automation.yaml) and replace `binary_sensor.office_pir_motion` with your sensor's entity ID (appears three times — once per automation). Also replace `"office"` in the MQTT topic strings if you're using a different room name.

Then add the automations to HA. The file header explains two options: append to your `automations.yaml` file, or paste each automation individually into the HA UI (Settings → Automations → Create → Edit in YAML, **without** the leading `- `).

There are three automations: one that fires when someone enters the room, one that pulses every 10 minutes while the room stays occupied, and one that publishes a "vacant" state when presence ends.

### 2. Your PCs

**Windows** (requires [Mosquitto client tools](https://mosquitto.org/download/)):
```
ha-display-wake.bat              # Double-click or run from terminal — first run walks you through setup
ha-display-wake.bat --setup      # Re-run setup any time
```

**Linux** (requires `paho-mqtt`, `xdotool`, `xprintidle`, `x11-xserver-utils`):
```bash
python3 ha-display-wake.py     # First run walks you through setup
```

Both scripts auto-detect your MQTT broker, test the connection, and save configuration. See **[SETUP.md](SETUP.md)** for detailed instructions including running as a background service.

## Supported Platforms

| Platform | Display Server | Dependencies |
|----------|---------------|-------------|
| Windows 10/11 | — | [Mosquitto client tools](https://mosquitto.org/download/) |
| Linux (X11) | X.Org / Xwayland | python3, paho-mqtt, xdotool, xprintidle, x11-xserver-utils |
| Linux (Wayland) | GNOME | python3, paho-mqtt |

## Configuration

First-run setup creates a config file automatically. Re-run any time with `--setup`.

| Setting | Default | What it does |
|---------|---------|-------------|
| broker | *(auto-detected)* | Your MQTT broker address |
| port | 1883 | MQTT port |
| room | office | Room name — used in the MQTT topic |
| active_threshold | 30s | If you've used keyboard/mouse within this window, you're "active" and wake signals are ignored |
| screen_timeout | *(auto-detected)* | Your system's screen timeout — used to determine if the screen is likely off |

Config location:
- **Windows:** `%APPDATA%\ha-display-wake\config.json`
- **Linux:** `~/.config/ha-display-wake/config.json`

## MQTT Topics

```
ha-display-wake/{room}/command    →  "wake"       (HA → clients)
ha-display-wake/{room}/state      →  "occupied"   (informational, retained)
                                     "vacant"
```

The `command` topic is what drives the clients. The `state` topic is informational — useful for HA dashboards and for future features like auto-locking workstations when you leave.

## Future Ideas

This project starts simple, but there's room to grow:

- **Auto-lock on vacancy** — lock workstations when the room becomes vacant
- **Webcam presence detection** — use a webcam as an additional presence source, either locally or feeding into HA
- **macOS support** — CoreGraphics API for display state detection
- **HA Blueprint** — one-click importable automation template
- **HACS integration** — full custom component with config flow UI
- **Multi-room** — different sensors and screen groups per room
- **Tray icon (Windows)** — systray indicator showing connection status

If any of these interest you, check the [issues](../../issues) or open a new one.

## Contributing

Contributions are very welcome — whether that's bug reports, feature ideas, documentation improvements, or code. See **[CONTRIBUTING.md](CONTRIBUTING.md)** for details.

This is a small project. There's no CI pipeline, no complex build system, no bureaucracy. If you have a setup that's slightly different from the one this was built on and you get it working, a note about what you did is genuinely valuable.

## License

[MIT](LICENSE) — do whatever you like with it.

---

*Built because walking into an office and having to wake three screens one at a time is one too many small annoyances.*
