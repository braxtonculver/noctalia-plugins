# Arch Updater

Automatic system update checker and updater for Arch Linux. Monitors pacman, AUR helpers (yay/paru), and flatpak for available updates, displays the count in your bar, and provides a panel to trigger updates with full terminal visibility.

## Plugin

| Field | Value |
| --- | --- |
| ID | `braxtonculver/arch-update` |
| Entries | Bar widget: `status`; service: `checker`; panel: `updates` |

## Requirements

- **pacman** — always available on Arch Linux
- **yay** or **paru** — optional, for AUR package updates. Auto-detected or configurable.
- **flatpak** — optional, for Flatpak package updates. Auto-detected at startup.

## Usage

Add the `status` widget from the Add-widget picker. It shows a configurable icon glyph with an optional badge indicating the number of packages that have updates available. The count updates automatically on boot and every 5 minutes (configurable).

Click the widget to open the updates panel.

Open the panel directly with:

```sh
noctalia msg panel-toggle braxtonculver/arch-update:updates
```

### Panel

The panel shows a status indicator, per-manager breakdowns with packages listed under their respective sections, and individual update buttons:

- **Status** — shows a large update count when updates are available, or a checkmark when up to date
- **Pacman** — lists official repository packages with an "Update" button
- **AUR** — lists AUR packages with an "Update" button (requires yay or paru)
- **Flatpak** — lists Flatpak packages with an "Update" button (requires flatpak)
- **Update All** — chains all applicable update commands

All update commands run in a terminal window so you can see exactly what is happening and provide your sudo password if prompted. No commands run silently in the background.

### Refresh

Click "Refresh" in the panel header to trigger an immediate recheck. The service also rechecks automatically after each update completes.

### Search

Type in the search box to filter the package list by name in real time.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `check_interval` | `int` | `300` | How often to check for updates automatically, in seconds. Minimum 30. |
| `enable_aur` | `bool` | `true` | Check for AUR package updates. |
| `aur_helper` | `select` | `auto` | Which AUR helper to use: auto-detect, yay, or paru. |
| `enable_flatpak` | `bool` | `true` | Check for Flatpak package updates. |
| `show_count` | `bool` | `true` | Display the number of available updates next to the icon. |
| `icon_glyph` | `glyph` | `refresh` | The icon glyph displayed in the bar widget. |

## IPC

```sh
noctalia msg plugin braxtonculver/arch-update:checker all check
noctalia msg plugin braxtonculver/arch-update:checker all update_pacman
noctalia msg plugin braxtonculver/arch-update:checker all update_aur
noctalia msg plugin braxtonculver/arch-update:checker all update_flatpak
noctalia msg plugin braxtonculver/arch-update:checker all update_all
```

## Notes

- All update commands run via `runInTerminal` for full user visibility and control.
- All update checks run in parallel with a 45-second safety timeout to prevent hangs.
- The service prevents concurrent update operations — if an update is in progress, new check requests are queued and run after the current update completes.
- AUR helper and flatpak detection is performed once at service startup. If you install yay, paru, or flatpak after the service starts, restart Noctalia to pick it up.
- You can disable AUR or Flatpak checking entirely in settings, which hides those sections from the panel.
