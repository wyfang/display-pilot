import Foundation

@main
struct BetterDisplayBridgeTests {
    private final class FakeTransport: BetterDisplayNotificationTransport {
        struct Timer {
            let delay: TimeInterval
            let action: () -> Void
        }
        var prefix: String? = "pro.betterdisplay.BetterDisplay"
        var receive: ((String) -> Void)?
        var requests: [[String: Any]] = []
        var timers: [UUID: Timer] = [:]
        var postedPrefixes: [String] = []

        func runningApplicationPrefix() -> String? { prefix }
        func observeResponses(_ receive: @escaping (String) -> Void) -> () -> Void {
            self.receive = receive
            return { [weak self] in self?.receive = nil }
        }
        func postRequest(_ json: String, prefix: String) {
            requests.append(try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
            postedPrefixes.append(prefix)
        }
        func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
            let id = UUID()
            timers[id] = Timer(delay: delay, action: action)
            return { [weak self] in self?.timers.removeValue(forKey: id) }
        }
        func reply(to index: Int, result: Bool?, payload: String? = nil) {
            var object: [String: Any] = ["uuid": requests[index]["uuid"]!]
            if let result { object["result"] = result }
            if let payload { object["payload"] = payload }
            let data = try! JSONSerialization.data(withJSONObject: object)
            receive?(String(decoding: data, as: UTF8.self))
        }
        func fireTimers(lessThan limit: TimeInterval = .infinity) {
            let current = timers.filter { $0.value.delay < limit }
            for (id, timer) in current {
                guard timers.removeValue(forKey: id) != nil else { continue }
                timer.action()
            }
        }
    }

    static func main() throws {
        precondition(Thread.isMainThread)
        missingDependencyDoesNotSend()
        responseMustMatchAndReadBack()
        rejectionAndMalformedResponsesFail()
        timeoutCompletesOnce()
        simultaneousRequestsRemainIndependent()
        mismatchRetriesAreBounded()
        invalidValuesDoNotSend()
        matchingRotationDoesNotSet()
        rotationWaitsForReadBack()
        rotationMismatchRetriesAreBounded()
        invalidRotationsDoNotSend()
        rotationReadAndSetFailuresStop()
        recycledDisplayDoesNotRotate()
        print("BetterDisplayBridgeTests: 13 scenarios passed")
    }

    private static func recycledDisplayDoesNotRotate() {
        let transport = FakeTransport()
        let bridge = BetterDisplayBridge(transport: transport)
        var current = true
        var error: String?
        bridge.setRotation(rotation: 90, displayID: 42, isCurrentDisplay: { current }) {
            if case .failure(let failure) = $0 { error = failure.message }
        }
        current = false
        transport.reply(to: 0, result: true, payload: "0")
        precondition(error?.contains("身份已变化") == true)
        precondition(transport.requests.count == 1, "never rotate a recycled ID after the asynchronous read")
    }

    private static func missingDependencyDoesNotSend() {
        let transport = FakeTransport()
        transport.prefix = nil
        let bridge = BetterDisplayBridge(transport: transport)
        var error: String?
        bridge.setVisualSettings(brightness: 0.5, contrast: 0, displayID: 1) {
            if case .failure(let failure) = $0 { error = failure.message }
        }
        precondition(error?.contains("未运行") == true)
        precondition(transport.requests.isEmpty)
    }

    private static func responseMustMatchAndReadBack() {
        let transport = FakeTransport()
        transport.prefix = "com.betterdisplay.BetterDisplay"
        let bridge = BetterDisplayBridge(transport: transport)
        var completions = 0
        bridge.setVisualSettings(brightness: 0.535, contrast: -0.15, displayID: 42) {
            precondition(Thread.isMainThread)
            guard case .success = $0 else { preconditionFailure("Expected verified success") }
            completions += 1
        }
        precondition(completions == 0)
        precondition(transport.requests[0]["commands"] as? [String] == ["set"])
        let sent = transport.requests[0]["parameters"] as! [String: Any]
        precondition(sent["displayID"] as? String == "42")
        precondition(sent["brightness"] as? String == "0.535")
        precondition(sent["contrast"] as? String == "-0.150")
        precondition(transport.postedPrefixes == ["com.betterdisplay.BetterDisplay"])
        transport.receive?("{\"uuid\":\"unrelated\",\"result\":true}")
        precondition(transport.requests.count == 1 && completions == 0)
        transport.reply(to: 0, result: true)
        precondition(completions == 0 && transport.requests.count == 2)
        let read = transport.requests[1]["parameters"] as! [String: Any]
        precondition(transport.requests[1]["commands"] as? [String] == ["get"])
        precondition(read["brightness"] is NSNull)
        transport.reply(to: 1, result: true, payload: "0.53\n")
        precondition(completions == 0 && transport.requests.count == 3)
        transport.reply(to: 2, result: true, payload: "-0.15")
        precondition(completions == 1 && transport.timers.isEmpty)
        transport.reply(to: 2, result: true, payload: "-0.15")
        precondition(completions == 1)
    }

