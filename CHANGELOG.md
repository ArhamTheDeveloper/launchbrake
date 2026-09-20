# Changelog

All notable changes are documented here. The project follows semantic
versioning.

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
