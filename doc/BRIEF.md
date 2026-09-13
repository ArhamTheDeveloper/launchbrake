# appblock — project brief

## What it is
`appblock` is a tiny, dependency-free CLI tool for Linux that lets you **block any installed app — GUI, CLI, or web-app/PWA — from launching, with an instant toggle to unblock it**. It exists to fight distraction (music players, games, social apps) without uninstalling or breaking anything.

## Why it exists
Every existing solution covers only websites (browser blockers), or is heavyweight/untoggleable (AppArmor/Firejail profiles, GNOME-only session blockers). macOS has proper app blockers; **Linux desktop has a gap**. GitHub searches for Linux desktop app blockers return essentially nothing. appblock fills that gap.

## How it works (the mechanism)
1. **PATH shims**: `~/.local/share/appblock/shims/` is prepended to `PATH`. Each managed app gets a ~6-line POSIX shell script there that (a) checks a plaintext blocklist, (b) if blocked → prints a message and exits, (c) if not → `exec`s the real binary with all args, so it's 100% transparent (signals, TTY, stdin all pass through). The shim is **named** for the launch binary but **keyed** on the canonical desktop id (recorded as `# appblock-block-key: <id>` inside it), so reverse-DNS-id apps (Flatpak-style `org.mozilla.firefox`) are actually intercepted instead of silently falling through to the real binary.
2. **Launcher hiding**: blocked apps also get a `NoDisplay=true` desktop-entry override in `~/.local/share/applications/`, so they vanish from app menus/launchers. Removed on unblock. **Web-apps/PWAs** (entries whose *original* lives in the user dir — Chromium PWAs, omarchy `omarchy-launch-webapp` apps) are instead **renamed aside** to `.appblock-disabled.<id>.desktop.off`: byte-exact, reversible, invisible to GLib (which only scans `*.desktop`). An override would clobber the original there, so rename is the only safe mechanism. **Desktop icons** (DING/xfdesktop-style views that show launcher *files*) are a separate namespace — matched by `Exec` contents in the XDG desktop dir and renamed aside the same way (see below).
3. **State**: plaintext files — `blocked.list`, `managed.list`, and `blocked-until.list` (timed blocks) — read fresh on every invocation, so toggling is instant and there's nothing to install/uninstall. The real binaries, packages, and configs are never touched (survives system updates).

## Current state (works, on one Arch/Omarchy machine)
- Commands: `appblock block|unblock|toggle <app|url...> [--until <dur>] [--after <dur>|--cancel]`, `list`, `install`, `shims`
- **Timed blocks** with lazy expiry (see below)
- Blocking verified end-to-end for CLI apps (`rmpc`) and launcher visibility
- Desktop-icon hiding on icon-showing DEs, with omarchy's `$HOME`-as-desktop caveat handled (see below)
- PATH wiring into all **three** launch paths (see below) — GUI-app gap CLOSED
- Written in POSIX sh, zero dependencies

## GUI-app launch paths — CLOSED (verified live)
`appblock install` wires the shim dir into every injection point:
1. **Interactive shells**: `~/.bashrc` + `~/.zshrc` (marker-idempotent)
2. **systemd --user env**: `~/.config/environment.d/appblock.conf` + live `systemctl --user set-environment PATH=…` (covers user services, `systemd-run --user`, portal-spawned apps)
3. **Compositor**: `hl.env("PATH", …)` appended to `~/.config/hypr/hyprland.lua` (Hyprland keybind/launcher-spawned apps; `hyprctl reload` ok)

All three launch styles **verified live on Omarchy/Hyprland**: compositor-spawned process PATH begins with shims, `systemd-run --user` sees shims, shell sees shims. Menu-hiding override wins per Base Directory Spec ($XDG_DATA_HOME before XDG_DATA_DIRS incl. Flatpak exports). **Menu click-through proven end-to-end** via GLib `GAppInfo` (the exact path menus use): blocked → resolves override (`NoDisplay=true`, bare `Exec`) → even a forced launch is shim-intercepted; unblocked → GLib resolves the untouched **absolute-Exec original** → app launches. That closes the "absolute `Exec=` bypass" concern: the override masks any absolute Exec with bare-name PATH resolution.

