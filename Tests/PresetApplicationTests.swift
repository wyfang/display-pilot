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
    var visualValues: [(displayID: UInt32, brightness: Double)] = []
    var beforeSnapshot: ((Bool) -> Void)?
    var beforeVisual: (() -> Void)?
    var afterDisable: (() -> Void)?
    var afterEnable: (() -> Void)?
    var afterRotation: (() -> Void)?
    var afterVerify: (() -> Void)?
    var recoverOnConnection: Int?
    var visualError: AppFailure?
    var rotationError: AppFailure?
    var result: [String]?
    lazy var application = PresetApplication(dependencies: .init(
        displays: { [unowned self] includeModes in
            self.beforeSnapshot?(includeModes)
            return self.displays
        },
        setEnabled: { [unowned self] enabled, identity in
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
                guard let index = self.displays.firstIndex(where: { $0.identity == request.identity }) else { continue }
                let current = self.displays[index]
                self.displays[index] = screen(current.identity, current.id, active: current.active,
                    currentMode: request.mode, availableModes: current.availableModes, rotation: current.rotation)
                self.events.append("mode:\(request.identity)")
            }
            return [:]
        },
        setVisual: { [unowned self] brightness, _, id, completion in
            self.visualCalls += 1
            self.visualValues.append((id, brightness))
            self.events.append("visual:\(id)")
            self.beforeVisual?()
            completion(self.visualError.map { .failure($0) } ?? .success(()))
        },
        verifyVisual: { [unowned self] _, _, _, completion in
            self.afterVerify?()
            completion(self.visualError.map { .failure($0) } ?? .success(()))
        },
        schedule: { [unowned self] delay, action in
            self.jobs.append { [unowned self] in self.elapsed += delay; action() }
        },
        setRotation: { [unowned self] rotation, identity, completion in
            self.rotationRequests.append((rotation, identity))
            self.events.append("rotation:\(identity)")
            if let error = self.rotationError { completion(.failure(error)); return }
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
            expect(f.displays.first { $0.identity == "spare" }!.active, "retain useful screens when a saved mode cannot be restored")
            expect(f.result?.contains { $0.contains("找不到完全匹配") } == true, "unavailable saved mode reported after bounded retries")
            expect(f.result?.contains { $0.contains("暂缓断开") } == true, "explain why the spare screen was retained")
            expect(f.visualCalls == 0, "unavailable geometry must not dim any target")
        }
        do {
            let f = Fixture(); f.displays.removeAll { $0.identity == "a" }
            f.start(); f.drain()
            expect(f.displays.first { $0.identity == "spare" }!.active, "one recovered target is insufficient to disable a useful screen")
            expect(f.result?.contains { $0.contains("a：waiting") } == true, "the missing target retains its actual connection failure")
            expect(f.visualCalls == 0, "partial target recovery must not change brightness")
        }
        portraitRotationSurvivesDisconnect()
        legacyDirectionIsLearnedBeforeDisconnect()
        sleepAndWorkRoundTrip()
        brightnessOnlyPresetAllowsOrientationChanges()
        failedRotationRestoresDisconnectedScreen()
        unavailableModeAfterDisconnectRestoresScreen()
        delayedModesAfterRotationRecover()
        let identified = DisplayInfo(id: 1, name: "Display", active: true, builtin: false,
            identity: "uuid:restored", currentMode: mode, availableModes: [mode], legacyIdentity: "external-1-2-123")
        expect(DisplayIdentity.migrationTarget(for: "hardware:external-1-2-123", displays: [identified]) == "uuid:restored", "temporary hardware identity upgrades to UUID")
        legacyBlackoutIgnoresUnavailableGeometry()
        topologyChangesBeforeVisualAreRejected()
        print("PresetApplication: 21 regression scenarios and hardware identity upgrade passed")
    }

    private static func legacyBlackoutIgnoresUnavailableGeometry() {
        let f = sleepFixture()
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

    private static func topologyChangesBeforeVisualAreRejected() {
        let f = Fixture()
        f.preset.displays.removeAll { !$0.enabled }
        f.displays.removeAll { $0.identity == "spare" }
        f.beforeSnapshot = { _ in
            if f.elapsed >= 3.2 { f.displays.removeAll { $0.identity == "a" } }
        }
        f.start(); f.drain()
        expect(f.result?.isEmpty == false, "late target disappearance prevents successful application")
        expect(f.visualCalls == 0, "recheck all targets immediately before visual changes")
    }

    private static let portrait = DisplayModeInfo(width: 1080, height: 1920, pixelWidth: 1080, pixelHeight: 1920, refreshRate: 60)

    private static func sleepFixture(rotation: Int = 90, savedRotation: Int? = 90) -> Fixture {
        let f = Fixture()
        f.displays = [screen("Philips", 1, currentMode: portrait, availableModes: [portrait], rotation: rotation), screen("Dell", 2)]
        f.preset = DisplayPreset(name: "息屏", displays: [
            entry("Philips", enabled: true, brightness: 0, savedMode: portrait, rotation: savedRotation),
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
        let f = sleepFixture()
        f.beforeVisual = {
            expect(f.displays[0].rotation == 90 && f.displays[0].currentMode == portrait,
                   "Philips must return to its saved portrait mode before dimming to zero")
            expect(!f.displays[1].active, "Dell must already be disconnected before dimming")
        }
        f.start(); f.drain()
        expect(f.result == [], "portrait preset survives the actual 90-to-0 topology failure")
        expect(f.rotationRequests.count == 1 && f.rotationRequests[0].rotation == 90, "restore the exact saved rotation")
        expect(f.events == ["disable:Dell", "rotation:Philips", "visual:1"], "disconnect, restore rotation, then apply brightness")
        expect(f.visualValues.last?.brightness == 0, "sleep brightness is applied after geometry is restored")
    }

    private static func legacyDirectionIsLearnedBeforeDisconnect() {
        let f = sleepFixture(rotation: 270, savedRotation: nil)
        f.start(); f.drain()
        expect(f.result == [], "a legacy portrait preset can retain a direction seen before disconnection")
        expect(f.rotationRequests.count == 1 && f.rotationRequests[0].rotation == 270, "do not infer 90 degrees from portrait dimensions")
        expect(f.displays[0].rotation == 270, "the observed 270-degree orientation is restored")
    }

    private static func sleepAndWorkRoundTrip() {
        let f = sleepFixture()
        f.start(); f.drain()
        expect(f.result == [] && !f.displays[1].active && f.visualValues.last?.brightness == 0, "complete sleep preset")
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
        expect(f.rotationRequests.count == 2 && !f.application.isRunning, "both topology transitions recover and release the application lock")
    }

    private static func brightnessOnlyPresetAllowsOrientationChanges() {
        let f = sleepFixture()
        f.preset.displays[0].mode = nil
        f.preset.displays[0].rotation = nil
        f.start(); f.drain()
        expect(f.result == [], "unspecified resolution and rotation are not implicit constraints")
        expect(f.displays[0].rotation == 0 && f.displays[0].currentMode == transposed(portrait), "brightness-only preset leaves changed geometry alone")
        expect(f.modeRequests.isEmpty && f.rotationRequests.isEmpty && f.visualCalls == 1, "brightness-only preset operates only on connection and visual settings")
    }

    private static func failedRotationRestoresDisconnectedScreen() {
        let f = sleepFixture()
        f.rotationError = AppFailure(message: "旋转不可用")
        f.start(); f.drain()
        expect(f.result?.contains { $0.contains("旋转不可用") } == true, "report the actual rotation failure")
        expect(f.rotationRequests.count == 6, "rotation retries are bounded")
        expect(f.visualCalls == 0, "failed rotation never reaches the zero-brightness command")
        expect(f.displays[1].active && f.enabledRequests == ["Dell"], "reconnect the screen disconnected by this attempt")
        expect(f.result?.contains { $0.contains("已请求重新连接") } == true, "explain the connection recovery")
        expect(!f.application.isRunning, "failure releases the application lock")
    }

    private static func unavailableModeAfterDisconnectRestoresScreen() {
        let f = sleepFixture()
        let temporary = DisplayModeInfo(width: 720, height: 1280, pixelWidth: 720, pixelHeight: 1280, refreshRate: 60)
        f.afterRotation = {
            f.displays[0] = screen("Philips", 1, currentMode: temporary, availableModes: [temporary], rotation: 90)
        }
        f.start(); f.drain()
        expect(f.result?.contains { $0.contains("找不到完全匹配") } == true, "mode disappearance after rotation is reported")
        expect(f.modeRequests.isEmpty && f.visualCalls == 0, "do not choose an approximate mode or dim after geometry failure")
        expect(f.displays[1].active && f.enabledRequests == ["Dell"], "mode failure also reconnects the previously disabled display")
        expect(f.elapsed < 35 && !f.application.isRunning, "unavailable mode finishes after bounded retries")
    }

    private static func delayedModesAfterRotationRecover() {
        let f = sleepFixture()
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
