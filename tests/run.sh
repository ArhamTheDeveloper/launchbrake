#!/bin/sh
# appblock smoke test suite.
# Runs entirely inside a sandboxed $HOME — real config, state, and systemd
# are NEVER touched. Requires only POSIX sh + coreutils; the by-id click-through
# section additionally exercises the real `gtk-launch` (gtk3 ships on Omarchy)
# against the sandboxed XDG tree and is skipped loudly if it is absent.
#
# Usage: sh tests/run.sh   (from the repo root)

set -u
fail=0
pass=0
skipped=0
AB="$(cd "$(dirname "$0")/.." && pwd)/bin/appblock"
AB="$(readlink -f "$AB" 2>/dev/null || echo "$AB")"

section() { printf '\n== %s ==\n' "$1"; }
ok()   { pass=$((pass+1)); printf '   ok:   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '   FAIL: %s\n' "$1"; }
skip() { skipped=$((skipped+1)); printf '   SKIP: %s\n' "$1"; }
check() { # check <msg> <cmd...> — runs cmd, drops msg from the arg list
  msg=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$msg"; else bad "$msg"; fi
}
check_not() { # check_not <msg> <cmd...> — negated check
  msg=$1; shift
  if "$@" >/dev/null 2>&1; then bad "$msg"; else ok "$msg"; fi
}

# Friction cooldown helpers. `unblock`/`toggle` only SCHEDULE a lift (by design);
# reconcile() performs it once the epoch passes. Rewrite every pending epoch to
# the distant past, then run a command so reconcile fires — no sleeping.
ab_finish_cooldown() {
  [ -f "$HOME/.local/share/appblock/unblock-at.list" ] \
    && sed -i 's/|[0-9]*$/|1/' "$HOME/.local/share/appblock/unblock-at.list"
  "$AB" list >/dev/null 2>&1
}
ab_unblock_now() { # <app|url...> — request, then drive the cooldown to completion
  "$AB" unblock "$@" >/dev/null 2>&1
  ab_finish_cooldown
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

# The suite's contract is that real config, state, and systemd are NEVER
# touched. appblock stops a running applet through the systemd unit generated
# from the autostart entry it just disabled, so a test run would otherwise poke
# the LIVE user manager — and a real systemctl that happens to be waiting on a
# busy manager turns a fast suite into a stalling one. Stub it out; the applet
# section below overrides this with its own fake to assert the "active" path.
mkdir -p "$HOME/stub"
cat >"$HOME/stub/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$HOME/stub/systemctl.calls"
case "$1 $2" in
  "--user is-active") echo inactive; exit 3 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$HOME/stub/systemctl"

export PATH="$HOME/.local/share/appblock/shims:$HOME/stub:$HOME/bin:$PATH"

section "block / run-guard / unblock"
"$AB" block demoapp >/dev/null 2>&1 && ok "block demoapp" || bad "block demoapp"
check "shim file created" test -x "$HOME/.local/share/appblock/shims/demoapp"
if demoapp 2>/dev/null; then bad "blocked app was allowed to run"; else ok "blocked app refused to run"; fi
ab_unblock_now demoapp >/dev/null 2>&1 && ok "unblock demoapp" || bad "unblock demoapp"
[ "$(demoapp)" = "hi-from-demoapp" ] && ok "app runs after unblock" || bad "app does not run after unblock"

section "toggle"
"$AB" toggle demoapp >/dev/null 2>&1
grep -qxF demoapp "$HOME/.local/share/appblock/blocked.list" && ok "toggle blocks" || bad "toggle blocks"
# Friction: toggling a BLOCKED app must not lift it — it only schedules the lift.
"$AB" toggle demoapp >/dev/null 2>&1
grep -qxF demoapp "$HOME/.local/share/appblock/blocked.list" \
  && ok "toggle on a blocked app stays blocked (friction)" || bad "toggle lifted the block immediately"
ab_finish_cooldown
! grep -qxF demoapp "$HOME/.local/share/appblock/blocked.list" && ok "cooldown elapsed -> unblocked" \
  || bad "cooldown did not lift the block"

section "enforcement label"
"$AB" block demoapp >/dev/null 2>&1
"$AB" list | grep -q 'demoapp — enforced' && ok "list shows 'enforced'" || bad "list lacks 'enforced' label"

section "desktop override (masks absolute Exec)"
check "menu override written (NoDisplay=true)" \
  grep -q '^NoDisplay=true' "$HOME/.local/share/applications/demoapp.desktop"
check "override Exec is the absolute deny path — never the raw id" \
  grep -qF "Exec=$HOME/.local/share/appblock/shims/.appblock-deny.demoapp" \
    "$HOME/.local/share/applications/demoapp.desktop"
check "NoDisplay=true alone is never asserted as the gate (Exec is checked too)" \
  grep -q '^# appblock override' "$HOME/.local/share/applications/demoapp.desktop"
check "deny script generated for the blocked app" \
  test -x "$HOME/.local/share/appblock/shims/.appblock-deny.demoapp"
check "original absolute-Exec entry untouched" \
  grep -q '^Exec=.*bin/demoapp$' "$HOME/.local/share/flatpak/exports/share/applications/demoapp.desktop"
check "anti-gotcha: fixture id has no real-system twin (resolve stays in the sandbox)" \
  sh -c '! test -f /usr/share/applications/demoapp.desktop -o -f /usr/local/share/applications/demoapp.desktop'

section "by-id .desktop click-through (gtk-launch; NoDisplay=true is NOT enforcement)"
# Omarchy's launcher/dock/taskbar launches apps the way gtk-launch does:
# resolve the desktop id against the data dirs and run whatever Exec the
# overriding user-dir entry carries. Two hard facts verified live:
#   (1) NoDisplay=true does NOT stop a by-id launch — GLib still runs the Exec;
#   (2) if that Exec cannot SPAWN (the old Exec=<id> shape for reverse-DNS
#       ids), gtk-launch silently falls through to the real system entry and
#       the blocked app launches.
# So the override Exec must be an absolute deny-script path for EVERY app, and
# this section executes the REAL gtk-launch with HOME/XDG sandboxed so no real
# system state is consulted.
if command -v gtk-launch >/dev/null 2>&1; then
  GLAUNCH() {
    XDG_DATA_HOME="$HOME/.local/share" \
    XDG_DATA_DIRS="$HOME/.local/share/flatpak/exports/share:/usr/local/share:/usr/share" \
    XDG_CONFIG_HOME="$HOME/.config" \
      gtk-launch "$@"
  }

  # same-name fixture (id == binary): the shape that used to work only by luck
  check "same-name override Exec is the absolute deny path (never the raw id)" \
    grep -qF "Exec=$HOME/.local/share/appblock/shims/.appblock-deny.demoapp" \
      "$HOME/.local/share/applications/demoapp.desktop"
  if GLAUNCH demoapp.desktop 2>/dev/null | grep -q hi-from-demoapp; then
    bad "same-name by-id click launched the blocked app"
  else
    ok "same-name by-id click refused (deterministic deny path, not the raw-id accident)"
  fi

  # reverse-DNS fixture: id != binary name — the shape that silently fell
  # through. The fixture name is unique so resolve_desktop_id cannot match a
  # real /usr/share entry from inside the sandbox (known suite gotcha).
  printf '#!/bin/sh\necho REVDNS-CLICKED\n' >"$HOME/bin/revguardapp"
  chmod +x "$HOME/bin/revguardapp"
  printf '[Desktop Entry]\nType=Application\nName=RevGuardApp\nExec=%s/bin/revguardapp\n' "$HOME" \
    >"$HOME/.local/share/flatpak/exports/share/applications/org.example.revguard.desktop"
  "$AB" block revguardapp >/dev/null 2>&1
  check "revdns fixture blocked under its canonical id (not the typed name)" \
    grep -qxF org.example.revguard "$HOME/.local/share/appblock/blocked.list"
  check "revdns override Exec is the absolute deny path — never the raw id" \
    grep -qF "Exec=$HOME/.local/share/appblock/shims/.appblock-deny.org.example.revguard" \
      "$HOME/.local/share/applications/org.example.revguard.desktop"
  check_not "revdns override does NOT carry the raw id as Exec (the old shape)" \
    grep -q '^Exec=org.example.revguard$' \
      "$HOME/.local/share/applications/org.example.revguard.desktop"
  if GLAUNCH org.example.revguard.desktop 2>/dev/null | grep -q REVDNS-CLICKED; then
    bad "reverse-DNS by-id click launched the blocked app (fall-through)"
  else
    ok "reverse-DNS by-id click refused (fall-through closed)"
  fi
  "$AB" list 2>&1 | grep -q 'org.example.revguard — enforced, launcher masked (by-id launch intercepted)' \
    && ok "list reports the verified by-id interception label" \
    || bad "list did not report by-id interception for the revdns app"

  # Specific regression: NoDisplay=true alone must NEVER be treated as
  # sufficient. Rewrite the override with the raw id as Exec (NoDisplay still
  # true, marker still present): the click must fall through and run the app.
  # Only reconcile's Exec re-assertion restores interception.
  printf '[Desktop Entry]\n# appblock override — do not edit\nType=Application\nName=org.example.revguard\nNoDisplay=true\nExec=org.example.revguard\n' \
    >"$HOME/.local/share/applications/org.example.revguard.desktop"
  if GLAUNCH org.example.revguard.desktop 2>/dev/null | grep -q REVDNS-CLICKED; then
    ok "bug shape reproduced: NoDisplay=true + raw-id Exec does NOT stop a by-id click"
  else
    bad "raw-id Exec did not fall through — the click-through harness is not real?"
  fi
  "$AB" list >/dev/null 2>&1   # reconcile re-asserts the deny Exec
  check "reconcile re-pointed the clobbered override Exec at the deny path" \
    grep -qF "Exec=$HOME/.local/share/appblock/shims/.appblock-deny.org.example.revguard" \
      "$HOME/.local/share/applications/org.example.revguard.desktop"
  if GLAUNCH org.example.revguard.desktop 2>/dev/null | grep -q REVDNS-CLICKED; then
    bad "blocked app launched again after reconcile repair"
  else
    ok "by-id click refused again after reconcile repair (drift self-healed)"
  fi

  # Lazy-expiry parity: a passed --until deadline lifts AT LAUNCH through the
  # deny script (same emitted block as the shim) and opens the app — a by-id
  # click is never lost on the timed path either.
  PASTGT=$(( $(date +%s) - 10 ))
  echo "org.example.revguard|$PASTGT" >>"$HOME/.local/share/appblock/blocked-until.list"
  [ "$(GLAUNCH org.example.revguard.desktop 2>/dev/null)" = "REVDNS-CLICKED" ] \
    && ok "by-id click lifts an expired timed block and runs the app (lazy parity)" \
    || bad "by-id click did not lift the expired timed block"
  check_not "lazy by-id lift cleared blocked.list for the revdns app" \
    grep -qxF org.example.revguard "$HOME/.local/share/appblock/blocked.list"

  # Drift repair on this surface: a deleted deny script (config regenerated /
  # re-pinned elsewhere) is re-created by the next invocation, no user action.
  "$AB" block revguardapp >/dev/null 2>&1
  rm -f "$HOME/.local/share/appblock/shims/.appblock-deny.org.example.revguard"
  "$AB" list >/dev/null 2>&1
  check "reconcile re-created a deleted deny script (drift self-heal)" \
    test -x "$HOME/.local/share/appblock/shims/.appblock-deny.org.example.revguard"

  # unblock: override + deny removed, original entry untouched (byte-exact restore)
  ab_unblock_now revguardapp >/dev/null 2>&1
  check "unblock removed the override (original system entry untouched)" \
    test ! -e "$HOME/.local/share/applications/org.example.revguard.desktop"
  check "unblock removed the deny script" \
    test ! -e "$HOME/.local/share/appblock/shims/.appblock-deny.org.example.revguard"
  [ "$(GLAUNCH org.example.revguard.desktop 2>/dev/null)" = "REVDNS-CLICKED" ] \
    && ok "unblocked by-id click runs the real entry (harness + restore verified)" \
    || bad "unblocked by-id click did not run (harness broken or restore wrong)"

  ab_unblock_now demoapp >/dev/null 2>&1
  [ "$(GLAUNCH demoapp.desktop 2>/dev/null)" = "hi-from-demoapp" ] \
    && ok "same-name by-id click runs after unblock (harness verified)" \
    || bad "same-name by-id click did not run after unblock"
  "$AB" block demoapp >/dev/null 2>&1   # next section expects demoapp blocked
else
  skip "gtk-launch not installed — by-id click-through regression not exercised (install gtk3: omarchy ships it)"
fi
check "autostart entry disabled (Hidden=true)" \
  grep -q '^Hidden=true' "$HOME/.config/autostart/demoapp.desktop"
# app update rewrites the autostart file: changes Exec to a new path, drops Hidden
printf '[Desktop Entry]\nType=Application\nName=demoapp\nExec=%s/bin2/demoapp --new-flag\n' "$HOME" \
  >"$HOME/.config/autostart/demoapp.desktop"
"$AB" list >/dev/null 2>&1
check "reconcile re-disabled autostart after clobber" \
  grep -q '^Hidden=true' "$HOME/.config/autostart/demoapp.desktop"
ab_unblock_now demoapp >/dev/null 2>&1
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
ab_unblock_now chatgpt >/dev/null 2>&1
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
ab_unblock_now figma >/dev/null 2>&1

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
ab_unblock_now "https://youtube.com/" x >/dev/null 2>&1
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
ab_unblock_now demoapp >/dev/null 2>&1
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
ab_unblock_now wine >/dev/null 2>&1
check "env-prefixed icon restored" test -f "$HOME/Desktop/game.desktop"
rm -f "$HOME/Desktop/game.desktop"

"$AB" block x >/dev/null 2>&1
check "web-app desktop icon hidden (matched by URL)" test ! -e "$HOME/Desktop/X.desktop"
ab_unblock_now x >/dev/null 2>&1
check "web-app desktop icon restored" test -f "$HOME/Desktop/X.desktop"
"$AB" block "https://x.com/" >/dev/null 2>&1
check "blocking a bare URL hides an icon for that URL" test ! -e "$HOME/Desktop/X.desktop"
ab_unblock_now "https://x.com/" >/dev/null 2>&1
check "URL unblock restores it" test -f "$HOME/Desktop/X.desktop"

# drift: an icon recreated while blocked is re-hidden on the next invocation
"$AB" block x >/dev/null 2>&1
cp "$HOME/Desktop/.appblock-disabled.X.desktop.off" "$HOME/Desktop/X.desktop"
"$AB" list >/dev/null 2>&1
check "icon recreated while blocked is re-hidden (drift repaired)" \
  test ! -e "$HOME/Desktop/X.desktop"
ab_unblock_now x >/dev/null 2>&1
check "no duplicate icons after drift repair + unblock" \
  test -f "$HOME/Desktop/X.desktop" -a ! -e "$HOME/Desktop/.appblock-disabled.X.desktop.off"

section "desktop dir resolution (XDG user-dirs, not hardcoded ~/Desktop)"
mkdir -p "$HOME/MyDesk" "$HOME/.config"
printf 'XDG_DESKTOP_DIR="$HOME/MyDesk"\n' >"$HOME/.config/user-dirs.dirs"
printf '[Desktop Entry]\nType=Application\nName=demoapp\nExec=demoapp\n' \
  >"$HOME/MyDesk/demoapp.desktop"
"$AB" block demoapp >/dev/null 2>&1
check "custom XDG_DESKTOP_DIR honored" test ! -e "$HOME/MyDesk/demoapp.desktop"
ab_unblock_now demoapp >/dev/null 2>&1
check "custom-dir icon restored" test -f "$HOME/MyDesk/demoapp.desktop"
rm -f "$HOME/.config/user-dirs.dirs"
rm -rf "$HOME/MyDesk"
rm -rf "$HOME/Desktop"
"$AB" block demoapp >/dev/null 2>&1 && ab_unblock_now demoapp >/dev/null 2>&1 \
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

section "timed blocks (lazy expiry)"
# Duration parser: verify relative specs resolve to now+seconds (within a few s
# of wall-clock drift). parse_duration_to_epoch is not exported, so exercise it
# the way the CLI does — through `block --until` writing blocked-until.list.
NOW=$(date +%s)
"$AB" block demoapp --until 25m >/dev/null 2>&1
ep=$(sed -n 's/^demoapp|//p' "$HOME/.local/share/appblock/blocked-until.list" | tail -1)
[ -n "$ep" ] && ok "block --until writes an epoch to blocked-until.list" || bad "no epoch written"
# allow 5s drift between NOW capture and the CLI's own date +%s
[ -n "$ep" ] && [ "$ep" -ge $((NOW + 1500 - 5)) ] && [ "$ep" -le $((NOW + 1500 + 5)) ] \
  && ok "epoch is now+25m (~1500s)" || bad "epoch wrong ($ep vs ~$((NOW+1500)))"
ab_unblock_now demoapp >/dev/null 2>&1
check "unblock clears the timed entry" test ! -s "$HOME/.local/share/appblock/blocked-until.list"

# Invalid duration must be rejected, not silently blocked forever.
"$AB" block demoapp --until NOTADURATION >/dev/null 2>&1
invalid_failed=$?
check "invalid --until duration rejected (non-zero exit)" [ "$invalid_failed" -ne 0 ]
ab_unblock_now demoapp >/dev/null 2>&1

# Lazy shim expiry: bake a PAST epoch into blocked-until.list, then launching the
# shim must self-unblock (clear both lists) and exec the real binary (echoes a
# known marker). No daemon, no wait — expiry is checked at invocation time.
printf '#!/bin/sh\necho REALDEMOOUTPUT\n' >"$HOME/bin2/demoapp-fake"
chmod +x "$HOME/bin2/demoapp-fake"
ln -sfn demoapp-fake "$HOME/bin2/demoapp"
"$AB" block demoapp >/dev/null 2>&1            # create shim, managed entry
PAST=$(( $(date +%s) - 10 ))
echo "demoapp|$PAST" >> "$HOME/.local/share/appblock/blocked-until.list"
out=$(PATH="$HOME/.local/share/appblock/shims:$HOME/bin2:$PATH" demoapp 2>/dev/null)
check "shim self-unblocks on expiry and execs real binary (lazy expiry)" [ "$out" = "REALDEMOOUTPUT" ]
check "expiry cleared blocked-until.list" test ! -s "$HOME/.local/share/appblock/blocked-until.list"
check_not "expiry removed app from blocked.list" grep -qxF demoapp "$HOME/.local/share/appblock/blocked.list"
# a still-active (future) timed block must NOT self-unblock.
# (the lazy expiry above already unblocked the app, so block it again first)
"$AB" block demoapp >/dev/null 2>&1
FUTURE=$(( $(date +%s) + 3600 ))
echo "demoapp|$FUTURE" >> "$HOME/.local/share/appblock/blocked-until.list"
PATH="$HOME/.local/share/appblock/shims:$HOME/bin2:$PATH" demoapp >/dev/null 2>&1; ec=$?
check "active timed block still refuses launch (exit 1)" [ "$ec" -ne 0 ]
check "active block kept its until-entry" grep -qF "demoapp|$FUTURE" "$HOME/.local/share/appblock/blocked-until.list"
ab_unblock_now demoapp >/dev/null 2>&1

# reconcile() expiry: a past-epoch entry gets fully unblocked (unhide desktop)
# even without a launch. Seed a fake desktop entry + icon + past epoch, run list.
printf '[Desktop Entry]\nType=Application\nName=demoapp\nExec=%s/bin/demoapp\n' "$HOME" \
  >"$HOME/.local/share/applications/demoapp.desktop"
"$AB" block demoapp >/dev/null 2>&1
PAST2=$(( $(date +%s) - 10 ))
echo "demoapp|$PAST2" >> "$HOME/.local/share/appblock/blocked-until.list"
"$AB" list >/dev/null 2>&1   # reconcile runs here
check_not "reconcile expires overdue timed block (not in blocked.list)" grep -qxF demoapp "$HOME/.local/share/appblock/blocked.list"
check "reconcile cleared the until-entry" test ! -s "$HOME/.local/share/appblock/blocked-until.list"
check_not "reconcile restored the menu override (desktop entry gone)" grep -q '^NoDisplay=true' "$HOME/.local/share/applications/demoapp.desktop"
ab_unblock_now demoapp >/dev/null 2>&1
rm -f "$HOME/bin2/demoapp-fake" "$HOME/.local/share/applications/demoapp.desktop"

# list shows remaining time for active timed blocks
FUT2=$(( $(date +%s) + 1500 ))
"$AB" block demoapp >/dev/null 2>&1
echo "demoapp|$FUT2" >> "$HOME/.local/share/appblock/blocked-until.list"
"$AB" list 2>&1 | grep -q '25m left\|24m left\|26m left' \
  && ok "list shows remaining time for timed block" || bad "list omitted remaining time"
ab_unblock_now demoapp >/dev/null 2>&1
rm -f "$HOME/.local/share/appblock/blocked-until.list"

section "unblock friction (cooldown)"
# Lifting a block is deliberately slow: `unblock`/`toggle` only SCHEDULE the
# lift. Self-contained fixture — an earlier section moves demoapp's binary away,
# so demoapp can no longer be launched.
printf '#!/bin/sh\necho FRIC-RAN\n' >"$HOME/bin/fricapp"
chmod +x "$HOME/bin/fricapp"
printf '[Desktop Entry]\nType=Application\nName=fricapp\nExec=%s/bin/fricapp\n' "$HOME" \
  >"$HOME/.local/share/applications/fricapp.desktop"
printf '[Desktop Entry]\nType=Application\nName=fricapp\nExec=%s/bin/fricapp\n' "$HOME" \
  >"$HOME/.config/autostart/fricapp.desktop"

"$AB" block fricapp >/dev/null 2>&1
# The shim is written from an UNQUOTED heredoc: a stray backtick or $(…) in a
# comment would execute at generation time. Nothing may leak in.
check_not "friction: shim generation ran no substituted command" grep -q \
  'usage: appblock' "$HOME/.local/share/appblock/shims/fricapp"
NOWF=$(date +%s)
"$AB" unblock fricapp >/dev/null 2>&1
check "friction: unblock does NOT lift immediately" grep -qxF fricapp \
  "$HOME/.local/share/appblock/blocked.list"
ep=$(sed -n 's/^fricapp|//p' "$HOME/.local/share/appblock/unblock-at.list" | tail -1)
[ -n "$ep" ] && ok "friction: lift scheduled in unblock-at.list" || bad "friction: no pending lift written"
[ -n "$ep" ] && [ "$ep" -ge $((NOWF + 595)) ] && [ "$ep" -le $((NOWF + 605)) ] \
  && ok "friction: default cooldown is 10m" || bad "friction: default cooldown wrong ($ep)"
"$AB" list 2>&1 | grep -q 'unblocks in 9m\|unblocks in 10m' \
  && ok "friction: list shows the pending lift" || bad "friction: list hides the pending lift"
if fricapp >/dev/null 2>&1; then bad "friction: app launched during cooldown"; else ok "friction: app still refused during the cooldown"; fi

NOWF=$(date +%s)
"$AB" unblock fricapp --after 2m >/dev/null 2>&1
ep=$(sed -n 's/^fricapp|//p' "$HOME/.local/share/appblock/unblock-at.list" | tail -1)
[ -n "$ep" ] && [ "$ep" -ge $((NOWF + 115)) ] && [ "$ep" -le $((NOWF + 125)) ] \
  && ok "friction: --after 2m sets the cooldown" || bad "friction: --after ignored ($ep)"

# No back door: a wait under the floor, a missing duration, and --after together
# with `block` must all be refused without disturbing the pending lift.
"$AB" unblock fricapp --after 30s >/dev/null 2>&1; tooshort=$?
check "friction: --after below the 60s floor refused" [ "$tooshort" -ne 0 ]
"$AB" unblock fricapp --after >/dev/null 2>&1; nodur=$?
check "friction: --after without a duration refused" [ "$nodur" -ne 0 ]
"$AB" block fricapp --after 5m >/dev/null 2>&1; withblock=$?
check "friction: --after rejected together with block" [ "$withblock" -ne 0 ]
check "friction: refused calls left the pending lift intact" grep -q '^fricapp|' \
  "$HOME/.local/share/appblock/unblock-at.list"

# --cancel abandons the pending lift; the block itself stays.
"$AB" unblock fricapp --cancel >/dev/null 2>&1
check "friction: --cancel clears the pending lift" test ! -s "$HOME/.local/share/appblock/unblock-at.list"
check "friction: --cancel leaves the app blocked" grep -qxF fricapp \
  "$HOME/.local/share/appblock/blocked.list"

# toggle must not be a one-keystroke bypass.
"$AB" toggle fricapp >/dev/null 2>&1
check "friction: toggle cannot bypass the cooldown" grep -qxF fricapp \
  "$HOME/.local/share/appblock/blocked.list"
check "friction: toggle scheduled a lift instead" grep -q '^fricapp|' \
  "$HOME/.local/share/appblock/unblock-at.list"

# A URL block obeys the same cooldown.
"$AB" block "https://fric.example/" >/dev/null 2>&1
"$AB" unblock "https://fric.example/" >/dev/null 2>&1
check "friction: URL unblock does not lift immediately" grep -qxF 'https://fric.example/' \
  "$HOME/.local/share/appblock/blocked.list"
check "friction: URL unblock is scheduled" grep -q '^https://fric.example/|' \
  "$HOME/.local/share/appblock/unblock-at.list"

# An elapsed cooldown really lifts both, at every layer.
ab_finish_cooldown
check_not "friction: elapsed cooldown lifts the app" grep -qxF fricapp \
  "$HOME/.local/share/appblock/blocked.list"
check_not "friction: elapsed cooldown lifted the URL" grep -qxF 'https://fric.example/' \
  "$HOME/.local/share/appblock/blocked.list"
check "friction: cooldown left the user desktop entry alone" test -f \
  "$HOME/.local/share/applications/fricapp.desktop"
check_not "friction: cooldown restored autostart" grep -q '^Hidden=true' \
  "$HOME/.config/autostart/fricapp.desktop"
[ "$(fricapp)" = "FRIC-RAN" ] && ok "friction: app runs after the cooldown" \
  || bad "friction: app does not run after the cooldown"

# The cooldown is honoured lazily AT LAUNCH too — no appblock command required,
# exactly like a timed deadline passing.
"$AB" block fricapp >/dev/null 2>&1
"$AB" unblock fricapp >/dev/null 2>&1
sed -i 's/|[0-9]*$/|1/' "$HOME/.local/share/appblock/unblock-at.list"   # age the wait
out=$(fricapp 2>/dev/null)
[ "$out" = "FRIC-RAN" ] && ok "friction: launch lifts an elapsed cooldown (lazy)" \
  || bad "friction: launch did not lift the elapsed cooldown"
check_not "friction: lazy launch lift cleared blocked.list" grep -qxF fricapp \
  "$HOME/.local/share/appblock/blocked.list"
check "friction: lazy launch lift cleared the pending entry" test ! -s \
  "$HOME/.local/share/appblock/unblock-at.list"

# Retrying must not push the wait out. Re-arming the whole cooldown from "now"
# on every request (the old behaviour) made the natural "it still hasn't
# unblocked, ask again" response the one thing that could postpone the lift for
# as long as the user kept asking — i.e. the wait never ended.
"$AB" block fricapp >/dev/null 2>&1
"$AB" unblock fricapp >/dev/null 2>&1
first=$(sed -n 's/^fricapp|//p' "$HOME/.local/share/appblock/unblock-at.list" | tail -1)
sleep 2
"$AB" unblock fricapp 2>&1 | grep -q 'already has a lift scheduled' \
  && ok "friction: a retry reports the lift is already scheduled" \
  || bad "friction: retry did not admit the lift was already scheduled"
second=$(sed -n 's/^fricapp|//p' "$HOME/.local/share/appblock/unblock-at.list" | tail -1)
[ "$first" = "$second" ] && ok "friction: a retry did NOT push the lift later" \
  || bad "friction: retry moved the deadline ($first -> $second)"
# --after is an explicit instruction, so it DOES count from now — including
# shortening a wait the user is no longer willing to sit through.
NOWF=$(date +%s)
"$AB" unblock fricapp --after 2m >/dev/null 2>&1
ep=$(sed -n 's/^fricapp|//p' "$HOME/.local/share/appblock/unblock-at.list" | tail -1)
[ -n "$ep" ] && [ "$ep" -ge $((NOWF + 115)) ] && [ "$ep" -le $((NOWF + 125)) ] \
  && ok "friction: explicit --after re-sets the wait from now" \
  || bad "friction: explicit --after ignored ($ep)"
"$AB" unblock fricapp >/dev/null 2>&1
ep2=$(sed -n 's/^fricapp|//p' "$HOME/.local/share/appblock/unblock-at.list" | tail -1)
[ "$ep" = "$ep2" ] && ok "friction: a retry never shortens an explicit --after either" \
  || bad "friction: retry changed an explicit --after wait ($ep -> $ep2)"
# "When does it actually lift?" must be answerable without guessing: name the
# clock time (a bare "another 10m" next to a "--after 30m" hint is what read as
# "my block now lasts 30 minutes").
"$AB" list 2>&1 | grep -q 'unblocks in .* at [0-9][0-9]:[0-9][0-9]' \
  && ok "friction: list names the exact lift time" || bad "friction: list omits the lift time"
"$AB" unblock fricapp --cancel >/dev/null 2>&1   # fixture back to a plain block

# A `--until` deadline passing is AUTOMATIC and must stay frictionless — it is
# not a user-requested lift, so no cooldown may apply to it.
"$AB" block fricapp --until 1s >/dev/null 2>&1
sleep 2
ab_finish_cooldown
check_not "friction: timed deadline lifts with no cooldown" grep -qxF fricapp \
  "$HOME/.local/share/appblock/blocked.list"
check "friction: timed lift left no pending entry" test ! -s \
  "$HOME/.local/share/appblock/unblock-at.list"

section "lazy lifts finish the job (menu layer + orphaned artifacts)"
# A lift that lands AT LAUNCH clears the blocklist from inside the shim or deny
# script — no appblock command runs, so reconcile() never sees that key again.
# Whatever we masked has to be unmasked by the lifting script itself, or the app
# launches but stays invisible in every menu/launcher, permanently.
"$AB" block fricapp >/dev/null 2>&1
"$AB" unblock fricapp >/dev/null 2>&1
sed -i 's/|[0-9]*$/|1/' "$HOME/.local/share/appblock/unblock-at.list"   # age the wait
[ "$(fricapp 2>/dev/null)" = "FRIC-RAN" ] && ok "lazy lift: app launches" \
  || bad "lazy lift: app did not launch"
check "lazy lift restored the renamed-aside menu entry" test -f \
  "$HOME/.local/share/applications/fricapp.desktop"
check "lazy lift left no masked residue" test ! -e \
  "$HOME/.local/share/applications/.appblock-disabled.fricapp.desktop.off"

# Same for the packaged-app shape (entry outside the user dir → NoDisplay
# override + deny script): both of OUR files must go, and the app's own entry
# must be untouched so the app is back in the menu.
printf '#!/bin/sh\necho LAZY-RAN\n' >"$HOME/bin/lazyapp"
chmod +x "$HOME/bin/lazyapp"
printf '[Desktop Entry]\nType=Application\nName=lazyapp\nExec=%s/bin/lazyapp\n' "$HOME" \
  >"$HOME/.local/share/flatpak/exports/share/applications/lazyapp.desktop"
"$AB" block lazyapp >/dev/null 2>&1
check "lazy: packaged-shape override written" test -f \
  "$HOME/.local/share/applications/lazyapp.desktop"
check "lazy: deny script written" test -x \
  "$HOME/.local/share/appblock/shims/.appblock-deny.lazyapp"
"$AB" unblock lazyapp >/dev/null 2>&1
sed -i 's/|[0-9]*$/|1/' "$HOME/.local/share/appblock/unblock-at.list"
[ "$(lazyapp 2>/dev/null)" = "LAZY-RAN" ] && ok "lazy: packaged-shape app launches" \
  || bad "lazy: packaged-shape app did not launch"
check "lazy: override removed (entry visible again)" test ! -e \
  "$HOME/.local/share/applications/lazyapp.desktop"
check "lazy: deny script removed" test ! -e \
  "$HOME/.local/share/appblock/shims/.appblock-deny.lazyapp"
check "lazy: original packaged entry never modified" grep -q '^Exec=.*bin/lazyapp$' \
  "$HOME/.local/share/flatpak/exports/share/applications/lazyapp.desktop"

# The documented escape hatch is editing blocked.list by hand; that never runs
# this program at all, so the layers keyed on the launch binary (autostart,
# desktop icons) can only be swept up by the next invocation.
printf '#!/bin/sh\necho SWEEP-RAN\n' >"$HOME/bin/sweepapp"
chmod +x "$HOME/bin/sweepapp"
printf '[Desktop Entry]\nType=Application\nName=sweepapp\nExec=%s/bin/sweepapp\n' "$HOME" \
  >"$HOME/.local/share/flatpak/exports/share/applications/sweepapp.desktop"
printf '[Desktop Entry]\nType=Application\nName=sweepapp\nExec=%s/bin/sweepapp\n' "$HOME" \
  >"$HOME/.config/autostart/sweepapp.desktop"
"$AB" block sweepapp >/dev/null 2>&1
check "sweep: autostart disabled while blocked" grep -q '^Hidden=true' \
  "$HOME/.config/autostart/sweepapp.desktop"
grep -vxF sweepapp "$HOME/.local/share/appblock/blocked.list" \
  >"$HOME/.local/share/appblock/blocked.list.tmp" || :
mv -f "$HOME/.local/share/appblock/blocked.list.tmp" "$HOME/.local/share/appblock/blocked.list"
"$AB" list >/dev/null 2>&1
check "sweep: orphaned menu override removed" test ! -e \
  "$HOME/.local/share/applications/sweepapp.desktop"
check "sweep: orphaned deny script removed" test ! -e \
  "$HOME/.local/share/appblock/shims/.appblock-deny.sweepapp"
check_not "sweep: autostart re-enabled (not left Hidden)" grep -q '^Hidden=true' \
  "$HOME/.config/autostart/sweepapp.desktop"
[ "$(sweepapp 2>/dev/null)" = "SWEEP-RAN" ] && ok "sweep: app runs and is back in the menu" \
  || bad "sweep: app still refuses to run"
rm -f "$HOME/.local/share/applications/lazyapp.desktop" \
      "$HOME/.local/share/applications/sweepapp.desktop" \
      "$HOME/.config/autostart/sweepapp.desktop"

# Discoverability: timed blocks and the running-applet opt-out are flags, not
# mysteries.
"$AB" bogus 2>&1 | grep -q -- '--until' \
  && ok "usage surfaces --until (block until a time)" || bad "usage hides --until"
# Bare `appblock` used to abort on `set -u` ($1 unbound) before printing help.
if "$AB" 2>&1 | grep -q 'unbound variable'; then
  bad "bare 'appblock' died instead of printing usage (set -u on \$1)"
else
  ok "bare 'appblock' prints usage (no set -u crash)"
fi
"$AB" bogus 2>&1 | grep -q -- '--keep-running' \
  && ok "usage surfaces --keep-running" || bad "usage hides --keep-running"

section "blocking a running applet (autostart entry + its tray icon)"
# A tray applet (Remmina's -i, Discord, Dropbox, …) is a LIVE process, and the
# icon on the omarchy bar / waybar / any StatusNotifierItem host belongs to that
# process. Disabling the autostart entry only stops the NEXT login, so blocking
# an applet that is already up must stop it too, or the icon the user is looking
# at survives the block. appblock touches ONLY the systemd unit generated from
# the very autostart entry it just disabled — never a blind pkill — which is why
# a fake systemctl is enough to observe the whole decision.
if command -v systemd-escape >/dev/null 2>&1; then
  printf '#!/bin/sh\necho TRAY-RAN\n' >"$HOME/bin/trayapp"
  chmod +x "$HOME/bin/trayapp"
  printf '[Desktop Entry]\nVersion=1.0\nName=trayapp Applet\nExec=trayapp -i\nType=Application\nHidden=false\n' \
    >"$HOME/.config/autostart/trayapp-applet.desktop"
  mkdir -p "$HOME/fakebin"
  cat >"$HOME/fakebin/systemctl" <<'FAKE'
#!/bin/sh
# fake systemctl: logs every call, answers for exactly one generated unit
printf '%s\n' "$*" >>"$HOME/fakebin/calls.log"
case "$1 $2" in
  "--user is-active")
    [ "$3" = 'app-trayapp\x2dapplet@autostart.service' ] && { echo active; exit 0; }
    echo inactive; exit 3 ;;
  "--user stop") exit 0 ;;
  *) exit 0 ;;
