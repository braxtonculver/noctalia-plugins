# Arch Updater

Automatic system update checker and updater for Arch Linux. Monitors pacman, AUR helpers (yay/paru), and flatpak for available updates, displays the count in your bar, and provides a panel to trigger updates with full terminal visibility.

## Plugin

| Field | Value |
| --- | --- |
| ID | `braxton/updater` |
| Entries | Bar widget: `status`; service: `checker`; panel: `updates` |

## Requirements

- **pacman** — always available on Arch Linux
- **yay** or **paru** — optional, for AUR package updates. Auto-detected at startup.
- **flatpak** — optional, for Flatpak package updates. Auto-detected at startup.

## Usage

Add the `status` widget from the Add-widget picker. It shows a system glyph with a badge indicating the number of packages that have updates available. No clicking required — the count updates automatically.

The service checks for updates on boot (after a 3-second delay) and then every 30 minutes (configurable). Each check queries:
- `pacman -Qu` for official repository packages
- `yay -Qua` or `paru -Qua` for AUR packages (if an AUR helper is installed)
- `flatpak remote-ls --updates` for Flatpak packages (if flatpak is installed)

Click the widget to open the updates panel.

Open the panel directly with:

```sh
noctalia msg panel-toggle braxton/updater:updates
```

### Panel

The panel shows per-manager breakdowns with individual update buttons and a combined "Update All" action:

- **Pacman** — runs `sudo pacman -Syu` in a terminal
- **AUR** — runs `yay -Sua` or `paru -Sua` in a terminal
- **Flatpak** — runs `flatpak update` in a terminal
- **Update All** — chains all applicable update commands

All update commands run in a terminal window so you can see exactly what is happening and provide your sudo password if prompted. No commands run silently in the background.

### Refresh

Click "Refresh" in the panel header to trigger an immediate recheck. The service also rechecks automatically after each update completes.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `check_interval_minutes` | `number` | `30` | How often to check for updates automatically. Minimum 5 minutes. |
| `show_count` | `bool` | `true` | Display the number of available updates next to the icon. |

## IPC

```sh
noctalia msg plugin braxton/updater:checker all check
noctalia msg plugin braxton/updater:checker all update_pacman
noctalia msg plugin braxton/updater:checker all update_aur
noctalia msg plugin braxton/updater:checker all update_flatpak
noctalia msg plugin braxton/updater:checker all update_all
```

## Notes

- All update commands run via `runInTerminal` for full user visibility and control.
- The service prevents concurrent update operations — if an update is in progress, new check requests are ignored until the update completes and a fresh check runs.
- AUR helper detection is performed once at service startup. If you install yay or paru after the service starts, restart Noctalia to pick it up.
- Network errors during update checks are handled gracefully — the previous state is preserved and a log message is emitted.
- Flatpak update counts may include trailing whitespace or header lines from `flatpak remote-ls`; the counting logic accounts for this.
