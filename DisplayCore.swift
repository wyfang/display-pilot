import AppKit
import CoreGraphics

@_silgen_name("CGSConfigureDisplayEnabled")
private func CGSConfigureDisplayEnabled(
    _ config: CGDisplayConfigRef?,
    _ display: CGDirectDisplayID,
    _ enabled: Bool
) -> CGError

struct DisplayModeInfo: Codable, Equatable, Hashable {
    let modeID: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    init(_ mode: CGDisplayMode) {
        modeID = mode.ioDisplayModeID
        width = mode.width
        height = mode.height
        pixelWidth = mode.pixelWidth
        pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate
    }

    init(modeID: Int32 = 0, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) {
        self.modeID = modeID
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
    }

    /// Selection and verification deliberately use the same exact criteria.
    func matchingMode(in modes: [DisplayModeInfo]) -> DisplayModeInfo? {
        modes.first { $0.describesSameMode(as: self) }
    }

    var label: String {
        var details: [String] = []
        if pixelWidth > width || pixelHeight > height {
            details.append("HiDPI")
        }
        if refreshRate > 0 {
            let rounded = refreshRate.rounded()
            let rate = abs(refreshRate - rounded) < 0.01
                ? String(Int(rounded))
                : String(format: "%.2f", refreshRate)
            details.append("\(rate) Hz")
        }
        let suffix = details.isEmpty ? "" : " · " + details.joined(separator: " · ")
        return "\(width) × \(height)\(suffix)"
    }

    func describesSameMode(as other: DisplayModeInfo) -> Bool {
        let refreshMatches = refreshRate == 0
            || other.refreshRate == 0
            || abs(refreshRate - other.refreshRate) < 0.02
        return width == other.width
            && height == other.height
            && pixelWidth == other.pixelWidth
            && pixelHeight == other.pixelHeight
            && refreshMatches
    }
}

struct DisplayInfo {
    let id: CGDirectDisplayID
    let name: String
    let active: Bool
    let builtin: Bool
    let identity: String
    let currentMode: DisplayModeInfo?
    let availableModes: [DisplayModeInfo]
    let legacyIdentity: String?
    let canControl: Bool

    init(id: CGDirectDisplayID, name: String, active: Bool, builtin: Bool, identity: String,
         currentMode: DisplayModeInfo?, availableModes: [DisplayModeInfo],
         legacyIdentity: String? = nil, canControl: Bool = true) {
        self.id = id
        self.name = name
        self.active = active
        self.builtin = builtin
        self.identity = identity
        self.currentMode = currentMode
        self.availableModes = availableModes
        self.legacyIdentity = legacyIdentity
        self.canControl = canControl
    }
}

struct StoredDisplay: Codable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let builtin: Bool
    let identity: String
    let legacyIdentity: String?

    init(_ display: DisplayInfo) {
        // Numerical IDs are session-local metadata, never an operational address.
        id = display.id
        name = display.name
        builtin = display.builtin
        identity = display.identity
        legacyIdentity = display.legacyIdentity
    }

    init(id: CGDirectDisplayID, name: String, builtin: Bool, identity: String, legacyIdentity: String? = nil) {
        self.id = id
        self.name = name
        self.builtin = builtin
        self.identity = identity
        self.legacyIdentity = legacyIdentity
    }

    var displayInfo: DisplayInfo {
        DisplayInfo(id: 0, name: name, active: false, builtin: builtin, identity: identity,
                    currentMode: nil, availableModes: [], legacyIdentity: legacyIdentity, canControl: false)
    }
}

struct DisplayPresetEntry: Codable, Equatable {
    var identity: String
    var name: String
    var enabled: Bool
    var brightness: Double
    var contrast: Double
    var mode: DisplayModeInfo?
}

struct DisplayPreset: Codable, Equatable {
    var name: String
    var displays: [DisplayPresetEntry]
}

struct PresetCollection: Codable, Equatable {
    var presetA: DisplayPreset
    var presetB: DisplayPreset
}

struct AppFailure: Error {
    let message: String
}

