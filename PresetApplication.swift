import Foundation
import CoreGraphics

/// Serializes a complete preset and validates the final state after every side effect.
/// Dependencies keep retries testable without changing physical displays or preferences.
final class PresetApplication {
    typealias VisualWrite = (VisualValues, Set<VisualField>, CGDirectDisplayID, @escaping (Result<Void, AppFailure>) -> Void) -> Void
    typealias VisualRead = (CGDirectDisplayID, @escaping (Result<VisualValues, AppFailure>) -> Void) -> Void
    typealias RotationOperation = (Int, String, @escaping (Result<Void, AppFailure>) -> Void) -> Void
    struct Dependencies {
        var displays: (Bool) -> [DisplayInfo]
        var setEnabled: (Bool, String) -> Result<Void, AppFailure>
        var setModes: ([(mode: DisplayModeInfo, identity: String)]) -> [String: AppFailure]
        var setVisual: VisualWrite
        var readVisual: VisualRead
        var schedule: (TimeInterval, @escaping () -> Void) -> Void
        var setRotation: RotationOperation = { _, _, completion in
            completion(.failure(AppFailure(message: "当前环境不支持旋转显示器。")))
        }
    }

    private final class Context {
        let preset: DisplayPreset
        let verifyVisualSettings: Bool
        let completion: ([String]) -> Void
        var enableFailures: [String: String] = [:]
        var modeFailures: [String: String] = [:]
        var rotationFailures: [String: String] = [:]
        var blockedRotations: Set<String> = []
        var connectionRequested = false
        var geometryRequested = false
        var disconnected: Set<String> = []
        var afterDisconnect = false
        var stoppedBeforeVisual = false
        var disableFailures: [String: String] = [:]
        var visualFailures: [String: AppFailure] = [:]
        var completedVisualIDs: [String: CGDirectDisplayID] = [:]
        init(_ preset: DisplayPreset, verifyVisualSettings: Bool, completion: @escaping ([String]) -> Void) {
            self.preset = preset
            self.verifyVisualSettings = verifyVisualSettings
            self.completion = completion
        }
    }

    private let dependencies: Dependencies
    private(set) var isRunning = false
    init(dependencies: Dependencies) { self.dependencies = dependencies }

    @discardableResult
    func apply(_ preset: DisplayPreset, verifyVisualSettings: Bool = true, completion: @escaping ([String]) -> Void) -> Bool {
        guard !isRunning else { return false }
        guard preset.displays.contains(where: \.enabled) else {
            completion(["预设没有设置要开启的显示器，请先编辑预设。"])
            return false
        }
        guard Set(preset.displays.map(\.identity)).count == preset.displays.count else {
            completion(["预设包含重复的显示器，请先编辑预设。"])
            return false
        }
        isRunning = true
        let context = Context(preset, verifyVisualSettings: verifyVisualSettings, completion: completion)
        connectTargets(context)
        waitForTargets(context, attempt: 0, signature: nil, stableCount: 0)
        return true
    }

    private func connectTargets(_ context: Context) {
        let displays = dependencies.displays(false)
        for entry in context.preset.displays where entry.enabled {
            if displays.contains(where: { $0.identity == entry.identity && $0.active && $0.canControl }) {
                context.enableFailures.removeValue(forKey: entry.identity)
                continue
            }
            context.connectionRequested = true
            switch dependencies.setEnabled(true, entry.identity) {
            case .success: context.enableFailures.removeValue(forKey: entry.identity)
            case .failure(let error): context.enableFailures[entry.identity] = error.message
            }
        }
    }

