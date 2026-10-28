// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Foundation
import Network

enum SMBDiagnostics {
    private final class Probe: @unchecked Sendable {
        let connection: NWConnection
        let continuation: CheckedContinuation<String, Never>
        private var finished = false
        init(_ connection: NWConnection, _ continuation: CheckedContinuation<String, Never>) {
            self.connection = connection
            self.continuation = continuation
        }
        // All callers execute on the probe's serial queue.
        func finish(_ result: String) {
            guard !finished else { return }
            finished = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.resume(returning: result)
        }
    }
    // Probe only the endpoint explicitly saved by the user. No credentials or
    // directory contents are included in the diagnostic report.
    static func transport(server: SMBServer) async -> String {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "org.iinamobile.connection-diagnostic")
            let connection = NWConnection(host: NWEndpoint.Host(server.host),
                                          port: NWEndpoint.Port(rawValue: UInt16(server.port ?? 445))!, using: .tcp)
            let probe = Probe(connection, continuation)
            connection.stateUpdateHandler = { state in
                let path = connection.currentPath
                let interfaces = path?.availableInterfaces.map { $0.type == .wifi ? "Wi-Fi" : String(describing: $0.type) }.joined(separator: ",") ?? "none"
                let context = "interfaces=\(interfaces), localNetworkDenied=\(path?.unsatisfiedReason == .localNetworkDenied)"
                switch state {
                case .ready: probe.finish("TCP ready; \(context)")
                case .waiting(let error): probe.finish("TCP waiting: \(error); \(context)")
                case .failed(let error): probe.finish("TCP failed: \(error); \(context)")
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) { probe.finish("TCP timed out") }
        }
    }
}
#endif