esac
FAKE
  chmod +x "$HOME/fakebin/systemctl"

  # --keep-running: the entry is still disabled, but a running applet is spared
  : >"$HOME/fakebin/calls.log"
  PATH="$HOME/fakebin:$PATH" "$AB" block trayapp --keep-running >/dev/null 2>&1
  check "applet: --keep-running still disables the autostart entry" \
    grep -q '^Hidden=true' "$HOME/.config/autostart/trayapp-applet.desktop"
  check "applet: --keep-running made no systemd call at all" \
    test ! -s "$HOME/fakebin/calls.log"

  ab_unblock_now trayapp >/dev/null 2>&1
  check_not "applet: lifting a block never (re)starts the app" \
    grep -qF -- '--user start' "$HOME/fakebin/calls.log"
  : >"$HOME/fakebin/calls.log"

  # default: the applet started from that entry is stopped, by unit name
  PATH="$HOME/fakebin:$PATH" "$AB" block trayapp >"$HOME/fakebin/out.log" 2>&1
  check "applet: autostart entry disabled" grep -q '^Hidden=true' \
    "$HOME/.config/autostart/trayapp-applet.desktop"
  check "applet: asked about the unit generated from THAT entry" grep -qF -- \
    '--user is-active app-trayapp\x2dapplet@autostart.service' "$HOME/fakebin/calls.log"
  check "applet: stopped exactly that unit (tray icon goes with it)" grep -qF -- \
    '--user stop app-trayapp\x2dapplet@autostart.service' "$HOME/fakebin/calls.log"
  grep -q 'stopped running applet' "$HOME/fakebin/out.log" \
    && ok "applet: the stop is reported, never silent" || bad "applet: stop not reported"
  check "applet: exactly one unit stopped (no process spray)" \
    test "$(grep -cF -- '--user stop' "$HOME/fakebin/calls.log")" = "1"

  # The suite's own contract: nothing here may talk to the LIVE systemd user
  # manager. The stub having been used is the proof that the real one was not.
  check "applet: every systemd call went to the sandbox stub, not the live manager" \
    test -s "$HOME/stub/systemctl.calls"

  "$AB" unblock trayapp --keep-running >/dev/null 2>&1; kr_fail=$?
  check "applet: --keep-running refused with unblock" [ "$kr_fail" -ne 0 ]
  ab_unblock_now trayapp >/dev/null 2>&1
  check "applet: unblock cleared the autostart Hidden flag" \
    test "$(grep -c '^Hidden=true' "$HOME/.config/autostart/trayapp-applet.desktop" || :)" = "0"
  rm -f "$HOME/.config/autostart/trayapp-applet.desktop" "$HOME/bin/trayapp"
