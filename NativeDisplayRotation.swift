import Foundation
import CoreGraphics

@_silgen_name("DisplayPilotRequestNativeRotation")
private func requestNativeDisplayRotation(_ displayID: UInt32, _ rotation: Int32) -> Int32

@_silgen_name("DisplayPilotFinishNativeRotation")
private func finishNativeDisplayRotation(_ displayID: UInt32)

/// Native rotation has no BetterDisplay dependency. Dispatch is not completion:
/// observe the same verified display address until Quartz confirms the angle.
final class NativeDisplayRotation {
    typealias Resolve = (String) -> DisplayInfo?
    typealias Request = (UInt32, Int) -> Result<Void, AppFailure>
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    private final class Operation {
        let identity: String
        let displayID: UInt32
        let rotation: Int
        let completion: (Result<Void, AppFailure>) -> Void
        var requests = 1
        var pollsSinceRequest = 0
        init(identity: String, displayID: UInt32, rotation: Int,
             completion: @escaping (Result<Void, AppFailure>) -> Void) {
            self.identity = identity
            self.displayID = displayID
            self.rotation = rotation
            self.completion = completion
        }
    }

    private let resolve: Resolve
    private let request: Request
    private let schedule: Schedule
    private let pollInterval: TimeInterval
    private let maxPolls: Int
    private let retryAfterPolls: Int
    private let maxRequests: Int
    private let finishRequest: (UInt32) -> Void
    private var operation: Operation?
    var isRunning: Bool { operation != nil }

    init(resolve: @escaping Resolve,
         request: @escaping Request = NativeDisplayRotation.systemRequest,
         schedule: @escaping Schedule = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         },
         pollInterval: TimeInterval = 0.15,
         maxPolls: Int = 67,
         retryAfterPolls: Int = 20,
         maxRequests: Int = 3,
         finishRequest: @escaping (UInt32) -> Void = { finishNativeDisplayRotation($0) }) {
        self.resolve = resolve
        self.request = request
        self.schedule = schedule
        self.pollInterval = pollInterval.isFinite && pollInterval > 0 ? pollInterval : 0.15
        self.maxPolls = max(2, maxPolls)
        self.retryAfterPolls = max(2, retryAfterPolls)
        self.maxRequests = max(1, maxRequests)
        self.finishRequest = finishRequest
    }

    func setRotation(rotation: Int, identity: String,
                     completion: @escaping (Result<Void, AppFailure>) -> Void) {
        onMain { [self] in
            guard DisplayRotation.angles.contains(rotation) else {
                completion(.failure(AppFailure(message: "旋转角度只能为 0°、90°、180° 或 270°。")))
                return
            }
            guard operation == nil else {
                completion(.failure(AppFailure(message: "已有旋转操作正在进行，请等待完成后重试。")))
                return
            }
            guard let initial = verifiedDisplay(identity: identity) else {
                completion(.failure(AppFailure(message: "无法核实旋转目标的身份或连接状态。")))
                return
            }
            if initial.rotation == rotation { completion(.success(())); return }
            // Resolve again immediately before dispatch: numeric IDs may be
            // recycled by a topology change after the initial menu snapshot.
            guard let current = verifiedDisplay(identity: identity), current.id == initial.id else {
                completion(.failure(AppFailure(message: "显示器身份或编号已变化，已取消旋转。")))
                return
            }
            if current.rotation == rotation { completion(.success(())); return }
            let context = Operation(identity: identity, displayID: current.id,
                                    rotation: rotation, completion: completion)
            operation = context
            switch request(current.id, rotation) {
            case .failure(let failure): finish(context, .failure(failure))
            case .success: poll(context, remaining: maxPolls, matches: 0)
            }
        }
    }

    private func verifiedDisplay(identity: String) -> DisplayInfo? {
        guard let display = resolve(identity), display.identity == identity,
              display.id != kCGNullDirectDisplay, display.active, display.canControl else { return nil }
        return display
    }

    private func poll(_ context: Operation, remaining: Int, matches: Int) {
        guard operation === context else { return }
        guard let display = verifiedDisplay(identity: context.identity), display.id == context.displayID else {
            finish(context, .failure(AppFailure(message: "旋转期间显示器身份、编号或连接已变化，无法确认旋转结果。")))
            return
        }
        let nextMatches = display.rotation == context.rotation ? matches + 1 : 0
        if nextMatches >= 2 {
            finish(context, .success(()))
        } else if remaining <= 1 {
            let actual = display.rotation.map { "\($0)°" } ?? "未知"
            finish(context, .failure(AppFailure(message: "等待 macOS 旋转超时：目标 \(context.rotation)°，当前 \(actual)。", reason: .unavailable)))
        } else {
            context.pollsSinceRequest += 1
            // A topology change can accept an orientation request before the
            // display service can apply it. Reissue the same target, never a
            // toggle, after a bounded wait and a fresh identity check.
            if nextMatches == 0 && context.pollsSinceRequest >= retryAfterPolls && context.requests < maxRequests {
                context.requests += 1
                context.pollsSinceRequest = 0
                switch request(display.id, context.rotation) {
                case .failure(let failure): finish(context, .failure(failure)); return
                case .success: break
                }
            }
            schedule(pollInterval) { [weak self] in
                self?.onMain { [weak self] in self?.poll(context, remaining: remaining - 1, matches: nextMatches) }
            }
        }
    }

    private func finish(_ context: Operation, _ result: Result<Void, AppFailure>) {
        guard operation === context else { return }
        operation = nil
        finishRequest(context.displayID)
        context.completion(result)
    }

    private func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() }
        else { DispatchQueue.main.async(execute: action) }
    }

    static func systemRequest(displayID: UInt32, rotation: Int) -> Result<Void, AppFailure> {
        guard DisplayRotation.angles.contains(rotation) else {
            return .failure(AppFailure(message: "旋转角度只能为 0°、90°、180° 或 270°。"))
        }
        return result(forNativeStatus: requestNativeDisplayRotation(displayID, Int32(rotation)))
    }

    static func result(forNativeStatus status: Int32) -> Result<Void, AppFailure> {
        let message: String
        switch status {
        case 0: return .success(())
        case 1: message = "原生旋转参数无效。"
        case 2: message = "此 macOS 环境无法加载原生显示器旋转组件。"
        case 3: message = "此 macOS 环境未提供所需的原生旋转方法。"
        case 4: message = "此 macOS 的旋转接口已变化，已停止调用以避免错误。"
        case 5: message = "原生旋转目标未连接或已无法访问。"
        case 6: message = "macOS 报告此显示器不支持旋转。"
        case 7: message = "macOS 原生旋转组件未能处理请求。"
        default: message = "macOS 原生旋转返回未知状态（\(status)）。"
        }
        return .failure(AppFailure(message: message, reason: status == 5 ? .general : .unavailable))
    }
}