    private func waitForTargets(_ context: Context, attempt: Int, signature: String?, stableCount: Int) {
        let displays = dependencies.displays(true)
        let targets = context.preset.displays.filter(\.enabled)
        let resolved = targets.compactMap { entry in displays.first { $0.identity == entry.identity && $0.active && $0.canControl } }
        // Already-correct geometry needs no settling delay unless this operation
        // requested a topology change. Later stages still recheck fresh state.
        if attempt == 0, !context.connectionRequested, !context.afterDisconnect,
           resolved.count == targets.count,
           targets.allSatisfy({ entry in resolved.contains { $0.identity == entry.identity && geometryMatches(entry, display: $0, context: context) } }) {
            applyModes(context, attempt: 1)
            return
        }
        let ready = resolved.count == targets.count && targets.allSatisfy { entry in
            if let angle = entry.requestedRotation,
               resolved.contains(where: { $0.identity == entry.identity && $0.rotation != angle }) { return true }
            guard let requested = entry.requestedMode else { return true }
            return resolved.contains {
                $0.identity == entry.identity
                    && ($0.currentMode?.describesSameMode(as: requested) == true
                        || requested.matchingMode(in: $0.availableModes) != nil)
            }
        }
        let currentSignature = resolved.sorted { $0.identity < $1.identity }.map { display in
            let modes = display.availableModes.map { "\($0.modeID):\($0.label):\($0.pixelWidth)x\($0.pixelHeight)" }.sorted().joined(separator: ",")
            return "\(display.identity):\(display.id):\(display.rotation ?? -1):\(display.currentMode?.modeID ?? -1):\(modes)"
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
            stopBeforeVisual(context)
        } else {
            // A later retry can recover a slow connection. Only final validation emits errors.
            applyModes(context, attempt: 1)
        }
    }

    private func applyModes(_ context: Context, attempt: Int) {
        connectTargets(context)
        applyRotations(context, entries: context.preset.displays.filter(\.enabled), index: 0) { [weak self] in
            self?.configureModes(context, attempt: attempt)
        }
    }

    private func applyRotations(_ context: Context, entries: [DisplayPresetEntry], index: Int, completion: @escaping () -> Void) {
        guard index < entries.count else { completion(); return }
        let entry = entries[index]
        let next = { [weak self] in self?.applyRotations(context, entries: entries, index: index + 1, completion: completion) }
        guard let display = dependencies.displays(false).first(where: { $0.identity == entry.identity && $0.active && $0.canControl }) else { next(); return }
        // Follow-current is not an implicit request to restore an earlier angle.
        guard let angle = entry.requestedRotation else { next(); return }
        guard display.rotation != angle else {
            context.rotationFailures.removeValue(forKey: entry.identity)
            context.blockedRotations.remove(entry.identity)
            next(); return
        }
        guard !context.blockedRotations.contains(entry.identity) else { next(); return }
        context.geometryRequested = true
        dependencies.setRotation(angle, entry.identity) { result in
            switch result {
            case .success: context.rotationFailures.removeValue(forKey: entry.identity)
            case .failure(let error):
                context.rotationFailures[entry.identity] = error.message
                if error.reason != .general { context.blockedRotations.insert(entry.identity) }
            }
            next()
        }
    }

    private func geometryMatches(_ entry: DisplayPresetEntry, display: DisplayInfo, context: Context) -> Bool {
        let angle = entry.requestedRotation
        return (angle == nil || display.rotation == angle)
            && (entry.requestedMode.map { display.currentMode?.describesSameMode(as: $0) == true } ?? true)
    }

    private func configureModes(_ context: Context, attempt: Int) {
        let displays = dependencies.displays(true)
        let requests: [(mode: DisplayModeInfo, identity: String)] = context.preset.displays.compactMap { entry in
            guard entry.enabled, let requested = entry.requestedMode,
                  let display = displays.first(where: { $0.identity == entry.identity && $0.active && $0.canControl }),
                  display.currentMode?.describesSameMode(as: requested) != true else { return nil }
            // Reconnection can initially expose only a partial mode list. Keep
            // waiting for the saved mode instead of applying an approximate one.
            guard requested.matchingMode(in: display.availableModes) != nil else {
                context.modeFailures[entry.identity] = "找不到完全匹配的已保存分辨率 \(requested.label)，未改用其它缩放或刷新率。"
                return nil
            }
            // An exact, currently available mode can be applied independently
            // even if an explicitly requested rotation could not be changed.
            return (requested, entry.identity)
        }
        if !requests.isEmpty { context.geometryRequested = true }
        let failures = dependencies.setModes(requests)
        for request in requests { context.modeFailures[request.identity] = failures[request.identity]?.message }
        let advance = { [weak self] in
            guard let self else { return }
            let current = self.dependencies.displays(false)
            let connected = self.targetsConnected(context, displays: current)
            let retryableGeometry = context.preset.displays.contains { entry in
                guard entry.enabled,
                      let display = current.first(where: { $0.identity == entry.identity && $0.active && $0.canControl }) else { return false }
                let rotationPending = entry.requestedRotation.map { display.rotation != $0 } ?? false
                let modePending = entry.requestedMode.map { display.currentMode?.describesSameMode(as: $0) != true } ?? false
                return (rotationPending && !context.blockedRotations.contains(entry.identity)) || modePending
            }
            if (!connected || retryableGeometry) && attempt < 6 { self.applyModes(context, attempt: attempt + 1) }
            else if !connected { self.stopBeforeVisual(context) }
            else if context.afterDisconnect { self.applyVisual(context) }
            else { self.disableUnwanted(context, attempt: 1) }
        }
        let alreadyMatched = context.preset.displays.filter(\.enabled).allSatisfy { entry in
            displays.contains { $0.identity == entry.identity && $0.active && geometryMatches(entry, display: $0, context: context) }
        }
        if !context.connectionRequested && !context.geometryRequested && !context.afterDisconnect && alreadyMatched {
            advance()
        } else {
            dependencies.schedule(min(0.8 + Double(attempt - 1) * 0.45, 2.6), advance)
        }
    }

