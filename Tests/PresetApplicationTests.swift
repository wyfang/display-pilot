import AppKit

private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}

private let mode = DisplayModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60)
private func screen(_ identity: String, _ id: UInt32, active: Bool = true, currentMode: DisplayModeInfo? = mode,
                    availableModes: [DisplayModeInfo] = [mode], rotation: Int? = 0) -> DisplayInfo {
    DisplayInfo(id: id, name: identity, active: active, builtin: false, identity: identity,
                currentMode: currentMode, availableModes: availableModes, rotation: rotation)
}
private func entry(_ identity: String, enabled: Bool, brightness: Double = 0.5,
                   savedMode: DisplayModeInfo? = mode, rotation: Int? = nil) -> DisplayPresetEntry {
    DisplayPresetEntry(identity: identity, name: identity, enabled: enabled, brightness: brightness,
                       contrast: 0, mode: savedMode, rotation: rotation)
}
private func transposed(_ mode: DisplayModeInfo) -> DisplayModeInfo {
    DisplayModeInfo(width: mode.height, height: mode.width, pixelWidth: mode.pixelHeight,
                    pixelHeight: mode.pixelWidth, refreshRate: mode.refreshRate)
}

private final class Fixture {
    var displays = [screen("a", 1), screen("b", 2), screen("spare", 3)]
    var jobs: [() -> Void] = []
    var visualCalls = 0
    var connectionCalls = 0
    var elapsed: TimeInterval = 0
    var modeRequests: [(time: TimeInterval, identities: [String])] = []
    var rotationRequests: [(rotation: Int, identity: String)] = []
    var enabledRequests: [String] = []
    var events: [String] = []
    var visualValues: [(displayID: UInt32, brightness: Double, contrast: Double)] = []
    var verifiedVisualValues: [(displayID: UInt32, brightness: Double, contrast: Double)] = []
    var beforeSnapshot: ((Bool) -> Void)?
    var beforeVisual: (() -> Void)?
    var afterDisable: (() -> Void)?
    var afterEnable: (() -> Void)?
    var afterRotation: (() -> Void)?
    var afterFailedRotation: (() -> Void)?
    var afterModes: (() -> Void)?
    var afterVerify: (() -> Void)?
    var recoverOnConnection: Int?
    var visualError: AppFailure?
    var visualErrorsByID: [UInt32: AppFailure] = [:]
    var rotationError: AppFailure?
    var modeErrors: [String: AppFailure] = [:]
    var disableErrors: [String: AppFailure] = [:]
    var result: [String]?
    lazy var application = PresetApplication(dependencies: .init(
        displays: { [unowned self] includeModes in
            self.beforeSnapshot?(includeModes)
            return self.displays
        },
        setEnabled: { [unowned self] enabled, identity in
            if !enabled, let error = self.disableErrors[identity] { return .failure(error) }
            if enabled {
                self.connectionCalls += 1
                self.enabledRequests.append(identity)
                if self.recoverOnConnection == self.connectionCalls { self.displays.append(screen("a", 1)) }
            }
            guard let index = self.displays.firstIndex(where: { $0.identity == identity }) else {
                return .failure(AppFailure(message: "waiting"))
            }
            let current = self.displays[index]
            self.displays[index] = screen(identity, current.id, active: enabled, currentMode: current.currentMode,
                availableModes: current.availableModes, rotation: current.rotation)
            self.events.append("\(enabled ? "enable" : "disable"):\(identity)")
            if enabled { self.afterEnable?() } else { self.afterDisable?() }
            return .success(())
        },
        setModes: { [unowned self] requests in
            if !requests.isEmpty { self.modeRequests.append((self.elapsed, requests.map(\.identity))) }
            for request in requests {
                if self.modeErrors[request.identity] != nil { continue }
                guard let index = self.displays.firstIndex(where: { $0.identity == request.identity }) else { continue }
                let current = self.displays[index]
                self.displays[index] = screen(current.identity, current.id, active: current.active,
                    currentMode: request.mode, availableModes: current.availableModes, rotation: current.rotation)
                self.events.append("mode:\(request.identity)")
            }
            self.afterModes?()
            return self.modeErrors.filter { identity, _ in requests.contains { $0.identity == identity } }
        },
        setVisual: { [unowned self] brightness, contrast, id, completion in
            self.visualCalls += 1
            self.visualValues.append((id, brightness, contrast))
            self.events.append("visual:\(id)")
            self.beforeVisual?()
            completion((self.visualErrorsByID[id] ?? self.visualError).map { .failure($0) } ?? .success(()))
        },
        verifyVisual: { [unowned self] brightness, contrast, id, completion in
            self.verifiedVisualValues.append((id, brightness, contrast))
            self.afterVerify?()
            completion((self.visualErrorsByID[id] ?? self.visualError).map { .failure($0) } ?? .success(()))
        },
        schedule: { [unowned self] delay, action in
            self.jobs.append { [unowned self] in self.elapsed += delay; action() }
        },
        setRotation: { [unowned self] rotation, identity, completion in
            self.rotationRequests.append((rotation, identity))
            self.events.append("rotation:\(identity)")
            if let error = self.rotationError { self.afterFailedRotation?(); completion(.failure(error)); return }
            guard let index = self.displays.firstIndex(where: { $0.identity == identity && $0.active }) else {
                completion(.failure(AppFailure(message: "旋转目标未连接"))); return
            }
            let current = self.displays[index]
            let swapAxes = (current.rotation ?? 0) % 180 != rotation % 180
            self.displays[index] = screen(identity, current.id, active: current.active,
                currentMode: swapAxes ? current.currentMode.map(transposed) : current.currentMode,
                availableModes: swapAxes ? current.availableModes.map(transposed) : current.availableModes,
                rotation: rotation)
            self.afterRotation?()
            completion(.success(()))
        }
    ))
    var preset = DisplayPreset(name: "A", displays: [entry("a", enabled: true), entry("b", enabled: true), entry("spare", enabled: false)])
    func start() {
        result = nil
        application.apply(preset) { [unowned self] in self.result = $0 }
    }
    func drain() {
        var count = 0
        while !jobs.isEmpty {
            count += 1
            expect(count < 100, "retry must be bounded")
            jobs.removeFirst()()
        }
    }
}

