import AppKit
import CoreGraphics

// Protocol: https://github.com/waydabber/BetterDisplay/wiki/Integration-features,-CLI
// Keep notification delivery injectable so tests never send display commands.
protocol BetterDisplayNotificationTransport: AnyObject {
    func runningApplicationPrefix() -> String?
    func observeResponses(_ receive: @escaping (String) -> Void) -> () -> Void
    func postRequest(_ json: String, prefix: String)
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void
}

private final class SystemBetterDisplayTransport: BetterDisplayNotificationTransport {
    static let bundleIdentifiers = ["pro.betterdisplay.BetterDisplay", "com.betterdisplay.BetterDisplay"]

    func runningApplicationPrefix() -> String? {
        Self.bundleIdentifiers.first {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).contains { !$0.isTerminated }
        }
    }

    func observeResponses(_ receive: @escaping (String) -> Void) -> () -> Void {
        let center = DistributedNotificationCenter.default()
        let observers = Self.bundleIdentifiers.map { prefix in
            center.addObserver(forName: Notification.Name(prefix + ".response"), object: nil, queue: .main) { notification in
                if let json = notification.object as? String { receive(json) }
            }
        }
        return { observers.forEach { center.removeObserver($0) } }
    }

    func postRequest(_ json: String, prefix: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(prefix + ".request"), object: json, userInfo: nil, deliverImmediately: true
        )
    }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }
}

enum VisualField: Hashable { case brightness, contrast }

struct VisualValues: Equatable {
    let brightness: Double
    let contrast: Double

    func mismatches(comparedTo target: VisualValues) -> Set<VisualField> {
        var fields: Set<VisualField> = []
        // Display brightness often has integer-percent steps, but blackout is an exact state.
        let brightnessMatches = (brightness == 0) == (target.brightness == 0)
            && abs(brightness - target.brightness) <= 0.010_001
        let contrastMatches = abs(contrast - target.contrast) <= 0.001_001
        if !brightnessMatches { fields.insert(.brightness) }
        if !contrastMatches { fields.insert(.contrast) }
        return fields
    }
}

final class BetterDisplayBridge {
    private struct Request: Encodable {
        let uuid: String
        let commands: [String]
        let parameters: [String: String?]
    }

    private struct Response: Decodable {
        let uuid: String?
        let result: Bool?
        let payload: String?
    }

    private struct PendingRequest {
        let completion: (Result<String?, AppFailure>) -> Void
        var cancelTimeout: () -> Void = {}
    }

    private let transport: BetterDisplayNotificationTransport
    private let timeout: TimeInterval
    private var stopObserving: (() -> Void)?
    private var pending: [String: PendingRequest] = [:]

    init(transport: BetterDisplayNotificationTransport? = nil, timeout: TimeInterval = 15) {
        self.transport = transport ?? SystemBetterDisplayTransport()
        self.timeout = timeout
        stopObserving = self.transport.observeResponses { [weak self] json in
            self?.onMain { [weak self] in self?.receiveResponse(json) }
        }
    }

    deinit {
        stopObserving?()
        pending.values.forEach { $0.cancelTimeout() }
    }

    func setVisualSettings(
        _ target: VisualValues, fields: Set<VisualField>, displayID: CGDirectDisplayID,
        completion: @escaping (Result<Void, AppFailure>) -> Void
    ) {
        onMain {
            guard !fields.isEmpty else { completion(.success(())); return }
            guard (0...1).contains(target.brightness), (-0.9...0.9).contains(target.contrast) else {
                completion(.failure(AppFailure(message: "预设中的亮度或对比度数值无效，请重新编辑预设。")))
                return
            }
            var parameters: [String: String?] = ["displayID": String(displayID)]
            if fields.contains(.brightness) {
                let rounded = Self.format(target.brightness)
                // Preserve legacy fractional settings that would otherwise request a blackout.
                parameters["brightness"] = target.brightness > 0 && rounded == "0.000" ? String(target.brightness) : rounded
            }
            if fields.contains(.contrast) { parameters["contrast"] = Self.format(target.contrast) }
            self.request(commands: ["set"], parameters: parameters) { result in
                completion(result.map { _ in () })
            }
        }
    }

