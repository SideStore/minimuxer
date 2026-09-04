//
//  HeartbeatService.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
internal import MinimuxerCommon
internal import DeviceGatewayAPI

final internal class HeartbeatService {
    let gateway: any DeviceGatewayAPI
    let proxyServer: UsbmuxdProxyServer
    let endpoint: DeviceEndpoint
    let connectionManager: DeviceConnectionManager

    init(
        gateway: any DeviceGatewayAPI,
        proxyServer: UsbmuxdProxyServer,
        endpoint: DeviceEndpoint,
        connectionManager: DeviceConnectionManager
    ) {
        self.gateway = gateway
        self.proxyServer = proxyServer
        self.endpoint = endpoint
        self.connectionManager = connectionManager
    }
    
    private actor MutableState {
        var running = false
        var taskActive = false

        func tryStart() -> Bool {
            if taskActive {
                running = true
                return false
            }
            running = true
            taskActive = true
            return true
        }

        func stop() {
            running = false
        }

        func terminate() {
            taskActive = false
            running = false
        }
    }

    private let state = MutableState()
    private var lastErrorDescription: String?

    var lastBeatSuccessful = false

    /// Start the heartbeat loop. Safe to call multiple times — ignored if a task is already active.
    func start() async {
        guard await state.tryStart() else {
            return
        }

        verboseLog("[minimuxer] Starting heartbeat task...")
        Task.detached { [weak self] in
            guard let self = self else { return }
            verboseLog("[minimuxer] heartbeat-task: started")

            await self.heartbeatLoop()

            await self.state.terminate()
            self.lastBeatSuccessful = false
            verboseLog("[minimuxer] heartbeat-task: stopped")
        }
    }

    /// Signal the heartbeat task to stop. The task will exit on next iteration.
    func stop() async {
        await state.stop()
        lastBeatSuccessful = false
        verboseLog("[minimuxer] HeartbeatService stop requested")
    }

    private func logIfNeeded(_ message: String, isVerbose: Bool = false) {
        if message != lastErrorDescription {
            if isVerbose {
                verboseLog("[minimuxer] heartbeat-task: \(message)")
            } else {
                debugLog("[minimuxer] heartbeat-task: \(message)")
            }
            lastErrorDescription = message
        }
    }

    private func heartbeatLoop() async {
        while !self.proxyServer.isListening {
            logIfNeeded("Waiting for usbmuxd to be ready...", isVerbose: true)
            try? await Task.sleep(nanoseconds: MinimuxerConstants.heartbeatSleepNs)
        }
        verboseLog("[minimuxer] heartbeat-task: usbmuxd is ready")

        var currentInterval: UInt64 = 1000

        while await state.running {
            let tunnelPeerIp: String
            do {
                tunnelPeerIp = try await self.endpoint.ip()
            } catch {
                logIfNeeded("device IP unavailable", isVerbose: true)
                lastBeatSuccessful = false
                try? await Task.sleep(nanoseconds: MinimuxerConstants.heartbeatSleepNs)
                continue
            }
            
            // verify tunnel/device reachability first
            if !(await connectionManager.testDeviceConnection(ifaddr: tunnelPeerIp)) {
                logIfNeeded("device IP not reachable, waiting...", isVerbose: true)
                lastBeatSuccessful = false
                try? await Task.sleep(nanoseconds: MinimuxerConstants.heartbeatSleepNs)
                continue
            }

            do {
                currentInterval = try await self.gateway.performHeartbeat(interval: currentInterval)
                lastBeatSuccessful = true
                lastErrorDescription = nil
            } catch {
                logIfNeeded("Heartbeat failed: \(error)")
                lastBeatSuccessful = false
                try? await Task.sleep(nanoseconds: MinimuxerConstants.heartbeatSleepNs)
            }
        }
    }
}
