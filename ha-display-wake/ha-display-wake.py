#!/usr/bin/env python3
"""
ha-display-wake.py
ha-display-wake client for Linux (X11 and Wayland/GNOME).

Three-tier behaviour:
  1. User active (recent input)       → ignore wake signal entirely
  2. User idle, screen still on       → silently reset idle timer (no visible effect)
  3. Screen off (DPMS standby/off)    → wake the display

First run:   python3 ha-display-wake.py           → interactive setup
Reconfigure: python3 ha-display-wake.py --setup
Normal run:  python3 ha-display-wake.py

Requires:
  pip install paho-mqtt
  sudo apt install xdotool x11-xserver-utils xprintidle   (X11)
"""

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import logging
from pathlib import Path

import paho.mqtt.client as mqtt

# ── Paths ──────────────────────────────────────────────────────────────────────

CONFIG_DIR = Path.home() / ".config" / "ha-display-wake"
CONFIG_FILE = CONFIG_DIR / "config.json"
LOG_FILE = CONFIG_DIR / "ha-display-wake.log"

SESSION_TYPE = os.environ.get("XDG_SESSION_TYPE", "x11")

# ── Logging ────────────────────────────────────────────────────────────────────

log = logging.getLogger("ha-display-wake")


def setup_logging():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="[%(asctime)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=[
            logging.StreamHandler(),
            logging.FileHandler(LOG_FILE),
        ],
    )


def trim_log():
    try:
        if LOG_FILE.exists() and LOG_FILE.stat().st_size > 500_000:
            lines = LOG_FILE.read_text().splitlines()
            LOG_FILE.write_text("\n".join(lines[-500:]) + "\n")
    except Exception:
        pass


# ── Configuration ──────────────────────────────────────────────────────────────

def test_broker(host: str, port: int = 1883, timeout: float = 2.0) -> bool:
    """Test if an MQTT broker is reachable via TCP."""
    try:
        sock = socket.create_connection((host, port), timeout=timeout)
        sock.close()
        return True
    except (socket.timeout, socket.error, OSError):
        return False


def find_broker() -> str | None:
    """Try to auto-detect the MQTT broker."""
    print("\nSearching for MQTT broker...")

    candidates = ["homeassistant.local", "homeassistant", "mqtt.local", "mqtt"]
    for candidate in candidates:
        print(f"  Trying {candidate}...", end="", flush=True)
        if test_broker(candidate):
            print(" found!", flush=True)
            return candidate
        print(" no")

    # Try resolving homeassistant.local to IP
    try:
        ip = socket.gethostbyname("homeassistant.local")
        print(f"  Trying {ip} (resolved from homeassistant.local)...", end="", flush=True)
        if test_broker(ip):
            print(" found!", flush=True)
            return ip
        print(" no")
    except socket.gaierror:
        pass

    print("  Auto-detection failed — you'll need to enter the address manually.")
    return None


def prompt(text: str, default: str = "") -> str:
    """Prompt with optional default value."""
    if default:
        result = input(f"  {text} [{default}]: ").strip()
        return result if result else default
    result = input(f"  {text}: ").strip()
    return result


def check_dependencies():
    """Check which tools are available and report."""
    print("\nChecking dependencies...")
    issues = []

    # paho-mqtt (already imported if we got here)
    print("  paho-mqtt: OK")

    if SESSION_TYPE == "wayland":
        print(f"  Session type: Wayland (will use D-Bus)")
        if not shutil.which("dbus-send"):
            issues.append("dbus-send not found — install dbus-tools")
            print("  dbus-send: MISSING")
        else:
            print("  dbus-send: OK")
    else:
        print(f"  Session type: X11")
        for tool in ["xset", "xdotool", "xprintidle"]:
            if shutil.which(tool):
                print(f"  {tool}: OK")
            else:
                issues.append(f"{tool} not found — sudo apt install {tool if tool != 'xset' else 'x11-xserver-utils'}")
                print(f"  {tool}: MISSING")

    if issues:
        print("\n  Missing dependencies:")
        for issue in issues:
            print(f"    - {issue}")
        print("  Install them and re-run setup, or the script may not work correctly.")

    return len(issues) == 0


def get_dpms_timeout_seconds() -> int:
    """Parse the DPMS timeout from xset q output."""
    if SESSION_TYPE != "x11":
        return 0
    try:
        result = subprocess.run(["xset", "q"], capture_output=True, text=True, timeout=5)
        # Look for "Standby:  NNN    Suspend:  NNN    Off:  NNN"
        match = re.search(r"Standby:\s+(\d+)\s+Suspend:\s+(\d+)\s+Off:\s+(\d+)", result.stdout)
        if match:
            values = [int(match.group(i)) for i in (1, 2, 3)]
            non_zero = [v for v in values if v > 0]
            if non_zero:
                return min(non_zero)
    except Exception:
        pass
    return 0