    func readVisualSettings(
        displayID: CGDirectDisplayID, completion: @escaping (Result<VisualValues, AppFailure>) -> Void
    ) {
        onMain {
            self.readValue("brightness", displayID: displayID) { result in
                switch result {
                case .failure(let failure): completion(.failure(failure))
                case .success(let brightness):
                    self.readValue("contrast", displayID: displayID) { contrast in
                        completion(contrast.map { VisualValues(brightness: brightness, contrast: $0) })
                    }
                }
            }
        }
    }

    private func readValue(
        _ feature: String, displayID: CGDirectDisplayID,
        completion: @escaping (Result<Double, AppFailure>) -> Void
    ) {
        // Request one feature and one display, so the get operation returns a
        // single numeric value rather than a multi-result payload.
        let parameters: [String: String?] = ["displayID": String(displayID), feature: nil]
        request(commands: ["get"], parameters: parameters) { result in
            switch result {
            case .failure(let failure): completion(.failure(failure))
            case .success(let payload):
                guard let payload, let value = Double(payload.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
                    let label = ["brightness": "亮度", "contrast": "对比度"][feature] ?? feature
                    completion(.failure(AppFailure(message: "BetterDisplay 未返回可验证的\(label)数值。")))
                    return
                }
                completion(.success(value))
            }
        }
    }

    private func request(
        commands: [String], parameters: [String: String?],
        completion: @escaping (Result<String?, AppFailure>) -> Void
    ) {
        guard let prefix = transport.runningApplicationPrefix() else {
            completion(.failure(AppFailure(message: "BetterDisplay 未运行，请先打开 BetterDisplay 再应用预设。")))
            return
        }
        let uuid = UUID().uuidString
        let request = Request(uuid: uuid, commands: commands, parameters: parameters)
        guard let data = try? JSONEncoder().encode(request), let json = String(data: data, encoding: .utf8) else {
            completion(.failure(AppFailure(message: "无法生成 BetterDisplay 指令。")))
            return
        }
        pending[uuid] = PendingRequest(completion: completion)
        let cancel = transport.schedule(after: timeout) { [weak self] in
            self?.finish(uuid, result: .failure(AppFailure(message: "BetterDisplay 响应超时，请确认应用仍在运行，并在其设置中启用 CLI 和通知集成。", reason: .unconfirmed)))
        }
        pending[uuid]?.cancelTimeout = cancel
        transport.postRequest(json, prefix: prefix)
    }

    private func receiveResponse(_ json: String) {
        let data = Data(json.utf8)
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uuid = envelope["uuid"] as? String, pending[uuid] != nil else { return }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), let succeeded = response.result else {
            finish(uuid, result: .failure(AppFailure(message: "BetterDisplay 返回了无法确认成功状态的响应。", reason: .unconfirmed)))
            return
        }
        if succeeded {
            finish(uuid, result: .success(response.payload))
        } else {
            let detail = response.payload?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = detail.isEmpty ? "BetterDisplay 拒绝了请求。" : "BetterDisplay 拒绝了请求：\(detail)"
            finish(uuid, result: .failure(AppFailure(message: message,
                reason: detail.localizedCaseInsensitiveContains("pro required") ? .requiresPro : .general)))
        }
    }

    private func finish(_ uuid: String, result: Result<String?, AppFailure>) {
        guard let request = pending.removeValue(forKey: uuid) else { return }
        request.cancelTimeout()
        request.completion(result)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }

    func openApp(completion: @escaping (Result<Void, AppFailure>) -> Void) {
        onMain {
            let workspace = NSWorkspace.shared
            let url = SystemBetterDisplayTransport.bundleIdentifiers.compactMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.bundleURL
                    ?? workspace.urlForApplication(withBundleIdentifier: $0)
            }.first
            guard let url else {
                completion(.failure(AppFailure(message: "没有找到 BetterDisplay，请先安装 BetterDisplay。")))
                return
            }
            workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                self.onMain {
                    if let error {
                        completion(.failure(AppFailure(message: "无法打开 BetterDisplay：\(error.localizedDescription)")))
                    } else {
                        completion(.success(()))
                    }
                }
            }
        }
    }

    func openApp() {
        openApp { result in
            if case .failure(let failure) = result {
                let alert = NSAlert()
                alert.messageText = "无法打开 BetterDisplay"
                alert.informativeText = failure.message
                alert.runModal()
            }
        }
    }
}
