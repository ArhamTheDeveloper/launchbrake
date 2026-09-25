# LaunchBrake

Block distracting Linux applications without uninstalling them. LaunchBrake is a
lightweight friction tool for normal command, launcher, autostart, desktop-icon,
and registered Omarchy web-app launch routes.

The project is named **LaunchBrake**; its stable command remains `appblock`, and
its state remains under `~/.local/share/appblock/`.

It is built and tested primarily on Omarchy with Hyprland, while its core uses
Linux PATH and XDG conventions that apply across desktop environments. It is not
an access-control or security boundary: direct executable paths and uncovered
runtime-specific launchers remain intentional escape hatches.

## Installation

### Requirements

LaunchBrake supports Linux and requires a POSIX-compatible `/bin/sh` plus GNU
core utilities. It is tested primarily on Arch Linux and Omarchy. Installation
is per-user and does not require `sudo`.

### 1. Download LaunchBrake

```sh
git clone https://github.com/ArhamTheDeveloper/launchbrake.git
cd launchbrake
```

### 2. Install the CLI

```sh
install -Dm755 bin/appblock ~/.local/share/appblock/appblock
~/.local/share/appblock/appblock install
```

**LaunchBrake** is the project name; its stable terminal command is `appblock`.

### 3. Log out and back in

Log out of your desktop session and log back in once. This allows new
terminals, application launchers, desktop menus, and user services to see
LaunchBrake's shim directory.

### 4. Verify the installation

```sh
appblock --version
appblock list
```

The first command should print the installed version. The second should show an
empty blocked-app list on a new installation.

### 5. Block an application

```sh
appblock block discord
appblock list

appblock block steam --until 2h
appblock unblock discord            # schedules the normal 10-minute cooldown
```

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

## What installation changes

`appblock install` is idempotent. It creates or updates:

- `~/.local/share/appblock/` — executable link, shims, and plaintext state;
- marked PATH snippets in `~/.bashrc` and `~/.zshrc`, when those files exist;
- `~/.config/environment.d/appblock.conf` for systemd user sessions;
- a marked `hl.env(...)` line in `~/.config/hypr/hyprland.lua`, when present;
- the live systemd user-manager PATH, when systemd is available.

On a non-Hyprland desktop, the Hyprland step is simply skipped. If your session
does not import `environment.d`, add the shim directory to the session's PATH.
For the current terminal, run:

```sh
export PATH="$HOME/.local/share/appblock/shims:$PATH"
```

Add the same export to your shell profile or desktop session environment to
make it persistent.

## Updating

From the cloned LaunchBrake repository, run:

```sh
git pull --ff-only
install -Dm755 bin/appblock ~/.local/share/appblock/appblock
~/.local/share/appblock/appblock install
appblock shims
```

The final command refreshes generated application shims with the updated
LaunchBrake logic. Log out and back in if the installer reports a session PATH
change.

## Usage

LaunchBrake is **not a website blocker**. It does not filter browser traffic and
cannot stop a URL typed into a browser. Block a browser or a registered web-app
launcher when that is the behavior you want.

```text
appblock block <app>... [--until <duration>] [--keep-running]
appblock unblock <app>... [--after <duration>|--cancel]
appblock toggle <app>... [--until <duration>]
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

appblock unblock discord
appblock unblock discord --after 30m
appblock unblock discord --cancel
```

Durations accept forms such as `45s`, `25m`, `2h`, `1h30m`, `22:30`, or
`2026-09-20 22:30`.

## What blocking covers

LaunchBrake combines several independent mechanisms:

- PATH shims for ordinary command launches;
- XDG desktop overrides for menus and by-ID launcher calls;
- reversible hiding of user-owned PWA and desktop-icon files;
- XDG autostart disabling, with optional systemd-user stopping of a running applet;
- registered Omarchy web-app launcher interception when applicable.

The Omarchy integration can refuse a URL passed specifically through
`omarchy-launch-webapp`; this is launcher interception, not general website
blocking. Normal browser tabs and address-bar navigation are outside the tool's
scope.

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

The optional [LaunchBrake Omarchy plugin](https://github.com/ArhamTheDeveloper/omarchy-launchbrake)
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

## Development disclosure

LaunchBrake was conceived, specified, tested, and maintained by Muhammad Arham.
Its implementation was produced with substantial assistance from AI coding
tools under human direction and review.

## License

MIT — see [LICENSE](LICENSE).
