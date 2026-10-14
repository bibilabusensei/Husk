// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Network
import Darwin

private struct TransportCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class ProgressProbe {
    var port: UInt16?
    var events: [HuskJITProgressEvent] = []
    private var unread: [HuskJITProgressEvent] = []
    private var portWaiter: CheckedContinuation<UInt16, Error>?
    private var eventWaiter: CheckedContinuation<HuskJITProgressEvent, Error>?
    private var failure: Error?

    func ready(_ value: UInt16) {
        guard failure == nil else { return }
        port = value
        portWaiter?.resume(returning: value)
        portWaiter = nil
    }

    func received(_ event: HuskJITProgressEvent) {
        guard failure == nil else { return }
        events.append(event)
        if let waiter = eventWaiter {
            eventWaiter = nil
            waiter.resume(returning: event)
        } else {
            unread.append(event)
        }
    }

    func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        portWaiter?.resume(throwing: error)
        portWaiter = nil
        eventWaiter?.resume(throwing: error)
        eventWaiter = nil
    }

    func waitForPort() async throws -> UInt16 {
        if let failure { throw failure }
        if let port { return port }
        return try await withCheckedThrowingContinuation { portWaiter = $0 }
    }

    func nextEvent() async throws -> HuskJITProgressEvent {
        if let failure { throw failure }
        if !unread.isEmpty { return unread.removeFirst() }
        return try await withCheckedThrowingContinuation { eventWaiter = $0 }
    }
}

/// This is a real network client, not a substitute implementation of the parser.
private final class CheckConnection: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.husk.check.connection")
    private let connection: NWConnection
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var closed = false

    init(port: UInt16) {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        connection = NWConnection(host: .ipv4(IPv4Address("127.0.0.1")!),
                                  port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !closed else {
                    continuation.resume(throwing: TransportCheckFailure(description: "The check connection was closed."))
                    return
                }
                connectWaiter = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.connectWaiter?.resume()
                        self.connectWaiter = nil
                    case .failed(let error):
                        self.connectWaiter?.resume(throwing: error)
                        self.connectWaiter = nil
                    case .cancelled:
                        self.connectWaiter?.resume(throwing: TransportCheckFailure(description: "Connection cancelled."))
                        self.connectWaiter = nil
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !closed else {
                    continuation.resume(throwing: TransportCheckFailure(description: "Connection closed before write."))
                    return
                }
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        }
    }

    func close() {
        queue.async { [self] in
            closed = true
            connectWaiter?.resume(throwing: TransportCheckFailure(description: "Connection closed by watchdog."))
            connectWaiter = nil
            connection.cancel()
        }
    }
}

@MainActor
private final class CheckResources {
    var probes: [ProgressProbe] = []
    var servers: [HuskJITProgressServer] = []
    var clients: [CheckConnection] = []
    var reporters: [HuskJITProgressReporter] = []

    func close() {
        for server in servers { server.stop() }
        for client in clients { client.close() }
        for reporter in reporters { reporter.stop() }
    }

    func timedOut() {
        let error = TransportCheckFailure(description: "Progress transport check exceeded its 10-second deadline.")
        for probe in probes { probe.fail(error) }
        close()
    }

    func makeServer(token: String) -> ProgressProbe {
        let probe = ProgressProbe()
        probes.append(probe)
        let server = HuskJITProgressServer(token: token, onEvent: { probe.received($0) },
            onReady: { probe.ready($0) }, onFailure: {
                probe.fail(TransportCheckFailure(description: $0))
            })
        servers.append(server)
        server.start()
        return probe
    }

    func connect(port: UInt16) async throws -> CheckConnection {
        let client = CheckConnection(port: port)
        clients.append(client)
        try await client.connect()
        return client
    }
}

