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
    let deviceProvider: DeviceProvider
    var gateway: any DeviceGatewayAPI {
        deviceProvider.gateway
    }
    let proxyServer: UsbmuxdProxyServer
    let endpoint: DeviceEndpoint

    private let sleepNs: UInt64 = MinimuxerConstants.heartbeatInterval * 1_000_000_000

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

    // Single writer (heartbeat task); readers poll a bool.
    var lastBeatSuccessful = false

    private var heartbeatTask: Task<Void, Never>?


    // MARK: - Lifecycle

    /// Start the heartbeat loop. Ignored if a task is already active.
    func start() async {
        guard await state.tryStart() else {
            return
        }

        verboseLog("[minimuxer] Starting heartbeat task...")
        let task = Task.detached { [weak self] in
            guard let self = self else { return }
            verboseLog("[minimuxer] heartbeat-task: started")

            await self.heartbeatLoop()

            await self.state.terminate()
            self.lastBeatSuccessful = false
            verboseLog("[minimuxer] heartbeat-task: stopped")
        }
        self.heartbeatTask = task
    }

    /// Signal the heartbeat task to stop and wait for it to terminate cleanly.
    func stop() async {
        await state.stop()
        lastBeatSuccessful = false
        let task = heartbeatTask
        heartbeatTask = nil
        task?.cancel()
        _ = await task?.value
        await state.terminate()
        verboseLog("[minimuxer] HeartbeatService stop completed")
    }

    /// Restart the heartbeat loop and optionally wait until the first heartbeat succeeds.
    @discardableResult
    func restart(timeout: TimeInterval = 8.0) async -> Bool {
        verboseLog("[minimuxer] HeartbeatService restarting...")
        await stop()
        try? await Task.sleep(nanoseconds: 200_000_000)
        await start()
        return await waitUntilReady(timeout: timeout)
    }

    // MARK: - Readiness

    /// Wait until the first heartbeat succeeds, or timeout expires.
    /// Returns true if ready, false on timeout / cancellation.
    @discardableResult
    func waitUntilReady(timeout: TimeInterval = 10.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !lastBeatSuccessful {
            if Task.isCancelled { return false }
            if Date() >= deadline {
                verboseLog("[minimuxer] heartbeat waitUntilReady timed out after \(timeout)s")
                return false
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    // MARK: - Internals

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
        if self.gateway.requiresUsbmuxd {
            while !self.proxyServer.isListening {
                if Task.isCancelled { return }
                logIfNeeded("Waiting for usbmuxd to be ready...", isVerbose: true)
                try? await Task.sleep(nanoseconds: sleepNs)
            }
            verboseLog("[minimuxer] heartbeat-task: usbmuxd is ready")
        }

        var currentInterval: UInt64 = MinimuxerConstants.heartbeatInterval

        while await state.running && !Task.isCancelled {
            let tunnelPeerIp: String
            do {
                tunnelPeerIp = try await self.endpoint.ip()
            } catch {
                logIfNeeded("device IP unavailable", isVerbose: true)
                lastBeatSuccessful = false
                try? await Task.sleep(nanoseconds: sleepNs)
                continue
            }

            do {
                currentInterval = try await self.gateway.performHeartbeat(interval: currentInterval)
                lastBeatSuccessful = true
                lastErrorDescription = nil
            } catch {
                logIfNeeded("Heartbeat failed: \(error)")
                lastBeatSuccessful = false
                currentInterval = MinimuxerConstants.heartbeatInterval
            }

            // FIX: sleep between beats on BOTH success and failure paths.
            // Clamp to [5, 60] seconds and reply at ~75% of interval (min 4s) to ensure
            // Marco is answered before the 10-second device watchdog expires.
            let clampedInterval = min(max(currentInterval, 5), 60)
            let sleepSeconds = max(Double(clampedInterval) * 0.75, 4.0)
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
        }
    }
}
