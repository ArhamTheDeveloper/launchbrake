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
   The shim is **named** for the command you type but **keyed** on the app's
   canonical desktop id (`# appblock-block-key: org.mozilla.firefox` inside
   the generated script), so apps whose id differs from their launch binary
   (reverse-DNS/Flatpak-style Firefox, Discord, Spotify, …) are intercepted
   too instead of silently falling through. `reconcile()` refreshes any shim
   whose key no longer matches its resolved id, so installs from before this
   fix self-heal on the next invocation.
2. **Menu hiding + by-id launcher interception** — blocked apps get a
   `NoDisplay=true` desktop-entry override. `NoDisplay` alone does **not** stop
   a by-id `.desktop` launch (`gtk-launch <id>.desktop`, the call Omarchy's
   launcher/dock/taskbar makes): GLib runs the override's `Exec=` regardless,
   and if that `Exec` cannot spawn it silently falls through to the real system
   entry. So the override's `Exec=` is always an **absolute path to a per-app
   deny script** (`shims/.appblock-deny.<id>`) that runs the same block-check
   as the shim and refuses — deterministic for same-name and reverse-DNS ids
   alike, keyed on the canonical id (per the Base Directory Spec,
   `$XDG_DATA_HOME` wins). `reconcile()` re-asserts this `Exec` if an update
   clobbers it, and the deny script is removed once the last block lifts (no
   permanent indirection).
   **Web-apps/PWAs** (entries living in `~/.local/share/applications`, e.g.
   Chromium PWAs or omarchy `omarchy-launch-webapp` apps) are instead
   **renamed aside** to `.appblock-disabled.<id>.desktop.off` — byte-exact
   and reversible on unblock, and invisible to GLib/menus while blocked.
3. **Autostart discipline** — blocked apps' `~/.config/autostart` entries
   get `Hidden=true`; `reconcile()` re-applies on every invocation so app
   updates can't silently clobber the block (this also re-renames a PWA
   entry that an update/reinstall brought back). Unblock merges (only clears
   `Hidden`, never reverts an updated `Exec=`).
   **A running applet started from that entry is stopped too.** Disabling an
   autostart entry only takes effect at your next login, while the icon you
   are actually looking at — Remmina's applet, Discord, Dropbox, the omarchy
   bar's tray, waybar, any StatusNotifierItem host — belongs to the *process*.
   So `block` also stops it, surgically: the only thing ever touched is the
   systemd user unit that systemd's own `xdg-autostart-generator` built from
   that very entry (`app-<escaped-index-name>@autostart.service`), and only
   while it is active. No `pkill`, no process hunting — an app you started by
   hand is not ours to kill. Pass `--keep-running` to `block`/`toggle` to
   disable the entry and leave the running applet alone. Lifting a block never
   *starts* anything: the entry is re-enabled for your next login, and nothing
   is ever launched behind your back.
