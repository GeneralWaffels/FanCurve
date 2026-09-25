# FanCurve

A Macs Fan Control–style fan curve app for Apple Silicon (built and verified on a MacBook Pro M5 Pro; M1–M4 fan unlock via `Ftst` follows exelban/stats).

- **FanCurve.app**: a menu bar app that runs as your user and reads the SMC directly. **Settings…** (⌘,) opens a System Settings–style window with Fans, Displays, Microphone and Keyboard pages, and so does launching FanCurve again from Applications or Spotlight. The Fans page has a draggable temperature→RPM curve editor and saved profiles.
- **External display brightness (DDC/CI)**: a brightness slider for each external monitor, in the Displays tab and the menu bar. It works over USB-C, Thunderbolt and DisplayPort; some HDMI ports and docks don't pass DDC through.
- **Match laptop light sensor**: sets monitor brightness from the MacBook's ambient light sensor, on a log curve between your Darkest and Brightest settings (0 lux → Darkest, 1000+ lux → Brightest). It's smoothed and only writes changes of 2% or more. It pauses while the lid is closed, because the sensor is covered. Moving a slider by hand switches it off.
- **Global mic mute**: mutes every input device system-wide (hardware mute where available, otherwise input volume 0). It re-applies every second and when devices change, so a headset plugged in while muted is muted too. You set a custom global shortcut (default ⌃⌥M) in the Mic tab. A separate menu bar mic icon can be shown Always, Only while muted, or Never. The mic is unmuted when FanCurve quits.
- **Keyboard cleaning mode**: a switch in the menu bar and the editor window. While it's on, every key press is ignored (including media and brightness keys) but the trackpad keeps working, so you can switch it off again. It turns itself off after 5 minutes. It needs Accessibility permission. The power button and Touch ID can't be blocked.
- **fancurved**: a small root daemon (launchd) that reads `/Library/Application Support/FanCurve/config.json` every 2 s and drives the fans.

## Install

```bash
./build.sh
sudo ./install.sh
open /Applications/FanCurve.app
```

Then turn on **Use fan curve** in the menu bar or the editor window.

## How it works

- **Temperature source**: the hottest CPU core by default (`Tp*`, `Ts*` and `Tm*` SMC sensors, 73 on the M5 Pro). CPU average, GPU hottest (`Tg*`) and hottest-of-both are also available.
- **Presets**: Noctua Quiet, Balanced and Performance. These are Noctua's recommended curves, tweaked for a laptop with a fans-off zone at low temperatures.
- **Curve**: linear interpolation between your points. Any point below the fan minimum (2317 RPM) means "fans off": control goes back to macOS so the fans can idle silently. A 3 °C hysteresis stops them flapping on and off.
- **Smoothing**: exponential smoothing on the temperature. Rising temps react 3× faster than falling ones.
- **Safety**: above the critical temperature (95 °C by default) the fans go to max. If a temperature read or fan write fails, the daemon quits, or you disable the curve, the fans go back to macOS auto. The SoC's own thermal throttling always stays active.

## CLI

```bash
fancurved sensors
sudo fancurved set 4000
sudo fancurved auto
tail -f /var/log/fancurved.log
```

- `fancurved sensors` lists the sensors, current temps and fan state.
- `sudo fancurved set 4000` is a manual test at 4000 RPM. The running daemon overrides it within 2 s, so stop the daemon first to test this.
- `sudo fancurved auto` hands the fans back to macOS.

## SMC keys (M5 Pro)

| key | meaning |
|---|---|
| `FNum` | fan count (2) |
| `F0Ac` / `F1Ac` | actual RPM |
| `F0Mn` / `F0Mx` | min / max RPM (2317 / 7826) |
| `F0md` | mode: 0 = auto, 1 = manual. Lowercase `md` on this chip; older chips use `F0Md` |
| `F0Tg` | target RPM (float) |

## Updating your other Macs

On this Mac (the one with the source), start the update server:

```bash
./serve.sh on
```

It builds the app, packages it, and serves it on your local network (port 8765). It prints a one-line install command for the other Mac. Stop the server with `./serve.sh off`, and check it with `./serve.sh status`. Run `./serve.sh on` again after every code change to publish a new version.

- **Other Mac, first time:** paste the `curl … | bash` line that `serve.sh on` printed.
- **Other Mac, later updates:** `~/Developer/FanCurve/update.sh`. It checks the version, downloads the package, verifies its checksum and runs `sudo ./install.sh`.
- **Security:** files are served over plain HTTP from a random secret path, so only use this on a network you trust (e.g. home Wi-Fi).
- **Firewall:** macOS may ask to allow incoming connections for python3.

## Uninstall

```bash
sudo ./uninstall.sh
```
