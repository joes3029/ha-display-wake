# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-02-16

### Added

- Initial release
- Home Assistant automations for PIR-based room occupancy detection
- Windows client (PowerShell) with three-tier wake logic
- Linux client (Python) with X11 and Wayland/GNOME support
- Interactive first-run setup with broker auto-detection on both platforms
- Automatic dependency detection and installation (Mosquitto via winget on Windows, paho-mqtt via pip on Linux)
- Auto-detection of system screen timeout settings
- Pre-flight MQTT broker connection test
- Automatic Scheduled Task creation for Windows auto-start at login
- Automatic systemd user service creation for Linux auto-start at login
- Batch launcher for Windows (handles execution policy and Zone.Identifier)
- MQTT topic structure: `ha-display-wake/{room}/command` and `ha-display-wake/{room}/state`
- `--setup`, `--install`, and `--uninstall` flags on both platforms
