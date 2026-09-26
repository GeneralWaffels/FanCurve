# Contributing to FanCurve

Thanks for your interest in improving FanCurve! Bug reports, sensor maps for other Macs, and pull requests are all welcome.

## Reporting bugs

Open an issue using the **Bug report** template. Please include:

- **Your Mac:** model and chip, e.g. *MacBook Pro 16", M4 Pro*, and your macOS version.
- **Sensor output** from `fancurved sensors`, especially if temperatures or fans look wrong.
- **Relevant log lines** from `/var/log/fancurved.log` for fan issues.

## Development setup

```bash
git clone https://github.com/GeneralWaffels/FanCurve.git
cd FanCurve
swift build
./build.sh
sudo ./install.sh
```

- **`swift build`** makes debug builds of the app and the daemon.
- **`./build.sh`** makes a release app bundle in `build/`.
- **`sudo ./install.sh`** installs it, including the fan service.

**Toolchain:** Xcode 26 or the Command Line Tools for macOS 26 or later. The Command Line Tools can't expand SwiftUI's `@State` macro, so views keep their local state in small `ObservableObject`s (`@StateObject`) instead. Please follow that pattern.

## Project layout

| Path | What's there |
|---|---|
| `Sources/SMCKit/` | SMC access, sensor/fan map, fan config and curve model (shared by the app and daemon) |
| `Sources/fancurved/` | The root launch daemon that applies the curve |
| `Sources/FanCurve/` | The menu bar app: settings UI, command palette, calendar, snippets, DDC, AeroSpace, updater |
| `Resources/` | App icon |
| `docs/` | README images |

## Guidelines

- **Fail safe.** Any change to fan control must hand the fans back to macOS on every error and exit path.
- **Look native.** Match System Settings: grouped forms, page header cards, left-aligned footnote footers, SF Symbols.
- **Stay light.** No background polling that isn't needed, and no main-thread blocking. Run `ps -o %cpu` against the app; it should idle near 0%.
- **Screenshots:** if you change the UI, refresh them with `.build/debug/FanCurve --snapshot docs/screenshots --shadow --height 900`.
- **No new dependencies** without discussion. FanCurve uses only system frameworks.

## Adding support for another Mac

Run `fancurved sensors` and open an issue with the output. If CPU temperatures are missing or implausible, the sensor prefixes in `Sources/SMCKit/Hardware.swift` may need extending for your chip.