    private struct VisualTarget {
        let identity: String
        let id: CGDirectDisplayID
        let desired: VisualValues
    }

    private typealias VisualChange = (target: VisualTarget, fields: Set<VisualField>)

    private struct VisualMismatch {
        let target: VisualTarget
        let actual: VisualValues
        let fields: Set<VisualField>

        var failure: AppFailure {
            func percent(_ value: Double) -> String {
                if value > 0 && value < 0.00001 { return "<0.001%" }
                return (value * 100).formatted(.number.precision(.fractionLength(0...3))) + "%"
            }
            var details: [String] = []
            if fields.contains(.brightness) {
                details.append("亮度目标 \(percent(target.desired.brightness))，实际 \(percent(actual.brightness))")
            }
            if fields.contains(.contrast) {
                details.append("对比度目标 \(percent(target.desired.contrast))，实际 \(percent(actual.contrast))")
            }
            return AppFailure(message: "BetterDisplay 读回结果不一致：" + details.joined(separator: "；"))
        }
    }

    private func applyVisual(_ context: Context) {
        let current = dependencies.displays(false)
        guard targetsConnected(context, displays: current) else { stopBeforeVisual(context); return }
        let targets = context.preset.displays.compactMap { entry -> VisualTarget? in
            guard entry.enabled, let display = current.first(where: { $0.identity == entry.identity && $0.active && $0.canControl }) else { return nil }
            return VisualTarget(identity: entry.identity, id: display.id,
                                desired: VisualValues(brightness: entry.brightness, contrast: entry.contrast))
        }
        let changes: [VisualChange] = targets.map { ($0, [.brightness, .contrast]) }
        writeVisual(context, changes: changes) {
            if context.verifyVisualSettings { self.verifyVisual(context, targets: targets, allowCorrection: true) }
            else { self.finish(context) }
        }
    }

    private func targetsConnected(_ context: Context, displays: [DisplayInfo]) -> Bool {
        context.preset.displays.filter(\.enabled).allSatisfy { entry in
            displays.contains { $0.identity == entry.identity && $0.active && $0.canControl }
        }
    }

    // Every operation and callback runs on the main thread. Wait for all screens
    // in a batch before reading: a linked display may be changed by its peer.
    private func runVisualBatch<Item>(_ items: [Item], operation: (Item, @escaping () -> Void) -> Void,
                                      completion: @escaping () -> Void) {
        guard !items.isEmpty else { completion(); return }
        var remaining = items.count
        for item in items {
            operation(item) {
                remaining -= 1
                if remaining == 0 { completion() }
            }
        }
    }

    private func visualAddressIsCurrent(_ target: VisualTarget, context: Context) -> Bool {
        guard dependencies.displays(false).contains(where: {
            $0.identity == target.identity && $0.id == target.id && $0.active && $0.canControl
        }) else {
            context.visualFailures[target.identity] = AppFailure(message: "显示器编号或连接已变化，请重新应用预设。")
            return false
        }
        return true
    }

    private func writeVisual(_ context: Context, changes: [VisualChange], completion: @escaping () -> Void) {
        runVisualBatch(changes, operation: { change, done in
            let target = change.target
            guard self.visualAddressIsCurrent(target, context: context) else { done(); return }
            self.dependencies.setVisual(target.desired, change.fields, target.id) { result in
                switch result {
                case .success:
                    context.visualFailures[target.identity] = nil
                    if !context.verifyVisualSettings { context.completedVisualIDs[target.identity] = target.id }
                case .failure(let error): context.visualFailures[target.identity] = error
                }
                done()
            }
        }, completion: completion)
    }