protocol PreferenceStorage: AnyObject {
    func data(forKey key: String) -> Data?
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PreferenceStorage {}

protocol DisplayBackend {
    func snapshots(includeModes: Bool) -> [DisplayInfo]
    func resolve(identity: String, includeModes: Bool) -> DisplayInfo?
    func resolveLegacy(identity: String, candidateID: CGDirectDisplayID, includeModes: Bool) -> DisplayInfo?
    func resolveRemembered(_ record: StoredDisplay, includeModes: Bool) -> DisplayInfo?
    func setEnabled(_ enabled: Bool, display: DisplayInfo) -> Result<Void, AppFailure>
    func setModes(_ requests: [(mode: DisplayModeInfo, identity: String)]) -> [String: AppFailure]
}

extension DisplayBackend {
    func resolveLegacy(identity: String, candidateID: CGDirectDisplayID, includeModes: Bool) -> DisplayInfo? { nil }
    func resolveRemembered(_ record: StoredDisplay, includeModes: Bool) -> DisplayInfo? { nil }
}

/// Legacy unit numbers were transient. Nonzero serials (or the sole built-in
/// screen) can be migrated when unambiguous; serial-zero external records cannot.
enum DisplayIdentity {
    /// CoreGraphics uses the four-character codes "unkn" / "virt" for
    /// anonymous virtual displays. They are not physical preset targets.
    static func isAnonymousVirtual(_ identity: String?) -> Bool {
        guard let identity else { return false }
        return normalizedLegacy(identity) == "external-1970170734-1986622068-0"
    }

    static func ignoredVirtualIdentities(defaults: PreferenceStorage, displays: [DisplayInfo]) -> Set<String> {
        var identities = Set(displays.filter { isAnonymousVirtual($0.legacyIdentity) }.map(\.identity))
        // Earlier cache keys are retained as migration backups and also identify
        // virtual entries already copied into the old presets.
        for key in ["knownDisplaysV3", "knownDisplaysV2", "knownDisplaysV1"] {
            guard let data = defaults.data(forKey: key),
                  let records = try? JSONDecoder().decode([StoredDisplay].self, from: data) else { continue }
            for record in records where isAnonymousVirtual(record.legacyIdentity ?? record.identity) {
                identities.insert(record.identity)
            }
        }
        return identities
    }

    static func normalizedLegacy(_ identity: String) -> String {
        let identity = identity.hasPrefix("hardware:") ? String(identity.dropFirst(9)) : identity
        let parts = identity.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "builtin" || parts[0] == "external" else { return identity }
        return parts.dropLast().joined(separator: "-")
    }

    static func canMigrateLegacy(_ identity: String) -> Bool {
        let parts = normalizedLegacy(identity).split(separator: "-")
        guard parts.count == 4 else { return false }
        return parts[0] == "builtin" || (parts[0] == "external" && UInt32(parts[3]).map { $0 != 0 } == true)
    }

    /// Disabling a physical screen can remove both Quartz UUID mappings while
    /// its framebuffer still reports the complete hardware identity. A cached
    /// number is only a lookup hint for these freshly read, nonzero identifiers.
    static func canRecoverRemembered(_ record: StoredDisplay, candidate: DisplayInfo,
                                     mappedID: CGDirectDisplayID, online: [DisplayInfo]) -> Bool {
        guard record.identity.hasPrefix("uuid:"),
              UUID(uuidString: String(record.identity.dropFirst(5))) != nil,
              let expected = record.legacyIdentity.map(normalizedLegacy),
              record.id != 0, candidate.id == record.id,
              candidate.builtin == record.builtin, !candidate.active, candidate.canControl,
              candidate.legacyIdentity.map(normalizedLegacy) == expected,
              mappedID == 0 || mappedID == candidate.id,
              candidate.identity == record.identity || candidate.identity == "hardware:" + expected else { return false }
        let parts = expected.split(separator: "-")
        guard parts.count == 4, parts[0] == (record.builtin ? "builtin" : "external"),
              parts.dropFirst().allSatisfy({ UInt32($0).map { $0 != 0 } == true }) else { return false }
        return online.allSatisfy {
            $0.id != candidate.id && $0.identity != record.identity
                && $0.legacyIdentity.map(normalizedLegacy) != expected
        }
    }

