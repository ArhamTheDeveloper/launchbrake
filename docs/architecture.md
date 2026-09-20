# Architecture

LaunchBrake applies one canonical blocked ID across several independent Linux
launch surfaces:

1. PATH shims intercept ordinary command launches.
2. XDG desktop overrides hide entries and intercept by-ID launches.
3. XDG autostart entries receive `Hidden=true`; systemd user units may be
   stopped when an applet is already running.
4. Matching desktop-icon files are renamed aside and restored byte-for-byte.
5. Omarchy web-app URLs are guarded through `omarchy-launch-webapp` on PATH.

State lives under `~/.local/share/appblock/`. CLI reconciliation and generated
launch guards share `.state.lock`, preventing concurrent processes from losing
updates. No daemon is required: timed expiry and unblock cooldowns are applied
lazily on launch or the next appblock invocation.

The optional LaunchBrake Omarchy plugin is a separate consumer. Its only state
API is `appblock list --json`; the CLI never depends on the plugin.

For implementation history and resolved edge cases, see
[design-notes.md](design-notes.md).