@main
private enum PresetApplicationTests {
    static func main() {
        do {
            let f = Fixture(); f.start()
            expect(!f.application.apply(f.preset) { _ in fatalError("concurrent completion") }, "concurrent operation rejected")
            f.drain()
            expect(f.result == [], "normal application should succeed")
            expect(!f.displays.first { $0.identity == "spare" }!.active, "unwanted screen disabled")
            expect(!f.application.isRunning, "application finishes")
        }
        do {
            let f = Fixture(); f.displays.removeAll { $0.identity == "a" }
            f.recoverOnConnection = 9 // Initial wait times out, the mode pass reconnects it.
            f.start(); f.drain()
            expect(f.connectionCalls == 9, "exercise post-timeout recovery")
            expect(f.result == [], "recovered transient failures must not persist")
        }
        do {
            let f = Fixture()
            f.beforeVisual = { f.displays.removeAll { $0.identity == "a" } }
            f.start(); f.drain()
            expect(f.result?.contains { $0.contains("a：目标显示器未连接") } == true, "final connection verified")
        }
        do {
            let f = Fixture()
            let changed = DisplayModeInfo(width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720, refreshRate: 60)
            f.afterDisable = { f.displays[0] = screen("a", 1, currentMode: changed) }
            f.start(); f.drain()
            expect(f.result == [], "restore a mode changed by the disconnection before visual settings")
            expect(f.displays[0].currentMode == mode, "the saved exact mode is restored after topology changes")
            expect(f.events.firstIndex(of: "mode:a")! < f.events.firstIndex(of: "visual:1")!, "restore geometry before changing brightness")
        }
        do {
            let f = Fixture(); f.displays = [screen("spare", 3)]
            f.start(); f.drain()
            expect(f.displays[0].active, "never disable spare when all targets unavailable")
            expect(f.result?.isEmpty == false, "missing all targets reported")
        }
        do {
            let f = Fixture(); f.visualError = AppFailure(message: "BetterDisplay 超时")
            f.start(); f.drain()
            expect(f.result?.contains { $0.contains("BetterDisplay 超时") } == true, "visual timeout must prevent success")
            expect(f.visualCalls == 4, "retry visual errors once for two targets")
        }
        do {
            let f = Fixture()
            f.afterVerify = { f.displays[0] = screen("a", 9) }
            f.start(); f.drain()
            expect(f.result?.contains { $0.contains("最终亮度") } == true, "changed display ID invalidates visual verification")
        }
        do {
            var original = Fixture().preset
            original.displays[0].mode = nil
            var refreshed = original
            refreshed.displays[0].name = "Localized monitor name"
            refreshed.displays.reverse()
            expect(PresetApplication.settingsUnchanged(executed: original, saved: refreshed), "metadata names and ordering are not user edits")
            var modeChanged = original
            modeChanged.displays[0].mode = mode
            expect(!PresetApplication.settingsUnchanged(executed: original, saved: modeChanged), "keeping current mode is an explicit V5 choice")
            refreshed.displays[0].brightness = 0.8
            expect(!PresetApplication.settingsUnchanged(executed: original, saved: refreshed), "real settings edit must invalidate completion")
        }
        do {
            let f = Fixture()
            let temporary = DisplayModeInfo(width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720, refreshRate: 60)
            f.displays[0] = screen("a", 1, currentMode: temporary, availableModes: [temporary])
            f.beforeSnapshot = { includeModes in
                guard includeModes, f.elapsed >= 17, f.modeRequests.isEmpty else { return }
                f.displays[0] = screen("a", 1, currentMode: temporary, availableModes: [temporary, mode])
            }
            f.start(); f.drain()
            expect(f.modeRequests.count == 1 && f.modeRequests[0].time >= 17, "wait for the saved mode after a partial mode list and the initial timeout")
            expect(f.result == [], "late mode enumeration recovers without a stale error")
        }
        do {
            let f = Fixture()
            f.displays[0] = screen("a", 1, availableModes: [])
            f.start(); f.drain()
            expect(f.result == [], "an already selected exact mode does not require enumeration")
            expect(f.elapsed < 8, "an already selected mode should not wait for the full timeout")
        }
        do {
            let f = Fixture()
            let temporary = DisplayModeInfo(width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720, refreshRate: 60)
            f.displays[0] = screen("a", 1, currentMode: temporary, availableModes: [temporary])
            f.start(); f.drain()
            expect(f.modeRequests.isEmpty, "an unavailable saved mode must not be replaced by another mode")
            expect(!f.displays.first { $0.identity == "spare" }!.active, "a mode failure does not cancel a requested disconnection when all targets are connected")
            expect(f.result?.contains { $0.contains("找不到完全匹配") } == true, "unavailable saved mode reported after bounded retries")
            expect(f.result?.contains { $0.contains("部分完成") } == true, "report geometry failure separately from completed visual settings")
            expect(f.visualCalls == 2 && f.verifiedVisualValues.count == 2, "unavailable geometry does not cancel independent visual settings")
        }
        do {
            let f = Fixture(); f.displays.removeAll { $0.identity == "a" }
            f.start(); f.drain()
            expect(f.displays.first { $0.identity == "spare" }!.active, "one recovered target is insufficient to disable a useful screen")
            expect(f.result?.contains { $0.contains("a：waiting") } == true, "the missing target retains its actual connection failure")
            expect(f.visualCalls == 0, "partial target recovery must not change brightness")
        }
        portraitRotationSurvivesDisconnect()
        followCurrentAllowsNaturalDirectionChanges()
        sleepAndWorkRoundTrip()
        brightnessOnlyPresetAllowsOrientationChanges()
        failedRotationDoesNotBlockOtherSettings()
        unavailableModeAfterDisconnectDoesNotBlockVisual()
        delayedModesAfterRotationRecover()
        let identified = DisplayInfo(id: 1, name: "Display", active: true, builtin: false,
            identity: "uuid:restored", currentMode: mode, availableModes: [mode], legacyIdentity: "external-1-2-123")
        expect(DisplayIdentity.migrationTarget(for: "hardware:external-1-2-123", displays: [identified]) == "uuid:restored", "temporary hardware identity upgrades to UUID")
        legacyBlackoutIgnoresUnavailableGeometry()
        explicitBlackoutAppliesGeometry()
        mixedPresetGeometryFailureDoesNotBlockBlackout()
        topologyChangesBeforeVisualAreRejected()
        alreadyMatchedPresetsSkipSettling()
        licenseFailureIsNotRetried()
        naturalRecoveryClearsLicenseFailure()
        oppositePortraitAnglesRemainDistinct()
        exactModeAppliesDespiteRotationFailure()
        modeWriteFailureDoesNotBlockVisual()
        disableFailureDoesNotBlockVisual()
        visualFailureIsIndependentPerDisplay()
        connectionLossAfterDisconnectRestoresScreen()
        identityUncertaintyInvalidatesCompletion()
        print("PresetApplication: 33 regression scenarios and hardware identity upgrade passed")
    }

