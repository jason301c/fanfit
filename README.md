# FanFit

A menu bar fan controller for Apple Silicon MacBooks. It learns a temperature-to-RPM curve from two buttons: **Too hot** and **Too loud**.

It keeps one curve for the desk and one for the lap. It picks the desk curve when an external display is connected and the lap curve when none is. You can also pick one by hand. A hand-picked position lasts until a display is plugged in or out.

## Install

```sh
./scripts/install.sh
```

The script does these steps:

1. Builds the app and the daemon.
2. Installs `FanFit.app` in `~/Applications` and starts it at login.
3. Asks for your password, then installs the root daemon `/usr/local/libexec/fanfitd`.
4. Stops and disables ThermalForge's daemon if it is installed, because two fan controllers fight. To bring it back, run `sudo launchctl enable system/com.thermalforge.daemon`.

To remove FanFit, run `./scripts/uninstall.sh`. It hands the fans back to Apple.

## How it works

| Part | Runs as | Does |
| --- | --- | --- |
| `fanfitd` | root, launchd | Once a second: reads the SMC, runs the curve, sets the fans, writes `/var/run/fanfit/status.json`. |
| `FanFit.app` | you | Shows the readings, takes button presses, fits the curves, writes `/Users/Shared/FanFit/control.json`. |

The curve input is the hottest CPU or GPU sensor, smoothed. Where the curve sits below the fans' minimum (1,350 RPM), Apple's own controller runs the fans.

These safety rules apply:

- A sensor at 98°C or hotter hands the fans to Apple until the chip cools to 90°C.
- The daemon hands the fans to Apple when it exits, when the app is paused, and when the control file is missing or invalid.
- Fan speed rises by at most 500 RPM a second and falls by at most 150 RPM a second.

### Fitting the curve

Each button press records the temperature and fan speed at that moment, and turns into a bound on the curve:

- **Too hot**: at this temperature, at least 30% faster, at least 700 RPM faster, and at least 2,000 RPM.
- **Too loud**: at this temperature, 20% slower minus 100 RPM. If Apple was running the fans, FanFit takes over at that lower speed.

The fitter changes the default curve as little as it can while meeting the bounds. It smooths the change into neighbouring temperatures and keeps the curve non-decreasing. A press loses half its weight every 21 days, so newer presses win conflicts. The code is in `Sources/FanFitCore/Curve.swift`.

### SMC keys on the M5 Pro

| Key | Meaning |
| --- | --- |
| `F0md`, `F1md` | Fan mode: 0 is Apple, 1 is manual. M1 to M4 use `F0Md` and need `Ftst=1` first. |
| `F0Tg`, `F0Ac`, `F0Mn`, `F0Mx` | Target, actual, minimum and maximum RPM (float). |
| `Tp*`, `TCMb`, `TCHP` | CPU |
| `Tg*` | GPU |
| `Ts0P` | Palm rest |
| `TB*T` | Battery |

To print the current readings without root, run `.build/release/fanfitd --probe`.

## Develop

```sh
swift build
swift test
```