    static func protectConflicts(_ displays: [DisplayInfo]) -> [DisplayInfo] {
        let groups = Dictionary(grouping: displays, by: \.identity)
        return displays.map { display in
            guard groups[display.identity]?.count == 1 else {
                return DisplayInfo(id: display.id, name: display.name + "（身份冲突）", active: display.active,
                                   builtin: display.builtin, identity: "unresolved:\(display.identity):\(display.id)",
                                   currentMode: display.currentMode, availableModes: display.availableModes,
                                   legacyIdentity: display.legacyIdentity, canControl: false)
            }
            return display
        }
    }

    static func migrationTarget(for identity: String, displays: [DisplayInfo]) -> String? {
        guard canMigrateLegacy(identity) else { return nil }
        let legacy = normalizedLegacy(identity)
        let candidates = displays.filter { $0.canControl && $0.legacyIdentity == legacy }
        let identities = Set(candidates.map(\.identity))
        return identities.count == 1 ? identities.first : nil
    }
}

final class DisplayController {
    private let defaults: PreferenceStorage
    private let backend: DisplayBackend
    private let storageKey = "knownDisplaysV3"

    init(defaults: PreferenceStorage = UserDefaults.standard, backend: DisplayBackend = QuartzDisplayBackend()) {
        self.defaults = defaults
        self.backend = backend
    }

    func displays(includeModes: Bool = true) -> [DisplayInfo] {
        var online = backend.snapshots(includeModes: includeModes).filter { !DisplayIdentity.isAnonymousVirtual($0.legacyIdentity) }
        let previous = loadStoredDisplays().filter { !DisplayIdentity.isAnonymousVirtual($0.legacyIdentity ?? $0.identity) }
        // On the first upgrade, a software-disabled screen may have only a
        // legacy record. Its old ID is a lookup hint, accepted only after the
        // nonzero hardware identity and a UUID round trip have both been checked.
        for record in previous where DisplayIdentity.canMigrateLegacy(record.identity) {
            guard !online.contains(where: { $0.legacyIdentity == DisplayIdentity.normalizedLegacy(record.identity) }),
                  let resolved = backend.resolveLegacy(identity: record.identity, candidateID: record.id, includeModes: includeModes),
                  resolved.canControl,
                  resolved.legacyIdentity == DisplayIdentity.normalizedLegacy(record.identity),
                  !online.contains(where: { $0.identity == resolved.identity }) else { continue }
            online.append(resolved)
        }
        var stored: [StoredDisplay] = []
        for remembered in previous {
            // Only migrate a uniquely identifiable screen, without ever using its
            // cached numeric ID. Retain unresolved entries so settings stay recoverable.
            if let target = DisplayIdentity.migrationTarget(for: remembered.identity, displays: online),
               let display = online.first(where: { $0.identity == target }) {
                if !stored.contains(where: { $0.identity == target }) { stored.append(StoredDisplay(display)) }
            } else if !stored.contains(remembered) {
                stored.append(remembered)
            }
        }
        for display in online where !display.identity.hasPrefix("unresolved:") {
            if let index = stored.firstIndex(where: { $0.identity == display.identity }) {
                stored[index] = StoredDisplay(display)
            } else {
                stored.append(StoredDisplay(display))
            }
        }
        if stored != previous || defaults.data(forKey: storageKey) == nil {
            if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: storageKey) }
        }

