//
//  HeartbeatService.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
internal import MinimuxerCommon
internal import DeviceGateway
import Logging

final internal class HeartbeatService {
    let deviceProvider: DeviceProvider
    var gateway: any DeviceGateway {
        deviceProvider.gateway
    }
    let proxyServer: UsbmuxdProxyServer
    let endpoint: DeviceEndpoint
    let logger = Logger(label: "minimuxer.heartbeat")

    private let sleepNs: UInt64 = MinimuxerConstants.heartbeatInterval * 1_000_000

    init(deviceProvider: DeviceProvider, proxyServer: UsbmuxdProxyServer, endpoint: DeviceEndpoint) {
        self.deviceProvider = deviceProvider
        self.proxyServer = proxyServer
        self.endpoint = endpoint
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

    // Start the heartbeat loop. ignored if a task is already active.
    func start() async {
        guard await state.tryStart() else {
            return
        }

        logger.trace("[minimuxer] Starting heartbeat task...")
        Task.detached { [weak self] in
            guard let self = self else { return }
            logger.trace("[minimuxer] heartbeat-task: started")

            await self.heartbeatLoop()

            await self.state.terminate()
            self.lastBeatSuccessful = false
            logger.trace("[minimuxer] heartbeat-task: stopped")
        }
    }

    // Signal the heartbeat task to stop. will exit on next iteration.
    func stop() async {
        await state.stop()
        lastBeatSuccessful = false
        logger.trace("[minimuxer] HeartbeatService stop requested")
    }

    private func heartbeatLoop() async {
        if self.gateway.requiresUsbmuxd {
            while !self.proxyServer.isListening {
                logger.trace("Waiting for usbmuxd to be ready...")
                try? await Task.sleep(nanoseconds: sleepNs)
            }
            logger.trace("[minimuxer] heartbeat-task: usbmuxd is ready")
        }

        var currentInterval: UInt64 = MinimuxerConstants.heartbeatInterval

        while await state.running {
            let tunnelPeerIp: String
            do {
                tunnelPeerIp = try await self.endpoint.ip()
            } catch {
                logger.trace("device IP unavailable")
                lastBeatSuccessful = false
                try? await Task.sleep(nanoseconds: sleepNs)
                continue
            }
            
            // verify tunnel/device reachability first
            let targetPort = self.gateway.servicePort
            if !NetworkUtils.testTCP(ip: tunnelPeerIp, port: targetPort) {
                logger.trace("device IP not reachable, waiting...")
                lastBeatSuccessful = false
                try? await Task.sleep(nanoseconds: sleepNs)
                continue
            }

            do {
                currentInterval = try await self.gateway.performHeartbeat(interval: currentInterval)
                lastBeatSuccessful = true
                lastErrorDescription = nil
            } catch {
                logger.debug("Heartbeat failed: \(error)")
                lastBeatSuccessful = false
                try? await Task.sleep(nanoseconds: sleepNs)
            }
        }
    }
}
