//
//  HeartbeatService.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
import MinimuxerDomain

enum HeartbeatService {
    enum Event: Sendable {
        case ready
        case disconnected
    }

    static func run(
        sessionID: UInt64,
        eventSink: @escaping @Sendable (Event) async -> Void
    ) async {
        var lastMessage: String?

        func logIfNeeded(_ message: String, isVerbose: Bool = false) {
            guard message != lastMessage else { return }
            let prefix = "[minimuxer] heartbeat-task: \(message) " +
                "session=\(sessionID)"
            if isVerbose {
                verboseLog(prefix)
            } else {
                debugLog(prefix)
            }
            lastMessage = message
        }

        while !Task.isCancelled && !MuxerService.isListening {
            logIfNeeded("waitingForUsbmuxd", isVerbose: true)
            guard await sleepBeforeReconnect() else { return }
        }
        guard !Task.isCancelled else { return }

        var wasReady = false
        while !Task.isCancelled {
            guard MuxerService.isListening else {
                logIfNeeded("waitingForUsbmuxd", isVerbose: true)
                if wasReady {
                    wasReady = false
                    await eventSink(.disconnected)
                }
                guard await sleepBeforeReconnect() else { return }
                continue
            }

            let client: OpaquePointer
            do {
                client = try IdeviceGateway.shared.connectLockdownHeartbeat()
                lastMessage = nil
                verboseLog(
                    "[minimuxer] heartbeat-task: connected " +
                    "session=\(sessionID)"
                )
            } catch {
                logIfNeeded(
                    "connectFailed error=\(error.localizedDescription)"
                )
                guard await sleepBeforeReconnect() else { return }
                continue
            }

            var receiveTimeout = HeartbeatTiming.initialReceiveTimeoutSeconds
            do {
                while !Task.isCancelled {
                    let requestedInterval = try IdeviceGateway.shared
                        .exchangeHeartbeat(
                            client: client,
                            interval: receiveTimeout
                        )
                    receiveTimeout = HeartbeatTiming.receiveTimeoutSeconds(
                        forRequestedInterval: requestedInterval
                    )
                    if !wasReady {
                        wasReady = true
                        lastMessage = nil
                        debugLog(
                            "[minimuxer] heartbeat-task: " +
                            "marcoReceived poloSent ready " +
                            "session=\(sessionID) " +
                            "nextInterval=\(requestedInterval) " +
                            "receiveTimeout=\(receiveTimeout)"
                        )
                        await eventSink(.ready)
                    }
                }
            } catch {
                logIfNeeded(
                    "serviceDisconnected error=\(error.localizedDescription)"
                )
                if wasReady {
                    wasReady = false
                    await eventSink(.disconnected)
                }
            }

            IdeviceGateway.shared.disconnectHeartbeat(client)
            guard !Task.isCancelled else { return }
            guard await sleepBeforeReconnect() else { return }
        }
    }

    private static func sleepBeforeReconnect() async -> Bool {
        do {
            try await Task.sleep(
                nanoseconds: MinimuxerConstants.heartbeatSleepNs
            )
            return true
        } catch {
            return false
        }
    }
}
