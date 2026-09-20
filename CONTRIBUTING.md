# Contributing

Keep the CLI dependency-light and compatible with POSIX `/bin/sh`. Omarchy-only
behavior must remain feature-detected so the core continues to work on other
Linux desktops.

Before submitting a change:

```sh
sh -n bin/appblock
sh tests/run.sh
```

The test suite uses a temporary `HOME` and must never modify real appblock,
desktop, autostart, Hyprland, or systemd-user state. Tests involving an
installed graphical launcher must first prove the launcher works in the current
session and skip clearly when it does not.

Update `CHANGELOG.md` for user-visible changes. If the JSON document changes
incompatibly, bump `JSON_SCHEMA` and document the migration in
`docs/json-api.md`.