    private static func legacyBlackoutIgnoresUnavailableGeometry() {
        let f = rotationFixture(brightness: 0)
        f.preset.displays[0].applyGeometry = nil
        f.preset.displays[0].rotation = nil
        f.displays[0] = screen("Philips", 1, currentMode: transposed(portrait), availableModes: [transposed(portrait)], rotation: 0)
        f.rotationError = AppFailure(message: "Pro required")
        f.start(); f.drain()
        expect(f.result == [], "a legacy blackout succeeds despite unavailable portrait geometry and no rotation license")
        expect(f.rotationRequests.isEmpty && f.modeRequests.isEmpty, "blackout does not request geometry changes")
        expect(f.visualValues.contains { $0.displayID == 1 && $0.brightness == 0 }, "Philips is blackened")
        expect(f.displays.first { $0.identity == "Dell" }?.active == false, "Dell is disconnected")
        expect(PresetApplication.configurationErrors(for: f.preset, displays: f.displays).isEmpty, "successful blackout keeps its menu check despite landscape geometry")
        expect(f.preset.displays[0].mode == portrait, "saved geometry is retained")
    }

    private static func explicitBlackoutAppliesGeometry() {
        let f = Fixture()
        let saved = DisplayModeInfo(width: 1600, height: 900, pixelWidth: 1600, pixelHeight: 900, refreshRate: 60)
        let current = DisplayModeInfo(width: 1152, height: 2048, pixelWidth: 2304, pixelHeight: 4096, refreshRate: 60)
        f.displays = [screen("27B1N3800", 1, currentMode: current, availableModes: [transposed(saved)], rotation: 270),
                      screen("DELL U2720QM", 2)]
        f.preset = DisplayPreset(name: "息屏模式", displays: [
            entry("27B1N3800", enabled: true, brightness: 0, savedMode: saved, rotation: 0),
            entry("DELL U2720QM", enabled: false)
        ])
        f.preset.displays[0].applyGeometry = true
        f.preset.displays[0].contrast = -0.9
        let original = f.preset
        f.start(); f.drain()
        expect(f.result == [], "explicit blackout geometry remains an independent request")
        expect(f.rotationRequests.count == 1 && f.modeRequests.count == 1, "explicit blackout applies the requested rotation and exact mode")
        expect(f.events == ["rotation:27B1N3800", "mode:27B1N3800", "disable:DELL U2720QM", "visual:1"], "apply geometry, disconnect Dell, then blacken Philips")
        expect(f.displays[1].active == false && f.displays[0].rotation == 0 && f.displays[0].currentMode == saved,
               "explicit blackout preserves the requested final geometry")
        expect(f.visualValues.count == 1 && f.visualValues[0].displayID == 1
               && f.visualValues[0].brightness == 0 && f.visualValues[0].contrast == -0.9,
               "apply the saved blackout brightness and contrast")
        expect(f.verifiedVisualValues.contains { $0.displayID == 1 && $0.brightness == 0 && $0.contrast == -0.9 },
               "verify both saved visual settings before reporting success")
        expect(f.preset == original && f.preset.displays[0].applyGeometry == true, "preserve all saved fields including the explicit geometry choice")
        expect(PresetApplication.configurationErrors(for: f.preset, displays: f.displays).isEmpty,
               "menu verification accepts all explicitly requested blackout settings")
    }

