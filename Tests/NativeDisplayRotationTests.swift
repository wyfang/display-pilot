import Foundation

@main
struct NativeDisplayRotationTests {
    private static func screen(id: UInt32 = 7, identity: String = "target", rotation: Int? = 0,
                               active: Bool = true, canControl: Bool = true) -> DisplayInfo {
        DisplayInfo(id: id, name: identity, active: active, builtin: false, identity: identity,
                    currentMode: nil, availableModes: [], canControl: canControl, rotation: rotation)
    }

    private final class Fixture {
        var display: DisplayInfo? = NativeDisplayRotationTests.screen()
        var jobs: [() -> Void] = []
        var requests: [(UInt32, Int)] = []
        var requestResult: Result<Void, AppFailure> = .success(())
        var beforeResolve: (() -> Void)?
        var elapsed: TimeInterval = 0
        lazy var controller = NativeDisplayRotation(
            resolve: { [unowned self] _ in beforeResolve?(); return display },
            request: { [unowned self] id, angle in requests.append((id, angle)); return requestResult },
            schedule: { [unowned self] delay, action in jobs.append { [unowned self] in elapsed += delay; action() } },
            pollInterval: 0.1, maxPolls: 5)
        func step() { precondition(!jobs.isEmpty); jobs.removeFirst()() }
        func drain() {
            var count = 0
            while !jobs.isEmpty { count += 1; precondition(count < 20); step() }
        }
    }

    static func main() {
        precondition(Thread.isMainThread)
        matchingRotationDoesNotWrite()
        allFourAnglesUseQuartzConvention()
        invalidInputAndUntrustedTargetsDoNotWrite()
        identityChangeBeforeRequestDoesNotWrite()
        addressChangeDuringPollingCannotSucceed()
        disconnectionDuringPollingCannotSucceed()
        requestFailureDoesNotPollOrRetry()
        acknowledgementWaitsForStableReadback()
        mismatchPollingHasAFiniteLimit()
        concurrentCallsCannotOverlap()
        unavailableStatusesRemainExplicit()
        acceptedButUnappliedRequestRetriesWithCleanup()
        print("NativeDisplayRotationTests: 12 scenarios passed (injected dependencies only)")
    }

    private static func acceptedButUnappliedRequestRetriesWithCleanup() {
        var display = screen(rotation: 0)
        var requests = 0
        var releases: [UInt32] = []
        var jobs: [() -> Void] = []
        var succeeded = false
        let controller = NativeDisplayRotation(resolve: { _ in display }, request: { id, angle in
            precondition(id == 7 && angle == 90)
            requests += 1
            if requests == 2 { display = screen(rotation: angle) }
            return .success(())
        }, schedule: { _, action in jobs.append(action) }, maxPolls: 8,
           retryAfterPolls: 2, maxRequests: 3, finishRequest: { releases.append($0) })
        controller.setRotation(rotation: 90, identity: "target") { if case .success = $0 { succeeded = true } }
        while !jobs.isEmpty { jobs.removeFirst()() }
        precondition(succeeded && requests == 2 && releases == [7] && !controller.isRunning)
    }

    private static func matchingRotationDoesNotWrite() {
        let f = Fixture(); f.display = screen(rotation: 270)
        var successes = 0
        f.controller.setRotation(rotation: 270, identity: "target") { if case .success = $0 { successes += 1 } }
        precondition(successes == 1 && f.requests.isEmpty && f.jobs.isEmpty && !f.controller.isRunning)
    }

    private static func allFourAnglesUseQuartzConvention() {
        for angle in [0, 90, 180, 270] {
            let f = Fixture(); f.display = screen(rotation: (angle + 90) % 360)
            var successes = 0
            f.controller.setRotation(rotation: angle, identity: "target") { if case .success = $0 { successes += 1 } }
            precondition(f.requests.count == 1 && f.requests[0].0 == 7 && f.requests[0].1 == angle)
            precondition(successes == 0)
            f.display = screen(rotation: angle); f.drain()
            precondition(successes == 1 && !f.controller.isRunning)
        }
    }

