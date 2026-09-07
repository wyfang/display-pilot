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
        brightness: Double,
        contrast: Double,
        displayID: CGDirectDisplayID,
        completion: @escaping (Result<Void, AppFailure>) -> Void
    ) {
        onMain {
            guard self.validate(brightness: brightness, contrast: contrast, completion: completion) else { return }
            self.request(commands: ["set"], parameters: [
                "displayID": String(displayID),
                "brightness": Self.format(brightness),
                "contrast": Self.format(contrast)
            ]) { result in
                switch result {
                case .failure(let failure): completion(.failure(failure))
                case .success:
                    // A successful response acknowledges the command. Read the
                    // resulting settings before reporting application success.
                    self.verifyVisualSettings(brightness: brightness, contrast: contrast, displayID: displayID, completion: completion)
                }
            }
        }
    }

    func verifyVisualSettings(
        brightness: Double,
        contrast: Double,
        displayID: CGDirectDisplayID,
        completion: @escaping (Result<Void, AppFailure>) -> Void
    ) {
        onMain {
            guard self.validate(brightness: brightness, contrast: contrast, completion: completion) else { return }
            self.verify(brightness: brightness, contrast: contrast, displayID: displayID, attempt: 0, completion: completion)
        }
    }

    private func verify(
        brightness: Double, contrast: Double, displayID: CGDirectDisplayID, attempt: Int,
        completion: @escaping (Result<Void, AppFailure>) -> Void
    ) {
        readValue("brightness", displayID: displayID) { brightnessResult in
            switch brightnessResult {
            case .failure(let failure): completion(.failure(failure))
            case .success(let actualBrightness):
                self.readValue("contrast", displayID: displayID) { contrastResult in
                    switch contrastResult {
                    case .failure(let failure): completion(.failure(failure))
                    case .success(let actualContrast):
                        // Hardware brightness commonly has integer-percent steps;
                        // software contrast is reported as a fractional value.
                        let brightnessMatches = abs(actualBrightness - brightness) <= 0.010_001
                        let contrastMatches = abs(actualContrast - contrast) <= 0.001_001
                        if brightnessMatches && contrastMatches {
                            completion(.success(()))
                        } else if attempt < 2 {
                            _ = self.transport.schedule(after: 0.35) {
                                self.verify(brightness: brightness, contrast: contrast, displayID: displayID, attempt: attempt + 1, completion: completion)
                            }
                        } else {
                            var differences: [String] = []
                            if !brightnessMatches {
                                differences.append("亮度目标 \(Self.percent(brightness))，实际 \(Self.percent(actualBrightness))")
                            }
                            if !contrastMatches {
                                differences.append("对比度目标 \(Self.percent(contrast))，实际 \(Self.percent(actualContrast))")
                            }
                            completion(.failure(AppFailure(message: "BetterDisplay 读回结果不一致：" + differences.joined(separator: "；"))))
                        }
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
                    completion(.failure(AppFailure(message: "BetterDisplay 未返回可验证的\(feature == "brightness" ? "亮度" : "对比度")数值。")))
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
            self?.finish(uuid, result: .failure(AppFailure(message: "BetterDisplay 响应超时，请确认应用仍在运行，并在其设置中启用 CLI 和通知集成。")))
        }
        pending[uuid]?.cancelTimeout = cancel
        transport.postRequest(json, prefix: prefix)
    }

    private func receiveResponse(_ json: String) {
        let data = Data(json.utf8)
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uuid = envelope["uuid"] as? String, pending[uuid] != nil else { return }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), let succeeded = response.result else {
            finish(uuid, result: .failure(AppFailure(message: "BetterDisplay 返回了无法确认成功状态的响应。")))
            return
        }
        if succeeded {
            finish(uuid, result: .success(response.payload))
        } else {
            let detail = response.payload?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = detail.isEmpty ? "BetterDisplay 拒绝了请求。" : "BetterDisplay 拒绝了请求：\(detail)"
            finish(uuid, result: .failure(AppFailure(message: message)))
        }
    }

    private func finish(_ uuid: String, result: Result<String?, AppFailure>) {
        guard let request = pending.removeValue(forKey: uuid) else { return }
        request.cancelTimeout()
        request.completion(result)
    }

    private func validate(brightness: Double, contrast: Double, completion: (Result<Void, AppFailure>) -> Void) -> Bool {
        guard brightness.isFinite, contrast.isFinite, (0...1).contains(brightness), (-0.9...0.9).contains(contrast) else {
            completion(.failure(AppFailure(message: "预设中的亮度或对比度数值无效，请重新编辑预设。")))
            return false
        }
        return true
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), value * 100)
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