        let onlineIdentities = Set(online.map(\.identity))
        var seen = onlineIdentities
        let remembered = stored.compactMap { record -> DisplayInfo? in
            guard seen.insert(record.identity).inserted else { return nil }
            if let resolved = resolveDisplay(identity: record.identity, includeModes: includeModes),
               resolved.identity == record.identity, resolved.canControl {
                return DisplayInfo(id: resolved.id, name: record.name, active: resolved.active, builtin: resolved.builtin,
                                   identity: resolved.identity, currentMode: resolved.currentMode,
                                   availableModes: resolved.availableModes,
                                   legacyIdentity: resolved.legacyIdentity, canControl: true)
            }
            return record.displayInfo
        }
        return (online + remembered).sorted {
            if $0.active != $1.active { return $0.active }
            if $0.builtin != $1.builtin { return $0.builtin }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func resolveDisplay(identity: String, includeModes: Bool = false) -> DisplayInfo? {
        let direct = backend.resolve(identity: identity, includeModes: includeModes)
        let records = loadStoredDisplays()
        let matching = records.filter { $0.identity == identity }
        var recovered: DisplayInfo?
        if direct == nil, matching.count == 1, let record = matching.first,
           let hardware = record.legacyIdentity.map(DisplayIdentity.normalizedLegacy),
           records.allSatisfy({ $0.identity == identity || DisplayIdentity.normalizedLegacy($0.legacyIdentity ?? $0.identity) != hardware }) {
            recovered = backend.resolveRemembered(record, includeModes: includeModes)
        }
        guard let display = direct ?? recovered,
              display.identity == identity, display.canControl,
              !DisplayIdentity.isAnonymousVirtual(display.legacyIdentity) else { return nil }
        return display
    }

    func setEnabled(_ enabled: Bool, identity: String) -> Result<Void, AppFailure> {
        guard let display = resolveDisplay(identity: identity) else {
            return .failure(AppFailure(message: "无法核实这块显示器的身份或连接状态，请重新连接后刷新；旧显示器编号不会被用于切换。"))
        }
        if display.active == enabled { return .success(()) }
        if !enabled && backend.snapshots(includeModes: false).filter(\.active).count <= 1 {
            return .failure(AppFailure(message: "为避免黑屏，不能断开最后一块正在使用的屏幕。"))
        }
        return backend.setEnabled(enabled, display: display)
    }

    func setModes(_ requests: [(mode: DisplayModeInfo, identity: String)]) -> [String: AppFailure] {
        var failures: [String: AppFailure] = [:]
        let valid = requests.filter { request in
            guard let display = resolveDisplay(identity: request.identity), display.active else {
                failures[request.identity] = AppFailure(message: "无法核实目标显示器，或显示器尚未连接。")
                return false
            }
            return true
        }
        return failures.merging(backend.setModes(valid)) { _, latest in latest }
    }

    private func loadStoredDisplays() -> [StoredDisplay] {
        // Keep the old key intact as a migration backup.
        for key in [storageKey, "knownDisplaysV2", "knownDisplaysV1"] {
            if let data = defaults.data(forKey: key),
               let displays = try? JSONDecoder().decode([StoredDisplay].self, from: data) { return displays }
        }
        return []
    }
}

struct QuartzDisplayBackend: DisplayBackend {
    func snapshots(includeModes: Bool) -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let raw = ids.prefix(Int(count)).map { snapshot(id: $0, includeModes: includeModes) }
        return DisplayIdentity.protectConflicts(raw.filter { !DisplayIdentity.isAnonymousVirtual($0.legacyIdentity) })
    }

    func resolve(identity: String, includeModes: Bool) -> DisplayInfo? {
        let online = snapshots(includeModes: false)
        if let display = online.first(where: { $0.identity == identity && $0.canControl }) {
            guard includeModes else { return display }
            let detailed = snapshot(id: display.id, includeModes: true)
            return detailed.identity == identity && detailed.canControl ? detailed : nil
        }
        guard identity.hasPrefix("uuid:"),
              let uuid = CFUUIDCreateFromString(nil, String(identity.dropFirst(5)) as CFString) else { return nil }
        let id = CGDisplayGetDisplayIDFromUUID(uuid)
        guard id != kCGNullDirectDisplay,
              online.allSatisfy({ $0.id != id }),
              uuidIdentity(id) == identity,
              CGDisplayVendorNumber(id) != 0 || CGDisplayModelNumber(id) != 0 else { return nil }
        // Software-disabled displays can disappear from the online list. Quartz's
        // UUID round trip verifies the current address before reconnecting them.
        let display = snapshot(id: id, includeModes: includeModes)
        return display.identity == identity && display.canControl
            && !DisplayIdentity.isAnonymousVirtual(display.legacyIdentity) ? display : nil
    }

