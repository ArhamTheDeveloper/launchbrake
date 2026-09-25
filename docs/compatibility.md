# Compatibility

LaunchBrake targets Linux and XDG-compatible desktop environments. It is tested
primarily on Omarchy with Hyprland; it is not intended for macOS, BSD, or
generic Unix systems.

## Environment support

| Environment | Status | Notes |
|---|---|---|
| Omarchy + Hyprland | First-class | All launch surfaces and the optional bar plugin are tested here. |
| Other Hyprland systems | Supported | PATH and XDG behavior work; session PATH setup may need manual configuration. |
| GNOME, KDE, XFCE, Cinnamon | Expected | PATH, XDG menu, autostart, and desktop-icon behavior are designed for these environments. |
| systemd-based Linux | Supported | Running XDG autostart applets can be stopped through their user units. |
| Non-systemd Linux | Partial | Normal blocking works; stopping an already-running autostart applet does not. |

## Package and launch formats

| Target | Normal launch coverage | Known bypass |
|---|---|---|
| Native package | PATH command and XDG desktop entry | Absolute binary path |
| Flatpak | XDG desktop entry | Direct `flatpak run <id>` |
| Snap | `/snap/bin` command through PATH, plus desktop entry | Direct `/snap/bin/<app>` |
| AppImage | PATH command or registered desktop entry | Direct execution of the AppImage file |
| Web app/PWA | Registered desktop entry; Omarchy's web-app launcher can also be intercepted | Normal browser navigation is not blocked |
| Wine app | Matching desktop entry/icon; blocking `wine` blocks all Wine launches | Direct or differently named Wine command |
| Steam game | Matching desktop entry where present | Direct Steam protocol/library launch |

Linux has no universal application-launch interception point. LaunchBrake covers
normal launch routes it can discover and reports the enforcement it currently
has. It deliberately remains a friction tool rather than an access-control
system.

LaunchBrake is not a DNS, proxy, browser-extension, or network filter. It does
not provide general website blocking.

## Runtime requirements

- A POSIX-compatible `/bin/sh`.
- Standard Linux userland tools, including GNU `date` for duration parsing.
- XDG desktop entries for menu-level integration.
- Optional: `systemd --user` for stopping running autostart applets.
- Optional: GLib/`gtk-launch` for the corresponding integration tests.
- Optional: Omarchy commands for the Omarchy web-app path and bar plugin.
