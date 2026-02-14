# Contributing to ha-display-wake

Thanks for your interest in contributing! This is a small project born from a simple
frustration — walking into a room and having to jiggle a mouse on every PC to wake
the screens. If you've found your way here, you probably know exactly what that feels
like.

Contributions of all kinds are welcome: bug reports, feature ideas, documentation
improvements, code, and platform support.

## Ways to Contribute

### Reporting Bugs

Found something that doesn't work? Please [open an issue](../../issues/new?template=bug_report.md).
Include:

- Your OS and version (e.g. Windows 11 23H2, Ubuntu 24.04)
- Display server if Linux (X11 or Wayland — run `echo $XDG_SESSION_TYPE`)
- Your Home Assistant version
- What happened vs what you expected
- Relevant log output from `ha-display-wake.log`

### Suggesting Features

Have an idea? [Open a feature request](../../issues/new?template=feature_request.md).
Some areas we're particularly interested in:

- **New platforms:** macOS support, other Linux desktop environments, Wayland
  compositors beyond GNOME
- **New presence sources:** Webcam-based presence detection, Bluetooth proximity,
  phone-based detection
- **HA integration:** Blueprints, HACS components, config flow UI
- **Quality of life:** Better auto-detection, installer scripts, tray icons

### Submitting Code

1. Fork the repo and create a branch from `main`
2. Make your changes
3. Test on your own setup (we don't have a CI pipeline yet — real-world testing is
   what matters here)
4. Open a pull request with a clear description of what you changed and why

### Improving Documentation

Documentation contributions are just as valuable as code. If the setup guide was
confusing, if you had to figure something out that wasn't documented, or if you have
tips for a specific hardware/software combination — please share.

## Design Philosophy

A few principles that guide this project:

- **Home Assistant owns the intelligence.** Occupancy detection, sensor fusion,
  scheduling — all of that belongs in HA. The client scripts should be as simple as
  possible.

- **Zero interference when you're working.** If the user is actively at their PC,
  the scripts should be completely invisible. No mouse movements, no idle timer
  resets, nothing.

- **Friction-free setup.** Interactive first-run configuration, auto-detection where
  possible, sensible defaults. The goal is that someone can go from download to
  working in under 5 minutes.

- **Quiet reliability.** This is background infrastructure. It should start on boot,
  reconnect when the broker blips, and never need attention. If it's working well,
  you forget it exists.

## Code Style

- **PowerShell:** Follow standard PowerShell conventions. Use `PascalCase` for
  functions, descriptive variable names.
- **Python:** PEP 8, type hints where they help readability. Keep dependencies
  minimal — `paho-mqtt` is the only required pip package.
- **YAML:** 2-space indentation for HA automations, clear comments.

## Questions?

Open a [discussion](../../discussions) or an issue. There are no silly questions —
if something wasn't obvious to you, it probably isn't obvious to others either.