    func resolveLegacy(identity: String, candidateID: CGDirectDisplayID, includeModes: Bool) -> DisplayInfo? {
        guard DisplayIdentity.canMigrateLegacy(identity), candidateID != kCGNullDirectDisplay,
              legacyIdentity(candidateID) == DisplayIdentity.normalizedLegacy(identity),
              let uuid = uuidIdentity(candidateID),
              let uuidValue = CFUUIDCreateFromString(nil, String(uuid.dropFirst(5)) as CFString),
              CGDisplayGetDisplayIDFromUUID(uuidValue) == candidateID,
              let resolved = resolve(identity: uuid, includeModes: includeModes),
              resolved.id == candidateID,
              resolved.legacyIdentity == DisplayIdentity.normalizedLegacy(identity) else { return nil }
        return resolved
    }

    func resolveRemembered(_ record: StoredDisplay, includeModes: Bool) -> DisplayInfo? {
        guard record.id != kCGNullDirectDisplay,
              record.identity.hasPrefix("uuid:"),
              let uuid = CFUUIDCreateFromString(nil, String(record.identity.dropFirst(5)) as CFString) else { return nil }
        let online = snapshots(includeModes: false)
        let candidate = snapshot(id: record.id, includeModes: includeModes)
        guard CGDisplayIsOnline(record.id) == 0,
              DisplayIdentity.canRecoverRemembered(record, candidate: candidate,
                  mappedID: CGDisplayGetDisplayIDFromUUID(uuid), online: online) else { return nil }
        return DisplayInfo(id: candidate.id, name: record.name, active: false, builtin: candidate.builtin,
                           identity: record.identity, currentMode: nil, availableModes: [],
                           legacyIdentity: candidate.legacyIdentity, canControl: true)
    }

    func setEnabled(_ enabled: Bool, display: DisplayInfo) -> Result<Void, AppFailure> {
        // Re-resolve immediately before the transaction: hotplug may recycle IDs
        // between the menu snapshot and this call.
        guard let current = resolve(identity: display.identity, includeModes: false)
                ?? (enabled ? resolveRemembered(StoredDisplay(display), includeModes: false) : nil) else {
            return .failure(AppFailure(message: "显示器连接已变化，无法安全切换，请刷新后重试。"))
        }
        if current.active == enabled { return .success(()) }
        if !enabled && snapshots(includeModes: false).filter(\.active).count <= 1 {
            return .failure(AppFailure(message: "为避免黑屏，不能断开最后一块正在使用的屏幕。"))
        }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else {
            return .failure(AppFailure(message: "无法开始修改显示器配置（错误 \(begin.rawValue)）。"))
        }
        guard let verified = resolve(identity: current.identity, includeModes: false)
                ?? (enabled ? resolveRemembered(StoredDisplay(current), includeModes: false) : nil),
              verified.id == current.id else {
            CGCancelDisplayConfiguration(config)
            return .failure(AppFailure(message: "显示器身份已变化，已取消切换。"))
        }
        let change = CGSConfigureDisplayEnabled(config, current.id, enabled)
        guard change == .success else {
            CGCancelDisplayConfiguration(config)
            return .failure(AppFailure(message: "macOS 拒绝了这次切换（错误 \(change.rawValue)）。如果屏幕已拔线，请重新插线后再试。"))
        }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else {
            return .failure(AppFailure(message: "显示器配置未能保存（错误 \(complete.rawValue)）。"))
        }
        return .success(())
    }

