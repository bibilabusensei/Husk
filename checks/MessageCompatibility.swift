// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

private enum CompatibilityFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case .assertion(let message): return message }
    }
}

@main
private struct MessageCompatibility {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CompatibilityFailure.assertion(message) }
    }

    static func main() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        // Literal fixtures use the original protocol. Optional keys are absent,
        // not merely present with JSON null, to exercise installed old helpers.
        let original: [(String, HuskJITRequest.Operation)] = [
            (#"{"operation":"prepare","pairingData":"AP+AAX8="}"#, .prepare),
            (#"{"operation":"enable","targetPID":123,"pairingData":"AP+AAX8=","scriptBase64":"cmV0"}"#, .enable),
            (#"{"operation":"resetDDI"}"#, .resetDDI),
        ]
        let binary = Data([0, 255, 128, 1, 127])
        for (fixture, operation) in original {
            let request = try decoder.decode(HuskJITRequest.self, from: Data(fixture.utf8))
            try require(request.operation == operation, "An old operation changed during decoding.")
            try require(request.progressPort == nil && request.progressToken == nil,
                        "An old request unexpectedly enabled the progress channel.")
            if operation != .resetDDI {
                try require(request.pairingData == binary, "Old pairing bytes were altered.")
            }
        }

        var current = [
            HuskJITRequest.prepare(pairingData: binary),
            HuskJITRequest.enable(targetPID: 321, pairingData: binary, scriptBase64: "cmV0"),
            HuskJITRequest.resetDDI,
        ]
        for index in current.indices {
            current[index].progressPort = 49_152
            current[index].progressToken = "synthetic-progress-token-for-protocol-check"
            let decoded = try decoder.decode(HuskJITRequest.self, from: encoder.encode(current[index]))
            try require(decoded.operation == current[index].operation, "A new operation changed during round trip.")
            try require(decoded.targetPID == current[index].targetPID, "The target PID changed during round trip.")
            try require(decoded.pairingData == current[index].pairingData, "Binary pairing bytes changed during round trip.")
            try require(decoded.scriptBase64 == current[index].scriptBase64, "The script changed during round trip.")
            try require(decoded.progressPort == 49_152, "The progress port was lost.")
            try require(decoded.progressToken == current[index].progressToken, "The progress token was lost.")
        }

        for port in [-1, 65_536] {
            let invalid = Data("{\"operation\":\"resetDDI\",\"progressPort\":\(port)}".utf8)
            var rejected = false
            do { _ = try decoder.decode(HuskJITRequest.self, from: invalid) }
            catch { rejected = true }
            try require(rejected, "An out-of-range TCP port was accepted.")
        }

        let response = HuskJITRequest.Response(success: false, message: "Synthetic DDI mount error", txmPresent: nil)
        let reply = try decoder.decode(HuskJITRequest.Response.self, from: encoder.encode(response))
        try require(!reply.success && reply.message == response.message && reply.txmPresent == nil,
                    "A helper error response lost its meaning.")
        print("PASS: old request JSON, new progress fields, binary pairing bytes, port bounds and response compatibility")
    }
}
