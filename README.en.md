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

Display Pilot connects the required displays, restores their requested rotation and resolution, then disables unused displays. It waits for the connection changes to settle and restores display modes again before applying brightness and contrast. It prefers system UUIDs and revalidates device identity before switching. Final verification checks connection state, requested display modes, and brightness and contrast read back from BetterDisplay.

Presets with brightness set to 0 apply only connection state, brightness, and contrast by default, so a system orientation change does not report failure after blackout succeeds. Saved resolution and rotation choices are retained. Enable “应用分辨率与旋转” in the preset editor to enforce them, or select “保持当前” for resolution and “跟随当前” for rotation independently.

### Limitations

- Display switching uses the private macOS API `CGSConfigureDisplayEnabled`, which is unsuitable for Mac App Store distribution and may be affected by system updates
- Changing rotation requires BetterDisplay Pro and display support; preserving the current orientation and the default blackout flow do not call the rotation API
- Missing BetterDisplay, disabled integration, or mismatched readback prevents a preset from being marked successful
- Physically disconnected displays cannot be reconnected by software; displays with unverified identities cannot be switched
- Upgrades retain legacy preset data; ambiguous legacy devices must be configured again. If an old preset has no saved rotation and its orientation differs from the current display, select 90° or 270° explicitly; the app does not guess the direction
- Cables, docks, mirroring, HDR, and macOS updates may invalidate saved modes

## License

Original code is licensed under the [Apache License 2.0](./LICENSE). Personal branding and assets are excluded. See [license scope](./LICENSE_SCOPE.md).
