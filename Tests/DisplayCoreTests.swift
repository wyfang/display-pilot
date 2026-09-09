import AppKit

private final class CoreMemoryPreferences: PreferenceStorage {
    var values: [String: Any] = [:]
    var writes: [String] = []
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value; writes.append(key) }
}

private final class CoreFakeBackend: DisplayBackend {
    var online: [DisplayInfo] = []
    var resolved: [String: DisplayInfo] = [:]
    var legacyResolved: [UInt32: DisplayInfo] = [:]
    var rememberedResolved: [String: DisplayInfo] = [:]
    var rememberedCalls: [StoredDisplay] = []
    var enabledCalls: [(Bool, String, UInt32)] = []
    var modeCalls: [(DisplayModeInfo, String)] = []
    var modeEnumerationCount = 0
    func snapshots(includeModes: Bool) -> [DisplayInfo] {
        if includeModes { modeEnumerationCount += 1 }
        return online
    }
    func resolve(identity: String, includeModes: Bool) -> DisplayInfo? {
        if includeModes { modeEnumerationCount += 1 }
        return resolved[identity] ?? online.first { $0.identity == identity }
    }
    func resolveLegacy(identity: String, candidateID: UInt32, includeModes: Bool) -> DisplayInfo? {
        legacyResolved[candidateID]
    }
    func resolveRemembered(_ record: StoredDisplay, includeModes: Bool) -> DisplayInfo? {
        rememberedCalls.append(record)
        return rememberedResolved[record.identity]
    }
    func setEnabled(_ enabled: Bool, display: DisplayInfo) -> Result<Void, AppFailure> {
        enabledCalls.append((enabled, display.identity, display.id))
        return .success(())
    }
    func setModes(_ requests: [(mode: DisplayModeInfo, identity: String)]) -> [String: AppFailure] {
        modeCalls += requests.map { ($0.mode, $0.identity) }
        return [:]
    }
}

private struct CoreTestFailure: Error { let message: String }
private func coreExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CoreTestFailure(message: message) }
}
private let coreMode = DisplayModeInfo(modeID: 11, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60)
private func coreScreen(_ id: UInt32, _ identity: String, legacy: String = "external-10-20-123", active: Bool = true) -> DisplayInfo {
    DisplayInfo(id: id, name: "Display \(id)", active: active, builtin: false, identity: identity,
                currentMode: coreMode, availableModes: [coreMode], legacyIdentity: legacy)
}
private func coreEntry(_ identity: String, brightness: Double = 0.377, contrast: Double = 0.12, enabled: Bool = true) -> DisplayPresetEntry {
    DisplayPresetEntry(identity: identity, name: "Saved screen", enabled: enabled, brightness: brightness, contrast: contrast, mode: coreMode)
}

@main
struct DisplayCoreTests {
    static func main() throws { try run() }

