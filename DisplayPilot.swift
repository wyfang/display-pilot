import AppKit
import CoreGraphics
import ServiceManagement

final class DisplayPresetRowView: NSBox {
    private var entry: DisplayPresetEntry
    private let display: DisplayInfo
    private var modes: [DisplayModeInfo]
    private let enabledButton: NSButton
    private let brightnessSlider: NSSlider
    private let contrastSlider: NSSlider
    private let brightnessValue = NSTextField(labelWithString: "")
    private let contrastValue = NSTextField(labelWithString: "")
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rotationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let geometryButton = NSButton(checkboxWithTitle: "应用分辨率与旋转", target: nil, action: nil)
    private let rotationHint = NSTextField(wrappingLabelWithString: "")
    var onChange: ((DisplayPresetEntry) -> Void)?

    init(display: DisplayInfo, entry: DisplayPresetEntry) {
        self.entry = entry
        self.display = display
        modes = []

        enabledButton = NSButton(checkboxWithTitle: display.name, target: nil, action: nil)
        brightnessSlider = NSSlider(value: entry.brightness * 100, minValue: 0, maxValue: 100, target: nil, action: nil)
        contrastSlider = NSSlider(value: entry.contrast * 100, minValue: -90, maxValue: 90, target: nil, action: nil)
        super.init(frame: .zero)

        boxType = .custom
        borderColor = .separatorColor
        borderWidth = 1
        cornerRadius = 9
        contentViewMargins = NSSize(width: 14, height: 12)
        titlePosition = .noTitle
        buildUI(display: display)
        updateControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI(display: DisplayInfo) {
        guard let contentView else { return }
        enabledButton.target = self
        enabledButton.action = #selector(enabledChanged)
        enabledButton.font = .systemFont(ofSize: 14, weight: .semibold)

        let status = NSTextField(labelWithString: display.active ? "当前已开启" : "当前已关闭")
        status.textColor = .secondaryLabelColor
        status.alignment = .right

        let header = NSStackView(views: [enabledButton, status])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill

        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessChanged)
        brightnessSlider.identifier = NSUserInterfaceItemIdentifier("presetBrightness")
        contrastSlider.target = self
        contrastSlider.action = #selector(contrastChanged)
        for value in [brightnessValue, contrastValue] {
            value.alignment = .right
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }

        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        modePopup.identifier = NSUserInterfaceItemIdentifier("presetMode")
        rotationPopup.target = self
        rotationPopup.action = #selector(rotationChanged)
        rotationPopup.identifier = NSUserInterfaceItemIdentifier("presetRotation")
        rotationPopup.addItem(withTitle: "跟随当前")
        for angle in DisplayRotation.angles {
            let item = NSMenuItem(title: "\(angle)°", action: nil, keyEquivalent: "")
            item.representedObject = NSNumber(value: angle)
            rotationPopup.menu?.addItem(item)
        }
        rebuildModePopup()
        geometryButton.target = self
        geometryButton.action = #selector(geometryChanged)
        geometryButton.identifier = NSUserInterfaceItemIdentifier("presetGeometry")

        let grid = NSGridView(views: [
            [fieldLabel("亮度"), brightnessSlider, brightnessValue],
            [fieldLabel("对比度调整"), contrastSlider, contrastValue],
            [fieldLabel("显示模式"), geometryButton, NSView()],
            [fieldLabel("旋转"), rotationPopup, NSView()],
            [fieldLabel("分辨率"), modePopup, NSView()]
        ])
        grid.column(at: 0).width = 88
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 2).width = 54
        grid.rowSpacing = 10
        grid.columnSpacing = 10

        let hint = NSTextField(wrappingLabelWithString: "对比度 0% 为默认；负值更柔和，正值更强烈。")
        hint.textColor = .tertiaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        rotationHint.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [header, grid, rotationHint, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rotationHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func fieldLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return label
    }

    private func modeForSelectedRotation(_ mode: DisplayModeInfo) -> DisplayModeInfo {
        guard let source = display.rotation, let target = entry.rotation else { return mode }
        return mode.rotated(from: source, to: target)
    }

