// SPDX-License-Identifier: GPL-2.0-or-later
// Modified 2026-10-14: authenticated phase progress to the main App.
import Foundation
import StikJIT

/// The debugger half of Built-in StikJIT (docs/06-built-in-jit.md).
///
/// A process cannot synchronously debug itself, so Husk starts this extension,
/// sends it its PID, the pairing file and husk-jit.js, and StikJIT attaches over
/// LocalDevVPN and services the script's trap requests until Husk detaches.
private enum HuskJITWork {
    /// One request at a time: enabling JIT holds this queue while the debugger is attached.
    static let queue = DispatchQueue(label: "com.husk.app.jit-helper")

    static func handle(_ request: HuskJITRequest) -> HuskJITRequest.Response {
        let reporter: HuskJITProgressReporter?
        if let port = request.progressPort, let token = request.progressToken, port != 0,
           (32...128).contains(token.utf8.count) {
            reporter = HuskJITProgressReporter(port: port, token: token)
        } else {
            reporter = nil
        }
        defer { reporter?.stop() }
        reporter?.send(stage: "helperStarted")
        func report(_ stage: StikJIT.PreparationStage) {
            switch stage {
            case .checkingReachability: reporter?.send(stage: "checkingReachability")
            case .checkingDDI: reporter?.send(stage: "checkingDDI")
            case .downloadingDDI(let fraction, _):
                reporter?.send(stage: "downloadingDDI", fraction: fraction)
            case .mountingDDI(let fraction): reporter?.send(stage: "mountingDDI", fraction: fraction)
            case .verifyingDDI: reporter?.send(stage: "verifyingDDI")
            case .ready: reporter?.send(stage: request.operation == .enable ? "attaching" : "ready")
            @unknown default: break
            }
        }
        let manager = FileManager.default
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            if request.operation == .resetDDI {
                reporter?.send(stage: "resettingDDI")
                try StikJIT.resetCachedDDI(at: paths)
                return .init(success: true, message: "Developer Disk Image cache reset.",
                             txmPresent: StikJIT.isTXMPresent)
            }

            guard let pairingData = request.pairingData, !pairingData.isEmpty else {
                throw NSError(domain: "HuskJITHelper", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The pairing file was not provided."])
            }
            let pairingURL = root.appendingPathComponent("pairingFile-\(UUID().uuidString).plist")
            try pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }

            switch request.operation {
            case .prepare:
                let readiness = StikJIT.prepareDevice(
                    pairingFile: pairingURL, paths: paths,
                    progress: report)
                switch readiness {
                case .ready(let security):
                    return .init(success: true,
                                 message: "LocalDevVPN is reachable and the Developer Disk Image is ready.",
                                 txmPresent: security.isTXMPresent)
                case .unreachable(let reason), .preparationFailed(let reason):
                    return .init(success: false, message: reason, txmPresent: StikJIT.isTXMPresent)
                @unknown default:
                    return .init(success: false, message: "StikJIT returned an unknown preparation state.",
                                 txmPresent: StikJIT.isTXMPresent)
                }
            case .enable:
                guard let targetPID = request.targetPID,
                      let scriptBase64 = request.scriptBase64, !scriptBase64.isEmpty else {
                    throw NSError(domain: "HuskJITHelper", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "The target process or Husk's JIT script was not provided."])
                }
                try StikJIT.enableJIT(
                    targetPID: targetPID,
                    pairingFile: pairingURL,
                    ddiPaths: paths,
                    script: .customBase64(scriptBase64),
                    forceScript: true,
                    preparationProgress: report,
                    progress: { _ in reporter?.send(stage: "scriptRunning") })
                reporter?.send(stage: "detached")
                return .init(success: true, message: "Husk detached cleanly from its built-in JIT helper.",
                             txmPresent: StikJIT.isTXMPresent)
            case .resetDDI:
                preconditionFailure("Handled above")
            }
        } catch {
            return .init(success: false, message: error.localizedDescription,
                         txmPresent: StikJIT.isTXMPresent)
        }
    }
}

/// NSExtensionPrincipalClass (Info.plist). The request arrives as JSON in the
/// first input item; the response goes back as JSON in the item the request
/// completes with. Enable completes only once Husk's script has detached, so
/// the request, and this process, last as long as the debugger does.
@objc(HuskJITHelperHandler)
final class HuskJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo
        let data = info?[HuskJITRequest.itemKey] as? Data
        HuskJITWork.queue.async {
            let response: HuskJITRequest.Response
            if let data, let request = try? JSONDecoder().decode(HuskJITRequest.self, from: data) {
                response = HuskJITWork.handle(request)
            } else {
                response = .init(success: false, message: "Husk's JIT helper received no request.",
                                 txmPresent: nil)
            }
            let item = NSExtensionItem()
            item.userInfo = [HuskJITRequest.Response.itemKey: (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}

