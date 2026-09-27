# How FanCurve works with AeroSpace

FanCurve controls [AeroSpace](https://github.com/nikitabobko/AeroSpace) only through AeroSpace's own command-line tool, `aerospace`. It never moves windows itself. Everything it does is a normal AeroSpace command, exactly what a key binding in `~/.aerospace.toml` would run.

The code lives in [`Sources/FanCurve/AeroSpace.swift`](../Sources/FanCurve/AeroSpace.swift).

## 1. How a command travels

```
FanCurve ──runs──▶ aerospace workspace 3 ──socket──▶ AeroSpace.app
                                                     │ 1. parse the command
                                                     │ 2. update its window tree
                                                     │ 3. move real windows (Accessibility)
FanCurve ◀──output + exit code─────────────────────◀┘
```

1. **The CLI is only a messenger.** `aerospace` (installed at `/opt/homebrew/bin/aerospace`) connects to the running AeroSpace app through a local Unix socket in `/tmp/bobko.aerospace/`. It sends the command and waits for the reply. If AeroSpace isn't running, the socket doesn't exist and the CLI prints *"Can't connect to AeroSpace server. Is AeroSpace.app running?"*
2. **The command language is the one your config uses.** `alt-3 = 'workspace 3'` in `~/.aerospace.toml` and FanCurve running `aerospace workspace 3` are identical to AeroSpace; only the trigger differs.
3. **AeroSpace changes its own model first.** It keeps a record of every monitor and workspace. Each workspace holds a tree of containers (tiles or accordion, horizontal or vertical), with windows as the leaves. Commands edit that tree:
   - `workspace 3` makes workspace 3 the visible one on its monitor.
   - `move-node-to-workspace 5` moves the focused window from this workspace's tree into workspace 5's.
   - `resize width 1504` adjusts the relative sizes of the window and its siblings in the nearest side-by-side container until this window is 1504 points wide.
4. **Then it moves the real windows.** AeroSpace works out every window's frame from the tree and applies it through macOS's Accessibility interface, which sets the window position and size directly.
5. **Workspaces are virtual.** AeroSpace doesn't use macOS Spaces. Windows on hidden workspaces are moved almost entirely off-screen into a corner and brought back when you switch, which is why switching is instant.
6. **It replies.** Any output, such as the lines from `list-windows`, and a success or failure exit code come back through the socket. FanCurve reads both.

## 2. What FanCurve uses it for

| Purpose | Commands | When |
|---|---|---|
| **Actions** from the palette or shortcuts | `workspace`, `move-node-to-workspace`, `layout`, `fullscreen`, `balance-sizes`, `flatten-workspace-tree`, `move-workspace-to-monitor`, `enable toggle`, `focus --window-id`, `resize width` | When you pick a command |
| **Reading state** | `list-workspaces --all / --focused`, `list-windows --all --format …`, `list-windows --focused --format %{window-layout}`, `list-monitors --focused` | Each time the command palette opens |
| **Settings toggles** (gaps, start at login, default layout, unhide hidden apps, flattening) | Edits `~/.aerospace.toml`, then runs `aerospace reload-config` | When you pick a setting |
| **Shortcut clash warnings** | Reads the `[mode.main.binding]` section of the config file | In Settings |

**Config edits** change only the value itself: comments, bindings and column alignment are kept. A copy is saved to `~/.aerospace.toml.fancurve-backup` before the first edit.

**CLI calls** run off the main thread with a 3-second timeout, so a busy or missing AeroSpace can't freeze FanCurve.

## 3. Layout presets, step by step

Both presets run as a short sequence of commands. Each step waits for AeroSpace's reply before the next.

**Example setup:** you're focused on **Mail**, with Safari and Notes on the same workspace. The monitor's usable width is 3008 pt.

### Shared steps

**Step 1: check the workspace**

```sh
aerospace list-windows --focused --format '%{window-id}'   # Mail → the "main" window
aerospace list-windows --workspace focused --count         # 3
```

The main window is whichever one is focused, so focus the app you want big first. With fewer than two windows the preset stops and beeps.

**Step 2: flatten into one row**

```sh
aerospace flatten-workspace-tree
aerospace layout h_tiles
```

All nested splits are removed, and every window becomes a column in a single row, in whatever order AeroSpace had them:

```
┌────────┬────────┬────────┐
│ Safari │  Mail  │ Notes  │
└────────┴────────┴────────┘
```

**Step 3: move the main window to the far left**

```sh
aerospace swap left    # repeated until it fails (non-zero exit = reached the left edge)
```

```
┌────────┬────────┬────────┐
│  Mail  │ Safari │ Notes  │
└────────┴────────┴────────┘
```

### Preset A: Half + Two Quarters (stacked), ⌃⌥Q

**Step 4: stack the other windows into one column**

```sh
aerospace focus right      # → Safari
aerospace focus right      # → Notes
aerospace join-with left   # Notes + Safari share a new vertical container
# for each extra window (4th, 5th …):
aerospace focus right
aerospace move left        # pulls it into the stack
```

`join-with` always creates a container at right angles to its parent. Inside a horizontal row, that means a vertical stack.

```
┌────────┬────────┐
│        │ Safari │
│  Mail  ├────────┤
│        │ Notes  │
└────────┴────────┘
```

**Step 5: give the main window exactly half**

```sh
aerospace focus --window-id <Mail>
aerospace resize width 1504    # (monitor width − outer gaps) ÷ 2, minus half an inner gap
```

The stack takes the other half, and its two windows split it top and bottom, so each is a quarter of the screen.

```
┌──────────────────┬────────┐
│                  │ Safari │ ¼
│    Mail  ½       ├────────┤
│                  │ Notes  │ ¼
└──────────────────┴────────┘
```

### Preset B: Half + Two Quarter Columns, ⌃⌥W

Steps 1–3 are the same. There's no stacking.

**Step 4: give the main window exactly half**

```sh
aerospace focus --window-id <Mail>
aerospace resize width 1504
```

**Step 5: make the first neighbour a quarter**

```sh
aerospace focus right              # → Safari
aerospace resize width 752         # ¼ of the monitor: width ÷ (2 × (windows − 1))
aerospace focus --window-id <Mail> # focus returns to you
```

The last window takes the rest, which is the other quarter.

```
┌──────────────────┬────────┬────────┐
│     Mail  ½      │Safari ¼│ Notes ¼│
└──────────────────┴────────┴────────┘
```

With more than three windows, the right half is shared between all the other windows.

### How the width is worked out

1. `aerospace list-monitors --focused --format '%{monitor-name}'` gives the monitor name. It's matched against macOS's list of screens to get that monitor's usable width, without the menu bar or Dock.
2. If gaps are on in `~/.aerospace.toml`, the outer gaps are subtracted and half an inner gap is allowed for.
3. The fraction (½, ¼, …) is applied and sent as `aerospace resize width <points>`.

The **Width: ½ / ⅓ / ¼ / ⅔ / ¾** commands use the same calculation for a single window, without rearranging anything.

## 4. Things to know

- **Presets replace the workspace's layout.** Step 2 flattens it, so any custom nesting on that workspace is lost. **Balance Window Sizes** or your usual AeroSpace keys put things back.
- **Floating windows are ignored.** They aren't part of the tiling tree.
- **Errors don't stop the sequence.** If one step fails, the others still run; the only step that uses the failure is the `swap left` loop, which stops once it reaches the edge. The last error is shown in Settings → Command Palette → AeroSpace.
- **AeroSpace must be running.** If it isn't, every command fails immediately and the palette offers **Start AeroSpace**. Set `start-at-login = true` (palette: *Start AeroSpace at Login*) so it comes back after a restart.
- **Shortcuts:**
  - **Presets:** ⌃⌥Q and ⌃⌥W.
  - **Width commands:** none by default, so assign your own in Settings → Command Palette → AeroSpace Layout Shortcuts.
  - **Clashes:** the ⌃⌥ combinations don't clash with AeroSpace's defaults, which all use ⌥ or ⌥⇧.
