//
//  EMProxyImpl.swift
//  Minimuxer
//
//  Created by Magesh K on 12/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import EMProxy
import Network
internal import MinimuxerCommon
import Logging


public enum EMProxyError: Error, LocalizedError, CustomStringConvertible, Equatable, Sendable {
    case invalidBindAddressPointer
    case invalidUTF8String
    case invalidSocketAddress(String)
    case socketBindFailed
    case cryptoInitFailed
    case serverNotRunning
    case stopSignalFailed
    case threadJoinFailed
    case handshakeClientNotConfigured
    case unknownError(Int32)

    public var description: String {
        switch self {
        case .invalidBindAddressPointer:
            return "Invalid bind address pointer"
        case .invalidUTF8String:
            return "Failed to convert bind address to UTF-8"
        case .invalidSocketAddress(let addr):
            return "Invalid IPv4 socket address format: \(addr)"
        case .socketBindFailed:
            return "Failed to bind to UDP socket address"
        case .cryptoInitFailed:
            return "Failed to initialize EMProxy crypto keys"
        case .serverNotRunning:
            return "EMProxy server is not running"
        case .stopSignalFailed:
            return "Failed to send stop signal to EMProxy server"
        case .threadJoinFailed:
            return "Failed to join EMProxy loopback thread"
        case .handshakeClientNotConfigured:
            return "EMProxy WireGuard VPN handshake client not configured"
        case .unknownError(let code):
            return "EMProxy error code: \(code)"
        }
    }

    public var errorDescription: String? {
        return description
    }
}

public final class EMProxyImpl: @unchecked Sendable, EMProxyAPI {
    private struct HandshakeConfig: Sendable {
        let host: String
        let port: UInt16
        let enabled: Bool
    }
    private var handshakeConfig: HandshakeConfig?
    private let handshakeLock = NSLock()

    public func setHandshakeClient(host: String, port: UInt16, enabled: Bool) {
        handshakeLock.withLock {
            self.handshakeConfig = HandshakeConfig(host: host, port: port, enabled: enabled)
        }
    }

    public init() {
        set_log_callback { level, msgPtr in
            guard let msgPtr = msgPtr else { return false }
            let msg = "[EMProxy] \(String(cString: msgPtr))"
            if level <= 1 {
                MinimuxerCommonLogging.logger.trace(Logger.Message(stringLiteral: msg))
            } else {
                MinimuxerCommonLogging.logger.debug(Logger.Message(stringLiteral: msg))
            }
            return true
        }
    }



    public func start(host: String, port: UInt16) async throws {
        let config = handshakeLock.withLock { self.handshakeConfig }
        guard let config = config else {
            throw EMProxyError.handshakeClientNotConfigured
        }
        let address = "\(host):\(port)"
        try await matchingPriority {
            try await withFFIDispatch {
                switch start_emotional_damage(address) {
                    case 0:
                        break
                    case -1:
                        throw EMProxyError.invalidBindAddressPointer
                    case -2:
                        throw EMProxyError.invalidUTF8String
                    case -3:
                        throw EMProxyError.invalidSocketAddress(address)
                    case -4:
                        throw EMProxyError.socketBindFailed
                    case -5:
                        throw EMProxyError.cryptoInitFailed
                    case let err:
                        throw EMProxyError.unknownError(err)
                }
            }
        }
        if config.enabled && !config.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await triggerVPNHandshake(host: config.host, port: config.port)
        } else {
            await probeVPNHandshake(port: config.port != 0 ? config.port : MinimuxerConstants.lockdowndPort)
        }
    }

    public func stop() async throws {
        try await matchingPriority {
            try await withFFIDispatch {
                switch stop_emotional_damage() {
                    case 0:
                        return
                    case -1:
                        throw EMProxyError.serverNotRunning
                    case -2:
                        throw EMProxyError.stopSignalFailed
                    case -3:
                        throw EMProxyError.threadJoinFailed
                    case let err:
                        throw EMProxyError.unknownError(err)
                }
            }
        }
    }



    private func triggerVPNHandshake(host: String, port: UInt16) async {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            MinimuxerCommonLogging.logger.debug("[EMProxy] triggerVPNHandshake skipped: host is empty")
            return
        }
        let timeout = Double(MinimuxerConstants.vpnHandshakeTimeoutNs) / 1_000_000_000.0
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            let success = await probeHost(host, port: port)
            if success {
                return // Tunnel is ready!
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func probeVPNHandshake(port: UInt16) async {
        let candidates = discoverUtunCandidateDestinations()
        guard !candidates.isEmpty else {
            MinimuxerCommonLogging.logger.debug("[EMProxy] probeVPNHandshake skipped: no utun interface candidates found")
            return
        }

        MinimuxerCommonLogging.logger.debug("[EMProxy] probeVPNHandshake starting for candidates: \(candidates), port: \(port)")
        let timeout = Double(MinimuxerConstants.vpnHandshakeTimeoutNs) / 1_000_000_000.0
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            let success = await withTaskGroup(of: Bool.self) { group in
                for host in candidates {
                    group.addTask {
                        await self.probeHost(host, port: port)
                    }
                }

                for await result in group {
                    if result {
                        group.cancelAll()
                        return true
                    }
                }
                return false
            }

            if success {
                MinimuxerCommonLogging.logger.debug("[EMProxy] probeVPNHandshake succeeded!")
                return
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        MinimuxerCommonLogging.logger.debug("[EMProxy] probeVPNHandshake timed out after \(timeout)s")
    }

    private func probeHost(_ host: String, port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)

        let states = AsyncStream<NWConnection.State> { continuation in
            connection.stateUpdateHandler = { state in
                continuation.yield(state)
            }
            continuation.onTermination = { @Sendable _ in
                connection.cancel()
            }
            connection.start(queue: .global())
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await state in states {
                    MinimuxerCommonLogging.logger.debug("[EMProxy] probeHost(\(host):\(port)) state: \(state)")
                    if let result = self.isProbeSuccessful(for: state) {
                        connection.cancel()
                        return result
                    }
                }
                return false
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                connection.cancel()
                return false
            }

            let firstResult = await group.next() ?? false
            group.cancelAll()
            return firstResult
        }
    }

    private func discoverUtunCandidateDestinations() -> [String] {
        let interfaces = NetworkIfaceScanner.scan(quiet: true)
        return DeviceConnectionManager.resolveCandidatePeers(from: interfaces).map(\.ip)
    }

    private func isProbeSuccessful(for state: NWConnection.State) -> Bool? {
        switch state {
            case .ready:
                return true
            case .failed, .cancelled:
                return false
            case .waiting(let error):
                // POSIX error 61 is "Connection refused".
                // This means the tunnel is fully working and routed, but nothing is listening on that port yet.
                let isRefused = (error as NSError).code == 61
                if isRefused {
                    return true
                }
                return nil
            default:
                return nil
        }
    }
}