    func setModes(_ requests: [(mode: DisplayModeInfo, identity: String)]) -> [String: AppFailure] {
        var failures: [String: AppFailure] = [:]
        var selected: [(identity: String, id: CGDirectDisplayID, requested: DisplayModeInfo, mode: CGDisplayMode)] = []
        for request in requests {
            guard let display = resolve(identity: request.identity, includeModes: true), display.active else {
                failures[request.identity] = AppFailure(message: "无法核实目标显示器，或显示器尚未连接。")
                continue
            }
            let modes = rawDisplayModes(display.id).filter { $0.isUsableForDesktopGUI() }
            guard let mode = modes.first(where: { DisplayModeInfo($0).describesSameMode(as: request.mode) }) else {
                failures[request.identity] = AppFailure(message: "找不到完全匹配的已保存分辨率 \(request.mode.label)，未改用其它缩放或刷新率。")
                continue
            }
            if display.currentMode?.describesSameMode(as: request.mode) == true { continue }
            selected.append((request.identity, display.id, request.mode, mode))
        }
        guard !selected.isEmpty else { return failures }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else {
            for selection in selected {
                failures[selection.identity] = AppFailure(message: "无法开始修改分辨率（错误 \(begin.rawValue)）。")
            }
            return failures
        }
        var configured: [String] = []
        for selection in selected {
            guard uuidOrHardwareIdentity(selection.id) == selection.identity,
                  CGDisplayIsActive(selection.id) != 0 else {
                failures[selection.identity] = AppFailure(message: "显示器身份或连接已变化，未修改分辨率。")
                continue
            }
            let change = CGConfigureDisplayWithDisplayMode(config, selection.id, selection.mode, nil)
            if change == .success { configured.append(selection.identity) }
            else { failures[selection.identity] = AppFailure(message: "macOS 拒绝了分辨率 \(selection.requested.label)（错误 \(change.rawValue)）。") }
        }
        guard !configured.isEmpty else { CGCancelDisplayConfiguration(config); return failures }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        if complete != .success {
            for identity in configured {
                failures[identity] = AppFailure(message: "分辨率配置未能保存（错误 \(complete.rawValue)）。")
            }
        }
        return failures
    }

    private func snapshot(id: CGDirectDisplayID, includeModes: Bool) -> DisplayInfo {
        let builtin = CGDisplayIsBuiltin(id) != 0
        let identity = uuidOrHardwareIdentity(id)
        return DisplayInfo(id: id, name: displayName(id), active: CGDisplayIsActive(id) != 0,
                           builtin: builtin, identity: identity,
                           currentMode: CGDisplayCopyDisplayMode(id).map(DisplayModeInfo.init),
                           availableModes: includeModes ? displayModes(id) : [],
                           legacyIdentity: legacyIdentity(id), canControl: !identity.hasPrefix("unresolved:"))
    }

    private func uuidIdentity(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return "uuid:" + (CFUUIDCreateString(nil, uuid) as String).lowercased()
    }

    private func uuidOrHardwareIdentity(_ id: CGDirectDisplayID) -> String {
        if let identity = uuidIdentity(id) { return identity }
        let legacy = legacyIdentity(id)
        return DisplayIdentity.canMigrateLegacy(legacy) ? "hardware:" + legacy : "unresolved:\(legacy):\(id)"
    }

    private func legacyIdentity(_ id: CGDirectDisplayID) -> String {
        [CGDisplayIsBuiltin(id) != 0 ? "builtin" : "external", String(CGDisplayVendorNumber(id)),
         String(CGDisplayModelNumber(id)), String(CGDisplaySerialNumber(id))].joined(separator: "-")
    }

    private func displayModes(_ id: CGDirectDisplayID) -> [DisplayModeInfo] {
        var seen = Set<String>()
        return rawDisplayModes(id).filter { $0.isUsableForDesktopGUI() }.map(DisplayModeInfo.init).filter { mode in
            let key = "\(mode.width)x\(mode.height)-\(mode.pixelWidth)x\(mode.pixelHeight)-\(Int((mode.refreshRate * 100).rounded()))"
            return seen.insert(key).inserted
        }.sorted {
            if $0.width != $1.width { return $0.width < $1.width }
            if $0.height != $1.height { return $0.height < $1.height }
            if $0.pixelWidth != $1.pixelWidth { return $0.pixelWidth < $1.pixelWidth }
            return $0.refreshRate < $1.refreshRate
        }
    }