    private static func mixedPresetGeometryFailureDoesNotBlockBlackout() {
        let f = Fixture()
        f.preset.displays[0].brightness = 0
        f.preset.displays[0].applyGeometry = false
        f.preset.displays[0].rotation = 90
        f.preset.displays[1].rotation = 90
        f.preset.displays[1].mode = transposed(mode)
        f.rotationError = AppFailure(message: "Pro required.")
        f.start(); f.drain()
        expect(f.result?.contains { $0.contains("b：") && $0.contains("Pro required.") } == true,
               "the nonzero-brightness target retains strict rotation failure reporting")
        expect(f.result?.filter { $0.hasPrefix("b：") }.count == 2,
               "report both independently requested rotation and exact mode failures")
        expect(!f.rotationRequests.isEmpty && f.rotationRequests.allSatisfy { $0.identity == "b" },
               "only the nonzero-brightness target requests rotation in a mixed preset")
        expect(f.visualCalls == 2 && f.verifiedVisualValues.count == 2, "geometry failure does not cancel either target's visual settings")
        expect(!f.displays.first { $0.identity == "spare" }!.active, "connected visible targets allow the requested spare disconnection")
    }

    private static func topologyChangesBeforeVisualAreRejected() {
        let f = Fixture()
        f.preset.displays.removeAll { !$0.enabled }
        f.displays.removeAll { $0.identity == "spare" }
        f.afterModes = { f.displays.removeAll { $0.identity == "a" } }
        f.start(); f.drain()
        expect(f.result?.isEmpty == false, "late target disappearance prevents successful application")
        expect(f.visualCalls == 0, "recheck all targets immediately before visual changes")
    }

