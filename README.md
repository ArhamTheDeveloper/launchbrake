# appblock

Block any installed app — GUI, CLI, or **web-app/PWA** — from launching, with
an instant toggle. A dependency-free POSIX-sh tool for people who get
distracted by their own computer (music players, games, chat apps) and don't
want to uninstall things. Covers every launch surface it can see: PATH,
app menus, autostart, omarchy web-app keybinds, and desktop icons.

## How it works

1. **PATH shims** — `~/.local/share/appblock/shims/` is prepended to PATH.
   Each managed app gets a small script there that checks a plaintext
   blocklist: blocked → message + exit; open → `exec`s the real binary,
   fully transparently (signals/TTY/stdin all pass through).
2. **Menu hiding** — blocked apps get a `NoDisplay=true` desktop-entry
   override, which also masks any absolute `Exec=` in the original entry
   (per Base Directory Spec, `$XDG_DATA_HOME` wins).
   **Web-apps/PWAs** (entries living in `~/.local/share/applications`, e.g.
   Chromium PWAs or omarchy `omarchy-launch-webapp` apps) are instead
   **renamed aside** to `.appblock-disabled.<id>.desktop.off` — byte-exact
   and reversible on unblock, and invisible to GLib/menus while blocked.
3. **Autostart discipline** — blocked apps' `~/.config/autostart` entries
   get `Hidden=true`; `reconcile()` re-applies on every invocation so app
   updates can't silently clobber the block (this also re-renames a PWA
   entry that an update/reinstall brought back). Unblock merges (only clears
   `Hidden`, never reverts an updated `Exec=`).