    private func readAfterSettling(_ context: Context, targets: [VisualTarget],
                                   completion: @escaping ([VisualMismatch]) -> Void) {
        let readable = targets.filter {
            guard let failure = context.visualFailures[$0.identity] else { return true }
            return failure.reason == .unconfirmed // The write may have succeeded despite a lost ACK.
        }
        guard !readable.isEmpty else { completion([]); return }
        dependencies.schedule(0.35) {
            var mismatches: [VisualMismatch] = []
            self.runVisualBatch(readable, operation: { target, done in
                guard self.visualAddressIsCurrent(target, context: context) else { done(); return }
                self.dependencies.readVisual(target.id) { result in
                    switch result {
                    case .success(let actual):
                        context.visualFailures[target.identity] = nil
                        let fields = actual.mismatches(comparedTo: target.desired)
                        if fields.isEmpty { context.completedVisualIDs[target.identity] = target.id }
                        else {
                            context.completedVisualIDs[target.identity] = nil
                            mismatches.append(VisualMismatch(target: target, actual: actual, fields: fields))
                        }
                    case .failure(let error):
                        let detail = context.visualFailures[target.identity].map { $0.message + "\n读回失败：" } ?? ""
                        context.visualFailures[target.identity] = AppFailure(message: detail + error.message)
                    }
                    done()
                }
            }, completion: { completion(mismatches) })
        }
    }

    private func verifyVisual(_ context: Context, targets: [VisualTarget], allowCorrection: Bool) {
        readAfterSettling(context, targets: targets) { first in
            guard !first.isEmpty else { self.finish(context); return }
            let firstFields = Dictionary(uniqueKeysWithValues: first.map { ($0.target.identity, $0.fields) })
            self.readAfterSettling(context, targets: first.map(\.target)) { second in
                let corrections: [VisualChange] = second.compactMap { mismatch in
                    let persistent = mismatch.fields.intersection(firstFields[mismatch.target.identity] ?? [])
                    return persistent.isEmpty ? nil : (mismatch.target, persistent)
                }
                if allowCorrection && !corrections.isEmpty {
                    self.writeVisual(context, changes: corrections) {
                        self.verifyVisual(context, targets: targets, allowCorrection: false)
                    }
                } else {
                    for mismatch in second { context.visualFailures[mismatch.target.identity] = mismatch.failure }
                    self.finish(context)
                }
            }
        }
    }

    private func stopBeforeVisual(_ context: Context) {
        context.stoppedBeforeVisual = true
        let displays = dependencies.displays(false)
        for entry in context.preset.displays where !entry.enabled {
            if context.disconnected.contains(entry.identity) {
                // The target changed after a topology operation. Restore screens
                // disconnected by this attempt before returning the error.
                switch dependencies.setEnabled(true, entry.identity) {
                case .success: context.disableFailures[entry.identity] = "目标显示器未就绪，已请求重新连接以保留可用屏幕。"
                case .failure(let error): context.disableFailures[entry.identity] = "目标显示器未就绪，重新连接失败：" + error.message
                }
            } else if displays.contains(where: { $0.identity == entry.identity && $0.active }) {
                context.disableFailures[entry.identity] = "目标显示器尚未全部连接，已暂缓断开以保留可用屏幕。"
            }
        }
        dependencies.schedule(context.disconnected.isEmpty ? 0 : 0.9) { [weak self] in self?.finish(context) }
    }

    private func disableUnwanted(_ context: Context, attempt: Int) {
        let unwanted = context.preset.displays.filter { !$0.enabled }
        var requestedDisconnect = false
        for entry in unwanted {
            let displays = dependencies.displays(false)
            // Keep connection protection independent of optional geometry.
            guard targetsConnected(context, displays: displays) else { stopBeforeVisual(context); return }
            guard displays.contains(where: { $0.identity == entry.identity && $0.active }) else { continue }
            requestedDisconnect = true
            switch dependencies.setEnabled(false, entry.identity) {
            case .success:
                context.disconnected.insert(entry.identity)
                context.disableFailures.removeValue(forKey: entry.identity)
            case .failure(let error): context.disableFailures[entry.identity] = error.message
            }
        }
        let advance = { [weak self] in
            guard let self else { return }
            let displays = self.dependencies.displays(false)
            let remaining = unwanted.contains { entry in displays.contains { $0.identity == entry.identity && $0.active } }
            if remaining && attempt < 3 { self.disableUnwanted(context, attempt: attempt + 1) }
            else if context.disconnected.isEmpty { self.applyVisual(context) }
            else {
                context.afterDisconnect = true
                self.waitForTargets(context, attempt: 0, signature: nil, stableCount: 0)
            }
        }
        if requestedDisconnect { dependencies.schedule(0.7, advance) }
        else { advance() }
    }

