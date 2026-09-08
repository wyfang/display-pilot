import Foundation
import CoreGraphics

/// Serializes a complete preset and validates the final state after every side effect.
/// Dependencies keep retries testable without changing physical displays or preferences.
final class PresetApplication {
    typealias VisualOperation = (Double, Double, CGDirectDisplayID, @escaping (Result<Void, AppFailure>) -> Void) -> Void
    struct Dependencies {
        var displays: (Bool) -> [DisplayInfo]
        var setEnabled: (Bool, String) -> Result<Void, AppFailure>
        var setModes: ([(mode: DisplayModeInfo, identity: String)]) -> [String: AppFailure]
        var setVisual: VisualOperation
        var verifyVisual: VisualOperation
        var schedule: (TimeInterval, @escaping () -> Void) -> Void
    }

    private final class Context {
        let preset: DisplayPreset
        let completion: ([String]) -> Void
        var enableFailures: [String: String] = [:]
        var modeFailures: [String: String] = [:]
        var disableFailures: [String: String] = [:]
        var visualFailures: [String: String] = [:]
        var verifiedIDs: [String: CGDirectDisplayID] = [:]
        init(_ preset: DisplayPreset, completion: @escaping ([String]) -> Void) {
            self.preset = preset
            self.completion = completion
        }
    }

    private let dependencies: Dependencies
    private(set) var isRunning = false
    init(dependencies: Dependencies) { self.dependencies = dependencies }

    @discardableResult
    func apply(_ preset: DisplayPreset, completion: @escaping ([String]) -> Void) -> Bool {
        guard !isRunning else { return false }
        guard preset.displays.contains(where: \.enabled) else {
            completion(["预设没有设置要开启的显示器，请先编辑预设。"])
            return false
        }
        isRunning = true
        let context = Context(preset, completion: completion)
        connectTargets(context)
        waitForTargets(context, attempt: 0, signature: nil, stableCount: 0)
        return true
    }

    private func connectTargets(_ context: Context) {
        let displays = dependencies.displays(false)
        for entry in context.preset.displays where entry.enabled {
            if displays.contains(where: { $0.identity == entry.identity && $0.active }) {
                context.enableFailures.removeValue(forKey: entry.identity)
                continue
            }
            switch dependencies.setEnabled(true, entry.identity) {
            case .success: context.enableFailures.removeValue(forKey: entry.identity)
            case .failure(let error): context.enableFailures[entry.identity] = error.message
            }
        }
    }

    private func waitForTargets(_ context: Context, attempt: Int, signature: String?, stableCount: Int) {
        let displays = dependencies.displays(true)
        let targets = context.preset.displays.filter(\.enabled)
        let resolved = targets.compactMap { entry in displays.first { $0.identity == entry.identity && $0.active } }
        let ready = resolved.count == targets.count && targets.allSatisfy { entry in
            guard let requested = entry.mode else { return true }
            return resolved.contains {
                $0.identity == entry.identity
                    && ($0.currentMode?.describesSameMode(as: requested) == true
                        || requested.matchingMode(in: $0.availableModes) != nil)
            }
        }
        let currentSignature = resolved.sorted { $0.identity < $1.identity }.map { display in
            let modes = display.availableModes.map { "\($0.modeID):\($0.label):\($0.pixelWidth)x\($0.pixelHeight)" }.sorted().joined(separator: ",")
            return "\(display.identity):\(display.id):\(display.currentMode?.modeID ?? -1):\(modes)"
        }.joined(separator: "|")
        let nextCount = ready ? (signature == currentSignature ? stableCount + 1 : 1) : 0
        if ready && nextCount >= 3 {
            applyModes(context, attempt: 1)
        } else if attempt < 16 {
            if attempt > 0 && attempt.isMultiple(of: 2) { connectTargets(context) }
            dependencies.schedule(0.9) { [weak self] in
                self?.waitForTargets(context, attempt: attempt + 1, signature: ready ? currentSignature : nil, stableCount: nextCount)
            }
        } else if resolved.isEmpty {
            finish(context)
        } else {
            // A later retry can recover a slow connection. Only final validation emits errors.
            applyModes(context, attempt: 1)
        }
    }

    private func applyModes(_ context: Context, attempt: Int) {
        connectTargets(context)
        let displays = dependencies.displays(true)
        let requests: [(mode: DisplayModeInfo, identity: String)] = context.preset.displays.compactMap { entry in
            guard entry.enabled, let requested = entry.mode,
                  let display = displays.first(where: { $0.identity == entry.identity && $0.active }),
                  display.currentMode?.describesSameMode(as: requested) != true else { return nil }
            // Reconnection can initially expose only a partial mode list. Keep
            // waiting for the saved mode instead of applying an approximate one.
            guard requested.matchingMode(in: display.availableModes) != nil else {
                context.modeFailures[entry.identity] = "找不到完全匹配的已保存分辨率 \(requested.label)，未改用其它缩放或刷新率。"
                return nil
            }
            return (requested, entry.identity)
        }
        let failures = dependencies.setModes(requests)
        for request in requests { context.modeFailures[request.identity] = failures[request.identity]?.message }
        dependencies.schedule(min(0.8 + Double(attempt - 1) * 0.45, 2.6)) { [weak self] in
            guard let self else { return }
            let current = self.dependencies.displays(false)
            let pending = context.preset.displays.contains { entry in
                guard entry.enabled else { return false }
                guard let display = current.first(where: { $0.identity == entry.identity && $0.active }) else { return true }
                return entry.mode.map { display.currentMode?.describesSameMode(as: $0) != true } ?? false
            }
            if pending && attempt < 6 { self.applyModes(context, attempt: attempt + 1) }
            else { self.applyVisual(context, pass: 1) }
        }
    }