def run_setup(existing: dict = None) -> dict:
    """Interactive first-run configuration."""
    if existing is None:
        existing = {}

    print()
    print("╔══════════════════════════════════════════╗")
    print("║      ha-display-wake — Setup             ║")
    print("╚══════════════════════════════════════════╝")

    check_dependencies()

    # ── Broker ──────────────────────────────
    detected = find_broker()
    default_broker = existing.get("broker") or detected or ""

    print()
    if default_broker:
        broker = prompt("MQTT broker address", default_broker)
    else:
        broker = ""
        while not broker:
            broker = prompt("MQTT broker address (IP or hostname)")
            if not broker:
                print("    Broker address is required.")

    default_port = str(existing.get("port", 1883))
    port = int(prompt("MQTT port", default_port))

    print()
    print(f"  Testing connection to {broker}:{port}...", end="", flush=True)
    if test_broker(broker, port):
        print(" OK")
    else:
        print(" unreachable")
        print("  (The broker may not be running, or the address/port may be wrong.)")
        print("  You can continue setup and fix this later.")

    # ── Auth ────────────────────────────────
    print()
    default_user = existing.get("username", "")
    username = prompt("MQTT username (leave empty if none)", default_user)

    password = ""
    if username:
        default_pass = existing.get("password", "")
        password = prompt("MQTT password", default_pass)

    # ── Room ────────────────────────────────
    print()
    default_room = existing.get("room", "office")
    room = prompt("Room name (used in MQTT topic)", default_room)
    topic = f"ha-display-wake/{room}/command"
    print(f"    MQTT topic will be: {topic}")

    # ── Active threshold ────────────────────
    print()
    default_threshold = str(existing.get("active_threshold", 30))
    print("  Active threshold: if you've touched the keyboard/mouse within this")
    print("  many seconds, wake signals are ignored (you're already working).")
    active_threshold = int(prompt("Active threshold in seconds", default_threshold))

    # ── Screen timeout detection ────────────
    print()
    print("  Detecting screen timeout from system settings...", end="", flush=True)
    screen_timeout = get_dpms_timeout_seconds()
    if screen_timeout > 0:
        mins = round(screen_timeout / 60, 1)
        print(f" {mins} minutes")
    else:
        print(" could not determine")
        print("  Defaulting to 1200 seconds (20 minutes).")
        screen_timeout = 1200

    default_timeout = str(existing.get("screen_timeout", screen_timeout))
    screen_timeout = int(prompt("Screen timeout in seconds (used to detect if screen is likely off)", default_timeout))

    # ── Save ────────────────────────────────
    config = {
        "broker": broker,
        "port": port,
        "username": username,
        "password": password,
        "room": room,
        "topic": topic,
        "active_threshold": active_threshold,
        "screen_timeout": screen_timeout,
    }

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(config, indent=2) + "\n")

    print()
    print(f"  Configuration saved to: {CONFIG_FILE}")
    print()
    print("  Summary:")
    print(f"    Broker:           {broker}:{port}")
    print(f"    Auth:             {username if username else '(none)'}")
    print(f"    Topic:            {topic}")
    print(f"    Active threshold: {active_threshold} seconds")
    print(f"    Screen timeout:   {screen_timeout} seconds")
    print(f"    Session type:     {SESSION_TYPE}")
    print()

    return config


