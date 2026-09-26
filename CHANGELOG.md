# Changelog

FanCurve uses date-based versions (`YYYY.MM.DD.HHMM`). See [Releases](../../releases) for downloadable builds.

## 2026-09-26

### Added
- **AeroSpace layouts:** width commands (½ ⅓ ¼ ⅔ ¾) and two presets, Half + Two Quarters (stacked) and Half + Two Quarter Columns.
- **Mouse jiggler** (Settings → Keep Awake), with an adjustable idle delay and interval. It moves across all monitors and doesn't prevent sleep with the lid closed unless in clamshell mode.
- **Quick Notes (⌃⌥N):** a floating notes window with a note list. It saves as you type, you can search it from the palette, and you can move a note to Obsidian.
- **Spotlight file search** in the command palette.
- **Obsidian integration** in the command palette: note search (titles and text), append to the daily note (the layout is detected from your notes), create notes, open the daily note, open the vault, and open a random note.
- **⌘Space option** to replace Spotlight's shortcut.
- **Rename fan profiles**; the Save, Rename and Delete buttons now sit above the curve.
- **Command palette (⌥Space):** fuzzy search over apps, FanCurve commands, meetings and snippets, plus a calculator and system commands.
- **Favourites:** pinned apps first in the palette; ⌘1–9 in the palette, global ⌃⌥1–9, and ⌘F to pin the selected app.
- **AeroSpace integration:** live window-manager commands, workspace and window navigation, and config toggles.
- **Calendar:** next meeting in the menu bar, join-next-meeting shortcut, schedule panel, and notifications with a Join button.
- **Snippets:** keyword expansion with placeholders, and a search-and-paste panel.
- **Updates from GitHub Releases.**
- **App icon.**
- **Shortcut clash warnings** against AeroSpace bindings.

## 2026-09-25

### Added
- **Fan control:** fan curves with a daemon, Noctua-based presets, custom profiles, spin-up delay, and critical-temperature override.
- **Displays:** external monitor brightness over DDC/CI, and matching the laptop's ambient light sensor.
- **Microphone:** global mic mute with a custom shortcut and a menu bar indicator.
- **Keyboard cleaning mode.**
- **Brightness keys** for external monitors.
- **Open at login.**
- **M1–M4 fan-control support** (`Ftst` unlock).
- **System Settings–style interface** with the macOS 26+ design.

### Fixed
- A menu bar hang caused by a SwiftUI update loop.
- Fans cycling at idle: the spin-up delay was added.
