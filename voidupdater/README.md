# Void Updater

Check xbps and Flatpak for updates from the bar, with a reboot heads-up
before you upgrade. Runs the update in a terminal window.

## Plugin

| Field | Value |
| --- | --- |
| ID | `helmsman/void-updater` |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service`; launcher: `launcher` |
| Launcher Prefix | `/void` |

## Requirements

- `xbps-install` on `PATH`, required.
- `sh`, `sudo`, `awk`, `sed`, `test` and `uname`, required — base tools from
  any standard Void install, used to run and parse the xbps check and the
  reboot probe, and to run the upgrade.
- `flatpak`, optional, for the Flatpak check and update.
- `xdg-open`, optional, to open a package page.
- A terminal emulator for the update run: Noctalia's own detection
  (`$TERMINAL`, then `ghostty`, `kitty`, `alacritty`, `wezterm`, `foot`,
  `konsole`, `gnome-terminal`, `ptyxis`, `xterm`), or the one named in the
  **Terminal** setting.

Everything except `xbps-install`, `sh`, `sudo`, `awk`, `sed`, `test` and
`uname` is optional. A missing optional tool is skipped, not treated as an
error.

## Usage

Add the `widget` bar widget from Noctalia's widget picker. Left click opens
the panel, right click checks for updates now, middle click opens the
widget's own settings. You can also open the panel directly or bind it in
your compositor:

```sh
noctalia msg panel-toggle helmsman/void-updater:panel
```

The panel groups pending packages by source (Xbps, Flatpak). Click a source
row to expand it into its packages. Each package row has a copy button (name
and version) and an open button (its page on voidlinux.org or Flathub).
**Check Updates** queries all sources, **Update** opens a terminal running the
upgrade, **Dismiss** keeps the numbers but returns the bar glyph to its
resting colour.

Type `/void` in the launcher for quick actions (check, update), or
`/void <text>` to fuzzy-search the packages from the last check. Activating a
result opens that package's page.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `flatpak_enabled` | `bool` | `true` | Also check and update Flatpak. Skipped automatically when `flatpak` isn't installed. |
| `ignore_packages` | `string_list` | *(empty)* | Package names excluded from the count and left at their current version on Update. |
| `auto_check_hours` | `int` | `0` | Check automatically every N hours. `0` never checks on its own. |
| `notify_on_updates` | `bool` | `true` | Send a desktop notification when a check finds packages to upgrade. |
| `check_reboot_needed` | `bool` | `true` | Flag when the running kernel is no longer installed on disk. |
| `terminal` | `string` | *(empty)* | Terminal command for the update run, e.g. `kitty`. Empty uses Noctalia's detection. |
| `assume_yes` | `bool` | `false` | Pass `-y` so package managers do not ask for confirmation. |
| `check_cmd` | `string` | *(empty)* | Full override for the check command. Empty builds it from the defaults below. |
| `update_cmd` | `string` | *(empty)* | Full override for the update command. Empty builds it from the settings above. |
| `glyph` | `glyph` | `package` | The glyph shown for the widget on the bar. |
| `show_count` | `bool` | `true` | Show the pending-update count next to the bar glyph. |
| `hide_on_empty` | `bool` | `false` | Hide the widget entirely when there is nothing to show. |

## IPC

```sh
noctalia msg plugin helmsman/void-updater:service all check
noctalia msg plugin helmsman/void-updater:service all update
noctalia msg plugin helmsman/void-updater:service all dismiss
```

## Notes

- **Commands spawned.** `xbps-install -Mun` for the check; `flatpak list` /
  `flatpak remote-ls --updates`; a local `test -d` against `uname -r` for the
  reboot check; and, for the update, your terminal running `sh` to launch
  `sudo xbps-install -Su` (or `-Suy` with **Answer yes**), optionally
  `flatpak update`. No upgrade command runs outside the terminal.
- **Rootless check.** `xbps-install -Mun` fetches the repository index into
  memory and dry-runs the update, so the count is always fresh without
  needing a prior `sudo xbps-install -S`. It does contact the mirrors on
  every check; when there is no network, the check fails with a clear error.
  Prefer an offline local-index check (`xbps-install -un`) or a custom
  command? Set **Custom check command**.
- **Privileges.** The plugin never elevates anything itself. Updates run via
  `sudo xbps-install` in the terminal, where `sudo` prompts normally.
- **Reboot recommendation.** Detected from whether the running kernel's
  `/usr/lib/modules/<version>` directory still exists, so it works for any
  kernel flavour (`linux`, `linux-lts`, `linux6.x`, ...) without naming one.
- **Kernel updates.** Void rebuilds the initramfs via
  `sudo xbps-reconfigure -f <kernel-package>`, which is not run automatically;
  the plugin flags the reboot instead. Run it yourself if you update a kernel.
- **Ignore list.** xbps-install has no `--ignore`, so packages in **Ignore
  packages** are filtered out of the count and, on Update, the remaining
  pending packages are passed to `xbps-install -Su <names>` explicitly
  (Flatpak the same way) — ignored packages stay at their current version.

## Credits

Adapted for Void Linux and the xbps package manager from the Arch Updater
example plugin (MIT).

## License

MIT.