    private static func rejectionAndMalformedResponsesFail() {
        for scenario in 0..<4 {
            let transport = FakeTransport()
            let bridge = BetterDisplayBridge(transport: transport)
            var error: String?
            bridge.verifyVisualSettings(brightness: 0.5, contrast: 0, displayID: 1) {
                if case .failure(let failure) = $0 { error = failure.message }
            }
            switch scenario {
            case 0: transport.reply(to: 0, result: false, payload: "Feature unavailable")
            case 1: transport.reply(to: 0, result: nil)
            case 2: transport.reply(to: 0, result: true, payload: "nan")
            default: transport.reply(to: 0, result: true, payload: "")
            }
            precondition(error != nil && transport.timers.isEmpty)
            if scenario == 0 { precondition(error!.contains("Feature unavailable")) }
        }
    }

    private static func timeoutCompletesOnce() {
        let transport = FakeTransport()
        let bridge = BetterDisplayBridge(transport: transport, timeout: 0.1)
        var completions = 0
        bridge.setVisualSettings(brightness: 0.5, contrast: 0, displayID: 1) {
            guard case .failure(let failure) = $0 else { preconditionFailure("Expected timeout") }
            precondition(failure.message.contains("超时"))
            completions += 1
        }
        transport.receive?("invalid JSON")
        precondition(completions == 0)
        transport.fireTimers()
        precondition(completions == 1)
        transport.reply(to: 0, result: true)
        transport.fireTimers()
        precondition(completions == 1 && transport.requests.count == 1)
    }

    private static func simultaneousRequestsRemainIndependent() {
        let transport = FakeTransport()
        let bridge = BetterDisplayBridge(transport: transport)
        var finished: [Int] = []
        for display in 1...2 {
            bridge.verifyVisualSettings(brightness: 0.5, contrast: 0, displayID: UInt32(display)) {
                guard case .success = $0 else { preconditionFailure("Expected success") }
                finished.append(display)
            }
        }
        transport.reply(to: 1, result: true, payload: "0.5")
        transport.reply(to: 2, result: true, payload: "0.0")
        precondition(finished == [2])
        transport.reply(to: 0, result: true, payload: "0.5")
        transport.reply(to: 3, result: true, payload: "0.0")
        precondition(finished == [2, 1] && transport.timers.isEmpty)
    }

    private static func mismatchRetriesAreBounded() {
        let transport = FakeTransport()
        let bridge = BetterDisplayBridge(transport: transport)
        var error: String?
        bridge.verifyVisualSettings(brightness: 0.5, contrast: 0, displayID: 1) {
            if case .failure(let failure) = $0 { error = failure.message }
        }
        for pass in 0..<3 {
            transport.reply(to: pass * 2, result: true, payload: "0.8")
            transport.reply(to: pass * 2 + 1, result: true, payload: "0.2")
            if pass < 2 {
                precondition(error == nil)
                transport.fireTimers(lessThan: 1)
            }
        }
        precondition(error?.contains("读回结果不一致") == true)
        precondition(error?.contains("80.0%") == true)
        precondition(transport.requests.count == 6 && transport.timers.isEmpty)
    }

    private static func invalidValuesDoNotSend() {
        let transport = FakeTransport()
        let bridge = BetterDisplayBridge(transport: transport)
        for values in [(Double.nan, 0.0), (0.5, Double.infinity), (1.1, 0.0), (0.5, -1.0)] {
            var failed = false
            bridge.setVisualSettings(brightness: values.0, contrast: values.1, displayID: 1) {
                if case .failure = $0 { failed = true }
            }
            precondition(failed)
        }
        precondition(transport.requests.isEmpty)
    }