    private func applyVisual(_ context: Context, pass: Int) {
        performVisual(context, verify: false) { [weak self] in
            guard let self else { return }
            if pass == 1 && !context.visualFailures.isEmpty {
                self.dependencies.schedule(0.8) { [weak self] in self?.applyVisual(context, pass: 2) }
            } else {
                self.dependencies.schedule(0.35) { [weak self] in self?.disableUnwanted(context, attempt: 1) }
            }
        }
    }

    private func performVisual(_ context: Context, verify: Bool, completion: @escaping () -> Void) {
        let displays = dependencies.displays(false)
        let targets = context.preset.displays.compactMap { entry -> (DisplayPresetEntry, DisplayInfo)? in
            guard entry.enabled, let display = displays.first(where: { $0.identity == entry.identity && $0.active }) else { return nil }
            return (entry, display)
        }
        guard !targets.isEmpty else { completion(); return }
        var remaining = targets.count
        let operation = verify ? dependencies.verifyVisual : dependencies.setVisual
        for (entry, display) in targets {
            operation(entry.brightness, entry.contrast, display.id) { result in
                switch result {
                case .success:
                    context.visualFailures.removeValue(forKey: entry.identity)
                    if verify { context.verifiedIDs[entry.identity] = display.id }
                case .failure(let error): context.visualFailures[entry.identity] = error.message
                }
                remaining -= 1
                if remaining == 0 { completion() }
            }
        }
    }

    private func disableUnwanted(_ context: Context, attempt: Int) {
        // Keep every currently useful screen until all intended targets and their
        // saved modes have recovered. Recheck after each topology change.
        let unwanted = context.preset.displays.filter { !$0.enabled }
        for entry in unwanted {
            let displays = dependencies.displays(false)
            guard context.preset.displays.filter(\.enabled).allSatisfy({ target in
                guard let display = displays.first(where: { $0.identity == target.identity && $0.active }) else { return false }
                return target.mode.map { display.currentMode?.describesSameMode(as: $0) == true } ?? true
            }) else {
                for retained in unwanted where displays.contains(where: { $0.identity == retained.identity && $0.active }) {
                    context.disableFailures[retained.identity] = "目标显示器及其分辨率尚未全部恢复，已暂缓断开以保留可用屏幕。"
                }
                performVisual(context, verify: true) { [weak self] in self?.finish(context) }
                return
            }
            guard displays.contains(where: { $0.identity == entry.identity && $0.active }) else { continue }
            switch dependencies.setEnabled(false, entry.identity) {
            case .success: context.disableFailures.removeValue(forKey: entry.identity)
            case .failure(let error): context.disableFailures[entry.identity] = error.message
            }
        }
        dependencies.schedule(0.7) { [weak self] in
            guard let self else { return }
            let displays = self.dependencies.displays(false)
            let remaining = unwanted.contains { entry in displays.contains { $0.identity == entry.identity && $0.active } }
            if remaining && attempt < 3 { self.disableUnwanted(context, attempt: attempt + 1) }
            else {
                self.performVisual(context, verify: true) { [weak self] in self?.finish(context) }
            }
        }
    }

    /// Names, ordering and an automatically learned mode are not user edits.
    static func settingsUnchanged(executed: DisplayPreset, saved: DisplayPreset) -> Bool {
        guard executed.name == saved.name, executed.displays.count == saved.displays.count else { return false }
        return executed.displays.allSatisfy { entry in
            let matches = saved.displays.filter { $0.identity == entry.identity }
            guard matches.count == 1, let current = matches.first,
                  entry.enabled == current.enabled,
                  entry.brightness == current.brightness,
                  entry.contrast == current.contrast else { return false }
            if let mode = entry.mode { return current.mode?.describesSameMode(as: mode) == true }
            return true
        }
    }

    static func configurationErrors(for preset: DisplayPreset, displays: [DisplayInfo]) -> [String] {
        preset.displays.compactMap { entry in
            let display = displays.first { $0.identity == entry.identity && $0.active }
            if entry.enabled {
                guard let display else { return "\(entry.name)：目标显示器未连接" }
                if let mode = entry.mode, display.currentMode?.describesSameMode(as: mode) != true {
                    return "\(entry.name)：未切换到保存的分辨率 \(mode.label)"
                }
            } else if display != nil { return "\(entry.name)：显示器没有按预设断开" }
            return nil
        }
    }

    private func finish(_ context: Context) {
        // The final snapshot is deliberately taken AFTER visual acknowledgements and topology changes.
        let displays = dependencies.displays(false)
        var errors: [String] = []
        for entry in context.preset.displays {
            let display = displays.first { $0.identity == entry.identity && $0.active }
            if entry.enabled {
                guard let display else {
                    errors.append("\(entry.name)：\(context.enableFailures[entry.identity] ?? "目标显示器未连接")")
                    continue
                }
                if let mode = entry.mode, display.currentMode?.describesSameMode(as: mode) != true {
                    errors.append("\(entry.name)：\(context.modeFailures[entry.identity] ?? "未切换到保存的分辨率 \(mode.label)")")
                }
                if let reason = context.visualFailures[entry.identity] { errors.append("\(entry.name)：\(reason)") }
                else if context.verifiedIDs[entry.identity] != display.id {
                    errors.append("\(entry.name)：尚未确认最终亮度和对比度，请重新应用预设")
                }
            } else if display != nil {
                errors.append("\(entry.name)：\(context.disableFailures[entry.identity] ?? "显示器没有按预设断开")")
            }
        }
        isRunning = false
        context.completion(errors)
    }
}
