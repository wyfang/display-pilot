# Display Pilot

A macOS menu bar app for switching an entire multi-display setup with one click.

[Latest release](https://github.com/wyfang/display-pilot/releases/latest) · [简体中文](./README.md)

## Features

- Save two named display presets
- Store connection state, brightness, contrast, resolution, and rotation per display
- Switch from the menu bar or with `⌘1` and `⌘2`
- Remember temporarily disconnected displays and restore their configuration when they reconnect
- Prevent the last active display from being disabled
- Optional launch at login

## Usage

### Requirements

- macOS 13 or later
- [BetterDisplay](https://github.com/waydabber/BetterDisplay) with integration enabled for brightness and contrast
- Xcode Command Line Tools for source builds

### Build from source

```bash
git clone https://github.com/wyfang/display-pilot.git
cd display-pilot
./build.sh
```

The app is written to `dist/Display Pilot.app`. Builds target macOS 13 and the current CPU architecture; set `DISPLAYPILOT_ARCH=arm64` or `DISPLAYPILOT_ARCH=x86_64` to select an architecture. The app uses local ad-hoc signing and is not notarized by Apple; on first launch, you may need to right-click it and choose “Open”.

Run `./Tests/run.sh` for isolated regression tests or `./scripts/generate-icon.sh` to regenerate the app icon.

## Notes

### How it works

Display Pilot turns two common multi-display configurations into single-click menu bar presets. macOS controls display connections, resolution, and rotation. Brightness and contrast use BetterDisplay's notification integration, which shares its CLI protocol.

Switching connects target displays, applies requested rotation and resolution, disconnects unwanted displays, then applies and reads back brightness and contrast after the topology settles. Unavailable rotation or resolution does not block other supported settings; results are reported separately. Final checks cover display identity, connections, requested modes, and visual settings, so partial completion is not marked as complete.

“Apply resolution and rotation” is independent of brightness: an explicit selection also applies the saved geometry at 0% brightness. Legacy blackout presets without this option default to changing connection, brightness, and contrast only. “Follow current” does not actively change orientation, and upgrading legacy presets does not add a rotation requirement based on the screen's current angle. Existing explicit settings remain unchanged.

Brightness slider edits save whole percentages, so a displayed 0% saves exactly zero. Existing fractional values are preserved, with nonzero values below 1% shown separately. Explicit rotation uses the native macOS interface without BetterDisplay rotation permissions; 90° and 270° are verified separately.

Already-matched connections and display modes skip unnecessary fixed waits while brightness and contrast are still verified. Actual connection changes retain their stabilization waits.

### Limitations

- Display switching uses the private macOS API `CGSConfigureDisplayEnabled`, and rotation uses the system `MonitorPanel` interface; these are unsuitable for Mac App Store distribution and may be affected by system updates
- Rotation requires support from macOS and the display. Unsupported rotation is reported separately while other available settings continue
- Missing BetterDisplay, disabled integration, or mismatched readback prevents a preset from being marked successful
- Physically disconnected displays cannot be reconnected by software; displays with unverified identities cannot be switched
- Upgrades retain legacy preset data; ambiguous legacy devices must be configured again. Choose an explicit angle when active rotation is needed; the app does not infer direction from resolution
- Cables, docks, mirroring, HDR, and macOS updates may invalidate saved modes

## License

Original code is licensed under the [Apache License 2.0](./LICENSE). Personal branding and assets are excluded. See [license scope](./LICENSE_SCOPE.md).