## Debugging artifacts (worth keeping visible)
- **Stale-binary**: shims hardcode resolved absolute path; re-`block` re-resolves PATH (shim dir excluded); vanished binary → shim **deleted** + loud skip. Deletion is structurally guarded against launch-time (resolved-`$0` in-shims check) + generated-shim marker.
- **Autostart**: block sets `Hidden=true` (with backup), `reconcile()` self-heals app-update clobbering on every invocation, unblock **merges** — only clears `Hidden`, never reverts a changed `Exec=`.
- **PATH-less apps** (Flatpak/tray/autostart-only) are blockable at the menu/autostart layer via `surface_found()`.
- **Honest labels**: `list` shows `enforced (launch blocked)` vs `hidden only — NOT launch-enforced`, re-verified at list-time (no caching); web-apps/PWAs show `hidden only (menu entry hidden; direct launch NOT intercepted)`.
- **Fuzzy name resolution**: `appblock block chatgpt` → `ChatGPT.desktop` (case-insensitive id / `Name=` / URL match); ambiguity is reported, never guessed; entries renamed aside stay resolvable so unblock works while blocked.

## Web-apps / PWAs — CLOSED (verified live, omarchy web-apps)
- `appblock block chatgpt` / `block x` → menu entry **renamed aside**; **GLib `GAppInfo` confirms it vanishes from menus**; `unblock` restores the file **byte-identical** (verified with `cmp` + sha256).
- **Keybind path closed**: omarchy's web-app keybinds (`SUPER SHIFT X` → `omarchy-launch-webapp https://x.com/`) never read a `.desktop` entry — Hyprland calls the launcher, which resolves the browser binary itself. Interception point: that launcher name on **PATH**. While any URL is blocked, appblock writes a URL-guard shim (`$SHIMS/omarchy-launch-webapp`) that refuses blocked URLs (URL itself **and everything under it**) and `exec`s the real launcher otherwise; it is deleted as soon as the last URL block is lifted, so there's never a permanent indirection. `omarchy-launch-or-focus-webapp` is covered too (its `eval exec setsid $CMDLINE` resolves through PATH).
- **URLs are first-class targets**: `appblock block https://youtube.com/` needs no desktop entry (covers keybind-only web-apps such as YouTube/Grok).
- Verified live: `SUPER SHIFT X` command → exit 1, browser never starts; compose sub-binding `https://x.com/compose/post` → exit 1; `omarchy-launch-or-focus-webapp` path → refused.
- `reconcile()` re-renames a reinstalled PWA entry and recreates a deleted guard shim (drift repair, both tested).
- **Remaining boundary (documented, not a bug):** typing the URL into the browser's address bar, or a keybind calling the browser binary directly (`chromium --app=<url>`), is not intercepted — block the browser for a hard guarantee.

