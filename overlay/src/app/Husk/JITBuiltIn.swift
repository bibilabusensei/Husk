// SPDX-License-Identifier: GPL-2.0-or-later
// Modified 2026-10-14: bounded helper launch, progress IPC and cancellation lifecycle.
import Foundation
import Darwin

@objc private protocol NSExtensionClassShim {
    @objc(extensionWithIdentifier:error:)
    func `extension`(withIdentifier identifier: String) throws -> AnyObject
}

@objc private protocol NSExtensionShim {
    @objc(beginExtensionRequestWithInputItems:completion:)
    func beginExtensionRequest(withInputItems items: [Any], completion: @escaping (NSUUID?) -> Void)
    @objc(pidForRequestIdentifier:)
    func pid(forRequestIdentifier identifier: NSUUID) -> Int32
    @objc(setRequestCompletionBlock:)
    func setRequestCompletionBlock(_ block: @escaping (NSUUID?, [Any]?) -> Void)
    @objc(setRequestCancellationBlock:)
    func setRequestCancellationBlock(_ block: @escaping (NSUUID?, NSError?) -> Void)
    @objc(setRequestInterruptionBlock:)
    func setRequestInterruptionBlock(_ block: @escaping (NSUUID?) -> Void)
    @objc(cancelExtensionRequestWithIdentifier:)
    optional func cancelExtensionRequest(withIdentifier identifier: NSUUID)
}

/// StikJIT remains a separate process. A cancelled request stays registered until
/// iOS reports completion or the helper exits, so a retry cannot race its DDI work.
@MainActor
enum HuskBuiltInJIT {
    static let helperFile = "HuskJITHelper.appex"
    private static var running: [HelperRequest] = []
    static var hasPendingRequest: Bool { !running.isEmpty }

    static var unavailableReason: String? {
#if targetEnvironment(simulator)
        return "内置 JIT 需要真机。"
#else
        guard #available(iOS 26.0, *) else { return "内置 JIT 需要 iOS 26 或更高版本，请使用 StikDebug。" }
        if getenv("LC_HOME_PATH") != nil { return "请独立侧载安装；当前处于 LiveContainer 内。" }
        return nil
#endif
    }
    static var isAvailable: Bool { unavailableReason == nil }
    static var helperIdentifier: String? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent(helperFile) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    static func send(_ request: HuskJITRequest,
                     started: @escaping () -> Void = {},
                     progress: @escaping (HuskJITProgressEvent) -> Void = { _ in },
                     completion: @escaping (Result<HuskJITRequest.Response, Error>) -> Void) {
        func fail(_ code: Int, _ message: String) {
            HuskLog.log("jit-helper", message)
            completion(.failure(HelperRequest.error(code, message)))
        }
        guard !hasPendingRequest else {
            fail(9, "上一次 helper 请求尚未结束。请稍后重试；如果一直无法结束，请完全关闭并重新打开 App。")
            return
        }
        guard unavailableReason == nil else { fail(1, unavailableReason ?? "内置 JIT 不可用。"); return }
        guard let identifier = helperIdentifier else {
            fail(2, "安装中缺少 HuskJITHelper 扩展。重新侧载时保留 App Extensions，并为扩展签名。")
            return
        }
        guard let appID = Bundle.main.bundleIdentifier, identifier.hasPrefix(appID + ".") else {
            fail(2, "主 App 与 JIT helper 的 bundle ID 不匹配。请让侧载器一起重签主 App 和扩展。")
            return
        }
        if NSClassFromString("NSExtension") == nil {
            dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
        }
        guard let extensionClass = NSClassFromString("NSExtension") else {
            fail(3, "系统未提供启动 JIT helper 所需的扩展 API。"); return
        }
        let factory = unsafeBitCast(extensionClass as AnyObject, to: NSExtensionClassShim.self)
        let found: AnyObject
        do { found = try factory.extension(withIdentifier: identifier) }
        catch {
            fail(2, "iOS 无法注册或找到 JIT helper：" + JITDiagnostics.redact(error.localizedDescription)
                 + "。请检查扩展签名，然后重新安装。")
            return
        }
        let helper = HelperRequest(extension: found, operation: request.operation,
                                   progress: progress, completion: completion)
        running.append(helper)
        helper.begin(request: request, started: started)
    }

    static func cancelPending() {
        for helper in running { helper.cancel(message: "已请求停止设置检查；旧 helper 结束后才能重试。") }
    }
    fileprivate static func finished(_ helper: HelperRequest) {
        running.removeAll { $0 === helper }
    }
}

@MainActor
private final class HelperRequest {
    private let shim: NSExtensionShim
    private let extensionObject: AnyObject
    private let operation: HuskJITRequest.Operation
    private let onProgress: (HuskJITProgressEvent) -> Void
    private var completion: ((Result<HuskJITRequest.Response, Error>) -> Void)?
    private var server: HuskJITProgressServer?
    private var launchTimer: Timer?
    private var exitTimer: Timer?
    private var requestID: NSUUID?
    private var pid: Int32 = 0
    private var cancelled = false
    private var retired = false
    private var launchWasSent = false

    init(extension found: AnyObject, operation: HuskJITRequest.Operation,
         progress: @escaping (HuskJITProgressEvent) -> Void,
         completion: @escaping (Result<HuskJITRequest.Response, Error>) -> Void) {
        extensionObject = found
        shim = unsafeBitCast(found, to: NSExtensionShim.self)
        self.operation = operation
        onProgress = progress
        self.completion = completion
    }

