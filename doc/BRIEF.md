# appblock — project brief

## What it is
`appblock` is a tiny, dependency-free CLI tool for Linux that lets you **block any installed app — GUI, CLI, or web-app/PWA — from launching, with an instant toggle to unblock it**. It exists to fight distraction (music players, games, social apps) without uninstalling or breaking anything.

## Why it exists
Every existing solution covers only websites (browser blockers), or is heavyweight/untoggleable (AppArmor/Firejail profiles, GNOME-only session blockers). macOS has proper app blockers; **Linux desktop has a gap**. GitHub searches for Linux desktop app blockers return essentially nothing. appblock fills that gap.

## How it works (the mechanism)
1. **PATH shims**: `~/.local/share/appblock/shims/` is prepended to `PATH`. Each managed app gets a ~6-line POSIX shell script there that (a) checks a plaintext blocklist, (b) if blocked → prints a message and exits, (c) if not → `exec`s the real binary with all args, so it's 100% transparent (signals, TTY, stdin all pass through).
2. **Launcher hiding**: blocked apps also get a `NoDisplay=true` desktop-entry override in `~/.local/share/applications/`, so they vanish from app menus/launchers. Removed on unblock. **Web-apps/PWAs** (entries whose *original* lives in the user dir — Chromium PWAs, omarchy `omarchy-launch-webapp` apps) are instead **renamed aside** to `.appblock-disabled.<id>.desktop.off`: byte-exact, reversible, invisible to GLib (which only scans `*.desktop`). An override would clobber the original there, so rename is the only safe mechanism.
3. **State**: two plaintext files — `blocked.list` and `managed.list` — read fresh on every invocation, so toggling is instant and there's nothing to install/uninstall. The real binaries, packages, and configs are never touched (survives system updates).

## Current state (works, on one Arch/Omarchy machine)
- Commands: `appblock block|unblock|toggle <app...>`, `list`, `install`, `shims`
- Blocking verified end-to-end for CLI apps (`rmpc`) and launcher visibility
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

## Known gap
- GUI apps launched by the desktop session use the **session PATH**, not the shell's — so the launcher-hidden layer works, but direct binary launch isn't shimmed for GUI apps yet.

## Roadmap
1. **Timed blocks**: `appblock block rmpc --until 25m` — lazy expiry: shim checks a `blocked-until` timestamp at invocation time; zero daemon, zero drift (reviewer-endorsed as the clean design)
2. **`status`/`list --json`** output so bar widgets/plugins can consume state
3. Flatpak runtime blocking (`flatpak run <id>` interception) — documented gap; most GUI apps are Flatpaks
4. **Self-abuse guardrails** (stretch): optional friction when unblocking (e.g. require typing a phrase), since the block is otherwise trivially defeated by `appblock unblock`
5. Packaging: AUR package, eventually omarchy plugin (thin QML wrapper around `appblock toggle`)

## Design constraints
- POSIX sh only, no dependencies, no daemon required
- Never modify real binaries or system files (`/usr/*`) — state is all under `~/.local/share/appblock/`
- Distro-agnostic (Arch/Fedora/Debian) and DE-agnostic
- Honest limitation to document: absolute-path invocation (`/usr/bin/rmpc`) bypasses the shim by design — this is a friction tool, not a security tool