else
  skip "systemd-escape absent — running-applet stop path not exercised"
fi

section "argument handling (no eval of user input)"
# The parser used to collect the non-flag words into a string and then eval
# "set -- $_args" it, which re-parsed every argument as shell SOURCE:
#   * a URL with a query string (?a=1&b=2) was truncated at the & and blocked
#     nothing at all — silently;
#   * a name or URL containing a quote died with a syntax error;
#   * one containing a command substitution or backticks was EXECUTED.
# Arguments must survive byte-exact, and must never be evaluated.
pwn="$HOME/PWNED-BY-ARGS"
"$AB" block "https://x.example/?a=1&b=2" >/dev/null 2>&1
check "args: a URL with a query string is stored byte-exact" grep -qxF \
  'https://x.example/?a=1&b=2' "$HOME/.local/share/appblock/blocked.list"
"$AB" block "https://y.example/\$(touch $pwn)" >/dev/null 2>&1
check "args: a command substitution is NOT executed" test ! -e "$pwn"
check "args: ...it is stored literally instead" grep -qxF \
  "https://y.example/\$(touch $pwn)" "$HOME/.local/share/appblock/blocked.list"
"$AB" block 'https://z.example/a"b' >/dev/null 2>&1
check "args: a quote in an argument is stored byte-exact" grep -qxF \
  'https://z.example/a"b' "$HOME/.local/share/appblock/blocked.list"