    private static func invalidInputAndUntrustedTargetsDoNotWrite() {
        for angle in [-90, 45, 360, Int.max] {
            let f = Fixture(); var failed = false
            f.controller.setRotation(rotation: angle, identity: "target") { if case .failure = $0 { failed = true } }
            precondition(failed && f.requests.isEmpty)
        }
        for target in [nil, screen(id: 0), screen(identity: "different"), screen(active: false), screen(canControl: false)] {
            let f = Fixture(); f.display = target; var failed = false
            f.controller.setRotation(rotation: 90, identity: "target") { if case .failure = $0 { failed = true } }
            precondition(failed && f.requests.isEmpty)
        }
    }

    private static func identityChangeBeforeRequestDoesNotWrite() {
        let f = Fixture(); var reads = 0; var failed = false
        f.beforeResolve = { reads += 1; if reads == 2 { f.display = screen(id: 8) } }
        f.controller.setRotation(rotation: 90, identity: "target") { if case .failure = $0 { failed = true } }
        precondition(failed && f.requests.isEmpty && f.jobs.isEmpty)
    }

    private static func addressChangeDuringPollingCannotSucceed() {
        let f = Fixture(); var error: String?
        f.controller.setRotation(rotation: 90, identity: "target") { if case .failure(let failure) = $0 { error = failure.message } }
        f.display = screen(id: 8, rotation: 90); f.drain()
        precondition(error?.contains("编号") == true && f.requests.count == 1 && !f.controller.isRunning)
    }

    private static func disconnectionDuringPollingCannotSucceed() {
        let f = Fixture(); var failed = false
        f.controller.setRotation(rotation: 90, identity: "target") { if case .failure = $0 { failed = true } }
        f.display = screen(rotation: 90, active: false); f.drain()
        precondition(failed && f.requests.count == 1)
    }

    private static func requestFailureDoesNotPollOrRetry() {
        let f = Fixture(); f.requestResult = .failure(AppFailure(message: "native failure")); var error: String?
        f.controller.setRotation(rotation: 90, identity: "target") { if case .failure(let failure) = $0 { error = failure.message } }
        precondition(error == "native failure" && f.requests.count == 1 && f.jobs.isEmpty && !f.controller.isRunning)
    }

    private static func acknowledgementWaitsForStableReadback() {
        let f = Fixture(); var successes = 0
        f.controller.setRotation(rotation: 90, identity: "target") { if case .success = $0 { successes += 1 } }
        precondition(successes == 0)
        f.display = screen(rotation: 90); f.step(); precondition(successes == 0)
        f.display = screen(rotation: 0); f.step(); precondition(successes == 0)
        f.display = screen(rotation: 90); f.step(); precondition(successes == 0)
        f.step(); precondition(successes == 1 && f.jobs.isEmpty)
    }

    private static func mismatchPollingHasAFiniteLimit() {
        let f = Fixture(); var completions = 0; var error: String?
        f.controller.setRotation(rotation: 90, identity: "target") {
            completions += 1; if case .failure(let failure) = $0 { error = failure.message }
        }
        f.display = screen(rotation: nil); f.drain()
        precondition(completions == 1 && error?.contains("超时") == true && error?.contains("未知") == true)
        precondition(f.requests.count == 1 && f.elapsed <= 0.401 && !f.controller.isRunning)
    }

    private static func concurrentCallsCannotOverlap() {
        let f = Fixture(); var firstSucceeded = false; var secondFailed = false
        f.controller.setRotation(rotation: 90, identity: "target") { if case .success = $0 { firstSucceeded = true } }
        f.controller.setRotation(rotation: 180, identity: "target") { if case .failure = $0 { secondFailed = true } }
        precondition(secondFailed && f.requests.count == 1)
        f.display = screen(rotation: 90); f.drain(); precondition(firstSucceeded)
        var thirdSucceeded = false
        f.controller.setRotation(rotation: 90, identity: "target") { if case .success = $0 { thirdSucceeded = true } }
        precondition(thirdSucceeded && f.requests.count == 1)
    }

    private static func unavailableStatusesRemainExplicit() {
        guard case .success = NativeDisplayRotation.result(forNativeStatus: 0) else { preconditionFailure() }
        for status: Int32 in [1, 2, 3, 4, 5, 6, 7, 999] {
            guard case .failure(let failure) = NativeDisplayRotation.result(forNativeStatus: status) else { preconditionFailure() }
            precondition(!failure.message.isEmpty && !failure.message.contains("Pro"))
        }
    }
}
