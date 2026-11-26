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

    private static let sample = VisualValues(brightness: 0.5, contrast: 0)
    private static let both: Set<VisualField> = [.brightness, .contrast]

    static func main() throws {
        precondition(Thread.isMainThread)
        missingDependencyDoesNotSend()
        acknowledgeOneWriteAndVerifyOnRequest()
        rejectionAndMalformedResponsesFail()
        timeoutCompletesOnce()
        simultaneousRequestsRemainIndependent()
        writesOnlyRequestedFields()
        mismatchesIdentifyOnlyFieldsOutsideTolerance()
        failedContrastReadDoesNotReturnPartialValues()
        tinyPositiveBrightnessSurvivesEncoding()
        invalidValuesDoNotSend()
        print("BetterDisplayBridgeTests: 10 scenarios passed")
    }

    private static func missingDependencyDoesNotSend() {
        let transport = FakeTransport()
        transport.prefix = nil
        let bridge = BetterDisplayBridge(transport: transport)
        var error: String?
        bridge.setVisualSettings(sample, fields: both, displayID: 1) {
            if case .failure(let failure) = $0 { error = failure.message }
        }
        precondition(error?.contains("未运行") == true)
        precondition(transport.requests.isEmpty)
    }

    private static func acknowledgeOneWriteAndVerifyOnRequest() {
        let transport = FakeTransport()
        transport.prefix = "com.betterdisplay.BetterDisplay"
        let bridge = BetterDisplayBridge(transport: transport)
        var completions = 0
        bridge.setVisualSettings(VisualValues(brightness: 0.535, contrast: -0.15), fields: both, displayID: 42) {
            precondition(Thread.isMainThread)
            guard case .success = $0 else { preconditionFailure("Expected write acknowledgement") }
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
        precondition(completions == 1 && transport.requests.count == 1 && transport.timers.isEmpty)
        var verified = false
        bridge.readVisualSettings(displayID: 42) {
            guard case .success(let values) = $0 else { preconditionFailure("Expected both values") }
            precondition(values == VisualValues(brightness: 0.53, contrast: -0.15))
            verified = true
        }
        let read = transport.requests[1]["parameters"] as! [String: Any]
        precondition(transport.requests[1]["commands"] as? [String] == ["get"])
        precondition(read["brightness"] is NSNull)
        transport.reply(to: 1, result: true, payload: "0.53\n")
        precondition(!verified && transport.requests.count == 3)
        transport.reply(to: 2, result: true, payload: "-0.15")
        precondition(verified && transport.timers.isEmpty)
        transport.reply(to: 2, result: true, payload: "-0.15")
        precondition(completions == 1)
    }

    private static func rejectionAndMalformedResponsesFail() {
        for scenario in 0..<6 {
            let transport = FakeTransport()
            let bridge = BetterDisplayBridge(transport: transport)
            var error: String?
            var reason: AppFailure.Reason?
            let completion: (Result<Void, AppFailure>) -> Void = {
                if case .failure(let failure) = $0 { error = failure.message; reason = failure.reason }
            }
            if scenario == 5 {
                bridge.setVisualSettings(sample, fields: both, displayID: 1, completion: completion)
            } else {
                bridge.readVisualSettings(displayID: 1) { result in completion(result.map { _ in () }) }
            }
            switch scenario {
            case 0: transport.reply(to: 0, result: false, payload: "Feature unavailable")
            case 1: transport.reply(to: 0, result: nil)
            case 2: transport.reply(to: 0, result: true, payload: "nan")
            case 3: transport.reply(to: 0, result: true, payload: "")
            default: transport.reply(to: 0, result: false, payload: "Pro required.")
            }
            precondition(error != nil && transport.timers.isEmpty && transport.requests.count == 1)
            if scenario == 1 { precondition(reason == .unconfirmed) }
            if scenario == 0 { precondition(error!.contains("Feature unavailable")) }
            if scenario >= 4 {
                precondition(error!.contains("Pro required.") && reason == .requiresPro,
                             "visual get and set rejections preserve the generic machine-readable reason")
            }
        }
    }

    private static func timeoutCompletesOnce() {
        let transport = FakeTransport()
        let bridge = BetterDisplayBridge(transport: transport, timeout: 0.1)
        var completions = 0
        bridge.setVisualSettings(sample, fields: both, displayID: 1) {
            guard case .failure(let failure) = $0 else { preconditionFailure("Expected timeout") }
            precondition(failure.message.contains("超时") && failure.reason == .unconfirmed)
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
            bridge.readVisualSettings(displayID: UInt32(display)) {
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

    private static func writesOnlyRequestedFields() {
        for fields: Set<VisualField> in [[], [.brightness], [.contrast], both] {
            let transport = FakeTransport()
            let bridge = BetterDisplayBridge(transport: transport)
            var completed = false
            bridge.setVisualSettings(sample, fields: fields, displayID: 7) {
                guard case .success = $0 else { preconditionFailure("Expected write success") }
                completed = true
            }
            if fields.isEmpty {
                precondition(completed && transport.requests.isEmpty)
                continue
            }
            precondition(!completed && transport.requests.count == 1)
            precondition(transport.requests[0]["commands"] as? [String] == ["set"])
            let sent = transport.requests[0]["parameters"] as! [String: String]
            precondition(sent["displayID"] == "7")
            precondition(sent["brightness"] == (fields.contains(.brightness) ? "0.500" : nil))
            precondition(sent["contrast"] == (fields.contains(.contrast) ? "0.000" : nil))
            transport.reply(to: 0, result: true)
            precondition(completed && transport.requests.count == 1)
        }
    }

    private static func mismatchesIdentifyOnlyFieldsOutsideTolerance() {
        precondition(VisualValues(brightness: 0.49, contrast: 0.001).mismatches(comparedTo: sample).isEmpty)
        precondition(VisualValues(brightness: 0.48, contrast: 0).mismatches(comparedTo: sample) == [.brightness])
        precondition(VisualValues(brightness: 0.5, contrast: -0.002).mismatches(comparedTo: sample) == [.contrast])
        precondition(VisualValues(brightness: 0.48, contrast: -0.002).mismatches(comparedTo: sample) == both)
        let off = VisualValues(brightness: 0, contrast: 0)
        let dim = VisualValues(brightness: 0.01, contrast: 0)
        precondition(off.mismatches(comparedTo: dim) == [.brightness])
        precondition(dim.mismatches(comparedTo: off) == [.brightness])
    }

    private static func failedContrastReadDoesNotReturnPartialValues() {
        let transport = FakeTransport()
        let bridge = BetterDisplayBridge(transport: transport)
        var failure: AppFailure?
        bridge.readVisualSettings(displayID: 3) {
            if case .failure(let error) = $0 { failure = error }
        }
        transport.reply(to: 0, result: true, payload: "0.5")
        let sent = transport.requests[1]["parameters"] as! [String: Any]
        precondition(sent["contrast"] is NSNull && sent["brightness"] == nil)
        transport.reply(to: 1, result: true, payload: "nan")
        precondition(failure?.message.contains("对比度") == true && transport.timers.isEmpty)
        precondition(transport.requests.count == 2)
    }

    private static func tinyPositiveBrightnessSurvivesEncoding() {
        for brightness in [0.0004, 0.00001] {
            let transport = FakeTransport()
            let bridge = BetterDisplayBridge(transport: transport)
            bridge.setVisualSettings(VisualValues(brightness: brightness, contrast: 0), fields: [.brightness], displayID: 1) { _ in }
            let parameters = transport.requests[0]["parameters"] as! [String: Any]
            precondition(Double(parameters["brightness"] as! String) == brightness, "never encode a nonzero target as zero")
        }
    }

    private static func invalidValuesDoNotSend() {
        let transport = FakeTransport()
        let bridge = BetterDisplayBridge(transport: transport)
        for values in [(Double.nan, 0.0), (0.5, Double.infinity), (1.1, 0.0), (0.5, -1.0)] {
            var failed = false
            bridge.setVisualSettings(VisualValues(brightness: values.0, contrast: values.1), fields: both, displayID: 1) {
                if case .failure = $0 { failed = true }
            }
            precondition(failed)
        }
        precondition(transport.requests.isEmpty)
    }

}