    private static func alreadyMatchedPresetsSkipSettling() {
        let f = Fixture()
        f.preset.displays.removeAll { !$0.enabled }
        f.displays.removeAll { $0.identity == "spare" }
        f.start(); f.drain()
        expect(f.result == [] && f.elapsed < 0.5, "already-matched topology and geometry skip empty settling delays")
        expect(f.connectionCalls == 0 && f.modeRequests.isEmpty && f.rotationRequests.isEmpty, "fast path does not reconfigure matched displays")
        expect(f.visualValues.count == 2 && f.verifiedVisualValues.count == 2, "fast path still sets and verifies every target's visual settings")
        let failed = Fixture()
        failed.preset.displays.removeAll { !$0.enabled }
        failed.displays.removeAll { $0.identity == "spare" }
        failed.visualError = AppFailure(message: "readback mismatch")
        failed.start(); failed.drain()
        expect(failed.result?.contains { $0.contains("readback mismatch") } == true, "fast path cannot hide visual readback failures")
    }

    private static func licenseFailureIsNotRetried() {
        let f = rotationFixture()
        f.rotationError = AppFailure(message: "Pro required.", reason: .requiresPro)
        f.start(); f.drain()
        expect(f.rotationRequests.count == 1, "an explicit license rejection is not sent six times")
        expect(f.result?.contains { $0.contains("Pro required.") } == true && f.visualCalls == 1, "license failure preserves its error while visual settings continue")
        expect(!f.displays[1].active && f.enabledRequests.isEmpty, "geometry rejection does not undo an otherwise completed disconnection")
    }

    private static func naturalRecoveryClearsLicenseFailure() {
        let f = rotationFixture()
        f.rotationError = AppFailure(message: "Pro required.", reason: .requiresPro)
        f.afterFailedRotation = {
            f.jobs.append { f.displays[0] = screen("Philips", 1, currentMode: portrait, availableModes: [portrait], rotation: 90) }
        }
        f.start(); f.drain()
        expect(f.result == [] && f.rotationRequests.count == 1 && f.visualCalls == 1, "a fresh matching state can recover despite an earlier license rejection")
    }

    private static func oppositePortraitAnglesRemainDistinct() {
        let f = rotationFixture(rotation: 270)
        f.afterDisable = nil
        f.rotationError = AppFailure(message: "Pro required.", reason: .requiresPro)
        f.start(); f.drain()
        expect(f.result?.contains { $0.contains("预设旋转 90°，当前 270°") } == true, "equal portrait resolutions do not make opposite rotation angles equivalent")
        expect(f.rotationRequests.count == 1 && f.visualCalls == 1 && !f.displays[1].active, "opposite-angle failure does not cancel connection and visual settings")
    }

