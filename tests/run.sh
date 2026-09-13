#!/bin/sh
# appblock smoke test suite.
# Runs entirely inside a sandboxed $HOME — real config, state, and systemd
# are NEVER touched. Requires only POSIX sh + coreutils.
#
# Usage: sh tests/run.sh   (from the repo root)

set -u
fail=0
pass=0
AB="$(cd "$(dirname "$0")/.." && pwd)/bin/appblock"
AB="$(readlink -f "$AB" 2>/dev/null || echo "$AB")"

section() { printf '\n== %s ==\n' "$1"; }
ok()   { pass=$((pass+1)); printf '   ok:   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '   FAIL: %s\n' "$1"; }
check() { # check <msg> <cmd...> — runs cmd, drops msg from the arg list
  msg=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$msg"; else bad "$msg"; fi
}
check_not() { # check_not <msg> <cmd...> — negated check
  msg=$1; shift
  if "$@" >/dev/null 2>&1; then bad "$msg"; else ok "$msg"; fi
}

sh -n "$AB" && ok "syntax check" || bad "syntax check"

# ---------- sandbox ----------
export HOME="$(mktemp -d /tmp/appblock-test.XXXXXX)"
# xdg-user-dir reads $XDG_CONFIG_HOME (set on Omarchy) — sandbox it too, else
# the desktop-dir lookup escapes the fake HOME.
export XDG_CONFIG_HOME="$HOME/.config"
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/bin" "$HOME/bin2" \
         "$HOME/.local/share/applications" \
         "$HOME/.local/share/flatpak/exports/share/applications" \
         "$HOME/.config/autostart"
touch "$HOME/.bashrc" "$HOME/.zshrc"
printf '#!/bin/sh\necho hi-from-demoapp\n' >"$HOME/bin/demoapp"
chmod +x "$HOME/bin/demoapp"
cp "$HOME/bin/demoapp" "$HOME/bin2/demoapp"   # same-basename updated binary (app update)
# omarchy's web-app keybind launcher (the path SUPER SHIFT X et al. use)
printf '#!/bin/sh\necho "launched:$1"\n' >"$HOME/bin/omarchy-launch-webapp"
chmod +x "$HOME/bin/omarchy-launch-webapp"
# The app's REAL desktop entry: absolute Exec, in a GLib-searched dir (packaged-app shape)
printf '[Desktop Entry]\nType=Application\nName=demoapp\nExec=%s/bin/demoapp\n' "$HOME" \
  >"$HOME/.local/share/flatpak/exports/share/applications/demoapp.desktop"
# The app's autostart entry: absolute Exec, like a tray app
printf '[Desktop Entry]\nType=Application\nName=demoapp\nExec=%s/bin/demoapp\n' "$HOME" \
  >"$HOME/.config/autostart/demoapp.desktop"

export PATH="$HOME/.local/share/appblock/shims:$HOME/bin:$PATH"

section "block / run-guard / unblock"
"$AB" block demoapp >/dev/null 2>&1 && ok "block demoapp" || bad "block demoapp"
check "shim file created" test -x "$HOME/.local/share/appblock/shims/demoapp"
if demoapp 2>/dev/null; then bad "blocked app was allowed to run"; else ok "blocked app refused to run"; fi
"$AB" unblock demoapp >/dev/null 2>&1 && ok "unblock demoapp" || bad "unblock demoapp"
[ "$(demoapp)" = "hi-from-demoapp" ] && ok "app runs after unblock" || bad "app does not run after unblock"

section "toggle"
"$AB" toggle demoapp >/dev/null 2>&1
grep -qxF demoapp "$HOME/.local/share/appblock/blocked.list" && ok "toggle blocks" || bad "toggle blocks"
"$AB" toggle demoapp >/dev/null 2>&1
! grep -qxF demoapp "$HOME/.local/share/appblock/blocked.list" && ok "toggle unblocks" || bad "toggle unblocks"

section "enforcement label"
"$AB" block demoapp >/dev/null 2>&1
"$AB" list | grep -q 'demoapp — enforced' && ok "list shows 'enforced'" || bad "list lacks 'enforced' label"

section "desktop override (masks absolute Exec)"
check "menu override written (NoDisplay=true)" \
  grep -q '^NoDisplay=true' "$HOME/.local/share/applications/demoapp.desktop"
check "override uses bare Exec (masks the absolute original)" \
  grep -q '^Exec=demoapp$' "$HOME/.local/share/applications/demoapp.desktop"
check "original absolute-Exec entry untouched" \
  grep -q '^Exec=.*bin/demoapp$' "$HOME/.local/share/flatpak/exports/share/applications/demoapp.desktop"

section "autostart disable + drift repair + merge-unblock"
check "autostart entry disabled (Hidden=true)" \
  grep -q '^Hidden=true' "$HOME/.config/autostart/demoapp.desktop"
# app update rewrites the autostart file: changes Exec to a new path, drops Hidden
printf '[Desktop Entry]\nType=Application\nName=demoapp\nExec=%s/bin2/demoapp --new-flag\n' "$HOME" \
  >"$HOME/.config/autostart/demoapp.desktop"
"$AB" list >/dev/null 2>&1
check "reconcile re-disabled autostart after clobber" \
  grep -q '^Hidden=true' "$HOME/.config/autostart/demoapp.desktop"
"$AB" unblock demoapp >/dev/null 2>&1
! grep -q '^Hidden=' "$HOME/.config/autostart/demoapp.desktop" && ok "unblock cleared Hidden flag" \
  || bad "unblock left Hidden flag behind"
grep -q 'bin2/demoapp --new-flag' "$HOME/.config/autostart/demoapp.desktop" \
  && ok "unblock MERGED (kept app-updated Exec)" || bad "unblock reverted app-updated Exec"

section "web-app / PWA (user-dir entries, rename flow)"
# Chromium-style PWA: real entry lives in ~/.local/share/applications
printf '[Desktop Entry]\nType=Application\nName=ChatGPT\nExec=/usr/bin/chromium --profile-directory=Default --app=https://chatgpt.com/\n' \
  >"$HOME/.local/share/applications/chrome-chatgpt-abc123.desktop"
# omarchy-style web-app
printf '[Desktop Entry]\nType=Application\nName=Figma\nExec=omarchy-launch-webapp https://figma.com/\n' \
  >"$HOME/.local/share/applications/Figma.desktop"

"$AB" block chatgpt >/dev/null 2>&1 && ok "block web-app by lowercase name (fuzzy → chrome-chatgpt-abc123)" \
  || bad "fuzzy name resolution failed"
check "canonical id in blocklist" \
  grep -qxF chrome-chatgpt-abc123 "$HOME/.local/share/appblock/blocked.list"
check "original PWA entry renamed aside (not clobbered)" \
  test ! -e "$HOME/.local/share/applications/chrome-chatgpt-abc123.desktop"
check "renamed original preserved on disk" \
  test -f "$HOME/.local/share/applications/.appblock-disabled.chrome-chatgpt-abc123.desktop.off"
if "$AB" list | grep -q 'chrome-chatgpt-abc123 — menu hidden + omarchy-launch-webapp guard'; then
  ok "list shows menu-hide + keybind-guard coverage for a PWA URL"
else
  bad "PWA label wrong"
fi
"$AB" unblock chatgpt >/dev/null 2>&1
check "restore is byte-exact (original Exec back)" \
  grep -q -- '--app=https://chatgpt.com/' "$HOME/.local/share/applications/chrome-chatgpt-abc123.desktop"
check "no disabled file left after restore" \
  test ! -e "$HOME/.local/share/applications/.appblock-disabled.chrome-chatgpt-abc123.desktop.off"

section "PWA reinstall drift repair"
"$AB" block figma >/dev/null 2>&1
check "omarchy web-app Figma blocked via name→id (Figma)" \
  grep -qxF Figma "$HOME/.local/share/appblock/blocked.list"
# simulate Chrome/omarchy re-adding the entry after a reinstall
printf '[Desktop Entry]\nType=Application\nName=Figma\nExec=omarchy-launch-webapp https://figma.com/\n' \
  >"$HOME/.local/share/applications/Figma.desktop"
"$AB" list >/dev/null 2>&1
check "reinstall drift: reconcile re-renames the fresh entry" \
  test ! -e "$HOME/.local/share/applications/Figma.desktop"
"$AB" unblock figma >/dev/null 2>&1

section "ambiguous fuzzy name is rejected, not guessed"
# second entry whose Name= collides with ChatGPT's
printf '[Desktop Entry]\nType=Application\nName=ChatGPT\nExec=/usr/bin/other-chromium --app=https://chatgpt.dev/\n' \
  >"$HOME/.local/share/applications/another-chatgpt.desktop"
if "$AB" block chatgpt 2>&1 | grep -q "ambiguous"; then
  ok "ambiguity reported loudly"
else
  bad "ambiguous name did not produce an error"
fi
check_not "nothing blocked on ambiguity" \
  grep -q chatgpt "$HOME/.local/share/appblock/blocked.list"
rm -f "$HOME/.local/share/applications/another-chatgpt.desktop"

section "web-app URL guard (the keybind path: omarchy-launch-webapp)"
# omarchy keybinds (e.g. SUPER SHIFT X) run `omarchy-launch-webapp <url>`,
# which picks the browser itself and never reads a .desktop entry — so the
# guard has to own the launcher name on PATH.
printf '[Desktop Entry]\nType=Application\nName=X\nExec=omarchy-launch-webapp https://x.com/\n' \
  >"$HOME/.local/share/applications/X.desktop"
"$AB" block x >/dev/null 2>&1
check "guard shim installed while a web-app is blocked" \
  test -x "$HOME/.local/share/appblock/shims/omarchy-launch-webapp"
if omarchy-launch-webapp "https://x.com/" 2>&1 | grep -q blocked; then
  ok "blocked web-app URL is refused on the keybind path"
else
  bad "keybind URL still launches while blocked"
fi
if omarchy-launch-webapp "https://x.com/compose/post" 2>&1 | grep -q blocked; then
  ok "paths under the blocked URL are refused too (compose binding)"
else
  bad "subpath URL bypasses the guard"
fi
[ "$(omarchy-launch-webapp "https://example.com/" 2>/dev/null)" = "launched:https://example.com/" ] \
  && ok "unrelated URL still launches (guard is transparent)" || bad "guard broke unrelated launches"
"$AB" list | grep -q 'X — menu hidden + omarchy-launch-webapp guard' \
  && ok "list reports honest keybind coverage" || bad "coverage label missing"

# A URL is blockable with no desktop entry at all (keybind-only web-apps).
"$AB" block "https://youtube.com/" >/dev/null 2>&1
if omarchy-launch-webapp "https://youtube.com/watch?v=1" 2>&1 | grep -q blocked; then
  ok "direct URL block covers keybind-only web-apps (no .desktop entry)"
else
  bad "direct URL block did not intercept"
fi
"$AB" list | grep -q 'https://youtube.com/ — web-app URL guard' \
  && ok "URL block listed with its own label" || bad "URL block not listed"
check_not "guard is NOT registered as a name-blocking managed shim" \
  grep -q '^omarchy-launch-webapp$' "$HOME/.local/share/appblock/managed.list"
# drift: guard deleted -> self-heals on the next invocation
rm -f "$HOME/.local/share/appblock/shims/omarchy-launch-webapp"
"$AB" list >/dev/null 2>&1
check "guard self-heals after deletion (reconcile)" \
  test -x "$HOME/.local/share/appblock/shims/omarchy-launch-webapp"
"$AB" unblock "https://youtube.com/" x >/dev/null 2>&1
check "guard removed once the last URL block is lifted" \
  test ! -e "$HOME/.local/share/appblock/shims/omarchy-launch-webapp"
[ "$(omarchy-launch-webapp "https://x.com/" 2>/dev/null)" = "launched:https://x.com/" ] \
  && ok "launcher runs untouched again (no permanent indirection)" || bad "stale guard left behind"

section "desktop icon hiding (DING / Folder View / xfdesktop / Nemo / pcmanfm-qt)"
mkdir -p "$HOME/Desktop"
# what a desktop view really shows: launcher *files*, launched by path
printf '[Desktop Entry]\nType=Application\nName=demoapp\nExec=%s/bin/demoapp\n' "$HOME" \
  >"$HOME/Desktop/demoapp-abs.desktop"
printf '[Desktop Entry]\nType=Application\nName=demoapp\nExec=demoapp\n' \
  >"$HOME/Desktop/demoapp-bare.desktop"
printf '[Desktop Entry]\nType=Application\nName=X\nExec=omarchy-launch-webapp https://x.com/\n' \
  >"$HOME/Desktop/X.desktop"
printf '[Desktop Entry]\nType=Application\nName=unrelated\nExec=false\n' \
  >"$HOME/Desktop/unrelated.desktop"
"$AB" block demoapp >/dev/null 2>&1
check "absolute-Exec desktop icon hidden (path-launch bypass closed)" \
  test ! -e "$HOME/Desktop/demoapp-abs.desktop"
check "  ...renamed aside, byte-preserved for restore" \
  test -f "$HOME/Desktop/.appblock-disabled.demoapp-abs.desktop.off"
check "bare-Exec desktop icon hidden too" test ! -e "$HOME/Desktop/demoapp-bare.desktop"
check "unrelated desktop icon untouched" test -f "$HOME/Desktop/unrelated.desktop"
"$AB" unblock demoapp >/dev/null 2>&1
check "unblock restores the absolute-Exec icon" test -f "$HOME/Desktop/demoapp-abs.desktop"
check "unblock restores the bare-Exec icon" test -f "$HOME/Desktop/demoapp-bare.desktop"
check_not "no disabled icons left behind" \
  ls "$HOME/Desktop"/.appblock-disabled.demoapp-abs.desktop.off

# Wine/game launcher shape (as found in a real omarchy $HOME):
#   Exec=env "WINEPREFIX=…" wine "C:\…\Game.lnk"   → first token is `env`
printf '#!/bin/sh\necho wine\n' >"$HOME/bin/wine"
chmod +x "$HOME/bin/wine"
printf '[Desktop Entry]\nType=Application\nName=Cuphead\nExec=env "WINEPREFIX=%s/.wine" wine "C:\\\\games\\\\Cuphead.lnk"\n' "$HOME" \
  >"$HOME/Desktop/game.desktop"
"$AB" block wine >/dev/null 2>&1
check "env-prefixed (Wine) icon hidden — any Exec token matches" \
  test ! -e "$HOME/Desktop/game.desktop"
"$AB" unblock wine >/dev/null 2>&1
check "env-prefixed icon restored" test -f "$HOME/Desktop/game.desktop"
rm -f "$HOME/Desktop/game.desktop"

"$AB" block x >/dev/null 2>&1
check "web-app desktop icon hidden (matched by URL)" test ! -e "$HOME/Desktop/X.desktop"
"$AB" unblock x >/dev/null 2>&1
check "web-app desktop icon restored" test -f "$HOME/Desktop/X.desktop"
"$AB" block "https://x.com/" >/dev/null 2>&1
check "blocking a bare URL hides an icon for that URL" test ! -e "$HOME/Desktop/X.desktop"
"$AB" unblock "https://x.com/" >/dev/null 2>&1
check "URL unblock restores it" test -f "$HOME/Desktop/X.desktop"

# drift: an icon recreated while blocked is re-hidden on the next invocation
"$AB" block x >/dev/null 2>&1
cp "$HOME/Desktop/.appblock-disabled.X.desktop.off" "$HOME/Desktop/X.desktop"
"$AB" list >/dev/null 2>&1
check "icon recreated while blocked is re-hidden (drift repaired)" \
  test ! -e "$HOME/Desktop/X.desktop"
"$AB" unblock x >/dev/null 2>&1
check "no duplicate icons after drift repair + unblock" \
  test -f "$HOME/Desktop/X.desktop" -a ! -e "$HOME/Desktop/.appblock-disabled.X.desktop.off"

section "desktop dir resolution (XDG user-dirs, not hardcoded ~/Desktop)"
mkdir -p "$HOME/MyDesk" "$HOME/.config"
printf 'XDG_DESKTOP_DIR="$HOME/MyDesk"\n' >"$HOME/.config/user-dirs.dirs"
printf '[Desktop Entry]\nType=Application\nName=demoapp\nExec=demoapp\n' \
  >"$HOME/MyDesk/demoapp.desktop"
"$AB" block demoapp >/dev/null 2>&1
check "custom XDG_DESKTOP_DIR honored" test ! -e "$HOME/MyDesk/demoapp.desktop"
"$AB" unblock demoapp >/dev/null 2>&1
check "custom-dir icon restored" test -f "$HOME/MyDesk/demoapp.desktop"
rm -f "$HOME/.config/user-dirs.dirs"
rm -rf "$HOME/MyDesk"
rm -rf "$HOME/Desktop"
"$AB" block demoapp >/dev/null 2>&1 && "$AB" unblock demoapp >/dev/null 2>&1 \
  && ok "no desktop dir present → graceful no-op (Hyprland shape)" \
  || bad "errored when no desktop dir exists"

section "moved binary -> shim dropped, menu-level block survives"
"$AB" block demoapp >/dev/null 2>&1   # re-block against $HOME/bin/demoapp (still present)
mv "$HOME/bin/demoapp" "$HOME/bin2/demoapp"
"$AB" block demoapp 2>&1 | grep -q 'menu/autostart-level only' \
  && ok "honest note: menu-level only (binary moved, desktop entry remains)" \
  || bad "no honest menu-level note"
check "stale shim removed" test ! -f "$HOME/.local/share/appblock/shims/demoapp"

section "structural guard (no management from within a shim)"
# The guard's job: if appblock ITSELF ever ends up (copied) inside the shims
# dir — the historical stale-copy bug — it must refuse install_shim, so a
# transient PATH lookup can never run management/cleanup from launch context.
cp "$AB" "$HOME/.local/share/appblock/shims/appblock-stale"
if sh "$HOME/.local/share/appblock/shims/appblock-stale" shims 2>&1 \
     | grep -q 'may not run from within a shim'; then
  ok "guard refuses management from within shims dir (copy intrusion)"
else
  bad "guard did not fire"
fi
rm -f "$HOME/.local/share/appblock/shims/appblock-stale"
# A SYMLINK into the shims dir is NOT an intrusion — it is the designed entry
# point (shims/appblock -> real script). The guard resolves symlinks
# (readlink -f) so it must stay silent here: one body of code, no divergence.
# 'shims' exercises install_shim for every managed app — the guard's real path.
ln -s "$AB" "$HOME/.local/share/appblock/shims/appblock-alias"
if PATH="$HOME/.local/share/appblock/shims:$HOME/bin2:$PATH" \
     "$HOME/.local/share/appblock/shims/appblock-alias" shims 2>&1 \
     | grep -q 'may not run from within a shim'; then
  bad "symlink entry point false-positived the guard"
else
  ok "symlink entry point works, guard silent (no false positive)"
fi
rm -f "$HOME/.local/share/appblock/shims/appblock-alias"
# ...but the normal PATH entry point through the shims symlink still works
"$AB" block demoapp >/dev/null 2>&1 || true
PATH="$HOME/.local/share/appblock/shims:$HOME/bin2:$PATH"
appblock list >/dev/null 2>&1 && ok "normal entry point works from shims symlink" || bad "normal entry point broken"

section "uninstall-cleanliness"
"$AB" unblock demoapp >/dev/null 2>&1
remaining=$(wc -l <"$HOME/.local/share/appblock/blocked.list")
[ "$remaining" -eq 0 ] && ok "blocked.list empty after unblocks" || bad "blocked.list not empty ($remaining)"

printf '\n================\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]