## Desktop icons — CLOSED (verified live)
- A desktop view (GNOME DING, KDE Folder View, xfdesktop, Nemo, pcmanfm-qt) is a namespace of its own: it shows launcher *files* and launches `Exec=` **by path** — menu keys (`NoDisplay`/`Hidden`) are irrelevant there and an absolute Exec bypasses PATH. The PWA rename-aside trick is therefore applied to this namespace too.
- Desktop dir resolved per XDG: `xdg-user-dir DESKTOP` → `XDG_DESKTOP_DIR` from `user-dirs.dirs` → `~/Desktop`; absent dir → graceful no-op (the Hyprland shape).
- **omarchy caveat (the machine this was built on): `XDG_DESKTOP_DIR="$HOME/"`** — the desktop folder *is* the home directory. Matching is therefore surgical: only top-level `*.desktop` files whose `Exec` names the blocked binary (any whitespace-separated token, quotes stripped — `env "WINEPREFIX=…" wine "…lnk"` matches `wine`) or opens a blocked URL are renamed aside; nothing else in `$HOME` is ever touched.
- URL coupling: an icon whose Exec is `omarchy-launch-webapp https://x.com/` hides when `x` *or* the URL is blocked; subpath coverage follows the same rule as the guard (`url_covered`).
- Drift repair: `reconcile()` re-hides an icon recreated while blocked.
- Verified live on the omarchy machine: probe icon for a throwaway URL → hidden on block, guard refused exact + subpath URLs (exit 1, browser never started), the four real `$HOME/*.desktop` game launchers (Cuphead, CoD ×2, steam) checksum-identical throughout, restore byte-identical (`cmp`), no aside residue, guard shim removed when the last URL block lifted. Sandbox suite: 62/62 (was 44).

## Timed blocks — CLOSED (lazy expiry, no daemon)
- `appblock block rmpc --until 25m` (relative `45s`/`25m`/`2h`/`1h30m`, or an absolute `HH:MM` / `YYYY-MM-DD HH:MM`); `--until` applies to every id in the call, including `toggle`; `unblock` clears it.
- Deadlines are stored as `<id>|<epoch>` in `blocked-until.list`. Expiry is **lazy**: the generated shim compares the epoch at launch time and, if passed, lifts the block (rewrites `blocked.list` + `blocked-until.list`) and `exec`s the real binary — zero background processes, zero drift.
- `reconcile()` expires overdue blocks that were never launched, so menu/icon/autostart hiding is lifted too (not just the PATH shim).
- Unparseable durations are rejected with a non-zero exit instead of blocking forever. `list` appends `(24m left)` to active timed blocks.
- Sandbox suite covers: epoch arithmetic (`25m`), invalid duration rejection, shim self-unblock at expiry, a future deadline still refusing, `reconcile` expiry + menu restore, and the remaining-time label.
- Bug found and fixed while landing this: `grep -v ... && mv` inside the shim skipped the state rewrite exactly when the *last* line was filtered (grep exits 1 on empty selection), so an expired block never left `blocked.list`.