    /// Names and ordering are metadata; explicit geometry choices are settings.
    static func settingsUnchanged(executed: DisplayPreset, saved: DisplayPreset) -> Bool {
        guard executed.name == saved.name, executed.displays.count == saved.displays.count else { return false }
        return executed.displays.allSatisfy { entry in
            let matches = saved.displays.filter { $0.identity == entry.identity }
            guard matches.count == 1, let current = matches.first,
                  entry.enabled == current.enabled,
                  entry.brightness == current.brightness,
                  entry.contrast == current.contrast,
                  entry.rotation == current.rotation,
                  entry.applyGeometry == current.applyGeometry else { return false }
            switch (entry.mode, current.mode) {
            case (nil, nil): return true
            case let (mode?, other?): return mode.describesSameMode(as: other)
            default: return false
            }
        }
    }

    static func configurationErrors(for preset: DisplayPreset, displays: [DisplayInfo]) -> [String] {
        preset.displays.compactMap { entry in
            let display = displays.first { $0.identity == entry.identity && $0.active }
            if entry.enabled {
                guard let display else { return "\(entry.name)：目标显示器未连接" }
                guard display.canControl else { return "\(entry.name)：无法核实显示器身份" }
                if let angle = entry.requestedRotation, display.rotation != angle {
                    return "\(entry.name)：未恢复保存的旋转角度 \(angle)°"
                }
                if let mode = entry.requestedMode, display.currentMode?.describesSameMode(as: mode) != true {
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
                guard display.canControl else {
                    errors.append("\(entry.name)：无法核实显示器身份，未确认预设完成")
                    continue
                }
                if let angle = entry.requestedRotation, display.rotation != angle {
                    let actual = display.rotation.map { "\($0)°" } ?? "无法读取"
                    let detail = context.rotationFailures[entry.identity].map { "\n\($0)" } ?? ""
                    errors.append("\(entry.name)：预设旋转 \(angle)°，当前 \(actual)。\(detail)")
                }
                if let mode = entry.requestedMode, display.currentMode?.describesSameMode(as: mode) != true {
                    errors.append("\(entry.name)：\(context.modeFailures[entry.identity] ?? "未切换到保存的分辨率 \(mode.label)")")
                }
                if let failure = context.visualFailures[entry.identity] { errors.append("\(entry.name)：\(failure.message)") }
                else if !context.stoppedBeforeVisual && context.completedVisualIDs[entry.identity] != display.id {
                    let detail = context.verifyVisualSettings ? "尚未确认最终亮度和对比度" : "显示器编号已变化，无法确认亮度和对比度指令已送达当前显示器"
                    errors.append("\(entry.name)：\(detail)，请重新应用预设")
                }
            } else if display != nil || (context.stoppedBeforeVisual && context.disconnected.contains(entry.identity)) {
                errors.append("\(entry.name)：\(context.disableFailures[entry.identity] ?? "显示器没有按预设断开")")
            }
        }
        if context.stoppedBeforeVisual {
            errors.append("目标显示器连接未就绪，已停止调整亮度和对比度，请确认连接后重试。")
        } else if !errors.isEmpty {
            let confirmed = context.preset.displays.compactMap { entry -> String? in
                guard entry.enabled, context.visualFailures[entry.identity] == nil,
                      let display = displays.first(where: { $0.identity == entry.identity && $0.active && $0.canControl }),
                      context.completedVisualIDs[entry.identity] == display.id else { return nil }
                return entry.name
            }
            if !confirmed.isEmpty {
                let detail = context.verifyVisualSettings ? "亮度和对比度已应用并确认" : "亮度和对比度指令已发送"
                errors.append("部分完成：\(confirmed.joined(separator: "、"))的\(detail)；其余未完成设置见上方。")
            }
        }
        isRunning = false
        context.completion(errors)
    }
}