def load_config() -> dict | None:
    """Load config from file, return None if not found."""
    if CONFIG_FILE.exists():
        try:
            return json.loads(CONFIG_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            print("Warning: Could not parse config file, running setup.")
            return None
    return None


# ── X11 Display Functions ─────────────────────────────────────────────────────

def get_idle_seconds_x11() -> int:
    """Get user idle time in seconds via xprintidle."""
    try:
        result = subprocess.run(
            ["xprintidle"], capture_output=True, text=True, timeout=5
        )
        return int(result.stdout.strip()) // 1000  # xprintidle returns milliseconds
    except Exception:
        return 0


def is_screen_off_x11() -> bool:
    """Check DPMS state via xset. Returns True if monitor is NOT 'On'."""
    try:
        result = subprocess.run(
            ["xset", "q"], capture_output=True, text=True, timeout=5
        )
        match = re.search(r"Monitor is (\w+)", result.stdout)
        if match:
            return match.group(1) != "On"
        return False  # Safe default: assume screen is on
    except Exception:
        return False


def reset_idle_timer_x11():
    """Silently reset the screensaver/DPMS idle timer. No visible effect."""
    try:
        subprocess.run(["xset", "s", "reset"], capture_output=True, timeout=5)
    except Exception as e:
        log.warning(f"xset s reset failed: {e}")


def wake_screen_x11():
    """Wake a DPMS-off display."""
    try:
        subprocess.run(["xset", "dpms", "force", "on"], capture_output=True, timeout=5)
    except Exception as e:
        log.warning(f"xset dpms force on failed: {e}")
    # Also reset the idle timer so it doesn't immediately turn off again
    reset_idle_timer_x11()


# ── Wayland/GNOME Display Functions ──────────────────────────────────────────

def get_idle_seconds_wayland() -> int:
    """Get idle time on GNOME/Wayland via D-Bus. Returns 0 if unavailable."""
    try:
        result = subprocess.run(
            [
                "dbus-send", "--session", "--print-reply",
                "--dest=org.gnome.Mutter.IdleMonitor",
                "/org/gnome/Mutter/IdleMonitor/Core",
                "org.gnome.Mutter.IdleMonitor.GetIdletime",
            ],
            capture_output=True, text=True, timeout=5,
        )
        match = re.search(r"uint64\s+(\d+)", result.stdout)
        if match:
            return int(match.group(1)) // 1000  # milliseconds to seconds
    except Exception:
        pass
    return 0


def is_screen_off_wayland() -> bool:
    """Check if GNOME screensaver is active via D-Bus."""
    try:
        result = subprocess.run(
            [
                "dbus-send", "--session", "--print-reply",
                "--dest=org.gnome.ScreenSaver",
                "/org/gnome/ScreenSaver",
                "org.gnome.ScreenSaver.GetActive",
            ],
            capture_output=True, text=True, timeout=5,
        )
        return "boolean true" in result.stdout
    except Exception:
        return False


def reset_idle_timer_wayland():
    """Reset the GNOME screensaver timer via D-Bus. No visible effect."""
    try:
        subprocess.run(
            [
                "dbus-send", "--session", "--type=method_call",
                "--dest=org.gnome.ScreenSaver",
                "/org/gnome/ScreenSaver",
                "org.gnome.ScreenSaver.SimulateUserActivity",
            ],
            capture_output=True, timeout=5,
        )
    except Exception as e:
        log.warning(f"D-Bus idle reset failed: {e}")


def wake_screen_wayland():
    """Wake the screen on GNOME/Wayland."""
    try:
        subprocess.run(
            [
                "dbus-send", "--session", "--type=method_call",
                "--dest=org.gnome.ScreenSaver",
                "/org/gnome/ScreenSaver",
                "org.gnome.ScreenSaver.SetActive",
                "boolean:false",
            ],
            capture_output=True, timeout=5,
        )
    except Exception as e:
        log.warning(f"D-Bus screen wake failed: {e}")


# ── Unified Interface ─────────────────────────────────────────────────────────

def get_idle_seconds() -> int:
    if SESSION_TYPE == "wayland":
        return get_idle_seconds_wayland()
    return get_idle_seconds_x11()


def is_screen_off() -> bool:
    if SESSION_TYPE == "wayland":
        return is_screen_off_wayland()
    return is_screen_off_x11()


def reset_idle_timer():
    if SESSION_TYPE == "wayland":
        reset_idle_timer_wayland()
    else:
        reset_idle_timer_x11()


def wake_screen():
    if SESSION_TYPE == "wayland":
        wake_screen_wayland()
    else:
        wake_screen_x11()


# ── Wake Signal Handler ───────────────────────────────────────────────────────

def handle_wake(config: dict):
    """Three-tier wake logic."""
    active_threshold = config.get("active_threshold", 30)
    screen_timeout = config.get("screen_timeout", 1200)

    idle = get_idle_seconds()

    # Tier 1: User is actively working — do nothing
    if idle < active_threshold:
        return

    # Tier 3: Screen is likely off
    if is_screen_off():
        log.info(f"Wake signal — screen is off (idle {idle}s) — waking display")
        wake_screen()
        return

    # Tier 2: Idle but screen is still on — silently keep it on
    log.info(f"Wake signal — idle {idle}s, screen on — resetting idle timer")
    reset_idle_timer()


# ── MQTT Callbacks ─────────────────────────────────────────────────────────────

_config = {}  # Module-level reference for callbacks


def on_connect(client, userdata, flags, rc, properties=None):
    if rc == 0:
        log.info("Connected to MQTT broker")
        client.subscribe(_config["topic"])
    else:
        log.error(f"MQTT connection failed (rc={rc})")


def on_disconnect(client, userdata, flags, rc, properties=None):
    log.warning(f"Disconnected from broker (rc={rc}), will auto-reconnect...")


def on_message(client, userdata, msg):
    payload = msg.payload.decode("utf-8", errors="replace").strip()
    if payload == "wake":
        handle_wake(_config)


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    global _config

    force_setup = "--setup" in sys.argv or "--reconfigure" in sys.argv

    config = load_config()

    if config is None or force_setup:
        existing = config or {}
        config = run_setup(existing)

        if force_setup:
            print("Setup complete. Restart the script (or the service) to apply.")
            sys.exit(0)

    _config = config

    setup_logging()
    trim_log()

    broker = config["broker"]
    port = config.get("port", 1883)
    topic = config["topic"]

    log.info(f"ha-display-wake starting (broker: {broker}:{port}, topic: {topic}, session: {SESSION_TYPE})")
    log.info(f"  Active threshold: {config.get('active_threshold', 30)}s, Screen timeout: {config.get('screen_timeout', 1200)}s")

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)

    username = config.get("username")
    if username:
        client.username_pw_set(username, config.get("password", ""))

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message
    client.reconnect_delay_set(min_delay=5, max_delay=60)

    while True:
        try:
            client.connect(broker, port, keepalive=60)
            client.loop_forever()
        except KeyboardInterrupt:
            log.info("Shutting down")
            client.disconnect()
            break
        except Exception as e:
            log.error(f"Connection error: {e}, retrying in 10s...")
            time.sleep(10)


if __name__ == "__main__":
    main()