    private static func exactModeAppliesDespiteRotationFailure() {
        let f = rotationFixture(rotation: 270)
        let temporary = DisplayModeInfo(width: 720, height: 1280, pixelWidth: 720, pixelHeight: 1280, refreshRate: 60)
        f.displays[0] = screen("Philips", 1, currentMode: temporary, availableModes: [temporary, portrait], rotation: 270)
        f.afterDisable = nil
        f.rotationError = AppFailure(message: "Pro required.", reason: .requiresPro)
        f.start(); f.drain()
        expect(f.rotationRequests.count == 1 && f.modeRequests.count == 1, "a denied rotation does not prevent a currently available exact resolution")
        expect(f.displays[0].currentMode == portrait && f.displays[0].rotation == 270, "mode and rotation remain distinct settings")
        expect(f.visualCalls == 1 && f.verifiedVisualValues.count == 1, "independent mode and visual settings complete")
        expect(f.result?.contains { $0.contains("预设旋转 90°，当前 270°") } == true
               && f.result?.contains { $0.contains("分辨率") } == false, "report only the setting that still differs")
    }

    private static func modeWriteFailureDoesNotBlockVisual() {
        let f = Fixture()
        f.preset.displays.removeAll { !$0.enabled }
        f.displays.removeAll { $0.identity == "spare" }
        let temporary = DisplayModeInfo(width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720, refreshRate: 60)
        f.displays[0] = screen("a", 1, currentMode: temporary, availableModes: [temporary, mode])
        f.modeErrors["a"] = AppFailure(message: "mode write rejected")
        f.start(); f.drain()
        expect(f.modeRequests.count == 6, "transient mode failures retain bounded retries")
        expect(f.result?.contains { $0.contains("a：mode write rejected") } == true, "preserve the actual mode failure")
        expect(f.visualValues.count == 2 && f.verifiedVisualValues.count == 2, "both targets receive and verify visual settings after a mode error")
        expect(f.result?.contains { $0.contains("部分完成") } == true && !f.application.isRunning, "partial completion releases the application lock")
    }

    private static func disableFailureDoesNotBlockVisual() {
        let f = Fixture()
        f.disableErrors["spare"] = AppFailure(message: "disconnect rejected")
        f.start(); f.drain()
        expect(f.result?.contains { $0.contains("spare：disconnect rejected") } == true, "preserve the actual disconnection failure")
        expect(f.displays.first { $0.identity == "spare" }!.active, "a rejected disconnection remains accurately reported")
        expect(f.visualValues.count == 2 && f.verifiedVisualValues.count == 2, "disconnection rejection does not block the connected targets' visual settings")
        expect(f.result?.contains { $0.contains("已停止调整") } == false, "never claim visual settings were stopped after applying them")
    }

    private static func visualFailureIsIndependentPerDisplay() {
        let f = Fixture()
        f.visualErrorsByID[1] = AppFailure(message: "visual readback rejected")
        f.start(); f.drain()
        expect(f.result?.contains { $0.contains("a：visual readback rejected") } == true, "one visual failure is retained")
        expect(f.verifiedVisualValues.contains { $0.displayID == 2 }, "the other display is still verified")
        expect(f.result?.contains { $0.contains("部分完成：b的亮度和对比度已应用并确认") } == true, "claim partial visual success only for the verified target")
        expect(!f.displays.first { $0.identity == "spare" }!.active, "an independent visual error does not misreport a completed disconnection")
    }

    private static func connectionLossAfterDisconnectRestoresScreen() {
        let f = rotationFixture()
        f.afterDisable = { f.displays.removeAll { $0.identity == "Philips" } }
        f.start(); f.drain()
        expect(f.visualCalls == 0, "missing target identity still prevents visual writes")
        expect(f.displays.first { $0.identity == "Dell" }!.active && f.enabledRequests.contains("Dell"), "connection loss restores the screen disconnected by this operation")
        expect(f.result?.contains { $0.contains("已请求重新连接") } == true, "connection safety recovery is explained")
        expect(!f.application.isRunning, "connection recovery failure completes within its retry bound")
    }