@main
private struct ProgressTransport {
    @MainActor
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TransportCheckFailure(description: message) }
    }

    static func frame(token: String, stage: String, fraction: Double? = nil) throws -> Data {
        let event = HuskJITProgressEvent(token: token, stage: stage, fraction: fraction, elapsed: 1)
        var data = try JSONEncoder().encode(event)
        data.append(10)
        return data
    }

    @MainActor
    static func run() async throws {
        let resources = CheckResources()
        let deadline = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { return }
            resources.timedOut()
        }
        defer { deadline.cancel(); resources.close() }

        let token = UUID().uuidString + UUID().uuidString
        let probe = resources.makeServer(token: token)
        let port = try await probe.waitForPort()
        try require(port > 0, "The listener did not bind an ephemeral port.")

        let intruder = try await resources.connect(port: port)
        try await intruder.write(frame(token: "wrong-token", stage: "checkingDDI"))
        try await Task.sleep(nanoseconds: 150_000_000)
        try require(probe.events.isEmpty, "An incorrect token delivered a progress callback.")
        intruder.close()

        // A fresh, correctly authenticated connection remains usable after an
        // invalid client. Separate writes force the listener to buffer a frame.
        let client = try await resources.connect(port: port)
        let fragmented = try frame(token: token, stage: "downloadingDDI", fraction: 0.25)
        let split = fragmented.count / 2
        try await client.write(Data(fragmented.prefix(split)))
        try await Task.sleep(nanoseconds: 150_000_000)
        try require(probe.events.isEmpty, "An incomplete JSON frame produced a callback.")
        try await client.write(Data(fragmented.dropFirst(split)))
        let first = try await probe.nextEvent()
        try require(first.stage == "downloadingDDI" && first.fraction == 0.25 && first.token == token,
                    "A fragmented authenticated frame was lost or altered.")

        var joined = try frame(token: token, stage: "checkingDDI")
        joined.append(try frame(token: token, stage: "mountingDDI", fraction: 0.5))
        try await client.write(joined)
        let second = try await probe.nextEvent()
        let third = try await probe.nextEvent()
        try require(second.stage == "checkingDDI" && third.stage == "mountingDDI" && third.fraction == 0.5,
                    "Coalesced newline frames were not delivered in order.")

        let beforeStop = probe.events.count
        resources.servers[0].stop()
        // Cancellation may make this write fail. Either outcome must suppress
        // callbacks, including callbacks that were already enqueued on main.
        do { try await client.write(frame(token: token, stage: "ready")) } catch {}
        try await Task.sleep(nanoseconds: 150_000_000)
        try require(probe.events.count == beforeStop, "A stopped listener updated the UI callback.")

        // Also exercise the actual helper-side reporter and its allowlist;
        // the custom client above exists only to split production wire frames.
        let reporterToken = UUID().uuidString + UUID().uuidString
        let reporterProbe = resources.makeServer(token: reporterToken)
        let reporterPort = try await reporterProbe.waitForPort()
        let reporter = HuskJITProgressReporter(port: reporterPort, token: reporterToken)
        resources.reporters.append(reporter)
        reporter.send(stage: "arbitrary-private-status-should-never-be-sent")
        reporter.send(stage: "mountingDDI", fraction: 4)
        let reported = try await reporterProbe.nextEvent()
        try require(reported.stage == "mountingDDI" && reported.fraction == 1 && reported.token == reporterToken,
                    "The production reporter leaked an unknown stage or failed to clamp its fraction.")
        reporter.send(stage: "mountingDDI", fraction: 4) // duplicate after clamping
        reporter.send(stage: "heartbeat")
        reporter.send(stage: "heartbeat")
        reporter.send(stage: "mountingDDI", fraction: 0.75)
        reporter.send(stage: "verifyingDDI")
        let heartbeatOne = try await reporterProbe.nextEvent()
        let heartbeatTwo = try await reporterProbe.nextEvent()
        let advancedFraction = try await reporterProbe.nextEvent()
        let advancedStage = try await reporterProbe.nextEvent()
        try require(heartbeatOne.stage == "heartbeat" && heartbeatTwo.stage == "heartbeat",
                    "Duplicate progress was sent, or consecutive heartbeats were suppressed.")
        try require(advancedFraction.stage == "mountingDDI" && advancedFraction.fraction == 0.75
                        && advancedStage.stage == "verifyingDDI",
                    "A genuine fraction or stage change was suppressed.")
        reporter.stop()
        print("PASS: loopback authentication, fragmented/coalesced frames, stop delivery guard, reporter sanitizing and progress/heartbeat distinction")
        print("Scope: macOS progress IPC only; iOS extension cancellation, signing, DDI and JIT are not exercised.")
    }

    @MainActor
    static func main() async {
        // This independent watchdog also covers a bug that wedges MainActor or
        // prevents a Network completion from resuming its checked continuation.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
            fputs("FAIL: progress IPC integration check exceeded 10 seconds.\n", stderr)
            exit(1)
        }
        do { try await run() }
        catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