4. **Desktop icons** — on DEs whose desktop view shows launcher *files*
   (GNOME's DING, KDE Folder View, xfdesktop, Nemo, pcmanfm-qt), menu hiding
   is irrelevant: the icon launches `Exec=` by path. appblock resolves the
   desktop dir via XDG user-dirs (`xdg-user-dir` → `user-dirs.dirs` →
   `~/Desktop`) and renames matching icons aside
   (`.appblock-disabled.<name>.desktop.off`), restored byte-identically on
   unblock. On omarchy `XDG_DESKTOP_DIR="$HOME/"`, so matching is strictly
   per-`Exec`: only icons naming the blocked binary (any token, e.g.
   `env WINEPREFIX=… wine …`) or opening a blocked URL are touched.
5. **State** — plaintext files (`blocked.list`, `managed.list`), read fresh
   each run. Toggling is instant. Real binaries and packages are untouched,
   so the tool survives system updates.
6. **Name resolution** — `appblock block chatgpt` works: names are matched
   case-insensitively against desktop ids, `Name=` fields, and entry URLs.
   An ambiguous match is reported, never guessed.
7. **Web-app URL guard** — omarchy web-app keybinds (`SUPER SHIFT X` → `X`,
   YouTube, ChatGPT, …) don't read a `.desktop` entry at all: Hyprland runs
   `omarchy-launch-webapp <url>`, which picks the browser itself. So while any
   web-app URL is blocked, appblock also owns that launcher **name on PATH**
   and refuses the matching URL(s); with nothing blocked the shim is removed
   and the real launcher runs untouched (no permanent indirection).

## Install

```sh
install -Dm755 bin/appblock ~/.local/share/appblock/appblock
~/.local/share/appblock/appblock install   # wires PATH into shells + systemd user env + Hyprland
```

## Usage

```
appblock block <app|url>...  block (terminal + launcher + keybind + systemd)
appblock unblock <app|url>... unblock
appblock toggle <app|url>... flip state
appblock list                show blocked apps with honest enforcement labels
appblock install             (re)wire PATH into every launch path
appblock shims               refresh shims after a package upgrade moved binaries
```

`list` distinguishes `enforced (launch blocked)` from
`hidden only — NOT launch-enforced` — a PATH-shim architecture cannot
intercept hand-typed absolute paths, raw dock commands, or `flatpak run` —
and says so instead of pretending otherwise. Web-apps/PWAs are labelled per
what is actually covered: `menu hidden + omarchy-launch-webapp guard (keybind
intercepted)`, or plain `hidden only (…)` when no URL is known.

## Web-apps / PWAs

Works for both shapes: omarchy web-apps (`omarchy-launch-webapp`) and
Chromium PWAs (`chrome-chatgpt-abc123.desktop`).

```sh
appblock block x            # resolves to ~/.local/share/applications/X.desktop
                            # → menu entry renamed aside AND https://x.com/* guarded
appblock list               # 🚫 X — menu hidden + omarchy-launch-webapp guard
appblock unblock x          # byte-identical restore, verified with cmp

appblock block https://youtube.com/   # no desktop entry needed at all
```

- **URL matching covers the URL and everything under it**, case-insensitively:
  blocking `https://x.com/` also refuses `https://x.com/compose/post` (so
  `SUPER SHIFT X` *and* `SUPER SHIFT ALT X` are both caught). Blocking or
  launching is *never* guessed: a URL is only refused when it equals a blocked
  URL or sits below it.
- **Honest boundary:** *typing* the URL into the browser's address bar, or a
  keybind that calls the browser binary directly (`chromium --app=<url>`), is
  out of reach — block the browser for that (`appblock block chromium`).

## Desktop icons

A desktop view is a third namespace: it shows launcher *files*, and
double-clicking runs `Exec=` by path — `NoDisplay`/`Hidden` (menu keys) do
nothing there, and an absolute Exec bypasses PATH. So when a DE shows desktop
icons (GNOME DING, KDE Folder View, xfdesktop, Nemo, pcmanfm-qt), appblock
hides those too:

```sh
appblock block steam   # → ~/steam.desktop renamed aside, restored on unblock
appblock block x       # → an icon that runs omarchy-launch-webapp https://x.com/ is hidden too
appblock block https://youtube.com/   # a bare URL block hides its icon as well
```

- The desktop dir is resolved per XDG: `xdg-user-dir DESKTOP`, then
  `XDG_DESKTOP_DIR` from `user-dirs.dirs`, then `~/Desktop`. No dir → no-op.
- **omarchy sets `XDG_DESKTOP_DIR="$HOME/"`** — the desktop folder *is* your
  home directory. appblock therefore never sweeps the directory: only
  top-level `*.desktop` files whose `Exec` names the blocked binary (any
  token — `env "WINEPREFIX=…" wine "…lnk"` still matches `wine`) or opens the
  blocked URL are renamed aside. Everything else in `$HOME` is untouched.
- Same reversible mechanism as PWA entries: byte-identical restore, and
  `reconcile()` re-hides an icon recreated while blocked.

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
- **Web-app URL guard owns `omarchy-launch-webapp` on PATH only while a URL
  is blocked** — the shim is created and deleted automatically, self-heals if
  removed (`reconcile`), and is deliberately *not* registered as a managed
  app (so `appblock shims` can't turn it into an everything-blocker). It
  falls through to the real launcher for every other invocation.

## Verified launch coverage (Omarchy/Hyprland, live)

| launch style | result |
|---|---|
| interactive shell | shim intercepts |
| compositor/keybind | shim intercepts (hl.env PATH wiring) |
| `systemd-run --user` / user services | shim intercepts (environment.d) |
| menu/launcher (GLib GAppInfo) | hidden + shim intercepts even on forced launch |
| web-app keybind (`omarchy-launch-webapp`) | URL guard intercepts (verified live: `SUPER SHIFT X` + compose binding) |
| web-app keybind via `omarchy-launch-or-focus-webapp` | same guard intercepts (inner `eval exec` resolves through PATH) |
| desktop-icon double-click (DING/xfdesktop/…) | icon renamed aside (XDG desktop dir); guarded URL icons also refused |

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