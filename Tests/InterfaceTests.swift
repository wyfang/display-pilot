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
                                  currentMode: one, availableModes: [one, two, three])
        let entry = DisplayPresetEntry(identity: "screen", name: "Screen", enabled: true, brightness: 0.5, contrast: 0, mode: three)
        let row = DisplayPresetRowView(display: display, entry: entry)
        let popup = descendants(row).compactMap { $0 as? NSPopUpButton }.first!
        precondition(popup.numberOfItems == 3 && popup.indexOfSelectedItem == 2)
        var changed: DisplayPresetEntry?
        row.onChange = { changed = $0 }
        popup.selectItem(at: 1)
        _ = popup.sendAction(popup.action, to: popup.target)
        precondition(changed?.mode == two, "mode represented object preserves duplicate labels")
        let memory = Memory()
        let store = PresetStore(defaults: memory)
        let controller = PresetWindowController(store: store) { [display] }
        controller.present()
        let nameField = descendants(controller.window!.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        nameField.stringValue = "Unsaved draft"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: nameField))
        controller.present()
        precondition(nameField.stringValue == "Unsaved draft", "reopening visible settings preserves draft")
        let before = memory.data(forKey: "displayPresetsV4")
        controller.canSave = { false }
        let save = descendants(controller.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "保存" }!
        _ = save.sendAction(save.action, to: save.target)
        precondition(memory.data(forKey: "displayPresetsV4") == before, "save handler enforces operation lock")
        controller.setSavingEnabled(false)
        precondition(!save.isEnabled)
        controller.window?.close()
        print("Interface: duplicate labels, draft preservation and save lock passed")
    }
}
