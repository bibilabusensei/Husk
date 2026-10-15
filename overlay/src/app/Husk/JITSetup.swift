// SPDX-License-Identifier: GPL-2.0-or-later
// Modified 2026-10-14: phase progress, monotonic stall detection and request isolation.
import Foundation
import SwiftUI
import UIKit

/// How Husk gets a debugger attached. See docs/06-built-in-jit.md.
enum JITMethod: String, CaseIterable, Identifiable {
    /// StikDebug when it is installed, then TrollStore, otherwise Built-in StikJIT.
    case automatic
    case stikDebug
    case trollStore
    case jailbreak
    case builtIn

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .stikDebug: return "StikDebug"
        case .trollStore: return "TrollStore"
        case .jailbreak: return "Jailbreak (Dopamine)"
        case .builtIn: return "Built-in StikJIT"
        }
    }
}

/// Where Built-in StikJIT's pairing file came from.
enum JITPairingSource: String {
    /// Made by Husk on this device (iOS 27, OnDevicePairing).
    case onDevice
    /// Imported from a file made on a computer.
    case imported
}

/// The RPPairing file Built-in StikJIT authenticates with. Lives in Documents,
/// so it is visible through Finder file sharing -- it is device-sensitive and
/// is only ever sent to Husk's own helper process.
enum JITPairingFileStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
    }
    static var url: URL { directory.appendingPathComponent("pairingFile.plist") }
    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    private static let sourceKey = "husk.jitPairingSource"

    static var source: JITPairingSource? {
        guard exists else { return nil }
        return UserDefaults.standard.string(forKey: sourceKey).flatMap(JITPairingSource.init(rawValue:)) ?? .imported
    }

    static func data() throws -> Data { try Data(contentsOf: url) }

    static func importFile(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try store(try Data(contentsOf: source), source: .imported)
    }

    /// Validates an RPPairing plist and makes it the pairing file.
    static func store(_ data: Data, source: JITPairingSource) throws {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let publicKey = dictionary["public_key"] as? Data, publicKey.count == 32,
              let privateKey = dictionary["private_key"] as? Data, privateKey.count == 32,
              let identifier = dictionary["identifier"] as? String, !identifier.isEmpty else {
            throw NSError(domain: "HuskJIT", code: 10,
                          userInfo: [NSLocalizedDescriptionKey:
                            "That is not a remote pairing file. Make one with the StikDebug pairing-file guide and try again."])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        UserDefaults.standard.set(source.rawValue, forKey: sourceKey)
    }
}

@MainActor
final class JITCoordinator: ObservableObject {
    static let shared = JITCoordinator()

    /// Why the built-in helper could not reach this device, read from its error.
    enum ConnectionProblem: Equatable {
        /// Nothing answered at LocalDevVPN's address: the VPN is off or not routing.
        case vpn
        /// The device closed the connection, usually because it no longer accepts
        /// this pairing (every new pairing replaces the last).
        case pairing

        init?(helperMessage: String) {
            let text = helperMessage.lowercased()
            let has = { (needles: [String]) in needles.contains(where: text.contains) }
            if has(["connectionreset", "connection reset", "device refused connection"]) {
                self = .pairing
            } else if has(["connectionrefused", "connection refused", "timedout", "timed out",
                           "networkunreachable", "network unreachable", "hostunreachable",
                           "host unreachable", "no route"]) {
                self = .vpn
            } else {
                return nil
            }
        }

        var message: String {
            switch self {
            case .vpn:
                return "Husk couldn't reach this device. Connect LocalDevVPN, then try again."
            case .pairing:
                return "This device closed the connection, which usually means it no longer accepts "
                     + "Husk's pairing. Pair again, and check that LocalDevVPN is connected."
            }
        }
    }

    @Published var method: JITMethod {
        didSet { UserDefaults.standard.set(method.rawValue, forKey: "husk.jitMethod") }
    }
    @Published var showSetup = false
    @Published private(set) var connectionProblem: ConnectionProblem?
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    @Published private(set) var txmPresent: Bool?
    @Published private(set) var progressFraction: Double?
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var progressStalled = false
    @Published private(set) var helperResponding = false
    @Published private(set) var diagnosticEvents: [String] = []
    private var activeRequest: UUID?
    private var monitoring: Timer?
    private var requestBegan: TimeInterval = 0
    private var lastProgressAt: TimeInterval = 0
    private var lastHeartbeatAt: TimeInterval = 0
    private var lastStage: String?
    private var lastFraction: Double?
    private var attachBegan: TimeInterval?
    /// The setup check passed for the current pairing file.
    @Published private(set) var prepared = false
    @Published private(set) var pairingSource = JITPairingFileStore.source
    /// Bumped each time the built-in helper attaches. Husk stays in the
    /// foreground for that, so nothing else tells ContentView to claim the region.
    @Published private(set) var attachGeneration = 0