    static func run() throws {
        // The old ID now belongs to a different screen. No operation may reach it.
        do {
            let defaults = CoreMemoryPreferences()
            let old = StoredDisplay(id: 7, name: "Old screen", builtin: false, identity: "uuid:old")
            let oldData = try JSONEncoder().encode([old])
            defaults.values["knownDisplaysV1"] = oldData
            let backend = CoreFakeBackend(); backend.online = [coreScreen(7, "uuid:new")]
            let controller = DisplayController(defaults: defaults, backend: backend)
            let displays = controller.displays(includeModes: false)
            let remembered = displays.first { $0.identity == "uuid:old" }
            try coreExpect(remembered?.id == 0 && remembered?.canControl == false, "offline record exposes no stale ID")
            if case .success = controller.setEnabled(true, identity: "uuid:old") { throw CoreTestFailure(message: "stale ID accepted") }
            try coreExpect(backend.enabledCalls.isEmpty, "reused ID must never reach hardware")
            try coreExpect(defaults.data(forKey: "knownDisplaysV1") == oldData, "legacy cache backup unchanged")
            let stored = try JSONDecoder().decode([StoredDisplay].self, from: defaults.data(forKey: "knownDisplaysV3")!)
            try coreExpect(Set(stored.map(\.identity)) == ["uuid:old", "uuid:new"], "ID reuse must not overwrite another identity")
        }
        // A software-disabled screen can be reconnected through a verified UUID
        // resolution even when absent from the current online list.
        do {
            let defaults = CoreMemoryPreferences(); let backend = CoreFakeBackend()
            backend.online = [coreScreen(8, "uuid:spare")]
            backend.resolved["uuid:disabled"] = coreScreen(42, "uuid:disabled", active: false)
            let controller = DisplayController(defaults: defaults, backend: backend)
            _ = controller.setEnabled(true, identity: "uuid:disabled")
            try coreExpect(backend.enabledCalls.count == 1 && backend.enabledCalls[0].2 == 42, "reconnect uses fresh resolved ID")
            backend.resolved["uuid:disabled"] = coreScreen(42, "uuid:other", active: false)
            _ = controller.setEnabled(true, identity: "uuid:disabled")
            try coreExpect(backend.enabledCalls.count == 1, "reject resolver identity mismatch")
            _ = controller.setEnabled(false, identity: "uuid:spare")
            try coreExpect(backend.enabledCalls.count == 1, "protect last active display")
        }
        // UUID distinguishes serial-zero siblings; a duplicate UUID is quarantined.
        do {
            let a = coreScreen(1, "uuid:a", legacy: "external-10-20-0")
            let b = coreScreen(2, "uuid:b", legacy: "external-10-20-0")
            let distinct = DisplayIdentity.protectConflicts([a, b])
            try coreExpect(Set(distinct.map(\.identity)).count == 2 && distinct.allSatisfy(\.canControl), "same-model serial-zero displays stay distinct")
            let collision = DisplayIdentity.protectConflicts([a, coreScreen(2, "uuid:a", legacy: "external-10-20-0")])
            try coreExpect(collision.allSatisfy { !$0.canControl }, "duplicate persistent identity must not control either screen")
        }
        // V1 and V2 preset keys migrate without losing any user settings or backups.
        for oldKey in ["displayPresetsV1", "displayPresetsV2"] {
            let defaults = CoreMemoryPreferences()
            let a = coreEntry("external-10-20-123-9")
            let b = coreEntry("external-10-20-456", brightness: 0.82, contrast: 0.3, enabled: false)
            let original = PresetCollection(presetA: DisplayPreset(name: "办公", displays: [a, b]),
                                            presetB: DisplayPreset(name: "观影", displays: [b, a]))
            let oldData = try JSONEncoder().encode(original); defaults.values[oldKey] = oldData
            let displays = [coreScreen(11, "uuid:a"), coreScreen(12, "uuid:b", legacy: "external-10-20-456")]
            let migrated = PresetStore(defaults: defaults).load(displays: displays)
            try coreExpect(migrated.presetA.name == "办公" && migrated.presetB.name == "观影", "preset names preserved")
            for (before, after) in [(original.presetA, migrated.presetA), (original.presetB, migrated.presetB)] {
                try coreExpect(after.displays.count == before.displays.count, "migration does not duplicate screens")
                for entry in before.displays {
                    let target = entry.identity.contains("123") ? "uuid:a" : "uuid:b"
                    let result = after.displays.first { $0.identity == target }!
                    try coreExpect(result.enabled == entry.enabled && result.brightness == entry.brightness && result.contrast == entry.contrast && result.mode == entry.mode, "migration preserves enabled, brightness, contrast and mode")
                }
            }
            try coreExpect(defaults.data(forKey: oldKey) == oldData, "old preset key remains byte-identical")
        }
        // Ambiguous legacy data is retained verbatim instead of guessing a binding.
        do {
            let defaults = CoreMemoryPreferences()
            let old = coreEntry("external-10-20-0", brightness: 0.33)
            let original = PresetCollection(presetA: DisplayPreset(name: "A", displays: [old]), presetB: DisplayPreset(name: "B", displays: [old]))
            defaults.values["displayPresetsV2"] = try JSONEncoder().encode(original)
            let displays = [coreScreen(1, "uuid:a", legacy: "external-10-20-0"), coreScreen(2, "uuid:b", legacy: "external-10-20-0")]
            let result = PresetStore(defaults: defaults).load(displays: displays)
            try coreExpect(result.presetA.displays.contains(old), "retain ambiguous original settings")
            try coreExpect(DisplayIdentity.migrationTarget(for: old.identity, displays: [displays[0]]) == nil, "serial-zero legacy mapping remains unsafe even with one sibling present")
        }
        // Conflicting old entries are not merged and silently discarded.
        do {
            let defaults = CoreMemoryPreferences()
            let entries = [coreEntry("external-10-20-123-1", brightness: 0.2), coreEntry("external-10-20-123-2", brightness: 0.7)]
            let original = PresetCollection(presetA: DisplayPreset(name: "A", displays: entries), presetB: DisplayPreset(name: "B", displays: entries))
            defaults.values["displayPresetsV2"] = try JSONEncoder().encode(original)
            let result = PresetStore(defaults: defaults).load(displays: [coreScreen(1, "uuid:a")])
            try coreExpect(entries.allSatisfy { result.presetA.displays.contains($0) }, "conflicting settings remain recoverable")
        }
        // Cache migration never uses old numeric IDs and repeated lightweight reads don't write.
        do {
            let defaults = CoreMemoryPreferences(); let backend = CoreFakeBackend()
            let old = StoredDisplay(id: 900, name: "Old name", builtin: false, identity: "external-10-20-123-7")
            let oldData = try JSONEncoder().encode([old]); defaults.values["knownDisplaysV1"] = oldData
            backend.online = [coreScreen(12, "uuid:a")]
            let controller = DisplayController(defaults: defaults, backend: backend)
            let migrated = controller.displays(includeModes: false)
            try coreExpect(migrated.count == 1 && migrated[0].identity == "uuid:a", "unique nonzero legacy cache migrates")
            let writes = defaults.writes.count
            _ = controller.displays(includeModes: false)
            try coreExpect(defaults.writes.count == writes && backend.modeEnumerationCount == 0, "light snapshots neither enumerate modes nor rewrite unchanged cache")
            try coreExpect(defaults.data(forKey: "knownDisplaysV1") == oldData, "cache legacy bytes retained")
        }
        // Legacy software-disabled screens need a verified metadata lookup at
        // first migration; the cached number alone is never sufficient.
        do {
            let defaults = CoreMemoryPreferences(); let backend = CoreFakeBackend()
            let legacy = "external-10-20-123"
            defaults.values["knownDisplaysV1"] = try JSONEncoder().encode([
                StoredDisplay(id: 42, name: "Disabled", builtin: false, identity: legacy)
            ])
            let disabled = coreScreen(42, "uuid:disabled", active: false)
            backend.legacyResolved[42] = disabled
            backend.resolved["uuid:disabled"] = disabled
            let controller = DisplayController(defaults: defaults, backend: backend)
            let displays = controller.displays(includeModes: false)
            try coreExpect(displays.count == 1 && displays[0].identity == "uuid:disabled" && displays[0].canControl, "verified legacy disabled screen remains reconnectable")
            _ = controller.setEnabled(true, identity: "uuid:disabled")
            try coreExpect(backend.enabledCalls.count == 1, "migrated disabled screen resolves canonical identity before switching")
            let wrongDefaults = CoreMemoryPreferences()
            wrongDefaults.values["knownDisplaysV1"] = defaults.values["knownDisplaysV1"]
            backend.legacyResolved[42] = coreScreen(42, "uuid:wrong", legacy: "external-10-20-456", active: false)
            let refused = DisplayController(defaults: wrongDefaults, backend: backend).displays(includeModes: false)
            try coreExpect(refused.count == 1 && refused[0].identity == legacy && !refused[0].canControl, "mismatched hardware metadata never migrates")
        }
        // Selection and verification share exact logical/pixel geometry and refresh semantics.
        do {
            let loDPI = DisplayModeInfo(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60)
            let lowerRate = DisplayModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 30)
            try coreExpect(coreMode.matchingMode(in: [loDPI, lowerRate]) == nil, "no approximate fallback for missing HiDPI or refresh rate")
            let match = coreMode.matchingMode(in: [loDPI, coreMode])!
            try coreExpect(match.describesSameMode(as: coreMode), "every selected mode passes verification")
            let defaults = CoreMemoryPreferences(); let backend = CoreFakeBackend()
            backend.online = [coreScreen(1, "uuid:a")]
            let result = DisplayController(defaults: defaults, backend: backend).setModes([(coreMode, "uuid:missing"), (coreMode, "uuid:a")])
            try coreExpect(result["uuid:missing"] != nil && backend.modeCalls.count == 1 && backend.modeCalls[0].1 == "uuid:a", "mode commands also resolve the identity first")
        }
        // Anonymous system virtual screens must not become permanent preset
        // targets. Match hardware metadata, never a user-visible name or an ID.
        do {
            let defaults = CoreMemoryPreferences(); let backend = CoreFakeBackend()
            let physical = coreScreen(4, "uuid:physical")
            let virtual = coreScreen(14, "uuid:virtual", legacy: "external-1970170734-1986622068-0")
            backend.online = [physical, virtual]
            let oldCache = try JSONEncoder().encode([StoredDisplay(physical), StoredDisplay(virtual)])
            defaults.values["knownDisplaysV2"] = oldCache
            var physicalEntry = coreEntry(physical.identity, brightness: 0.5348591549295775)
            physicalEntry.name = physical.name
            let original = PresetCollection(presetA: DisplayPreset(name: "工作模式", displays: [physicalEntry, coreEntry(virtual.identity)]),
                                            presetB: DisplayPreset(name: "息屏模式", displays: [physicalEntry, coreEntry(virtual.identity)]))
            let oldPresets = try JSONEncoder().encode(original)
            defaults.values["displayPresetsV3"] = oldPresets
            let controller = DisplayController(defaults: defaults, backend: backend)
            let screens = controller.displays(includeModes: false)
            try coreExpect(screens.map(\.identity) == [physical.identity], "virtual screen excluded while online")
            if case .success = controller.setEnabled(true, identity: virtual.identity) { throw CoreTestFailure(message: "virtual target was controllable") }
            try coreExpect(backend.enabledCalls.isEmpty, "virtual screen never receives commands")
            let store = PresetStore(defaults: defaults)
            let result = store.load(displays: screens)
            try coreExpect(result.presetA.displays == [physicalEntry] && result.presetB.displays == [physicalEntry], "ghost target removed without changing physical settings")
            try coreExpect(defaults.data(forKey: "knownDisplaysV2") == oldCache && defaults.data(forKey: "displayPresetsV3") == oldPresets, "previous cache and presets remain byte-identical")
            backend.online = [physical]
            try coreExpect(controller.displays(includeModes: false).count == 1, "offline virtual record does not return")
            try coreExpect(store.load(displays: screens) == result, "migration is idempotent")
            try coreExpect(!DisplayIdentity.isAnonymousVirtual("external-1970170734-1986622068-123"), "nonzero-serial virtual displays are not guessed to be anonymous")
        }
        // Unknown/offline physical screens remain recoverable even when their
        // visible name is identical to the system's anonymous virtual display.
        do {
            let defaults = CoreMemoryPreferences(); let backend = CoreFakeBackend()
            let old = StoredDisplay(id: 14, name: "未知显示器", builtin: false, identity: "uuid:real", legacyIdentity: "external-10-20-0")
            defaults.values["knownDisplaysV2"] = try JSONEncoder().encode([old])
            let screens = DisplayController(defaults: defaults, backend: backend).displays(includeModes: false)
            try coreExpect(screens.count == 1 && screens[0].identity == old.identity, "physical offline record retained regardless of name")
            let entry = coreEntry(old.identity)
            let collection = PresetCollection(presetA: DisplayPreset(name: "A", displays: [entry]), presetB: DisplayPreset(name: "B", displays: [entry]))
            defaults.values["displayPresetsV3"] = try JSONEncoder().encode(collection)
            try coreExpect(PresetStore(defaults: defaults).load(displays: screens) == collection, "unresolved physical preset is never silently ignored")
        }
        // A pre-UUID virtual cache can already be offline at first launch.
        do {
            let defaults = CoreMemoryPreferences(); let backend = CoreFakeBackend()
            let virtualID = "external-1970170734-1986622068-0-14"
            let realID = "external-10-20-123-4"
            let cache = try JSONEncoder().encode([
                StoredDisplay(id: 14, name: "未知显示器", builtin: false, identity: virtualID),
                StoredDisplay(id: 4, name: "Real offline", builtin: false, identity: realID)
            ])
            defaults.values["knownDisplaysV1"] = cache
            let realEntry = coreEntry(realID)
            let original = PresetCollection(presetA: DisplayPreset(name: "A", displays: [coreEntry(virtualID), realEntry]),
                                            presetB: DisplayPreset(name: "B", displays: [coreEntry(virtualID), realEntry]))
            let presetData = try JSONEncoder().encode(original)
            defaults.values["displayPresetsV1"] = presetData
            let screens = DisplayController(defaults: defaults, backend: backend).displays(includeModes: false)
            let migrated = PresetStore(defaults: defaults).load(displays: screens)
            try coreExpect(screens.map(\.identity) == [realID], "offline pre-UUID virtual cache is excluded")
            try coreExpect(migrated.presetA.displays == [realEntry] && migrated.presetB.displays == [realEntry], "legacy virtual preset excluded while physical offline settings survive")
            try coreExpect(defaults.data(forKey: "knownDisplaysV1") == cache && defaults.data(forKey: "displayPresetsV1") == presetData, "pre-UUID backups remain untouched")
        }
        // A real software disconnect removes both Quartz UUID mappings while
        // leaving nonzero vendor/model/serial metadata at the old framebuffer.
        do {
            let identity = "uuid:11111111-2222-4333-8444-555555555555"
            let hardware = "external-1234-5678-987654"
            let record = StoredDisplay(id: 4, name: "Saved display", builtin: false,
                                       identity: identity, legacyIdentity: hardware)
            let candidate = coreScreen(4, "hardware:" + hardware, legacy: hardware, active: false)
            let spare = coreScreen(1, "uuid:spare", legacy: "external-10-20-123")
            func accepts(_ candidate: DisplayInfo, mappedID: UInt32 = 0, online: [DisplayInfo]? = nil) -> Bool {
                DisplayIdentity.canRecoverRemembered(record, candidate: candidate, mappedID: mappedID, online: online ?? [spare])
            }
            try coreExpect(accepts(candidate), "known UUID binding recovers when both UUID mappings vanish")
            try coreExpect(!accepts(coreScreen(0, "hardware:" + hardware, legacy: hardware, active: false)), "zero ID never reaches recovery")
            try coreExpect(!accepts(coreScreen(4, "uuid:other", legacy: hardware, active: false)), "explicit UUID mismatch overrides matching hardware")
            try coreExpect(!accepts(candidate, mappedID: 19), "UUID mapping to another ID blocks recovery")
            try coreExpect(!accepts(coreScreen(4, "hardware:external-1234-5678-111", legacy: "external-1234-5678-111", active: false)), "changed serial blocks recovery")
            try coreExpect(!accepts(coreScreen(4, "hardware:" + hardware, legacy: hardware)), "active candidates never use offline fallback")
            try coreExpect(!accepts(candidate, online: [coreScreen(4, "uuid:new")]), "reused online ID blocks recovery")
            try coreExpect(!accepts(candidate, online: [coreScreen(19, "uuid:twin", legacy: hardware)]), "online hardware collision blocks recovery")
            for incompleteHardware in ["external-1234-5678-0", "external-0-5678-123", "external-1234-0-123"] {
                let incomplete = StoredDisplay(id: 4, name: "Incomplete", builtin: false, identity: identity, legacyIdentity: incompleteHardware)
                let current = coreScreen(4, "hardware:" + incompleteHardware, legacy: incompleteHardware, active: false)
                try coreExpect(!DisplayIdentity.canRecoverRemembered(incomplete, candidate: current, mappedID: 0, online: []), "all three hardware identifiers must be nonzero")
            }
        }
        // Reconnecting through the controller preserves the saved UUID and
        // refuses cached bindings shared by another remembered display.
        do {
            let defaults = CoreMemoryPreferences(); let backend = CoreFakeBackend()
            let identity = "uuid:11111111-2222-4333-8444-555555555555"
            let hardware = "external-1234-5678-987654"
            let record = StoredDisplay(id: 4, name: "Saved display", builtin: false, identity: identity, legacyIdentity: hardware)
            defaults.values["knownDisplaysV3"] = try JSONEncoder().encode([record])
            backend.online = [coreScreen(1, "uuid:spare", legacy: "external-10-20-123")]
            backend.rememberedResolved[identity] = coreScreen(4, identity, legacy: hardware, active: false)
            let controller = DisplayController(defaults: defaults, backend: backend)
            let listed = controller.displays(includeModes: false).first { $0.identity == identity }
            try coreExpect(listed?.id == 4 && listed?.canControl == true, "software-disconnected screen remains available in menu")
            _ = controller.setEnabled(true, identity: identity)
            try coreExpect(backend.enabledCalls.count == 1 && backend.enabledCalls[0].2 == 4, "verified remembered binding reaches reconnect")
            let twin = StoredDisplay(id: 19, name: "Twin", builtin: false, identity: "uuid:other", legacyIdentity: hardware)
            defaults.values["knownDisplaysV3"] = try JSONEncoder().encode([record, twin])
            let calls = backend.rememberedCalls.count
            _ = controller.setEnabled(true, identity: identity)
            try coreExpect(backend.enabledCalls.count == 1 && backend.rememberedCalls.count == calls, "ambiguous remembered hardware never reaches recovery backend")
            defaults.values["knownDisplaysV3"] = try JSONEncoder().encode([record])
            backend.rememberedResolved[identity] = coreScreen(4, "uuid:wrong", legacy: hardware, active: false)
            _ = controller.setEnabled(true, identity: identity)
            try coreExpect(backend.enabledCalls.count == 1, "recovery result still must match requested UUID")
        }
        // Rotation is read as a standard angle; changing its axis transposes
        // both logical and pixel geometry without changing refresh or scaling.
        do {
            try coreExpect(DisplayRotation.normalized(-90) == 270 && DisplayRotation.normalized(450) == 90,
                           "normalize wrapped standard rotations")
            try coreExpect(DisplayRotation.normalized(359.999) == 0 && DisplayRotation.normalized(45) == nil
                           && DisplayRotation.normalized(.nan) == nil && DisplayRotation.normalized(.infinity) == nil,
                           "reject invalid angles without inventing an orientation")
            let portrait = coreMode.rotated(from: 0, to: 270)
            try coreExpect(portrait.width == 1080 && portrait.height == 1920 && portrait.pixelWidth == 2160
                           && portrait.pixelHeight == 3840 && portrait.refreshRate == 60, "transpose logical and backing dimensions together")
            try coreExpect(portrait.rotated(from: 270, to: 0) == coreMode && coreMode.rotated(from: 0, to: 180) == coreMode,
                           "rotation preserves exact mode on inverse and half turns")
            try coreExpect(!portrait.hasSameOrientation(as: coreMode), "portrait and landscape are distinct")
        }
        // V4 acquires only a matching live angle. V5 nil explicitly means
        // follow-current and must never be silently converted to a fixed angle.
        do {
            let defaults = CoreMemoryPreferences()
            let landscape = coreEntry("uuid:screen")
            var portrait = landscape; portrait.mode = coreMode.rotated(from: 0, to: 90)
            let original = PresetCollection(presetA: DisplayPreset(name: "Landscape", displays: [landscape]),
                                            presetB: DisplayPreset(name: "Portrait", displays: [portrait]))
            let bytes = try JSONEncoder().encode(original)
            defaults.values["displayPresetsV4"] = bytes
            let display = DisplayInfo(id: 1, name: landscape.name, active: true, builtin: false, identity: landscape.identity,
                                      currentMode: coreMode, availableModes: [coreMode], rotation: 180)
            let store = PresetStore(defaults: defaults)
            let migrated = store.load(displays: [display])
            try coreExpect(migrated.presetA.displays[0].rotation == 180 && migrated.presetB.displays[0].rotation == nil,
                           "learn only a live angle whose mode orientation matches the saved mode")
            try coreExpect(migrated.presetA.displays[0].mode == landscape.mode && migrated.presetB.displays[0].mode == portrait.mode,
                           "rotation migration never alters saved resolution or backing dimensions")
            try coreExpect(defaults.data(forKey: "displayPresetsV4") == bytes && defaults.data(forKey: "displayPresetsV5") != nil,
                           "V5 migration preserves V4 bytes")
            var edited = migrated; edited.presetA.displays[0].rotation = nil; edited.presetB.displays[0].rotation = 270
            edited.presetA.displays[0].mode = nil
            store.save(edited)
            try coreExpect(store.load(displays: [display]) == edited, "persist keep-current resolution, follow-current and explicit rotation across reload")
            try coreExpect(store.load(displays: []) == edited, "offline reads preserve saved rotation")
        }
        do {
            let defaults = CoreMemoryPreferences()
            let portrait = coreMode.rotated(from: 0, to: 90)
            let display = DisplayInfo(id: 1, name: "Portrait", active: true, builtin: false, identity: "uuid:portrait",
                                      currentMode: portrait, availableModes: [portrait], rotation: 270)
            let stored = PresetStore(defaults: defaults).load(displays: [display])
            try coreExpect(stored.presetA.displays[0].rotation == 270, "new presets record the actual angle instead of guessing 90")
            let conflicts = DisplayIdentity.protectConflicts([display, display])
            try coreExpect(conflicts.allSatisfy { $0.rotation == 270 && !$0.canControl }, "identity protection copies rotation metadata")
            let backend = CoreFakeBackend()
            backend.resolved[display.identity] = display
            defaults.values["knownDisplaysV3"] = try JSONEncoder().encode([StoredDisplay(display)])
            let remembered = DisplayController(defaults: defaults, backend: backend).displays(includeModes: false)
            try coreExpect(remembered.first?.rotation == 270, "remembered display resolution retains fresh rotation")
        }
        print("DisplayCore: 19 regression scenarios passed")
    }
}