## Unblock friction (cooldown) — DONE
- Decision (asked, answered): applies to **all** unblocks, not just timed ones. A timed block already has a self-enforcing exit (its deadline); an untimed block has none, and is therefore the case that needs friction most.
- Mechanism: cooldown, not a typed challenge. `unblock`/`toggle` never lift a block — they only **schedule** the lift in `unblock-at.list` (`<id>|<epoch>`). It is applied lazily on both existing paths: the generated shim checks it at **launch** (same branch as a `--until` deadline), and `reconcile()` applies it on the next appblock run. No daemon; works non-interactively; no TTY needed.
- Default 10m (`UNBLOCK_WAIT_DEFAULT`); `--after <dur>` raises it, `--after` under `UNBLOCK_WAIT_MIN` (60s) is rejected so a short wait can't serve as a back door, and `--after`/`--cancel` are refused with `block` (which stays immediate).
- All five user-facing lift paths were covered: `unblock`/`toggle` for apps and for URLs, plus the no-launch-surface branch. `toggle` on a blocked app schedules rather than lifts, so it is not a one-keystroke bypass.
- Exempt by design: a `--until` deadline passing (both the shim's lazy expiry and `reconcile`) lifts with no cooldown, and it clears any now-moot pending lift. A timed deadline beating a pending lift must never leave a stale schedule behind.
- `list` surfaces the pending lift: `🚫 rmpc — enforced (unblocks in 9m)`.
- Explored and rejected: typed confirmation phrase (beaten by muscle memory), PIN/passphrase (plaintext POSIX-sh tool — a plaintext PIN implies protection it can't provide).
- Scope note carried in the docs: state is plaintext, so hand-editing `blocked.list` bypasses everything — friction against impulse, not a security boundary.
- Bonus: two `set -eu` landmines the tests caught — a bare `n=$(grep -c …)` whose substitution exits 1 was fatal, and `_bk=$(shim_binary_for_key …)` likewise (it legitimately returns 1 for shim-less apps). Also found and fixed a **destructive** `unhide_desktop` bug: an unconditional `rm` of the user-dir `.desktop`, so a second unblock (or one after a timed expiry had already restored it) **deleted the user's own web-app/PWA entry**; it now only removes an override carrying our `# appblock override` marker.
- Sandbox suite: **113/113**, including that `unblock`/`toggle` cannot lift early, the 60s floor, `--cancel`, the URL path, the elapsed-cooldown lift at every layer, and that a timed deadline still lifts with no cooldown.

## Reverse-DNS desktop ids (shim key != launch name) — CLOSED
- Bug: the shim was generated from the **raw typed name** while `blocked.list` stored the **resolved desktop id**. For any app whose id differs from its launch binary (Flatpak-style `org.mozilla.firefox`, Discord, Spotify), the shim checked `firefox` against a list holding `org.mozilla.firefox` — never matching, so the app launched normally 100% of the time while the menu/icon layer was the only real defence. Invisible to the 75-check suite because every existing fixture had matching names.
- Fix: `install_shim <launch-name> <block-key>` resolves the canonical id first (`block|unblock|toggle` now resolves *before* installing), and the key is embedded as the `# appblock-block-key:` marker plus used for the `blocked.list`/`blocked-until.list` checks. Callers that hold only the id (`list`, `reconcile`) recover the launch name via `shim_for_key`/`shim_binary_for_key`.
- Same family, also fixed: `reconcile` expiry called `rm`/`restore_autostart` with the id (stale shim survived, autostart stayed `Hidden=true` forever after a timed block expired); autostart drift repair and `icon_matches` compared `Exec` basenames against the id (icons/drift skipped); `enforcement_label` looked for `$SHIMS/<id>`.
- `reconcile()` self-heals any shim whose key no longer matches its resolved id, so a pre-fix install fixes itself on the next invocation (and `appblock shims` does it explicitly).
- Sabotage-check: recreated the pre-fix on-disk state (id in `blocked.list`, name-keyed shim) → launch allowed; after `appblock list`, key rewritten and launch refused.
- Bonus destructive bug found while testing: `unhide_desktop` did an unconditional `rm` of the user-dir `.desktop`, so a second `unblock` (or an `unblock` after a timed expiry had already restored it) **deleted the user's own web-app/PWA entry**. Now it only removes an override carrying our `# appblock override` marker.
- Sandbox suite: **89/89** (was 75), including a `revdnsapp` fixture whose id (`org.example.revdnsapp`) differs from its binary, plus the empty-blocklist `grep -c . || echo 0` arithmetic error.

## Known gap
- GUI apps launched by the desktop session use the **session PATH**, not the shell's — so the launcher-hidden layer works, but direct binary launch isn't shimmed for GUI apps yet.

## Roadmap
1. **`status`/`list --json`** output so bar widgets/plugins can consume state
2. Flatpak runtime blocking (`flatpak run <id>` interception) — documented gap; most GUI apps are Flatpaks
3. **Self-abuse guardrails** (stretch): optional friction when unblocking (e.g. require typing a phrase), since the block is otherwise trivially defeated by `appblock unblock`
4. Packaging: AUR package, eventually omarchy plugin (thin QML wrapper around `appblock toggle`)

## Design constraints
- POSIX sh only, no dependencies, no daemon required
- Never modify real binaries or system files (`/usr/*`) — state is all under `~/.local/share/appblock/`
- Distro-agnostic (Arch/Fedora/Debian) and DE-agnostic
- Honest limitation to document: absolute-path invocation (`/usr/bin/rmpc`) bypasses the shim by design — this is a friction tool, not a security tool
