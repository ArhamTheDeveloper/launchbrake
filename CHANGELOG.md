# Changelog

All notable changes are documented here. The project follows semantic
versioning.

## Unreleased

- Renamed the public project to LaunchBrake while retaining `appblock` as the
  stable CLI command and state namespace.
- Clarified that Omarchy web-app launcher interception is not general website
  blocking, and removed the misleading standalone URL example from the README.

## 0.3.0

- Added `appblock uninstall`, including immediate restoration of appblock-owned
  launcher, desktop-icon, and autostart changes.
- Removed only marked shell, environment.d, and Hyprland PATH integration during
  uninstall, and safely republish the live systemd-user PATH without the shim.

## 0.2.1

- Serialized CLI reconciliation and launch-time lazy lifts with a shared lock.
- Rejected control characters before they can corrupt line-oriented or JSON state.
- Removed the remaining `eval` from desktop-entry discovery.
- Made the real `gtk-launch` tests skip when the current session cannot launch a
  verified sandbox entry.

## 0.2.0

- Added the schema-versioned `list --json` consumer API.
- Added by-ID desktop-launch interception and running-autostart-applet handling.
- Removed evaluation of user-provided arguments.

Earlier implementation history is retained in `docs/design-notes.md`.
