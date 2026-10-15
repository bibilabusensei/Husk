// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Network

/// Progress only. The NSExtension completion remains the authoritative result.
/// Neither pairing data nor underlying service messages are sent on this channel.
struct HuskJITProgressEvent: Codable, Sendable {
    let token: String
    let stage: String
    let fraction: Double?
    let elapsed: TimeInterval

    static let stages: Set<String> = [
        "helperStarted", "heartbeat", "checkingReachability", "checkingDDI",
        "downloadingDDI", "mountingDDI", "verifyingDDI", "ready", "attaching",
        "scriptRunning", "detached", "resettingDDI"
    ]

    var isValid: Bool {
        Self.stages.contains(stage) && token.utf8.count <= 128
            && elapsed.isFinite && elapsed >= 0
            && (fraction == nil || (fraction!.isFinite && (0...1).contains(fraction!)))
    }
}

/// Protects delivery after stop(), including callbacks already queued on main.
private final class HuskJITProgressLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func stop() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

/// An ephemeral, IPv4 loopback listener. No App Group entitlement is needed.
/// Each request must supply a new unpredictable token and its own server.
/// Mutable Network state is confined to queue; callbacks run on MainActor.
final class HuskJITProgressServer: @unchecked Sendable {
    typealias EventHandler = @MainActor @Sendable (HuskJITProgressEvent) -> Void
    typealias ReadyHandler = @MainActor @Sendable (UInt16) -> Void
    typealias FailureHandler = @MainActor @Sendable (String) -> Void

    private final class Client {
        let connection: NWConnection
        var buffer = Data()
        var authenticated = false

        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let queue = DispatchQueue(label: "com.husk.rebuilt.jit-progress.server")
    private let lifetime = HuskJITProgressLifetime()
    private let token: String
    private let onEvent: EventHandler
    private let onReady: ReadyHandler
    private let onFailure: FailureHandler
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var started = false
    private var reportedFailure = false
    private static let maximumLineLength = 2048

    init(token: String, onEvent: @escaping EventHandler,
         onReady: @escaping ReadyHandler, onFailure: @escaping FailureHandler) {
        self.token = token
        self.onEvent = onEvent
        self.onReady = onReady
        self.onFailure = onFailure
    }

    func start() {
        queue.async { [self] in
            guard lifetime.isActive, !started else { return }
            started = true
            guard token.utf8.count >= 32, token.utf8.count <= 128 else {
                fail("The JIT progress channel has no valid request token.")
                return
            }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredInterfaceType = .loopback
                parameters.requiredLocalEndpoint = .hostPort(
                    host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
                let server = try NWListener(using: parameters)
                listener = server
                server.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                server.stateUpdateHandler = { [weak self, weak server] state in
                    guard let self, self.lifetime.isActive else { return }
                    switch state {
                    case .ready:
                        guard let port = server?.port?.rawValue else {
                            self.fail("The JIT progress channel did not receive a local port.")
                            return
                        }
                        let lifetime = self.lifetime
                        let callback = self.onReady
                        DispatchQueue.main.async {
                            guard lifetime.isActive else { return }
                            callback(port)
                        }
                    case .failed(let error):
                        self.fail("The JIT progress channel could not start: \(error.localizedDescription)")
                    default: break
                    }
                }
                server.start(queue: queue)
            } catch {
                fail("The JIT progress channel could not start: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        lifetime.stop()
        queue.async { [self] in close() }
    }

    private func accept(_ connection: NWConnection) {
        guard lifetime.isActive, clients.count < 4 else {
            connection.cancel()
            return
        }
        let identifier = UUID()
        let client = Client(connection)
        clients[identifier] = client
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.receive(identifier)
            case .failed, .cancelled: self.drop(identifier)
            default: break
            }
        }
        connection.start(queue: queue)
        // Unauthenticated local clients cannot occupy a slot indefinitely.
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, let current = self.clients[identifier], !current.authenticated else { return }
            self.drop(identifier)
        }
    }

    private func receive(_ identifier: UUID) {
        guard let client = clients[identifier], lifetime.isActive else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, complete, error in
            guard let self, let client = self.clients[identifier], self.lifetime.isActive else { return }
            if let data { client.buffer.append(data) }
            while let newline = client.buffer.firstIndex(of: 10) {
                let line = Data(client.buffer[..<newline])
                client.buffer.removeSubrange(...newline)
                guard line.count <= Self.maximumLineLength,
                      let event = try? JSONDecoder().decode(HuskJITProgressEvent.self, from: line),
                      event.token == self.token, event.isValid else {
                    self.drop(identifier)
                    return
                }
                client.authenticated = true
                let lifetime = self.lifetime
                let callback = self.onEvent
                DispatchQueue.main.async {
                    guard lifetime.isActive else { return }
                    callback(event)
                }
            }
            guard client.buffer.count <= Self.maximumLineLength else {
                self.drop(identifier)
                return
            }
            if complete || error != nil {
                self.drop(identifier)
            } else {
                self.receive(identifier)
            }
        }
    }

