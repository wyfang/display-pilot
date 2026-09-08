import AppKit

private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}

private let mode = DisplayModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60)
private func screen(_ identity: String, _ id: UInt32, active: Bool = true, currentMode: DisplayModeInfo? = mode,
                    availableModes: [DisplayModeInfo] = [mode]) -> DisplayInfo {
    DisplayInfo(id: id, name: identity, active: active, builtin: false, identity: identity,
                currentMode: currentMode, availableModes: availableModes)
}
private func entry(_ identity: String, enabled: Bool) -> DisplayPresetEntry {
    DisplayPresetEntry(identity: identity, name: identity, enabled: enabled, brightness: 0.5, contrast: 0, mode: mode)
}

private final class Fixture {
    var displays = [screen("a", 1), screen("b", 2), screen("spare", 3)]
    var jobs: [() -> Void] = []
    var visualCalls = 0
    var connectionCalls = 0
    var elapsed: TimeInterval = 0
    var modeRequests: [(time: TimeInterval, identities: [String])] = []
    var beforeSnapshot: ((Bool) -> Void)?
    var beforeVisual: (() -> Void)?
    var afterDisable: (() -> Void)?
    var afterVerify: (() -> Void)?
    var recoverOnConnection: Int?
    var visualError: AppFailure?
    var result: [String]?
    lazy var application = PresetApplication(dependencies: .init(
        displays: { [unowned self] includeModes in
            self.beforeSnapshot?(includeModes)
            return self.displays
        },
        setEnabled: { [unowned self] enabled, identity in
            if enabled {
                self.connectionCalls += 1
                if self.recoverOnConnection == self.connectionCalls { self.displays.append(screen("a", 1)) }
            }
            guard let index = self.displays.firstIndex(where: { $0.identity == identity }) else {
                return .failure(AppFailure(message: "waiting"))
            }
            let current = self.displays[index]
            self.displays[index] = screen(identity, current.id, active: enabled)
            if !enabled { self.afterDisable?() }
            return .success(())
        },
        setModes: { [unowned self] requests in
            if !requests.isEmpty { self.modeRequests.append((self.elapsed, requests.map(\.identity))) }
            for request in requests {
                guard let index = self.displays.firstIndex(where: { $0.identity == request.identity }) else { continue }
                let current = self.displays[index]
                self.displays[index] = screen(current.identity, current.id, active: current.active,
                    currentMode: request.mode, availableModes: current.availableModes)
            }
            return [:]
        },
        setVisual: { [unowned self] _, _, _, completion in
            self.visualCalls += 1
            self.beforeVisual?()
            completion(self.visualError.map { .failure($0) } ?? .success(()))
        },
        verifyVisual: { [unowned self] _, _, _, completion in
            self.afterVerify?()
            completion(self.visualError.map { .failure($0) } ?? .success(()))
        },
        schedule: { [unowned self] delay, action in
            self.jobs.append { [unowned self] in self.elapsed += delay; action() }
        }
    ))
    let preset = DisplayPreset(name: "A", displays: [entry("a", enabled: true), entry("b", enabled: true), entry("spare", enabled: false)])
    func start() { application.apply(preset) { [unowned self] in self.result = $0 } }
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
            expect(f.result?.contains { $0.contains("分辨率") } == true, "mode changes caused by topology must fail final validation")
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
            refreshed.displays[0].mode = mode
            refreshed.displays.reverse()
            expect(PresetApplication.settingsUnchanged(executed: original, saved: refreshed), "automatic metadata sync is not a user edit")
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
            expect(f.elapsed < 5, "an already selected mode should not wait for the full timeout")
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
        }
        do {
            let f = Fixture(); f.displays.removeAll { $0.identity == "a" }
            f.start(); f.drain()
            expect(f.displays.first { $0.identity == "spare" }!.active, "one recovered target is insufficient to disable a useful screen")
            expect(f.result?.contains { $0.contains("a：waiting") } == true, "the missing target retains its actual connection failure")
        }
        let identified = DisplayInfo(id: 1, name: "Display", active: true, builtin: false,
            identity: "uuid:restored", currentMode: mode, availableModes: [mode], legacyIdentity: "external-1-2-123")
        expect(DisplayIdentity.migrationTarget(for: "hardware:external-1-2-123", displays: [identified]) == "uuid:restored", "temporary hardware identity upgrades to UUID")
        print("PresetApplication: 12 regression scenarios and hardware identity upgrade passed")
    }
}