# Flags keep working on either side of the app names.
"$AB" block fricapp --until 17m >/dev/null 2>&1
check "args: a flag AFTER the app name is parsed" grep -qxF fricapp \
  "$HOME/.local/share/appblock/blocked.list"
ab_unblock_now fricapp >/dev/null 2>&1
"$AB" block --until 17m fricapp >/dev/null 2>&1
check "args: a flag BEFORE the app name is parsed" grep -qxF fricapp \
  "$HOME/.local/share/appblock/blocked.list"
check "args: ...and the flag took effect (deadline recorded)" grep -q '^fricapp|' \
  "$HOME/.local/share/appblock/blocked-until.list"
ab_unblock_now fricapp >/dev/null 2>&1
ab_unblock_now "https://x.example/?a=1&b=2" "https://y.example/\$(touch $pwn)" 'https://z.example/a"b' >/dev/null 2>&1
check "args: fixtures cleaned up" test ! -s "$HOME/.local/share/appblock/blocked.list"

section "machine-readable state (list --json)"
# The contract a bar widget / plugin consumes. The point is that a consumer
# never re-derives blocked state from the plaintext files in another language:
# it reads this document. So it must ALWAYS be valid JSON on stdout, with no
# narration mixed in — reconcile's chatter has to go to stderr even when the
# call itself lifts a block.
printf '#!/bin/sh\necho JSONAPP-RAN\n' >"$HOME/bin/jsonapp"
chmod +x "$HOME/bin/jsonapp"
# Capture the clock BEFORE and AFTER the blocking, so the deadline can be
# asserted tightly (now+20m) without assuming the suite runs fast.
NOWB=$(date +%s)
"$AB" block jsonapp --until 20m >/dev/null 2>&1
"$AB" block 'https://example.com/a"b' >/dev/null 2>&1   # an id needing JSON escaping
NOWJ=$(date +%s)
out=$("$AB" list --json 2>/dev/null)
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' \
    && ok "json: output parses as real JSON" || bad "json: output is not valid JSON"