    var hasPairing: Bool { pairingSource != nil }

    private init() {
        method = UserDefaults.standard.string(forKey: "husk.jitMethod")
            .flatMap(JITMethod.init(rawValue:)) ?? .automatic
    }

    var resolvedMethod: JITMethod {
        guard method == .automatic else { return method }
        if JITBootstrap.isStikDebugInstalled { return .stikDebug }
        if JITBootstrap.isTrollStoreInstalled { return .trollStore }
        if JITBootstrap.isJailbroken { return .jailbreak }
        return .builtIn
    }

    var automaticDescription: String {
        switch resolvedMethod {
        case .stikDebug: return "StikDebug is installed, so Husk will open it."
        case .trollStore: return "TrollStore is installed, so Husk will ask it to enable JIT."
        case .jailbreak: return "This device is jailbroken, so JIT comes from the jailbreak's Allow JIT in Apps setting."
        default: return "StikDebug, TrollStore and a jailbreak were not found, so Husk will use its built-in helper."
        }
    }

    func refreshPairingStatus() {
        pairingSource = JITPairingFileStore.source
    }

    private func log(_ line: String) {
        let safe = JITDiagnostics.redact(line)
        HuskLog.log("jit", safe)
        diagnosticEvents.append("[\(elapsedSeconds)s] " + safe)
        if diagnosticEvents.count > 80 { diagnosticEvents.removeFirst(diagnosticEvents.count - 80) }
    }

    var diagnosticReport: String {
        JITDiagnostics.snapshot() + "\n\n本次设置：\n" + diagnosticEvents.joined(separator: "\n")
    }

    /// Get a debugger attached with whichever method applies, or open the setup
    /// walkthrough when that method is not set up yet.
    /// "Turn on JIT at launch": when Husk opens without JIT, ask the built-in StikJIT for it straight away, once per launch.
    /// Only when StikJIT can do it unattended -- it is available here and already paired -- so opening Husk never lands in
    /// the setup walkthrough by surprise.
    static let autoEnableKey = "husk.jit.autoEnable"
    private var autoTried = false

    func enableAtLaunchIfAsked() {
        guard !autoTried, UserDefaults.standard.bool(forKey: Self.autoEnableKey) else { return }
        autoTried = true
        guard !JITBootstrap.ready else { return }
        guard HuskBuiltInJIT.isAvailable, hasPairing else {
            log("JIT at launch is on, but built-in StikJIT is not available or not paired; skipped")
            return
        }
        log("turning JIT on at launch with built-in StikJIT")
        method = .builtIn
        enable()
    }

    func enable() {
        guard !busy else { return }
        guard !JITBootstrap.ready else { return }
        error = nil
        connectionProblem = nil
        switch resolvedMethod {
        case .automatic:
            assertionFailure("Automatic must resolve to a concrete JIT method")
        case .stikDebug:
            if !JITBootstrap.requestAttach(), !JITBootstrap.requestTrollStoreAttach() {
                error = "StikDebug is not installed. Install it, or set up Built-in StikJIT."
                showSetup = true
            }
        case .trollStore:
            if JITBootstrap.requestTrollStoreAttach() {
                awaitTrollStore()
            } else {
                error = "TrollStore could not be opened. Install Husk through TrollStore, or choose another method."
                showSetup = true
            }
        case .jailbreak:
            // Nothing to ask: a jailbreak marks an app as debugged as it opens, if it has been told to. Say what to turn on.
            error = "Turn on Allow JIT in Apps in Dopamine's settings, then open Husk again."
            showSetup = true
        case .builtIn:
            guard HuskBuiltInJIT.isAvailable, hasPairing else {
                log("built-in JIT is not set up; opening the walkthrough")
                showSetup = true
                return
            }
            enableBuiltIn()
        }
    }

    /// After TrollStore is asked: it opens Husk again and attaches to it for a moment, which marks the process as debugged. Watch for
    /// that, so the Games tab and the Library notice without waiting for another trip to the foreground, and say what to check if
    /// it never comes -- TrollStore only answers enable-jit once its URL Scheme setting is on.
    private func awaitTrollStore() {
        busy = true
        status = "Waiting for TrollStore to enable JIT…"
        log("waiting for TrollStore's attach")
        _ = Self.waitForDebugger(timeout: 60) { [weak self] attached in
            guard let self else { return }
            busy = false
            if attached {
                status = "JIT is on."
                error = nil
                attachGeneration += 1
                log("TrollStore enabled JIT")
            } else {
                status = nil
                error = "TrollStore did not enable JIT. In TrollStore's Settings turn on URL Scheme, and make sure Husk was "
                      + "installed through TrollStore (or is signed with get-task-allow)."
                log("TrollStore did not enable JIT within a minute")
                showSetup = true
            }
        }
    }

