# appblock

Block distracting Linux applications without uninstalling them. appblock is a
lightweight friction tool for normal command, launcher, autostart, desktop-icon,
and Omarchy web-app launch routes.

It is built and tested primarily on Omarchy with Hyprland, while its core uses
Linux PATH and XDG conventions that apply across desktop environments. It is not
an access-control or security boundary: direct executable paths and uncovered
runtime-specific launchers remain intentional escape hatches.

## Quick start

```sh
install -Dm755 bin/appblock ~/.local/share/appblock/appblock
~/.local/share/appblock/appblock install

appblock block discord
appblock block steam --until 2h
appblock list
appblock unblock discord            # schedules the normal 10-minute cooldown
```

Start a new login session after installation so every desktop launch path sees
the shim directory.

## Support at a glance

| Environment or format | Support |
|---|---|
| Omarchy + Hyprland | First-class and tested |
| Other Hyprland systems | Supported; session PATH setup may need adjustment |
| GNOME, KDE, XFCE, Cinnamon | Expected through PATH and XDG integration |
| Native packages | Command and desktop-entry launches |
| Flatpak | Desktop-entry launches; direct `flatpak run` is not intercepted |
| Snap | PATH and desktop-entry launches; direct `/snap/bin/...` is not intercepted |
| AppImage | PATH or registered desktop-entry launches; direct file execution is not intercepted |
| Non-systemd Linux | Blocking works; stopping an already-running autostart applet does not |

See [the complete compatibility matrix](docs/compatibility.md) for package,
desktop, and runtime details.

## Installation

```sh
git clone https://github.com/ArhamTheDeveloper/appblock.git
cd appblock
install -Dm755 bin/appblock ~/.local/share/appblock/appblock
~/.local/share/appblock/appblock install
```

`appblock install` is idempotent. It creates or updates:

- `~/.local/share/appblock/` — executable link, shims, and plaintext state;
- marked PATH snippets in `~/.bashrc` and `~/.zshrc`, when those files exist;
- `~/.config/environment.d/appblock.conf` for systemd user sessions;
- a marked `hl.env(...)` line in `~/.config/hypr/hyprland.lua`, when present;
- the live systemd user-manager PATH, when systemd is available.

On a non-Hyprland desktop, the Hyprland step is simply skipped. If your session
does not import `environment.d`, add this directory to its PATH manually:

```sh
$HOME/.local/share/appblock/shims
```

## Usage

```text
appblock block <app|url>... [--until <duration>] [--keep-running]
appblock unblock <app|url>... [--after <duration>|--cancel]
appblock toggle <app|url>... [--until <duration>]
appblock list [--json]
appblock shims
appblock install
appblock uninstall
appblock --version
```

Examples:

```sh
appblock block discord spotify
appblock block steam --until 90m
appblock block youtube --until 22:30
appblock block https://youtube.com/

appblock unblock discord
appblock unblock discord --after 30m
appblock unblock discord --cancel
```

Durations accept forms such as `45s`, `25m`, `2h`, `1h30m`, `22:30`, or
`2026-09-20 22:30`.

## What blocking covers

appblock combines several independent mechanisms:

- PATH shims for ordinary command launches;
- XDG desktop overrides for menus and by-ID launcher calls;
- reversible hiding of user-owned PWA and desktop-icon files;
- XDG autostart disabling, with optional systemd-user stopping of a running applet;
- an Omarchy `omarchy-launch-webapp` URL guard when applicable.

The canonical desktop ID is used consistently across these layers. Every CLI
invocation reconciles drift caused by app updates. Concurrent CLI calls, bar
polls, and launch-time lazy lifts share a state lock so updates are not lost.

See [architecture](docs/architecture.md) for the design and
[design notes](docs/design-notes.md) for the detailed implementation history.

## Timed blocks and unblock friction

`--until` creates an automatic deadline. No daemon or cron job runs: the block
lifts on the next launch or appblock invocation after the deadline.

Manual unblocking deliberately takes time. `unblock` and `toggle` schedule a
lift behind a 10-minute cooldown rather than lifting immediately:

```sh
appblock unblock rmpc
appblock list
# 🚫 rmpc — enforced (unblocks in 9m, at 21:08)
```

Repeating `unblock` does not restart the wait. `--after` intentionally replaces
it with a new wait of at least 60 seconds; `--cancel` keeps the block and removes
the pending request. Plaintext state remains the documented manual escape hatch.

## Machine-readable state

```sh
appblock list --json | jq '.blocked'
```

stdout contains exactly one schema-versioned JSON document; reconciliation
messages go to stderr. Consumers must use this API rather than reading internal
state files. See the [JSON API contract](docs/json-api.md).

The optional [Omarchy bar plugin](https://github.com/ArhamTheDeveloper/omarchy-appblock)
is a separate repository and consumes only this API.

## Uninstall

Run:

```sh
appblock uninstall
```

Uninstall is an explicit whole-tool removal, so it restores blocked targets
immediately rather than scheduling an unblock cooldown. It then removes:

- `~/.local/share/appblock/`
- `~/.config/environment.d/appblock.conf`
- the `# appblock shims (added by appblock)` marker and following PATH line from
  `~/.bashrc` and `~/.zshrc`
- the `-- appblock shims on PATH (added by appblock)` marker and following
  `hl.env(...)` line from `~/.config/hypr/hyprland.lua`, if present

It also republishes the live systemd-user PATH without the shim directory. Log
out and back in afterward so every existing desktop process receives the clean
environment. Installed applications and unrelated desktop entries are never
removed.

## Development

```sh
sh -n bin/appblock
sh tests/run.sh
```

The suite runs under a temporary `HOME` and does not use real appblock state.
Graphical `gtk-launch` tests run only after a sandbox launcher probe succeeds.

```text
bin/appblock             single-file CLI
tests/run.sh             hermetic integration suite
docs/compatibility.md    supported environments and launch formats
docs/architecture.md     component and state boundaries
docs/json-api.md         consumer contract
docs/design-notes.md     detailed engineering history
```

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and
[CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).