else
  skip "python3 absent — JSON checked structurally only"
fi
printf '%s' "$out" | grep -q '"schema": 1' && ok "json: carries the schema version" \
  || bad "json: schema field missing"
printf '%s' "$out" | grep -q '"blocked": \[' && ok "json: blocked array present" \
  || bad "json: blocked array missing"
printf '%s' "$out" | grep -q '"managed": \[' && ok "json: managed array present" \
  || bad "json: managed array missing"
check "json: count matches the blocklist" \
  test "$(printf '%s' "$out" | sed -n 's/.*"count": \([0-9]*\).*/\1/p')" = "$(grep -c . "$HOME/.local/share/appblock/blocked.list")"
# A timed block exports the authoritative epoch AND the seconds remaining, so a
# widget runs a live countdown instead of re-implementing our parsing.
printf '%s' "$out" | grep -q '"id": "jsonapp"' && ok "json: blocked app listed by canonical id" \
  || bad "json: blocked app missing"
# A timed block exports the AUTHORITATIVE epoch plus the seconds remaining, so a
# widget runs a live countdown instead of re-implementing our parsing. Asserting
# the RELATIONSHIP (until - until_in == now) rather than a wall-clock window
# keeps this honest even when the suite runs slowly.
_jline=$(printf '%s' "$out" | grep -F '"id": "jsonapp"' | head -n1)
jq_until=$(printf '%s' "$_jline" | sed -n 's/.*"until": \([0-9]*\).*/\1/p')
jq_uin=$(printf '%s' "$_jline" | sed -n 's/.*"until_in": \([0-9]*\).*/\1/p')
if [ -n "$jq_until" ] && [ "$jq_until" -ge $((NOWB + 1195)) ] && [ "$jq_until" -le $((NOWJ + 1205)) ]; then
  ok "json: timed block exports its deadline epoch (now+20m)"