    func importPairingFile(_ source: URL) {
        do {
            try JITPairingFileStore.importFile(from: source)
            OnDevicePairing.shared.cancel()
            refreshPairingStatus()
            method = .builtIn
            prepared = false
            status = "Pairing file imported."
            error = nil
            log("pairing file imported")
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// OnDevicePairing finished: its file becomes the pairing file and Built-in StikJIT the method.
    func storeOnDevicePairing(_ data: Data) throws {
        try JITPairingFileStore.store(data, source: .onDevice)
        refreshPairingStatus()
        method = .builtIn
        prepared = false
        status = "Paired on this device."
        error = nil
    }

    /// Check LocalDevVPN and the Developer Disk Image, mounting it when needed.
    func prepareBuiltIn() {
        guard let pairing = builtInPairing() else { return }
        performBuiltIn(.prepare(pairingData: pairing))
    }

    func enableBuiltIn() {
        guard let pairing = builtInPairing() else { return }
        guard let script = JITBootstrap.scriptBase64 else {
            error = "Husk's JIT script is missing from this installation. Reinstall Husk."
            return
        }

        performBuiltIn(.enable(targetPID: getpid(), pairingData: pairing, scriptBase64: script))
    }

    func resetDDI() {
        performBuiltIn(.resetDDI)
    }

    /// Invalidate the generation before cancellation, including any synchronous
    /// error callback. Never let an old completion overwrite a later run.
    func cancelBuiltIn() {
        guard busy, !JITBootstrap.debuggedFlag else { return }
        activeRequest = nil
        monitoring?.invalidate()
        monitoring = nil
        busy = false
        prepared = false
        progressFraction = nil
        progressStalled = false
        status = nil
        error = "已请求停止。helper 完全结束前不能重试；如果一直无法结束，请完全关闭并重新打开 App。"
        log("设置检查取消；等待 helper 确认结束")
        HuskBuiltInJIT.cancelPending()
    }

    private func performBuiltIn(_ request: HuskJITRequest) {
        guard !busy else { return }
        guard !HuskBuiltInJIT.hasPendingRequest else {
            error = "上一次 helper 尚未结束，请稍后重试或重新打开 App。"
            return
        }
        let generation = UUID()
        activeRequest = generation
        busy = true
        prepared = false
        error = nil
        connectionProblem = nil
        progressFraction = nil
        elapsedSeconds = 0
        progressStalled = false
        helperResponding = false
        lastStage = nil
        lastFraction = nil
        attachBegan = nil
        requestBegan = ProcessInfo.processInfo.systemUptime
        lastProgressAt = requestBegan
        lastHeartbeatAt = 0
        status = "正在启动独立 JIT helper…"
        log("\(request.operation.rawValue): 新的设置请求")
        monitoring?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.activeRequest == generation, self.busy else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.elapsedSeconds = Int(now - self.requestBegan)
                self.progressStalled = now - self.lastProgressAt >= 90
                self.helperResponding = self.lastHeartbeatAt > 0 && now - self.lastHeartbeatAt < 15
                if request.operation == .enable {
                    if JITBootstrap.debuggedFlag || JITBootstrap.prewarmed || JITBootstrap.isLive {
                        self.monitoring?.invalidate()
                        self.monitoring = nil
                        self.busy = false
                        self.error = nil
                        self.status = "调试器已连接，正在申请可执行内存。"
                        self.attachGeneration += 1
                        self.log("helper debugger attach confirmed; JIT memory still requires prewarm")
                    } else if let began = self.attachBegan, now - began >= 90 {
                        self.cancelBuiltIn()
                        self.error = "DDI 准备完成，但 90 秒内没有确认调试器连接。请导出诊断并核对开发者签名、get-task-allow 和配对。"
                    }
                }
            }
        }
        monitoring = timer
        RunLoop.main.add(timer, forMode: .common)
        HuskBuiltInJIT.send(request, started: { [weak self] in
            guard let self, self.activeRequest == generation, self.busy else { return }
            self.status = request.operation == .resetDDI ? "正在重置 DDI 缓存…" : "helper 已启动，等待设备连接…"
        }, progress: { [weak self] event in
            guard let self, self.activeRequest == generation, self.busy else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.lastHeartbeatAt = now
            self.helperResponding = true
            guard event.stage != "heartbeat" else { return }
            if event.stage != self.lastStage || event.fraction != self.lastFraction {
                self.lastProgressAt = now
                self.progressStalled = false
                self.lastStage = event.stage
                self.lastFraction = event.fraction
                self.log("阶段=\(event.stage)" + (event.fraction.map { " 进度=\(Int($0 * 100))%" } ?? ""))
            }
            self.progressFraction = event.fraction
            self.status = Self.stageDescription(event.stage)
            if event.stage == "attaching", self.attachBegan == nil { self.attachBegan = now }
        }, completion: { [weak self] result in
            guard let self, self.activeRequest == generation else { return }
            // An enable request normally returns after prewarm and detach. Its
            // delayed successful completion must not replace the established UI.
            let memoryReady = request.operation == .enable && (JITBootstrap.prewarmed || JITBootstrap.isLive)
            self.monitoring?.invalidate()
            self.monitoring = nil
            self.busy = false
            self.progressStalled = false
            self.activeRequest = nil
            self.progressFraction = nil
            if memoryReady {
                self.status = "JIT 可执行内存已准备好。"
                self.error = nil
                self.log("helper 请求结束；已确认 JIT 内存，不再让迟到回调改变成功状态")
                return
            }
            switch result {
            case .success(let response):
                self.txmPresent = response.txmPresent
                self.log("\(request.operation.rawValue): \(response.success ? "成功" : "失败") \(response.message)")
                self.prepared = request.operation == .prepare && response.success
                if request.operation == .enable && response.success {
                    // A successful return without a observed debugger is not JIT.
                    self.error = "helper 已返回，但没有确认可执行内存。请检查日志并重新运行 JIT 设置。"
                    self.status = nil
                } else {
                    self.status = response.success ? response.message : nil
                    self.error = response.success ? nil : self.helperFailure(response.message)
                }
            case .failure(let failure):
                self.prepared = false
                self.status = nil
                self.error = JITDiagnostics.redact(failure.localizedDescription)
                self.log("\(request.operation.rawValue): \(self.error ?? "失败")")
            }
        })
    }

