//
//  DebugProxyTLS.swift
//  TLS connection to debugserver using pairing-file client identity
//  Implements GDB Remote Serial Protocol framing
//

import Foundation
import Network
import Security

internal final class DebugProxyTLS {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "minimuxer.debug.tls")
    private var ready = false

    init(host: String, port: UInt16, identity: SecIdentity) throws {
        let tlsOpts = NWProtocolTLS.Options()
        guard let secId = sec_identity_create(identity) else {
            throw NSError(domain: "DebugProxyTLS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "sec_identity_create failed"])
        }
        sec_protocol_options_set_local_identity(tlsOpts.securityProtocolOptions, secId)
        // Disable cert verification (device cert not in system trust store)
        sec_protocol_options_set_verify_block(tlsOpts.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, queue)

        let params = NWParameters(tls: tlsOpts, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "DebugProxyTLS", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "invalid port"])
        }
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
    }

    func startAndWaitReady(timeout: TimeInterval = 5.0) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
            resumed.initialize(to: false)
            connection.stateUpdateHandler = { state in
                if resumed.pointee { return }
                switch state {
                case .ready:
                    resumed.pointee = true
                    cont.resume()
                case .failed(let err):
                    resumed.pointee = true
                    cont.resume(throwing: err)
                case .cancelled:
                    resumed.pointee = true
                    cont.resume(throwing: NSError(domain: "DebugProxyTLS", code: -3,
                                                  userInfo: [NSLocalizedDescriptionKey: "cancelled"]))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if !resumed.pointee {
                    resumed.pointee = true
                    cont.resume(throwing: NSError(domain: "DebugProxyTLS", code: -4,
                                                  userInfo: [NSLocalizedDescriptionKey: "TLS handshake timeout"]))
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err = err { cont.resume(throwing: err) }
                else { cont.resume() }
            })
        }
    }

    func recv(maxLength: Int = 65536, timeout: TimeInterval = 5.0) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let resumed = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
            resumed.initialize(to: false)
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, _, err in
                if resumed.pointee { return }
                resumed.pointee = true
                if let err = err { cont.resume(throwing: err) }
                else { cont.resume(returning: data ?? Data()) }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                if !resumed.pointee {
                    resumed.pointee = true
                    cont.resume(throwing: NSError(domain: "DebugProxyTLS", code: -5,
                                                  userInfo: [NSLocalizedDescriptionKey: "recv timeout"]))
                }
            }
        }
    }

    func close() {
        connection.cancel()
    }

    // MARK: - GDB Remote Serial Protocol

    /// Send a GDB RSP packet: `$<payload>#<checksum>` where checksum = sum(bytes) & 0xff
    /// Optionally read response packet.
    func sendGDBCommand(_ command: String, expectResponse: Bool = true) async throws -> String? {
        let checksum = command.utf8.reduce(0) { ($0 + UInt32($1)) & 0xff }
        let packet = "$\(command)#\(String(format: "%02x", checksum))"
        try await send(packet.data(using: .utf8)!)

        if !expectResponse { return nil }

        // Read up to a few chunks until we can parse $...#cs
        var buf = Data()
        for _ in 0..<10 {
            let chunk = try await recv()
            buf.append(chunk)
            if let parsed = Self.parseResponse(buf) { return parsed }
        }
        return nil
    }

    private static func parseResponse(_ data: Data) -> String? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        guard let dollar = s.firstIndex(of: "$") else { return nil }
        let afterDollar = s.index(after: dollar)
        guard let hash = s[afterDollar...].firstIndex(of: "#") else { return nil }
        let afterHash = s.index(hash, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
        return String(s[afterDollar..<hash])
    }
}