else
  bad "json: until epoch wrong ($jq_until, wanted $((NOWB + 1200))..$((NOWJ + 1200)))"
fi
if [ -n "$jq_uin" ] && [ "$jq_uin" -le 1200 ] \
   && [ "$(( jq_until - jq_uin - $(date +%s) ))" -ge -3 ] \
   && [ "$(( jq_until - jq_uin - $(date +%s) ))" -le 3 ]; then
  ok "json: until_in is derived from that epoch at call time"
else
  bad "json: until_in inconsistent with the epoch ($jq_uin)"
fi

# A pending lift is exported the same way (the field a bar renders as a timer).
NOWU=$(date +%s)
"$AB" unblock jsonapp >/dev/null 2>&1
out2=$("$AB" list --json 2>/dev/null)
_jline2=$(printf '%s' "$out2" | grep -F '"id": "jsonapp"' | head -n1)
jq_up=$(printf '%s' "$_jline2" | sed -n 's/.*"unblock_at": \([0-9]*\).*/\1/p')
jq_upin=$(printf '%s' "$_jline2" | sed -n 's/.*"unblock_in": \([0-9]*\).*/\1/p')
if [ -n "$jq_up" ] && [ "$jq_up" -ge $((NOWU + 595)) ] && [ "$jq_up" -le $((NOWU + 620)) ]; then
  ok "json: pending lift exports its epoch (now+10m)"