    private func drop(_ identifier: UUID) {
        clients.removeValue(forKey: identifier)?.connection.cancel()
    }

    private func fail(_ message: String) {
        guard !reportedFailure, lifetime.isActive else { return }
        reportedFailure = true
        close()
        let lifetime = lifetime
        let callback = onFailure
        DispatchQueue.main.async {
            guard lifetime.isActive else { return }
            callback(message)
        }
    }

    private func close() {
        listener?.cancel()
        listener = nil
        let connections = clients.values.map(\.connection)
        clients.removeAll()
        for connection in connections { connection.cancel() }
    }

    deinit {
        lifetime.stop()
        listener?.cancel()
        for client in clients.values { client.connection.cancel() }
    }
}

/// Helper-side progress and liveness. Heartbeats never represent work progress.
/// Networking uses a separate serial queue so blocking StikJIT calls do not
/// prevent event delivery. Only stage names from the shared allowlist are sent.
final class HuskJITProgressReporter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.husk.rebuilt.jit-progress.reporter")
    private let connection: NWConnection
    private let token: String
    private let began = ProcessInfo.processInfo.systemUptime
    private var heartbeat: DispatchSourceTimer?
    private var pending: [Data] = []
    private var ready = false
    private var stopped = false
    private var stopping = false
    private var sendsInFlight = 0

    init(port: UInt16, token: String) {
        self.token = token
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        connection = NWConnection(host: .ipv4(IPv4Address("127.0.0.1")!),
                                  port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                self.ready = true
                let buffered = self.pending
                self.pending.removeAll()
                for data in buffered { self.transmit(data) }
                self.finishIfDrained()
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.async { [self] in
            guard !stopped else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in
                self?.enqueue(stage: "heartbeat", fraction: nil)
            }
            heartbeat = timer
            timer.resume()
        }
    }

    func send(stage: String, fraction: Double? = nil) {
        queue.async { [self] in enqueue(stage: stage, fraction: fraction) }
    }

    /// Best-effort drain with a bounded grace period; never blocks StikJIT.
    func stop() {
        queue.async { [self] in
            guard !stopping, !stopped else { return }
            stopping = true
            heartbeat?.cancel()
            heartbeat = nil
            finishIfDrained()
            // Keep the reporter alive long enough to drain even when the
            // helper's local variable goes out of scope immediately after stop.
            queue.asyncAfter(deadline: .now() + 2) { [self] in close() }
        }
    }

    private func enqueue(stage: String, fraction: Double?) {
        guard !stopped, !stopping, HuskJITProgressEvent.stages.contains(stage) else { return }
        let fraction = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        if stage != "heartbeat" {
            guard stage != previousStage || fraction != previousFraction else { return }
            previousStage = stage
            previousFraction = fraction
        }
        let event = HuskJITProgressEvent(token: token, stage: stage, fraction: fraction,
                                         elapsed: max(0, ProcessInfo.processInfo.systemUptime - began))
        guard var data = try? JSONEncoder().encode(event), data.count <= 2048 else { return }
        data.append(10)
        if ready {
            transmit(data)
        } else {
            // Bound memory if a listener is delayed or unavailable.
            if pending.count >= 32 { pending.removeFirst() }
            pending.append(data)
        }
    }

    private func transmit(_ data: Data) {
        guard !stopped else { return }
        sendsInFlight += 1
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.stopped else { return }
            self.sendsInFlight -= 1
            if error != nil { self.close() }
            else { self.finishIfDrained() }
        })
    }

    // The JIT script may emit many lines per second. Phase progress is sent
    // only when it changes, keeping its diagnostic channel bounded in practice.
    private var previousStage: String?
    private var previousFraction: Double?

    private func finishIfDrained() {
        if stopping, ready, pending.isEmpty, sendsInFlight == 0 { close() }
    }

    private func close() {
        guard !stopped else { return }
        stopped = true
        heartbeat?.cancel()
        heartbeat = nil
        pending.removeAll()
        connection.cancel()
    }

    deinit {
        heartbeat?.cancel()
        connection.cancel()
    }
}