    private static func identityUncertaintyInvalidatesCompletion() {
        let f = Fixture()
        f.afterVerify = {
            f.displays[0] = DisplayInfo(id: 1, name: "a", active: true, builtin: false, identity: "a",
                                       currentMode: mode, availableModes: [mode], canControl: false, rotation: 0)
        }
        f.start(); f.drain()
        expect(f.result?.contains { $0.contains("a：无法核实显示器身份") } == true, "matching numerical ID cannot validate an uncertain final identity")
        expect(!PresetApplication.configurationErrors(for: f.preset, displays: f.displays).isEmpty, "menu check also rejects uncertain identity")
        expect(f.result?.contains { $0.contains("部分完成：b的亮度和对比度已应用并确认") } == true, "partial success excludes the identity that became uncertain")
    }

    private static let portrait = DisplayModeInfo(width: 1080, height: 1920, pixelWidth: 1080, pixelHeight: 1920, refreshRate: 60)

    private static func rotationFixture(brightness: Double = 0.5, rotation: Int = 90, savedRotation: Int? = 90) -> Fixture {
        let f = Fixture()
        f.displays = [screen("Philips", 1, currentMode: portrait, availableModes: [portrait], rotation: rotation), screen("Dell", 2)]
        f.preset = DisplayPreset(name: "显示配置", displays: [
            entry("Philips", enabled: true, brightness: brightness, savedMode: portrait, rotation: savedRotation),
            entry("Dell", enabled: false)
        ])
        f.preset.displays[0].applyGeometry = true
        f.afterDisable = {
            f.displays[0] = screen("Philips", 1, currentMode: transposed(portrait),
                availableModes: [transposed(portrait)], rotation: 0)
        }
        return f
    }

    private static func portraitRotationSurvivesDisconnect() {
        let f = rotationFixture()
        f.beforeVisual = {
            expect(f.displays[0].rotation == 90 && f.displays[0].currentMode == portrait,
                   "Philips must return to its saved portrait mode before applying positive brightness")
            expect(!f.displays[1].active, "Dell must already be disconnected before dimming")
        }
        f.start(); f.drain()
        expect(f.result == [], "portrait preset survives the actual 90-to-0 topology failure")
        expect(f.rotationRequests.count == 1 && f.rotationRequests[0].rotation == 90, "restore the exact saved rotation")
        expect(f.events == ["disable:Dell", "rotation:Philips", "visual:1"], "disconnect, restore rotation, then apply brightness")
        expect(f.visualValues.last?.brightness == 0.5, "positive brightness is applied after geometry is restored")
    }

    private static func followCurrentAllowsNaturalDirectionChanges() {
        let f = rotationFixture(rotation: 270, savedRotation: nil)
        f.afterDisable = { f.displays[0] = screen("Philips", 1, currentMode: portrait, availableModes: [portrait], rotation: 90) }
        f.start(); f.drain()
        expect(f.result == [], "follow-current accepts the system's new direction after a topology change")
        expect(f.rotationRequests.isEmpty, "no implicit rotation is learned from an earlier snapshot")
        expect(f.displays[0].rotation == 90 && f.displays[0].currentMode == portrait, "only the explicit resolution is verified")
    }

    private static func sleepAndWorkRoundTrip() {
        let f = rotationFixture(brightness: 0)
        f.preset.displays[0].applyGeometry = false
        f.start(); f.drain()
        expect(f.result == [] && !f.displays[1].active && f.visualValues.last?.brightness == 0, "complete sleep preset")
        expect(f.rotationRequests.isEmpty && f.modeRequests.isEmpty, "sleep applies zero brightness without restoring geometry")
        f.preset = DisplayPreset(name: "工作", displays: [
            entry("Philips", enabled: true, brightness: 0.65, savedMode: portrait, rotation: 90),
            entry("Dell", enabled: true, brightness: 0.75, rotation: 0)
        ])
        f.afterEnable = {
            f.displays[0] = screen("Philips", 1, currentMode: transposed(portrait),
                availableModes: [transposed(portrait)], rotation: 0)
        }
        f.start(); f.drain()
        expect(f.result == [], "the work preset succeeds after the full sleep preset")
        expect(f.displays.allSatisfy(\.active), "both real displays are reconnected")
        expect(f.displays[0].rotation == 90 && f.displays[0].currentMode == portrait, "work restores exact portrait geometry after reconnection")
        expect(f.visualValues.suffix(2).map(\.brightness) == [0.65, 0.75], "work restores both requested brightness values")
        expect(f.rotationRequests.count == 1 && !f.application.isRunning, "only work restores rotation and both applications release the lock")
    }