else
  bad "json: unblock_at wrong ($jq_up vs ~$((NOWU + 600)))"
fi
if [ -n "$jq_upin" ] && [ "$jq_upin" -le 600 ] \
   && [ "$(( jq_up - jq_upin - $(date +%s) ))" -ge -3 ] \
   && [ "$(( jq_up - jq_upin - $(date +%s) ))" -le 3 ]; then
  ok "json: unblock_in is derived from that epoch at call time"
else
  bad "json: unblock_in inconsistent with the epoch ($jq_upin)"
fi

# Round-trip an id that needs JSON escaping: parse it back and compare, rather
# than trying to grep a quoted pattern through two levels of shell quoting.
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ids = [b["id"] for b in d["blocked"]]
assert "https://example.com/a\"b" in ids, ids
assert "jsonapp" in ids, ids
assert all(isinstance(b["enforcement"], str) and b["enforcement"] for b in d["blocked"]), d
' && ok "json: ids round-trip byte-exact (incl. a quote in a URL)" \
  || bad "json: an id did not survive the round-trip"
fi

# Purity: force reconcile to lift a block DURING the call — the narration must
# land on stderr while stdout stays a clean JSON document. Clear the URL block
# first so the lift empties the list, which also exercises the empty array.
ab_unblock_now 'https://example.com/a"b' >/dev/null 2>&1
# Re-arm a lift (the URL unblock above lifted this one too) so the call below has
# a real lift to perform while we watch where its narration lands.
"$AB" block jsonapp >/dev/null 2>&1
"$AB" unblock jsonapp >/dev/null 2>&1
sed -i 's/|[0-9]*$/|1/' "$HOME/.local/share/appblock/unblock-at.list"
out3=$("$AB" list --json 2>"$HOME/json.err")
printf '%s' "$out3" | grep -q 'unblocked' && bad "json: reconcile narration leaked into stdout" \
  || ok "json: stdout carries no narration"
