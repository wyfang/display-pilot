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

Open “预设切换设置…” (preset switching settings) in the menu bar to choose a delay of 0–60 seconds. Presets run immediately by default. With a five-second delay, selecting a preset or using its menu shortcut starts a visible countdown that you can cancel from the menu.

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

Switching connects target displays, applies the requested rotation and resolution, and disconnects unwanted displays. If a rotation or resolution is unavailable, other supported settings still run and the app reports the outcome. Once the configuration settles, Display Pilot sends each enabled display one request containing its brightness and software contrast targets.

“智能核验亮度与对比度” (verify brightness and contrast) is on by default under preset switching settings. After sending all requests, Display Pilot waits for BetterDisplay to update and reads each display’s brightness and contrast separately. If a reading differs from the target, Display Pilot waits and checks again. It resends only settings that missed their targets twice, at most once per display. After a correction, it rechecks the displays to catch changes from BetterDisplay’s brightness synchronization. When all checks pass, the menu shows “上次已核验” (last switch verified).

With verification off, Display Pilot sends one settings request per display. The menu shows “已发送” (sent) after BetterDisplay acknowledges the requests and Display Pilot checks display identity, connections, and requested modes.

“Apply resolution and rotation” is independent of brightness: an explicit selection also applies the saved geometry at 0% brightness. Legacy blackout presets without this option default to changing connection, brightness, and contrast only. “Follow current” does not actively change orientation, and upgrading legacy presets does not add a rotation requirement based on the screen's current angle. Existing explicit settings remain unchanged.

Brightness slider edits save whole percentages, so a displayed 0% saves exactly zero. Existing fractional values are preserved, with nonzero values below 1% shown separately. Explicit rotation uses the native macOS interface without BetterDisplay rotation permissions; 90° and 270° are verified separately.

Already-matched connections and display modes skip the wait for display configuration changes to settle.

### Limitations

- Display switching uses the private macOS API `CGSConfigureDisplayEnabled`, and rotation uses the system `MonitorPanel` interface; these are unsuitable for Mac App Store distribution and may be affected by system updates
- Rotation requires support from macOS and the display. Unsupported rotation is reported separately while other available settings continue
- Display Pilot reports when BetterDisplay is unavailable, rejects a request, or leaves the result unconfirmed. Verification also identifies displays with unreadable values or a final reading outside the target tolerance
- Physically disconnected displays cannot be reconnected by software; displays with unverified identities cannot be switched
- Upgrades retain legacy preset data; ambiguous legacy devices must be configured again. Choose an explicit angle when active rotation is needed; the app does not infer direction from resolution
- Cables, docks, mirroring, HDR, and macOS updates may invalidate saved modes

## License

Original code is licensed under the [Apache License 2.0](./LICENSE). Personal branding and assets are excluded. See [license scope](./LICENSE_SCOPE.md).