    private static func matchingRotationDoesNotSet() {
        for rotation in [0, 90, 180, 270] {
            let transport = FakeTransport()
            let bridge = BetterDisplayBridge(transport: transport)
            var finished = false
            bridge.setRotation(rotation: rotation, displayID: 42) {
                guard case .success = $0 else { preconditionFailure("Expected unchanged rotation to succeed") }
                finished = true
            }
            precondition(!finished)
            precondition(transport.requests[0]["commands"] as? [String] == ["get"])
            let read = transport.requests[0]["parameters"] as! [String: Any]
            precondition(read["displayID"] as? String == "42" && read["rotation"] is NSNull)
            transport.reply(to: 0, result: true, payload: "\(rotation)\n")
            precondition(finished && transport.requests.count == 1 && transport.timers.isEmpty)
        }
    }

    private static func rotationWaitsForReadBack() {
        let transport = FakeTransport()
        let bridge = BetterDisplayBridge(transport: transport)
        var completions = 0
        bridge.setRotation(rotation: 90, displayID: 42) {
            precondition(Thread.isMainThread)
            guard case .success = $0 else { preconditionFailure("Expected verified rotation") }
            completions += 1
        }
        transport.reply(to: 0, result: true, payload: "0")
        precondition(transport.requests[1]["commands"] as? [String] == ["set"])
        let set = transport.requests[1]["parameters"] as! [String: Any]
        precondition(set["displayID"] as? String == "42" && set["rotation"] as? String == "90")
        transport.reply(to: 1, result: true)
        precondition(completions == 0)
        transport.reply(to: 2, result: true, payload: "0")
        precondition(completions == 0 && transport.requests.count == 3)
        transport.fireTimers(lessThan: 1)
        transport.reply(to: 3, result: true, payload: "90.0")
        precondition(completions == 1 && transport.timers.isEmpty)
        transport.reply(to: 3, result: true, payload: "90.0")
        precondition(completions == 1)
    }

    private static func rotationMismatchRetriesAreBounded() {
        let transport = FakeTransport()
        let bridge = BetterDisplayBridge(transport: transport)
        var error: String?
        bridge.verifyRotation(rotation: 90, displayID: 42) {
            if case .failure(let failure) = $0 { error = failure.message }
        }
        for pass in 0..<3 {
            transport.reply(to: pass, result: true, payload: "0")
            if pass < 2 {
                precondition(error == nil)
                transport.fireTimers(lessThan: 1)
            }
        }
        precondition(error?.contains("旋转角度目标 90°") == true)
        precondition(transport.requests.count == 3 && transport.timers.isEmpty)
    }

    private static func invalidRotationsDoNotSend() {
        let transport = FakeTransport()
        let bridge = BetterDisplayBridge(transport: transport)
        for rotation in [-90, 45, 360, Int.max] {
            var failures = 0
            let completion: (Result<Void, AppFailure>) -> Void = {
                if case .failure(let failure) = $0 {
                    precondition(failure.message.contains("旋转角度无效"))
                    failures += 1
                }
            }
            bridge.setRotation(rotation: rotation, displayID: 42, completion: completion)
            bridge.verifyRotation(rotation: rotation, displayID: 42, completion: completion)
            precondition(failures == 2)
        }
        precondition(transport.requests.isEmpty)
    }

    private static func rotationReadAndSetFailuresStop() {
        for scenario in 0..<3 {
            let transport = FakeTransport()
            let bridge = BetterDisplayBridge(transport: transport)
            var error: String?
            bridge.setRotation(rotation: 90, displayID: 42) {
                if case .failure(let failure) = $0 { error = failure.message }
            }
            switch scenario {
            case 0: transport.reply(to: 0, result: false, payload: "Feature unavailable")
            case 1: transport.reply(to: 0, result: true, payload: "nan")
            default:
                transport.reply(to: 0, result: true, payload: "0")
                transport.reply(to: 1, result: false, payload: "Feature unavailable")
            }
            precondition(error != nil && transport.timers.isEmpty)
            precondition(transport.requests.count == (scenario == 2 ? 2 : 1))
            if scenario == 1 { precondition(error!.contains("旋转角度数值")) }
        }
    }
}