4. **Desktop icons** — on DEs whose desktop view shows launcher *files*
   (GNOME's DING, KDE Folder View, xfdesktop, Nemo, pcmanfm-qt), menu hiding
   is irrelevant: the icon launches `Exec=` by path. appblock resolves the
   desktop dir via XDG user-dirs (`xdg-user-dir` → `user-dirs.dirs` →
   `~/Desktop`) and renames matching icons aside
   (`.appblock-disabled.<name>.desktop.off`), restored byte-identically on
   unblock. On omarchy `XDG_DESKTOP_DIR="$HOME/"`, so matching is strictly
   per-`Exec`: only icons naming the blocked binary (any token, e.g.
   `env WINEPREFIX=… wine …`) or opening a blocked URL are touched.
5. **State** — plaintext files (`blocked.list`, `managed.list`,
   `blocked-until.list`), read fresh each run. Toggling is instant. Real
   binaries and packages are untouched, so the tool survives system updates.
   CLI reconciliation and launch-time lazy lifts share a cross-process lock,
   so simultaneous bar polls, commands, and app launches cannot lose each
   other's state updates. App names and URLs containing control characters are
   rejected before storage, keeping both the line-oriented files and JSON API
   well formed.
   The canonical id is the key everywhere (`blocked.list`, the timed-block
   deadline, and the shim's check); the layers that are inherently keyed on
   the launch binary (the shim file itself, autostart `Exec=`, desktop icons)
   recover the binary name from the shim's `appblock-block-key` marker.
6. **Name resolution** — `appblock block chatgpt` works: names are matched
   case-insensitively against desktop ids, `Name=` fields, and entry URLs.
   An ambiguous match is reported, never guessed. Whatever you type is
   resolved to the canonical desktop id before anything is stored or
   checked, so `block firefox` and `block org.mozilla.firefox` agree.
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
appblock block <app|url>... [--until <dur>] [--keep-running]
                                                         block (terminal + launcher + keybind + autostart)
                                                         --until 25m auto-lifts it later
appblock unblock <app|url>... [--after <dur>|--cancel]   request a lift (cooldown — see below)
appblock toggle <app|url>... [--until <dur>]             flip state (unblocking still cools down)
appblock list                                            show blocked apps with honest enforcement labels
appblock list --json                                     the same state, machine-readable (see below)
appblock install                                         (re)wire PATH into every launch path
appblock shims                                           refresh shims after a package upgrade moved binaries
appblock --version                                       what to gate on from a script/widget
```

## Machine-readable state (`list --json`)

For bar widgets, plugins and scripts. stdout is one JSON document and *nothing
else* — everything `reconcile()` narrates goes to stderr, so this is safe:

```sh
appblock list --json | jq -r '.blocked[] | "\(.id) \(.unblock_in // "-")"'
```

```json
{
  "schema": 1,
  "version": "0.2.1",
  "state_dir": "/home/you/.local/share/appblock",
  "count": 1,
  "blocked": [
    {"id": "rmpc", "enforcement": "enforced", "until": null, "unblock_at": 1789402126, "until_in": null, "unblock_in": 591}
  ],
  "managed": ["rmpc", "chromium"]
}
```

- `until` / `unblock_at` are **epoch seconds** — the authoritative values — and
  `until_in` / `unblock_in` are the seconds remaining at call time, so a widget
  can run a live countdown without re-implementing any of our parsing.
- `enforcement` is exactly the string `list` prints, verbatim: never a second
  interpretation of it.
- `schema` is the contract for consumers. Bump-gated; check `appblock --version`
  if you need a specific feature.
- **Consumers read this, never `blocked.list`.** Re-deriving "what is blocked"
  from the plaintext state in another language means two implementations of one
  truth — the exact class of bug this project keeps finding (a shim keyed
  differently from the blocklist it checks). The plaintext files remain an
  escape hatch for a human, not an API.
- A widget's action should be `toggle`, which *schedules* the lift, so the bar
  cannot become the one-click bypass the cooldown exists to prevent.

## Timed blocks

Block something for a while and let it release itself — no daemon, no cron,
no clock drift:

```sh
appblock block rmpc --until 25m        # relative: 25m, 2h, 1h30m, 90s
appblock block steam --until 22:30     # absolute: HH:MM (today)
appblock block x --until "2026-09-14 09:00"
appblock list                          # 🚫 rmpc — enforced (24m left)
```

- `--until` applies to every app/URL named in the same call (including
  `toggle`). `unblock` clears the deadline.
- **Lazy expiry — the deadline is checked when the app is launched**, inside
  the shim: past it, the shim lifts the block, writes state back, and `exec`s
  the real binary so the launch is not lost. Nothing runs in the background.
- `reconcile()` (which runs on every `appblock` invocation) also expires
  overdue blocks that were never launched, lifting the menu/icon/autostart
  hiding along with them.
- Deadlines live in `blocked-until.list` (`<id>|<epoch>`). An unparseable
  duration is rejected with a non-zero exit rather than silently blocking
  forever.

`list` distinguishes `enforced (launch blocked)` from
`hidden only — NOT launch-enforced` — a PATH-shim architecture cannot
intercept hand-typed absolute paths, raw dock commands, or `flatpak run` —
and says so instead of pretending otherwise. The launcher layer is reported
honestly too: `launcher masked (by-id launch intercepted)` appears only when
the deny-script override is live and its `Exec` provably routes a
`gtk-launch <id>.desktop` click into the block-check (verified by a real
click-through in the sandbox suite) — never assumed from `NoDisplay` alone.
Web-apps/PWAs are labelled per
what is actually covered: `menu hidden + omarchy-launch-webapp guard (keybind
intercepted)`, or plain `hidden only (…)` when no URL is known.

## Unblocking takes effort

Lifting a block is deliberately slow — for **every** block, timed or not.
`unblock` and `toggle` never lift directly; they **schedule** the lift and it
lands once the cooldown elapses:

```sh
appblock unblock rmpc              # ⏳ stays blocked for another 10m — lift scheduled for 21:08
appblock unblock rmpc              # ⏳ already has a lift scheduled — still blocked until 21:08
appblock unblock rmpc --after 30m  # ask for a longer wait first (floor: 60s)
appblock unblock rmpc --cancel     # changed your mind — stays blocked
appblock list                      # 🚫 rmpc — enforced (unblocks in 9m, at 21:08)
```

- Default cooldown is **10 minutes**. `--after` sets a fresh wait; anything
  under 60s is refused, so a tiny wait can't be used as a back door.
- **Asking twice changes nothing.** A bare `unblock`/`toggle` on an app that
  already has a lift pending leaves that pending lift exactly as it was and says
  so. Retrying is not a way to wait longer — and not a way to restart the wait
  either. Only an explicit `--after <dur>` re-sets one (it counts from now, and
  may shorten a longer wait you no longer want).
- The request lives in `unblock-at.list` (`<id>|<epoch>`) and is applied lazily:
  the next time you **launch** the app (the shim sees the elapsed wait, exactly
  like a `--until` deadline), or on the next `appblock` run via `reconcile()`.
  No daemon, no cron. Until it lands the app is still fully blocked, at every
  layer (shim, menu, autostart, icons, URL guard) — so if you asked for a lift,
  expect it to land on your next `appblock` run or app launch, not on the spot.
- `list` names the exact clock time, so you never have to work out when it lands.
- A lift that lands **at launch** finishes the job at every layer: the shim (or
  the by-id deny script) removes appblock's own `NoDisplay` override — or renames
  a PWA entry back — as it lets the launch through, so an unblocked app can never
  stay invisible in the launcher. The layers keyed on the launch binary
  (autostart `Hidden=`, desktop icons) are finished by `reconcile()`'s sweep on
  the next invocation, which also covers hand-editing `blocked.list`.
- `toggle` on a blocked app schedules a lift too, so it is not a one-keystroke
  bypass.
- **Timed blocks stay frictionless on the way out**: a `--until` deadline passing
  lifts automatically with no cooldown. The cooldown guards a *user-requested*
  lift only.
- Untimed blocks are covered as well — they have no deadline to fall back on, so
  they are exactly where friction matters most.
- Scope: the state files are plaintext, so editing `blocked.list` by hand bypasses
  all of it. As elsewhere here, it's friction against your own impulses, not a
  security boundary.

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

- `list --json` for bar widgets/plugins
- `flatpak run <id>` interception (documented gap)
- optional unblock friction (type a phrase)

## License

MIT — see LICENSE.