    private func rebuildModePopup() {
        let available = display.availableModes.map(modeForSelectedRotation)
        modes = available
        if let saved = entry.mode, saved.matchingMode(in: modes) == nil { modes.append(saved) }
        modePopup.removeAllItems()
        modePopup.addItem(withTitle: "保持当前")
        for mode in modes {
            let unavailable = mode.matchingMode(in: available) == nil
            let pendingRotation = entry.rotation != nil && entry.rotation != display.rotation
            let suffix = unavailable ? " · 当前不可用" : (pendingRotation ? " · 旋转后可选" : "")
            let item = NSMenuItem(title: mode.label + suffix, action: nil, keyEquivalent: "")
            item.representedObject = mode
            modePopup.menu?.addItem(item)
        }
        let selected = entry.mode
        if let selected, let index = modes.firstIndex(where: { $0.describesSameMode(as: selected) }) {
            modePopup.selectItem(at: index + 1)
        } else { modePopup.selectItem(at: 0) }
    }

    private func updateControls() {
        enabledButton.state = entry.enabled ? .on : .off
        brightnessSlider.doubleValue = entry.brightness * 100
        contrastSlider.doubleValue = entry.contrast * 100
        brightnessValue.stringValue = "\(Int(brightnessSlider.doubleValue.rounded()))%"
        let contrast = Int(contrastSlider.doubleValue.rounded())
        contrastValue.stringValue = contrast > 0 ? "+\(contrast)%" : "\(contrast)%"
        brightnessSlider.isEnabled = entry.enabled
        contrastSlider.isEnabled = entry.enabled
        geometryButton.state = entry.controlsGeometry ? .on : .off
        geometryButton.isEnabled = entry.enabled && entry.brightness > 0
        modePopup.isEnabled = entry.enabled && entry.controlsGeometry
        rotationPopup.isEnabled = entry.enabled && entry.controlsGeometry
        rotationPopup.selectItem(at: entry.rotation.flatMap { DisplayRotation.angles.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
        if entry.brightness == 0 {
            rotationHint.stringValue = "亮度为 0 时跳过分辨率与旋转，仅应用连接、亮度和对比度。已保存的显示模式设置会保留，调高亮度后可继续使用。"
            rotationHint.textColor = .secondaryLabelColor
        } else if !entry.controlsGeometry {
            rotationHint.stringValue = "仅调整连接、亮度和对比度；已保存的分辨率与旋转设置仍会保留。"
            rotationHint.textColor = .tertiaryLabelColor
        } else if entry.rotation == nil, let saved = entry.mode, let current = display.currentMode,
           !saved.hasSameOrientation(as: current) {
            rotationHint.stringValue = "已保存分辨率与当前屏幕方向不同，请选择旋转角度；竖屏需明确选择 90° 或 270°。"
            rotationHint.textColor = .systemOrange
        } else {
            rotationHint.stringValue = "跟随当前保留屏幕方向；修改旋转角度需要 BetterDisplay Pro 支持。"
            rotationHint.textColor = .tertiaryLabelColor
        }
    }

    private func publishChange() {
        updateControls()
        onChange?(entry)
    }

    @objc private func enabledChanged() {
        entry.enabled = enabledButton.state == .on
        publishChange()
    }

    @objc private func brightnessChanged() {
        entry.brightness = brightnessSlider.doubleValue / 100
        publishChange()
    }

    @objc private func contrastChanged() {
        entry.contrast = contrastSlider.doubleValue / 100
        publishChange()
    }

    @objc private func geometryChanged() {
        entry.applyGeometry = geometryButton.state == .on
        publishChange()
    }

    @objc private func modeChanged() {
        entry.mode = modePopup.selectedItem?.representedObject as? DisplayModeInfo
        publishChange()
    }

    @objc private func rotationChanged() {
        let selected = (rotationPopup.selectedItem?.representedObject as? NSNumber)?.intValue
        let target = selected ?? display.rotation
        if let saved = entry.mode, let target {
            if let original = entry.rotation {
                entry.mode = saved.rotated(from: original, to: target)
            } else if let current = display.currentMode, let source = display.rotation {
                let reference = current.rotated(from: source, to: target)
                if !saved.hasSameOrientation(as: reference) {
                    // This transforms only geometry to the explicitly selected
                    // orientation; it never guesses a missing 90/270 degree angle.
                    entry.mode = saved.rotated(from: 0, to: 90)
                }
            }
        }
        entry.rotation = selected
        rebuildModePopup()
        publishChange()
    }
}

final class PresetWindowController: NSWindowController, NSTextFieldDelegate {
    private let store: PresetStore
    private let displayProvider: () -> [DisplayInfo]
    private let segmented = NSSegmentedControl(labels: ["预设 A", "预设 B"], trackingMode: .selectOne, target: nil, action: nil)
    private let nameField = NSTextField(string: "")
    private let listStack = NSStackView()
    private var displays: [DisplayInfo] = []
    private var draft = PresetCollection(
        presetA: DisplayPreset(name: "预设 A", displays: []),
        presetB: DisplayPreset(name: "预设 B", displays: [])
    )
    var onSave: (() -> Void)?
    var canSave: () -> Bool = { true }
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)

    func setSavingEnabled(_ enabled: Bool) { saveButton.isEnabled = enabled }

    init(store: PresetStore, displayProvider: @escaping () -> [DisplayInfo]) {
        self.store = store
        self.displayProvider = displayProvider
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 690, height: 590),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "编辑显示器预设"
        window.minSize = NSSize(width: 620, height: 440)
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        if window?.isVisible == true {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        displays = displayProvider()
        draft = store.load(displays: displays)
        if segmented.selectedSegment < 0 { segmented.selectedSegment = 0 }
        updateSegmentLabels()
        rebuildRows()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(segmentChanged)

        let nameLabel = NSTextField(labelWithString: "名称")
        nameField.placeholderString = "输入预设名称"
        nameField.delegate = self
        let header = NSStackView(views: [segmented, nameLabel, nameField])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        let description = NSTextField(wrappingLabelWithString: "为每块显示器分别保存开关状态、亮度、对比度调整、旋转和分辨率。菜单栏中可用 ⌘1 / ⌘2 一键切换。")
        description.textColor = .secondaryLabelColor

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 12
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 2),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -10),
            listStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8)
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = document

        let save = saveButton
        save.target = self
        save.action = #selector(savePressed)
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelPressed))
        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        for view in [header, description, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            segmented.widthAnchor.constraint(equalToConstant: 250),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            description.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            description.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            description.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
    }

    private func rebuildRows() {
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let preset = selectedPreset
        nameField.stringValue = preset.name
        if displays.isEmpty && preset.displays.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "未检测到显示器。连接显示器后重新打开此窗口。")
            empty.textColor = .secondaryLabelColor
            listStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            return
        }

        let knownIdentities = Set(displays.map(\.identity))
        let unresolved = preset.displays.filter { !knownIdentities.contains($0.identity) }.map { entry in
            DisplayInfo(id: 0, name: entry.name + " · 待重新绑定", active: false, builtin: false,
                        identity: entry.identity, currentMode: nil, availableModes: [], canControl: false)
        }
        for display in displays + unresolved {
            guard let entry = preset.displays.first(where: { $0.identity == display.identity }) else { continue }
            let row = DisplayPresetRowView(display: display, entry: entry)
            row.onChange = { [weak self] updated in
                self?.updateSelectedPresetEntry(updated)
            }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    private var selectedPreset: DisplayPreset {
        segmented.selectedSegment == 1 ? draft.presetB : draft.presetA
    }

    private func updateSelectedPresetEntry(_ entry: DisplayPresetEntry) {
        if segmented.selectedSegment == 1 {
            guard let index = draft.presetB.displays.firstIndex(where: { $0.identity == entry.identity }) else { return }
            draft.presetB.displays[index] = entry
        } else {
            guard let index = draft.presetA.displays.firstIndex(where: { $0.identity == entry.identity }) else { return }
            draft.presetA.displays[index] = entry
        }
    }

    @objc private func segmentChanged() { rebuildRows() }

    func controlTextDidChange(_ notification: Notification) {
        if segmented.selectedSegment == 1 {
            draft.presetB.name = nameField.stringValue
        } else {
            draft.presetA.name = nameField.stringValue
        }
        updateSegmentLabels()
    }

    private func updateSegmentLabels() {
        let nameA = draft.presetA.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameB = draft.presetB.name.trimmingCharacters(in: .whitespacesAndNewlines)
        segmented.setLabel(nameA.isEmpty ? "预设 A" : nameA, forSegment: 0)
        segmented.setLabel(nameB.isEmpty ? "预设 B" : nameB, forSegment: 1)
    }

    @objc private func savePressed() {
        guard canSave() else { return }
        window?.makeFirstResponder(nil)
        draft.presetA.name = draft.presetA.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.presetB.name = draft.presetB.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.presetA.name.isEmpty { draft.presetA.name = "预设 A" }
        if draft.presetB.name.isEmpty { draft.presetB.name = "预设 B" }
        guard draft.presetA.displays.contains(where: \.enabled),
              draft.presetB.displays.contains(where: \.enabled) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "每个预设至少要开启一块显示器"
            alert.informativeText = "这样可以避免应用预设后出现黑屏。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        store.save(draft)
        UserDefaults.standard.removeObject(forKey: "lastAppliedPreset")
        window?.close()
        onSave?()
    }

    @objc private func cancelPressed() { window?.close() }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let displayController = DisplayController()
    private let presetStore = PresetStore()
    private let betterDisplay = BetterDisplayBridge()
    private var statusItem: NSStatusItem!
    private var presetWindow: PresetWindowController!
    private var applyingPreset = false
    private var displayChangeObserver: NSObjectProtocol?
    private var refreshWork: DispatchWorkItem?
    private lazy var presetApplication = PresetApplication(dependencies: .init(
        displays: { [unowned self] includeModes in self.displayController.displays(includeModes: includeModes) },
        setEnabled: { [unowned self] enabled, identity in self.displayController.setEnabled(enabled, identity: identity) },
        setModes: { [unowned self] requests in self.displayController.setModes(requests) },
        setVisual: { [unowned self] brightness, contrast, id, completion in
            self.betterDisplay.setVisualSettings(brightness: brightness, contrast: contrast, displayID: id, completion: completion)
        },
        verifyVisual: { [unowned self] brightness, contrast, id, completion in
            self.betterDisplay.verifyVisualSettings(brightness: brightness, contrast: contrast, displayID: id, completion: completion)
        },
        schedule: { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) },
        setRotation: { [unowned self] rotation, identity, completion in
            guard let display = self.displayController.resolveDisplay(identity: identity), display.active else {
                completion(.failure(AppFailure(message: "无法核实旋转目标显示器，或显示器尚未连接。")))
                return
            }
            self.betterDisplay.setRotation(rotation: rotation, displayID: display.id, isCurrentDisplay: { [weak self] in
                guard let current = self?.displayController.resolveDisplay(identity: identity) else { return false }
                return current.active && current.id == display.id
            }, completion: completion)
        }
    ))

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["presetA": 0.35, "presetB": 0.80])
        presetWindow = PresetWindowController(store: presetStore) { [weak self] in
            self?.displayController.displays() ?? []
        }
        presetWindow.onSave = { [weak self] in self?.rebuildMenu() }
        presetWindow.canSave = { [weak self] in self?.applyingPreset == false }
        // Persisted checks cannot prove the current BetterDisplay state after a restart.
        UserDefaults.standard.removeObject(forKey: "lastAppliedPreset")
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refreshWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.rebuildMenu() }
            self.refreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Display Pilot")
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu(menu) }

    private func rebuildMenu(_ existingMenu: NSMenu? = nil) {
        let menu = existingMenu ?? NSMenu()
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.delegate = self
        let title = NSMenuItem(title: "显示器连接", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let displays = displayController.displays(includeModes: false)
        if displays.isEmpty {
            let empty = NSMenuItem(title: "未检测到显示器", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for display in displays {
                let state = display.active ? "已连接" : (display.canControl ? "已断开" : "离线 · 请重新连接")
                let item = NSMenuItem(title: "\(display.name) · \(state)", action: #selector(toggleDisplay(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = display.identity
                item.state = display.active ? .on : .off
                item.isEnabled = !applyingPreset && display.canControl
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let presets = presetStore.load(displays: displays)
        var lastApplied = UserDefaults.standard.string(forKey: "lastAppliedPreset")
        if let slot = lastApplied {
            let preset = slot == "B" ? presets.presetB : presets.presetA
            if !PresetApplication.configurationErrors(for: preset, displays: displays).isEmpty {
                UserDefaults.standard.removeObject(forKey: "lastAppliedPreset")
                lastApplied = nil
            }
        }
        let a = actionItem(presetMenuTitle(presets.presetA), #selector(applyPresetA), key: "1")
        let b = actionItem(presetMenuTitle(presets.presetB), #selector(applyPresetB), key: "2")
        a.state = lastApplied == "A" ? .on : .off
        b.state = lastApplied == "B" ? .on : .off
        a.isEnabled = !applyingPreset
        b.isEnabled = !applyingPreset
        menu.addItem(a)
        menu.addItem(b)
        if applyingPreset {
            let progress = NSMenuItem(title: "正在应用预设…", action: nil, keyEquivalent: "")
            progress.isEnabled = false
            menu.addItem(progress)
        }
        let edit = actionItem("编辑预设…", #selector(openPresetSettings))
        edit.isEnabled = !applyingPreset
        menu.addItem(edit)

        menu.addItem(.separator())
        menu.addItem(actionItem("刷新显示器", #selector(refresh), key: "r"))
        menu.addItem(actionItem("打开 BetterDisplay", #selector(openBetterDisplay)))
        menu.addItem(launchAtLoginMenuItem())
        menu.addItem(.separator())
        menu.addItem(actionItem("退出 Display Pilot", #selector(quit), key: "q"))
        if existingMenu == nil { statusItem.menu = menu }
    }

    private func presetMenuTitle(_ preset: DisplayPreset) -> String {
        preset.name
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard !applyingPreset,
              let identity = sender.representedObject as? String,
              let display = displayController.displays(includeModes: false).first(where: { $0.identity == identity }) else { return }
        switch displayController.setEnabled(!display.active, identity: identity) {
        case .success:
            UserDefaults.standard.removeObject(forKey: "lastAppliedPreset")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.rebuildMenu() }
        case .failure(let error): showError(error.message)
        }
    }

    @objc private func applyPresetA() { applyPreset(slot: "A") }
    @objc private func applyPresetB() { applyPreset(slot: "B") }

    private func applyPreset(slot: String) {
        guard !applyingPreset else { return }
        let displays = displayController.displays(includeModes: false)
        let collection = presetStore.load(displays: displays)
        let preset = slot == "B" ? collection.presetB : collection.presetA
        guard preset.displays.contains(where: \.enabled) else {
            showError("\(preset.name) 没有设置要开启的显示器，请先编辑预设。")
            return
        }
        applyingPreset = true
        presetWindow.setSavingEnabled(false)
        UserDefaults.standard.removeObject(forKey: "lastAppliedPreset")
        rebuildMenu()
        presetApplication.apply(preset) { [weak self] errors in
            guard let self else { return }
            var errors = errors
            let saved = self.presetStore.load(displays: self.displayController.displays(includeModes: false))
            if !PresetApplication.settingsUnchanged(executed: preset, saved: slot == "B" ? saved.presetB : saved.presetA) {
                errors.append("预设在应用过程中已变化，请重新应用。")
            }
            self.applyingPreset = false
            self.presetWindow.setSavingEnabled(true)
            if errors.isEmpty { UserDefaults.standard.set(slot, forKey: "lastAppliedPreset") }
            else { UserDefaults.standard.removeObject(forKey: "lastAppliedPreset") }
            self.rebuildMenu()
            if !errors.isEmpty { self.showError(errors.joined(separator: "\n")) }
        }
    }

    private func launchAtLoginMenuItem() -> NSMenuItem {
        let service = SMAppService.mainApp
        let title: String
        switch service.status {
        case .requiresApproval:
            title = "开机自启动（需在系统设置中允许）"
        default:
            title = "开机自启动"
        }
        let item = actionItem(title, #selector(toggleLaunchAtLogin))
        item.state = service.status == .enabled ? .on : (service.status == .requiresApproval ? .mixed : .off)
        return item
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notRegistered, .notFound:
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            @unknown default:
                try service.register()
            }
            rebuildMenu()
        } catch {
            showError("无法修改开机自启动设置：\(error.localizedDescription)")
        }
    }

    @objc private func openPresetSettings() {
        guard !applyingPreset else { return }
        presetWindow.present()
    }
    @objc private func refresh() { rebuildMenu() }
    @objc private func openBetterDisplay() {
        betterDisplay.openApp { [weak self] result in
            if case .failure(let error) = result { self?.showError(error.message) }
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "操作没有完成"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

#if !TESTING
@main
private enum DisplayPilotApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
#endif