    private static func brightnessOnlyPresetAllowsOrientationChanges() {
        let f = rotationFixture()
        f.preset.displays[0].mode = nil
        f.preset.displays[0].rotation = nil
        f.start(); f.drain()
        expect(f.result == [], "unspecified resolution and rotation are not implicit constraints")
        expect(f.displays[0].rotation == 0 && f.displays[0].currentMode == transposed(portrait), "brightness-only preset leaves changed geometry alone")
        expect(f.modeRequests.isEmpty && f.rotationRequests.isEmpty && f.visualCalls == 1, "brightness-only preset operates only on connection and visual settings")
    }

    private static func failedRotationDoesNotBlockOtherSettings() {
        let f = rotationFixture()
        f.rotationError = AppFailure(message: "旋转不可用")
        f.start(); f.drain()
        expect(f.result?.contains { $0.contains("旋转不可用") } == true, "report the actual rotation failure")
        expect(f.rotationRequests.count == 6, "rotation retries are bounded")
        expect(f.visualCalls == 1 && f.verifiedVisualValues.count == 1, "failed rotation still applies and verifies visual settings")
        expect(!f.displays[1].active && f.enabledRequests.isEmpty, "completed connections are retained despite a geometry failure")
        expect(f.result?.contains { $0.contains("部分完成") && $0.contains("亮度和对比度已应用并确认") } == true, "report which settings completed")
        expect(!f.application.isRunning, "failure releases the application lock")
    }

    private static func unavailableModeAfterDisconnectDoesNotBlockVisual() {
        let f = rotationFixture()
        let temporary = DisplayModeInfo(width: 720, height: 1280, pixelWidth: 720, pixelHeight: 1280, refreshRate: 60)
        f.afterRotation = {
            f.displays[0] = screen("Philips", 1, currentMode: temporary, availableModes: [temporary], rotation: 90)
        }
        f.start(); f.drain()
        expect(f.result?.contains { $0.contains("找不到完全匹配") } == true, "mode disappearance after rotation is reported")
        expect(f.modeRequests.isEmpty && f.visualCalls == 1, "never choose an approximate mode, but continue independent visual settings")
        expect(!f.displays[1].active && f.enabledRequests.isEmpty, "mode failure does not undo requested connections")
        expect(f.elapsed < 35 && !f.application.isRunning, "unavailable mode finishes after bounded retries")
    }

    private static func delayedModesAfterRotationRecover() {
        let f = rotationFixture()
        let temporary = DisplayModeInfo(width: 720, height: 1280, pixelWidth: 720, pixelHeight: 1280, refreshRate: 60)
        var availableAt: TimeInterval?
        f.afterRotation = {
            availableAt = f.elapsed + 2
            f.displays[0] = screen("Philips", 1, currentMode: temporary, availableModes: [temporary], rotation: 90)
        }
        f.beforeSnapshot = { includeModes in
            guard includeModes, let ready = availableAt, f.elapsed >= ready, f.modeRequests.isEmpty else { return }
            f.displays[0] = screen("Philips", 1, currentMode: temporary, availableModes: [temporary, portrait], rotation: 90)
        }
        f.beforeVisual = { expect(f.displays[0].currentMode == portrait, "delayed mode enumeration completes before brightness") }
        f.start(); f.drain()
        expect(f.result == [], "delayed mode enumeration after rotation clears transient failures")
        expect(f.modeRequests.count == 1 && f.modeRequests[0].time >= availableAt!, "wait until the exact portrait mode is enumerated")
        expect(f.rotationRequests.count == 1 && !f.displays[1].active, "a successful delayed recovery does not reconnect the disabled display")
    }
}