grep -q 'cooldown elapsed' "$HOME/json.err" \
  && ok "json: the lift it performed was narrated on stderr" \
  || bad "json: the mid-call lift was silently lost"
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$out3" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"]==0, d' \
    && ok "json: still valid JSON after a mid-call lift (empty blocked)" \
    || bad "json: broke when the block lifted mid-call"
fi

# A consumer gates on the version it was built against.
v=$("$AB" --version 2>/dev/null); v=${v##* }
case "$v" in [0-9]*.[0-9]*) ok "version: prints a version ($v)" ;; *) bad "version flag broken ('$v')" ;; esac
"$AB" list --json 2>/dev/null | grep -q "\"version\": \"$v\"" \
  && ok "version: JSON reports the same version as --version" \
  || bad "version: JSON and --version disagree"
"$AB" list --nonsense >/dev/null 2>&1; junk=$?
check "json: an unknown list option is refused" [ "$junk" -ne 0 ]
rm -f "$HOME/bin/jsonapp" "$HOME/json.err"

section "reverse-DNS desktop id (shim key != launch name)"
# Regression: an app whose desktop id (org.example.revdnsapp) differs from the
# binary you type (revdnsapp). The shim is named after the binary but MUST key
# off the canonical id, or blocked.list never matches and the app launches
# anyway. NOTE: the fixture name must have no real /usr/share entry — resolution
# reads real system dirs even inside the sandbox and would mask the bug.
printf '#!/bin/sh\necho REVDNS-RAN\n' >"$HOME/bin/revdnsapp"
chmod +x "$HOME/bin/revdnsapp"
printf '[Desktop Entry]\nType=Application\nName=RevdnsApp\nExec=%s/bin/revdnsapp\n' "$HOME" \
  >"$HOME/.local/share/applications/org.example.revdnsapp.desktop"
printf '[Desktop Entry]\nType=Application\nName=RevdnsApp\nExec=%s/bin/revdnsapp\n' "$HOME" \
  >"$HOME/.config/autostart/org.example.revdnsapp.desktop"

"$AB" block revdnsapp >/dev/null 2>&1
check "revdns: blocklist gets the canonical id" grep -qxF org.example.revdnsapp \
  "$HOME/.local/share/appblock/blocked.list"
check "revdns: shim installed at the typed launch name" test -x \
  "$HOME/.local/share/appblock/shims/revdnsapp"
check "revdns: shim keyed on the canonical id, not the launch name" grep -qxF \
  '# appblock-block-key: org.example.revdnsapp' "$HOME/.local/share/appblock/shims/revdnsapp"
if revdnsapp >/dev/null 2>&1; then bad "revdns: blocked app was allowed to run"; else ok "revdns: blocked app refused to run"; fi
"$AB" list 2>&1 | grep -q 'org.example.revdnsapp — enforced' \
  && ok "revdns: list reports enforced" || bad "revdns: list lacks enforced label"
check "revdns: autostart entry disabled" grep -q '^Hidden=true' \
  "$HOME/.config/autostart/org.example.revdnsapp.desktop"

# Timed expiry must undo autostart + shim (both are keyed on the LAUNCH name,
# which differs from the id — the old code looked them up by the id and failed).
PASTR=$(( $(date +%s) - 10 ))
echo "org.example.revdnsapp|$PASTR" >>"$HOME/.local/share/appblock/blocked-until.list"
"$AB" list >/dev/null 2>&1   # reconcile runs here
check_not "revdns: timed expiry cleared autostart Hidden" grep -q '^Hidden=true' \
  "$HOME/.config/autostart/org.example.revdnsapp.desktop"
check_not "revdns: timed expiry removed the shim" test -f \
  "$HOME/.local/share/appblock/shims/revdnsapp"

ab_unblock_now revdnsapp >/dev/null 2>&1
[ "$(revdnsapp)" = "REVDNS-RAN" ] && ok "revdns: app runs after unblock" || bad "revdns: app does not run after unblock"
# A repeated/idempotent unblock must not delete the user's own .desktop entry
# (the user-dir flow renames it aside; unhide must only remove OUR override).
ab_unblock_now revdnsapp >/dev/null 2>&1
check "revdns: repeat unblock preserves the user desktop entry" test -f \
  "$HOME/.local/share/applications/org.example.revdnsapp.desktop"

# Self-heal: a pre-fix shim is keyed on the launch name and is inert. Any
# invocation (list runs reconcile) must rewrite it to the canonical key.
"$AB" block revdnsapp >/dev/null 2>&1
{
  printf '#!/bin/sh\n'
  printf '# generated by appblock — do not edit (refresh with: appblock shims)\n'
  printf "if grep -qxF 'revdnsapp' \"%s/blocked.list\" 2>/dev/null; then\n" "$HOME/.local/share/appblock"
  printf '  echo blocked\n  exit 1\nfi\n'
  printf 'exec %s/bin/revdnsapp "$@"\n' "$HOME"
} >"$HOME/.local/share/appblock/shims/revdnsapp"
chmod +x "$HOME/.local/share/appblock/shims/revdnsapp"
if revdnsapp >/dev/null 2>&1; then ok "revdns: pre-fix name-keyed shim is inert (bug shape reproduced)"; else bad "revdns: pre-fix shim unexpectedly enforced"; fi
"$AB" list >/dev/null 2>&1
check "revdns: self-heal rewrote the shim key" grep -qxF \
  '# appblock-block-key: org.example.revdnsapp' "$HOME/.local/share/appblock/shims/revdnsapp"
if revdnsapp >/dev/null 2>&1; then bad "revdns: launch allowed after self-heal"; else ok "revdns: launch refused after self-heal"; fi
ab_unblock_now revdnsapp >/dev/null 2>&1

# Empty blocklist must print cleanly (grep -c . exits 1 with no matches, which
# used to append a second "0" and blow up the arithmetic test).
: >"$HOME/.local/share/appblock/blocked.list"
"$AB" list 2>&1 | grep -q 'integer expected' \
  && bad "empty blocklist emits an integer error" || ok "empty blocklist lists cleanly"

section "uninstall-cleanliness"
ab_unblock_now demoapp >/dev/null 2>&1
remaining=$(wc -l <"$HOME/.local/share/appblock/blocked.list")
[ "$remaining" -eq 0 ] && ok "blocked.list empty after unblocks" || bad "blocked.list not empty ($remaining)"

printf '\n================\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]