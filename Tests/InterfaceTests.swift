import AppKit

@main
private enum InterfaceTests {
    private final class Memory: PreferenceStorage {
        var values: [String: Any] = [:]
        func data(forKey key: String) -> Data? { values[key] as? Data }
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
    }
    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let one = DisplayModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60)
        let two = DisplayModeInfo(width: 1920, height: 1080, pixelWidth: 5760, pixelHeight: 3240, refreshRate: 60)
        let three = DisplayModeInfo(width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720, refreshRate: 60)
        precondition(one.label == two.label)
        let display = DisplayInfo(id: 1, name: "Screen", active: true, builtin: false, identity: "screen",
                                  currentMode: one, availableModes: [one, two, three], rotation: 0)
        let entry = DisplayPresetEntry(identity: "screen", name: "Screen", enabled: true, brightness: 0.5, contrast: 0, mode: three)
        let row = DisplayPresetRowView(display: display, entry: entry)
        let popups = descendants(row).compactMap { $0 as? NSPopUpButton }
        let popup = popups.first { $0.identifier?.rawValue == "presetMode" }!
        let rotation = popups.first { $0.identifier?.rawValue == "presetRotation" }!
        precondition(popup.numberOfItems == 4 && popup.indexOfSelectedItem == 3)
        var changed: DisplayPresetEntry?
        row.onChange = { changed = $0 }
        popup.selectItem(at: 2)
        _ = popup.sendAction(popup.action, to: popup.target)
        precondition(changed?.mode == two, "mode represented object preserves duplicate labels")
        rotation.selectItem(withTitle: "90°")
        _ = rotation.sendAction(rotation.action, to: rotation.target)
        precondition(changed?.rotation == 90 && changed?.mode == two.rotated(from: 0, to: 90),
                     "explicit rotation transposes selected logical and backing dimensions")
        precondition((popup.item(at: 1)?.representedObject as? DisplayModeInfo) == one.rotated(from: 0, to: 90),
                     "resolution list follows selected rotation")
        rotation.selectItem(withTitle: "270°")
        _ = rotation.sendAction(rotation.action, to: rotation.target)
        precondition(changed?.rotation == 270 && changed?.mode == two.rotated(from: 0, to: 90),
                     "switching between portrait angles preserves geometry")
        rotation.selectItem(withTitle: "跟随当前")
        _ = rotation.sendAction(rotation.action, to: rotation.target)
        precondition(changed?.rotation == nil && changed?.mode == two, "follow-current restores current orientation without fixing an angle")
        popup.selectItem(withTitle: "保持当前")
        _ = popup.sendAction(popup.action, to: popup.target)
        precondition(changed?.mode == nil, "keep-current resolution explicitly clears mode")
        rotation.selectItem(withTitle: "90°")
        _ = rotation.sendAction(rotation.action, to: rotation.target)
        precondition(changed?.mode == nil && popup.indexOfSelectedItem == 0, "rotation edits do not silently learn an unspecified resolution")
        var ambiguousEntry = entry
        ambiguousEntry.mode = three.rotated(from: 0, to: 90)
        let ambiguous = DisplayPresetRowView(display: display, entry: ambiguousEntry)
        precondition(descendants(ambiguous).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("请选择旋转角度") },
                     "unknown portrait angle is explained instead of guessed")
        let ambiguousRotation = descendants(ambiguous).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "presetRotation" }!
        var resolved: DisplayPresetEntry?
        ambiguous.onChange = { resolved = $0 }
        ambiguousRotation.selectItem(withTitle: "270°")
        _ = ambiguousRotation.sendAction(ambiguousRotation.action, to: ambiguousRotation.target)
        precondition(resolved?.rotation == 270 && resolved?.mode == ambiguousEntry.mode,
                     "choosing the unknown portrait angle preserves the existing portrait resolution")
        for preference in [nil, true, false] as [Bool?] {
            var blackoutEntry = ambiguousEntry
            blackoutEntry.brightness = 0
            blackoutEntry.rotation = 270
            blackoutEntry.applyGeometry = preference
            let blackout = DisplayPresetRowView(display: display, entry: blackoutEntry)
            let controls = descendants(blackout)
            let geometry = controls.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "presetGeometry" }!
            let blackoutMode = controls.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "presetMode" }!
            let blackoutRotation = controls.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "presetRotation" }!
            let brightness = controls.compactMap { $0 as? NSSlider }.first { $0.identifier?.rawValue == "presetBrightness" }!
            precondition(geometry.state == .off && !geometry.isEnabled && !blackoutMode.isEnabled && !blackoutRotation.isEnabled,
                         "blackout disables all geometry controls even when the stored choice is explicitly true")
            precondition((blackoutMode.selectedItem?.representedObject as? DisplayModeInfo) == blackoutEntry.mode
                         && blackoutRotation.titleOfSelectedItem == "270°", "disabled geometry controls retain saved selections")
            precondition(controls.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("亮度为 0 时跳过分辨率与旋转") },
                         "blackout explains why geometry is suspended")
            var blackoutChange: DisplayPresetEntry?
            blackout.onChange = { blackoutChange = $0 }
            brightness.doubleValue = 65
            _ = brightness.sendAction(brightness.action, to: brightness.target)
            let appliesGeometry = preference ?? true
            precondition(geometry.isEnabled && geometry.state == (appliesGeometry ? .on : .off)
                         && blackoutMode.isEnabled == appliesGeometry && blackoutRotation.isEnabled == appliesGeometry,
                         "raising brightness restores the explicit true, false or legacy geometry policy")
            precondition(blackoutChange?.brightness == 0.65 && blackoutChange?.applyGeometry == preference
                         && blackoutChange?.mode == blackoutEntry.mode && blackoutChange?.rotation == 270,
                         "raising brightness preserves the stored geometry data")
            brightness.doubleValue = 0
            _ = brightness.sendAction(brightness.action, to: brightness.target)
            precondition(blackoutChange == blackoutEntry && !geometry.isEnabled && !blackoutMode.isEnabled && !blackoutRotation.isEnabled,
                         "returning to blackout suspends geometry without modifying saved fields")
            let encoded = try! JSONEncoder().encode(blackoutChange!)
            let decoded = try! JSONDecoder().decode(DisplayPresetEntry.self, from: encoded)
            precondition(decoded == blackoutEntry && !decoded.controlsGeometry, "blackout editor roundtrip preserves geometry without applying it")
        }
        let memory = Memory()
        let store = PresetStore(defaults: memory)
        let controller = PresetWindowController(store: store) { [display] }
        controller.present()
        let nameField = descendants(controller.window!.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        nameField.stringValue = "Unsaved draft"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: nameField))
        controller.present()
        precondition(nameField.stringValue == "Unsaved draft", "reopening visible settings preserves draft")
        let before = memory.data(forKey: "displayPresetsV5")
        controller.canSave = { false }
        let save = descendants(controller.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "保存" }!
        _ = save.sendAction(save.action, to: save.target)
        precondition(memory.data(forKey: "displayPresetsV5") == before, "save handler enforces operation lock")
        controller.setSavingEnabled(false)
        precondition(!save.isEnabled)
        controller.window?.close()
        print("Interface: duplicate labels, rotation, blackout geometry suspension, draft preservation and save lock passed")
    }
}
