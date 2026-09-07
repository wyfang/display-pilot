# Display Pilot

A macOS menu bar app for switching an entire multi-display setup with one click.

[简体中文](./README.md) · English · [Latest release](https://github.com/wyfang/display-pilot/releases/latest)

## Features

- Save two named display presets
- Store connection state, brightness, contrast, and resolution per display
- Switch from the menu bar or with `⌘1` and `⌘2`
- Remember temporarily disconnected displays
- Prevent the last active display from being disabled
- Optional launch at login

## Requirements

- macOS 13 or later
- [BetterDisplay](https://github.com/waydabber/BetterDisplay) with integration enabled for brightness and contrast
- Xcode Command Line Tools for source builds

## Build

```bash
git clone https://github.com/wyfang/display-pilot.git
cd display-pilot
./build.sh
```

The app is written to `dist/Display Pilot.app`. Builds target macOS 13 and the current CPU architecture; set `DISPLAYPILOT_ARCH=arm64` or `DISPLAYPILOT_ARCH=x86_64` to select an architecture. The app uses local ad-hoc signing and is not notarized by Apple.

Run `./Tests/run.sh` for isolated regression tests or `./scripts/generate-icon.sh` to regenerate the app icon.

## How it works

Display Pilot connects the required displays, waits for their modes to stabilize, switches all resolutions in one Core Graphics transaction, applies brightness and contrast, then disables unused displays. It prefers system UUIDs and revalidates device identity before switching. Final verification checks connection state, resolution, and brightness and contrast read back from BetterDisplay.

## Limitations

- Display switching uses the private macOS API `CGSConfigureDisplayEnabled`
- Missing BetterDisplay, disabled integration, or mismatched readback prevents a preset from being marked successful
- Physically disconnected displays cannot be reconnected by software; displays with unverified identities cannot be switched
- Upgrades retain legacy preset data; ambiguous legacy devices must be configured again in the preset editor
- Cables, docks, mirroring, HDR, and macOS updates may invalidate saved modes

## Copyright

Original code is licensed under the [Apache License 2.0](./LICENSE). Personal branding and assets are excluded.
