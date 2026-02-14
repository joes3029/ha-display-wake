# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-02-14

### Added

- Initial release
- Home Assistant automations for PIR-based room occupancy detection
- Windows client (PowerShell) with three-tier wake logic
- Linux client (Python) with X11 and Wayland/GNOME support
- Interactive first-run setup with broker auto-detection
- Auto-detection of system screen timeout settings
- Systemd user service for Linux
- Task Scheduler instructions for Windows
- MQTT topic structure: `ha-display-wake/{room}/command` and `ha-display-wake/{room}/state`