    private static func stageDescription(_ stage: String) -> String {
        switch stage {
        case "helperStarted": return "helper 已响应"
        case "checkingReachability": return "正在检查 VPN 路由与本机配对连接…"
        case "checkingDDI": return "正在检查 DDI 缓存和系统版本…"
        case "downloadingDDI": return "正在下载匹配系统的 Developer Disk Image…"
        case "mountingDDI": return "正在挂载 Developer Disk Image…"
        case "verifyingDDI": return "正在验证 Developer Disk Image…"
        case "ready": return "VPN 与 DDI 准备完成"
        case "attaching": return "DDI 已就绪，正在等待调试器连接…"
        case "scriptRunning": return "正在运行 Husk JIT 调试脚本…"
        case "resettingDDI": return "正在重置 DDI 缓存…"
        case "detached": return "调试器已结束请求"
        default: return "helper 正在处理请求…"
        }
    }

    private func builtInPairing() -> Data? {
        if let reason = HuskBuiltInJIT.unavailableReason {
            error = reason
            return nil
        }
        guard let pairing = try? JITPairingFileStore.data() else {
            error = "Pair this device or import its pairing file first."
            return nil
        }
        return pairing
    }

    /// The helper's failure as shown: a connection problem gets its plain
    /// explanation (the helper's own message is already in the log).
    private func helperFailure(_ message: String) -> String {
        connectionProblem = ConnectionProblem(helperMessage: message)
        return connectionProblem?.message ?? message
    }

    /// Polls CS_DEBUGGED until it is set or `timeout` passes.
    private static func waitForDebugger(timeout: TimeInterval = 90,
                                        completion: @escaping (Bool) -> Void) -> Timer {
        let deadline = Date().addingTimeInterval(timeout)
        let timer = Timer(timeInterval: 0.5, repeats: true) { timer in
            if JITBootstrap.debuggedFlag {
                timer.invalidate()
                completion(true)
            } else if Date() >= deadline {
                timer.invalidate()
                completion(false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// LocalDevVPN, which Built-in StikJIT and StikDebug reach the device through:
/// open it to connect when it is installed, otherwise its App Store page.
enum LocalDevVPN {
    static let appStore = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    /// `enable` connects the VPN; `scheme` has LocalDevVPN return to Husk afterwards.
    static let connect = URL(string: "localdevvpn://enable?scheme=husk")!

    static var isInstalled: Bool { UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!) }
    static var actionTitle: String { isInstalled ? "Connect LocalDevVPN" : "Get LocalDevVPN" }

    @MainActor static func open() {
        let installed = isInstalled
        HuskLog.log("jit", "LocalDevVPN \(installed ? "connect" : "app-store")")
        UIApplication.shared.open(installed ? connect : appStore)
    }
}

