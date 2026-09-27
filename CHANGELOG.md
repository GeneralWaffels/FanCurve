# Changelog

FanCurve uses date-based versions (`YYYY.MM.DD.HHMM`). See [Releases](../../releases) for downloadable builds.

## 2026-09-27

### Added
- **Puget Systems fan preset:** 30 °C 25%, 55 °C 35%, 70 °C 50%, 80 °C 75%, 90 °C 100%.
- **Download a model from Settings:** a one-click Gemma 4 E2B download from Hugging Face (Google's official build or Unsloth's Q4_K_M), with progress, a free-space check and SHA-256 verification.

### Changed
- **Noctua presets restored to Noctua's original curves,** including the 30% floor. The laptop fans-off zone is gone; a curve saved from the old presets switches to the matching original.

### Removed
- **Cotypist import:** the model and style import buttons are gone. A model you already imported keeps working.

## 2026-09-26

### Added
- **Autocomplete improvements:**
  - Suggestions stream in word by word.
  - Esc straight after accepting a suggestion undoes it.
  - Draft a reply (⌃⌥R) writes an answer to the email or chat on screen.
  - Writing styles can be set per app.
  - An optional words-completed counter shows in the menu bar.
  - llama-server restarts itself if it crashes or stops answering.
- **Clipboard history (⌃⌥V)** in the palette, with pinning (⌘P) and deleting (⌘⌫). Passwords and concealed items are never saved.
- **Quicklinks:** URL templates with `{query}`, for example `gh fancurve` to search GitHub.
- **Window snapping** without AeroSpace: halves, thirds, quarters, maximise, centre and next display, from the palette or custom shortcuts.
- **Calendar:**
  - Create events from plain English, for example "event lunch with Sam tomorrow at 1pm for 45 min".
  - Copy My Availability pastes your free times.
- **Fans:**
  - A temperature and fan-speed history graph covering the last 10 minutes to 3 hours.
  - Automatic profiles for battery, charger, calls, or while an app runs.
- **Battery page:** charge, measured health, cycles, power draw and charger.
- **Export Diagnostics** (General → Troubleshooting).
- **Unit tests** (Swift Testing) that run in CI.

### Fixed
- Window thirds were zero-width. The unit tests caught it before release.

- **Autocomplete now works in more apps:**
  - A typing buffer and a bubble display cover apps that don't expose their text, such as VS Code and Electron apps.
  - New features: emoji completion, autocorrect, a length setting, a choice of accept key, a Suggest now shortcut, per-app switches, word stats, and a live status line.
  - On battery, it can switch to Apple's on-device model or pause.
- **AI autocomplete:** local llama.cpp + GGUF model with ghost text at the cursor (Tab / ⌥→ / Esc). It uses screen context and a style prompt, and personalises from local history. Imports Cotypist's model and style.
- **Shortcuts for AeroSpace layouts** (⌃⌥Q, ⌃⌥W).
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