    private func rawDisplayModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    }

    private func displayName(_ id: CGDirectDisplayID) -> String {
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) { return screen.localizedName }
        return CGDisplayIsBuiltin(id) != 0 ? "内置显示器" : "外接显示器 \(id)"
    }
}

final class PresetStore {
    private let defaults: PreferenceStorage
    private let storageKey = "displayPresetsV4"

    init(defaults: PreferenceStorage = UserDefaults.standard) { self.defaults = defaults }

    func load(displays: [DisplayInfo]) -> PresetCollection {
        let decoded = loadStoredCollection()
        var collection = decoded ?? PresetCollection(
            presetA: DisplayPreset(name: "预设 A", displays: []),
            presetB: DisplayPreset(name: "预设 B", displays: [])
        )
        let original = collection
        let ignored = DisplayIdentity.ignoredVirtualIdentities(defaults: defaults, displays: displays)
        collection.presetA.displays.removeAll { ignored.contains($0.identity) || DisplayIdentity.isAnonymousVirtual($0.identity) }
        collection.presetB.displays.removeAll { ignored.contains($0.identity) || DisplayIdentity.isAnonymousVirtual($0.identity) }
        let displays = displays.filter { !ignored.contains($0.identity) && !DisplayIdentity.isAnonymousVirtual($0.legacyIdentity) }
        migrateLegacyIdentities(&collection.presetA, displays: displays)
        migrateLegacyIdentities(&collection.presetB, displays: displays)
        synchronize(&collection.presetA, with: displays, defaultBrightness: legacyBrightness("presetA", fallback: 0.35))
        synchronize(&collection.presetB, with: displays, defaultBrightness: legacyBrightness("presetB", fallback: 0.80))
        if collection != original || defaults.data(forKey: storageKey) == nil { save(collection) }
        return collection
    }

    func save(_ collection: PresetCollection) {
        guard let data = try? JSONEncoder().encode(collection) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func loadStoredCollection() -> PresetCollection? {
        // Old keys remain byte-for-byte intact to make this migration reversible.
        for key in [storageKey, "displayPresetsV3", "displayPresetsV2", "displayPresetsV1"] {
            if let data = defaults.data(forKey: key),
               let value = try? JSONDecoder().decode(PresetCollection.self, from: data) { return value }
        }
        return nil
    }

    private func synchronize(_ preset: inout DisplayPreset, with displays: [DisplayInfo], defaultBrightness: Double) {
        for display in displays where !display.identity.hasPrefix("unresolved:") {
            if let index = preset.displays.firstIndex(where: { $0.identity == display.identity }) {
                // Offline names and empty mode lists must not erase saved settings.
                if display.canControl { preset.displays[index].name = display.name }
                if preset.displays[index].mode == nil { preset.displays[index].mode = display.currentMode }
            } else {
                preset.displays.append(DisplayPresetEntry(
                    identity: display.identity, name: display.name, enabled: display.active,
                    brightness: defaultBrightness, contrast: 0, mode: display.currentMode
                ))
            }
        }
        preset.displays.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func migrateLegacyIdentities(_ preset: inout DisplayPreset, displays: [DisplayInfo]) {
        let original = preset.displays
        let proposed = original.map { DisplayIdentity.migrationTarget(for: $0.identity, displays: displays) }
        for index in preset.displays.indices {
            guard let target = proposed[index],
                  !original.contains(where: { $0.identity == target }),
                  proposed.filter({ $0 == target }).count == 1 else { continue }
            // A merge could discard distinct user choices. Ambiguous entries stay
            // untouched and non-operational until the user edits them explicitly.
            preset.displays[index].identity = target
        }
    }

    private func legacyBrightness(_ key: String, fallback: Double) -> Double {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return fallback }
        return min(max(number.doubleValue, 0), 1)
    }
}
