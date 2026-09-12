# appblock

Block any installed app — GUI or CLI — from launching, with an instant toggle.
A dependency-free POSIX-sh tool for people who get distracted by their own
computer (music players, games, chat apps) and don't want to uninstall things.

## How it works

1. **PATH shims** — `~/.local/share/appblock/shims/` is prepended to PATH.
   Each managed app gets a small script there that checks a plaintext
   blocklist: blocked → message + exit; open → `exec`s the real binary,
   fully transparently (signals/TTY/stdin all pass through).
2. **Menu hiding** — blocked apps get a `NoDisplay=true` desktop-entry
   override, which also masks any absolute `Exec=` in the original entry
   (per Base Directory Spec, `$XDG_DATA_HOME` wins).
3. **Autostart discipline** — blocked apps' `~/.config/autostart` entries
   get `Hidden=true`; `reconcile()` re-applies on every invocation so app
   updates can't silently clobber the block. Unblock merges (only clears
   `Hidden`, never reverts an updated `Exec=`).
4. **State** — plaintext files (`blocked.list`, `managed.list`), read fresh
   each run. Toggling is instant. Real binaries and packages are untouched,
   so the tool survives system updates.

## Install

```sh
install -Dm755 bin/appblock ~/.local/share/appblock/appblock
~/.local/share/appblock/appblock install   # wires PATH into shells + systemd user env + Hyprland
```

## Usage

```
appblock block <app>...      block (terminal + launcher + systemd + keybind)
appblock unblock <app>...    unblock
appblock toggle <app>...     flip state
appblock list                show blocked apps with honest enforcement labels
appblock install             (re)wire PATH into every launch path
appblock shims               refresh shims after a package upgrade moved binaries
```

`list` distinguishes `enforced (launch blocked)` from
`hidden only — NOT launch-enforced` — a PATH-shim architecture cannot
intercept hand-typed absolute paths, raw dock commands, or `flatpak run` —
and says so instead of pretending otherwise.

## Matching scope (structural boundaries, not bugs)

- **Reconcile matches autostart entries by binary *basename*.** An update
  that *renames* the binary (e.g. `spotify` → `spotify_1.2`) is out of
  scope: the block's menu-enforcement still holds, but autostart
  drift-repair won't match the renamed entry. Same category as the dock /
  absolute-path caveats above — re-block the app under its new name.
- **`enforced` means the four launch styles in the table below are
  intercepted *as of the last `list`*.** It is re-verified live on every
  `list`; a binary that since moved is reported honestly rather than
  silently left looking enforced.

## Verified launch coverage (Omarchy/Hyprland, live)

| launch style | result |
|---|---|
| interactive shell | shim intercepts |
| compositor/keybind | shim intercepts (hl.env PATH wiring) |
| `systemd-run --user` / user services | shim intercepts (environment.d) |
| menu/launcher (GLib GAppInfo) | hidden + shim intercepts even on forced launch |

## Tests

```sh
sh tests/run.sh   # sandboxed fake $HOME; never touches real state
```

## Roadmap

- timed blocks (`block <app> --until 25m`, lazy expiry inside the shim)
- `list --json` for bar widgets/plugins
- `flatpak run <id>` interception (documented gap)
- optional unblock friction (type a phrase)

## License

MIT — see LICENSE.