    func begin(request: HuskJITRequest, started: @escaping () -> Void) {
        shim.setRequestCompletionBlock { [weak self] _, items in
            let payload = (items?.first as? NSExtensionItem)?.userInfo?[HuskJITRequest.Response.itemKey] as? Data
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.returned(payload) } }
        }
        shim.setRequestCancellationBlock { [weak self] _, error in
            let message = error?.localizedDescription ?? "请求被取消"
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.end(.failure(Self.error(5, "helper 停止：" + JITDiagnostics.redact(message))))
            } }
        }
        shim.setRequestInterruptionBlock { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.end(.failure(Self.error(6, "helper 被系统中断。请检查签名和可用内存。")))
            } }
        }

        // This deadline bounds extension launch only. DDI download has no absolute
        // deadline: a slow, progressing transfer must not become a false failure.
        launchTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancel(message: "25 秒内没有确认 helper 启动。请检查 App Extension 是否保留并正确签名；这不表示 DDI 下载失败。")
            }
        }
        let token = UUID().uuidString + UUID().uuidString
        let server = HuskJITProgressServer(token: token, onEvent: { [weak self] event in
            guard let self, !self.cancelled, !self.retired else { return }
            self.onProgress(event)
        }, onReady: { [weak self] port in
            guard let self, !self.cancelled, !self.retired else { return }
            var outgoing = request
            outgoing.progressPort = port
            outgoing.progressToken = token
            self.launch(request: outgoing, started: started)
        }, onFailure: { [weak self] _ in
            guard let self else { return }
            if self.launchWasSent {
                // Do not interrupt an attached trap servicer for a diagnostic
                // channel failure. NSExtension remains authoritative.
                HuskLog.log("jit-helper", "进度通道中断；继续等待 helper 的正式结果")
            } else {
                self.cancel(message: "无法建立本机 helper 进度通道。请重新打开 App 后重试。")
            }
        })
        self.server = server
        server.start()
    }

    private func launch(request: HuskJITRequest, started: @escaping () -> Void) {
        guard !launchWasSent, !cancelled, !retired else { return }
        guard let data = try? JSONEncoder().encode(request) else {
            end(.failure(Self.error(4, "无法编码 helper 请求。"))); return
        }
        let item = NSExtensionItem()
        item.userInfo = [HuskJITRequest.itemKey: data]
        launchWasSent = true
        shim.beginExtensionRequest(withInputItems: [item]) { [weak self] uuid in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, !self.retired else { return }
                guard let uuid else {
                    // A nil UUID confirms no request started. Even after an
                    // earlier timeout/cancellation, there is no helper process
                    // to await; release the retry exclusion immediately.
                    self.retire()
                    self.deliver(.failure(Self.error(7, "JIT helper 未能启动。请重新安装并保留 App Extensions。")))
                    return
                }
                self.requestID = uuid
                self.pid = self.shim.pid(forRequestIdentifier: uuid)
                self.launchTimer?.invalidate()
                self.launchTimer = nil
                if self.cancelled { self.requestCancellation(); return }
                HuskLog.log("jit-helper", "\(self.operation.rawValue): helper 已启动 pid=\(self.pid)")
                started()
            } }
        }
    }

    func cancel(message: String) {
        guard !cancelled, !retired else { return }
        cancelled = true
        launchTimer?.invalidate()
        server?.stop()
        deliver(.failure(Self.error(10, message)))
        if !launchWasSent { retire(); return }
        if requestID != nil { requestCancellation() }
        // If beginExtensionRequest is still pending, keep this object alive.
        // A late UUID is immediately cancelled and never updates a later run.
    }

    private func requestCancellation() {
        guard let requestID else { return }
        if let object = extensionObject as? NSObject,
           object.responds(to: NSSelectorFromString("cancelExtensionRequestWithIdentifier:")) {
            shim.cancelExtensionRequest?(withIdentifier: requestID)
        } else {
            HuskLog.log("jit-helper", "当前系统不支持取消 helper；等待 helper 结束后才能重试")
        }
        guard exitTimer == nil, pid > 0 else { return }
        exitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.retired else { return }
                // EPERM means present but not signalable, not dead. Never send a
                // signal to the helper; iOS owns its process and cancellation.
                if kill(self.pid, 0) == -1 && errno == ESRCH { self.retire() }
            }
        }
    }

    private func returned(_ payload: Data?) {
        guard let payload, let response = try? JSONDecoder().decode(HuskJITRequest.Response.self, from: payload) else {
            end(.failure(Self.error(8, "helper 结束但没有返回有效结果。"))); return
        }
        if cancelled {
            // Unlike a cancellation notification, a well-formed response is
            // produced only after synchronous handle() has returned. iOS may
            // keep the idle helper process cached, so process exit is not needed.
            retire()
            return
        }
        var safe = response
        safe = .init(success: safe.success, message: JITDiagnostics.redact(safe.message), txmPresent: safe.txmPresent)
        end(.success(safe))
    }
    private func end(_ result: Result<HuskJITRequest.Response, Error>) {
        guard !retired else { return }
        if cancelled {
            // A request-cancellation callback is not proof that synchronous DDI
            // work has stopped. Keep the serial exclusion until process exit.
            if pid > 0, kill(pid, 0) == -1, errno == ESRCH { retire() }
            else if pid > 0, exitTimer == nil { requestCancellation() }
            return
        }
        retire()
        deliver(result)
    }
    private func deliver(_ result: Result<HuskJITRequest.Response, Error>) {
        guard let completion else { return }
        self.completion = nil
        completion(result)
    }
    private func retire() {
        guard !retired else { return }
        retired = true
        launchTimer?.invalidate()
        exitTimer?.invalidate()
        server?.stop()
        server = nil
        HuskBuiltInJIT.finished(self)
    }
    nonisolated static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "HuskBuiltInJIT", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
