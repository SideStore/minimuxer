//
//  MinimuxerImpl.swift
//  Minimuxer
//
//  Created by Magesh K on 4/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import Combine
import ZIPFoundation
internal import DeviceGatewayAPI
internal import MinimuxerCommon

private enum MinimuxerStatus {
    case started, inprogress, stopped
}

/// Heartbeat startup timeout in seconds.
/// iOS 16 needs 2-4s for Lockdown to stabilize; 10s is safe.
private let kHeartbeatInitialTimeoutSeconds: TimeInterval = 10.0
/// Endpoint resolution timeout in seconds.
private let kEndpointReadyTimeoutSeconds: TimeInterval = 8.0
private let kEndpointReadyPollIntervalNs: UInt64 = 500_000_000  // 500ms

final internal class MinimuxerImpl: MinimuxerAPI {
    public let statusSubject = PassthroughSubject<Result<Bool, MinimuxerError>, Never>()
    public var statusPublisher: AnyPublisher<Result<Bool, MinimuxerError>, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    let deviceProvider: DeviceProvider
    var gateway: any DeviceGatewayAPI {
        deviceProvider.gateway
    }
    let network: NetworkObserverService
    let emproxy: any EMProxyAPI
    let wirelessPair: any WirelessPairAPI
    let mounter: Mounter
    let proxyServer: UsbmuxdProxyServer
    let endpoint: DeviceEndpoint
    let connectionManager: DeviceConnectionManager
    let heartbeat: HeartbeatService

    var activeProtocol: PairingProtocol {
        gateway.pairingFileType
    }

    init(
        deviceProvider: DeviceProvider,
        network: NetworkObserverService,
        emproxy: any EMProxyAPI,
        wirelessPair: any WirelessPairAPI,
        mounter: Mounter,
        proxyServer: UsbmuxdProxyServer,
        endpoint: DeviceEndpoint,
        connectionManager: DeviceConnectionManager,
        heartbeat: HeartbeatService
    ) {
        self.deviceProvider = deviceProvider
        self.network = network
        self.emproxy = emproxy
        self.wirelessPair = wirelessPair
        self.mounter = mounter
        self.proxyServer = proxyServer
        self.endpoint = endpoint
        self.connectionManager = connectionManager
        self.heartbeat = heartbeat

        self.network.onNetworkChanged = { [weak self] in
            guard let self = self else { return }
            let readyResult = await self.isReady()
            debugLog("[minimuxer] [net] publishing status update to subscribers")
            self.statusSubject.send(readyResult)
        }
    }

    private actor State {
        var status: MinimuxerStatus = .stopped
        var mountTask: Task<Bool, Error>? = nil
        var lastDocsPath: String? = nil
        var preferredProtocol: PairingProtocol? = nil

        func with<T>(_ body: (isolated State) throws -> T) rethrows -> T {
            try body(self)
        }
    }
    private let state = State()

    var pairingFileType: PairingProtocol { self.gateway.pairingFileType }

    var isLoggingEnabled: Bool { MinimuxerLogging.isLoggingEnabled }

    var isPairingFileLoaded: Bool {
        return pairingFileType != .unknown
    }

    func describeError(_ error: MinimuxerError) -> String {
        return error.description
    }

    func getConnectionMode() async -> DeviceConnectionMode {
        await self.connectionManager.getPreferredConnectionMode()
    }

    // Actual force refresh happens in start() after gateway init.
    func bindConnectionConfig(_ binding: ConnectionConfigBinding) async {
        await self.connectionManager.bindConnectionConfig(binding)
        await self.network.refreshEndpoint(force: false)
    }

    // MARK: - isReady

    func isReady(withNetworkCheck: Bool, withDDIMountCheck: Bool) async -> Result<Bool, MinimuxerError> {
        if !isPairingFileLoaded {
            debugLog("[minimuxer] minimuxer not ready: pairing file not loaded")
            return .failure(.pairingNotLoaded("No valid pairing file has been loaded"))
        }

        let currentStatus = await state.with { $0.status }
        if currentStatus != .started {
            debugLog("[minimuxer] minimuxer not ready: minimuxer has not been started")
            return .failure(.notStarted("Minimuxer has not been started"))
        }

        if !self.heartbeat.lastBeatSuccessful {
            debugLog("[minimuxer] minimuxer not ready: heartbeat has not succeeded yet")
            return .failure(.noDevice(
                "Heartbeat has not succeeded yet  Lockdown session is not stable"
            ))
        }

        let endpointReady = await self.endpoint.isInitialized
        if !endpointReady {
            debugLog("[minimuxer] minimuxer not ready: device endpoint not initialized")
            return .failure(.noDevice(
                "Device endpoint (tunnel peer IP) has not been resolved yet"
            ))
        }

        // check connection status first
        if withNetworkCheck && !(
            self.network.isWifiSatisfied
        ) {
            debugLog("[minimuxer] minimuxer not ready: no network connection")
            return .failure(.noConnection("No wifi interface satisfied"))
        }

        // check connection mode
        let connectionMode = await getConnectionMode()
        let net = self.network

        switch connectionMode {
            case .notConfigured:
                return .failure(connectionNotConfiguredError())

            case .localVPN:
                let uTunPresent = net.isUTunAvailable
                if !uTunPresent {
                    debugLog("[minimuxer] minimuxer not ready: no utun interface found")
                    return .failure(.noVPN("No utun interface detected  LocalDevVPN is not connected"))
                }

                if self.gateway.pairingFileType != .rppairing && !net.isIKEv2IPSecAvailable {
                    if #available(iOS 26.4, *) {
                        debugLog("[minimuxer] minimuxer not ready: no ipsec interface (required for lockdown on iOS 26.4+)")
                        return .failure(.invalidVPN("utun is present but no ipsec/IKEv2 interface found  LocalDevVPN may not support the lockdown protocol on iOS 26.4+"))
                    }
                }

            case .remoteServer:
                break
        }

        // check if pairing file is loaded
        let pairingType = pairingFileType
        if pairingType == .unknown {
            debugLog("[minimuxer] minimuxer not ready: no valid pairing file loaded")
            return .failure(.pairingNotLoaded("No valid pairing file has been loaded in Minimuxer"))
        }

        // then check if device is ready
        let deviceIp: String
        do {
            deviceIp = try await self.endpoint.ip()
        } catch {
            switch connectionMode {
                case .localVPN:
                    debugLog("[minimuxer] minimuxer not ready: tunnel peer IP not available despite tunnel iface being present")
                    return .failure(.noDevice("VPN tunnel iface is up but tunnel peer IP is not yet reachable  VPN may not be routing device traffic correctly. Cause: \(error.localizedDescription)"))
                case .remoteServer:
                    debugLog("[minimuxer] minimuxer not ready: remote endpoint IP is not configured or reachable")
                    return .failure(.noDevice("Remote endpoint IP is not configured or reachable. Cause: \(error.localizedDescription)"))
                case .notConfigured:
                    return .failure(connectionNotConfiguredError())
            }
        }

        let peerReachable = testDeviceConnection(ifaddr: deviceIp)
        if !peerReachable {
            switch connectionMode {
                case .localVPN:
                    debugLog("[minimuxer] minimuxer not ready: failed to connect to tunnel peer IP")
                    return .failure(.invalidVPN("VPN tunnel iface is up and tunnel peer IP \(deviceIp) is known, but TCP port poll failed  device may be unreachable on this interface"))
                case .remoteServer:
                    debugLog("[minimuxer] minimuxer not ready: failed to connect to remote endpoint IP \(deviceIp)")
                    return .failure(.notReachable("Remote endpoint \(deviceIp) is configured, but TCP port poll failed  target device is unreachable"))
                case .notConfigured:
                    return .failure(connectionNotConfiguredError())
            }
        }

        let deviceUDID: String
        do {
            deviceUDID = try await fetchUDID()
        } catch {
            return .failure(error)
        }

        verboseLog(
            "minimuxer status (.\(activeProtocol)): " +
            "deviceUDID=\(deviceUDID) " +
            "started=\(self.proxyServer.isListening) "
        )

        if self.gateway.requiresUsbmuxd && !self.proxyServer.isListening {
            return .failure(.muxerNotListening("Usbmuxd fake server is not listening"))
        }

        if withDDIMountCheck {
            do {
                let isMounted = try await isDDIMounted()
                verboseLog("minimuxer status (.\(activeProtocol)): dmg=\(isMounted) started=\(self.proxyServer.isListening)")
                return .success(isMounted)
            } catch {
                return .failure(error)
            }
        }

        return .success(true)
    }

    private func runWithChecks<T: Sendable>(
        _ context: String,
        catchAll: @escaping (String) -> MinimuxerError,
        action: @escaping @Sendable () async throws -> T
    ) async throws(MinimuxerError) -> T {
        do {
            return try await matchingPriority {
                try await action()
            }
        } catch let err as DeviceGatewayError {
            throw err.asMinimuxerError(
                protocol: activeProtocol,
                heartbeatHasSucceeded: self.heartbeat.lastBeatSuccessful,
                catchAll: catchAll
            )
        } catch {
            throw (error as? MinimuxerError) ?? catchAll("\(error)")
        }
    }

    func setLogging(_ enabled: Bool) {
        MinimuxerLogging.setLogging(enabled)
        self.gateway.setLogging(enabled)
    }

    public var deviceProbeTimeout: Int {
        self.connectionManager.deviceProbeTimeout
    }

    func setDeviceProbeTimeout(_ timeoutMs: Int) {
        self.connectionManager.deviceProbeTimeout = timeoutMs
    }

    private func retargetUsbmuxdAddr() {
        verboseLog("[minimuxer] unsetenv(USBMUXD_SOCKET_ADDRESS)")
        unsetenv(MinimuxerConstants.usbmuxdEnvKey)
        verboseLog("[minimuxer] setenv(USBMUXD_SOCKET_ADDRESS, \(MinimuxerConstants.usbmuxdSocket))")
        setenv(MinimuxerConstants.usbmuxdEnvKey, MinimuxerConstants.usbmuxdSocket, 1)
        let value = String(cString: getenv(MinimuxerConstants.usbmuxdEnvKey))
        verboseLog("[minimuxer] getenv(USBMUXD_SOCKET_ADDRESS) = \(value)")
    }

    private func connectionNotConfiguredError() -> MinimuxerError {
        let modes: [DeviceConnectionMode] = [.localVPN, .remoteServer]
        debugLog("[minimuxer] minim gatewayuxer not ready: connection mode not configured. Supported modes: \(modes)")
        return MinimuxerError.connectionModeNotConfigured("Connection mode not configured. Supported modes: \(modes)")
    }

    private func restartMuxerServer() async throws(MinimuxerError) {
        guard self.gateway.requiresUsbmuxd else { return }
        guard let pairingDict = self.gateway.pairingDataDict else {
            debugLog("[minimuxer] ERROR: Pairing DICT missing...ignoring restart MuxerServer")
            throw MinimuxerError.pairingNotLoaded("Pairing dictionary is missing in gateway")
        }
        verboseLog("[minimuxer] loaded pairing file keys: \(pairingDict.keys)")

        guard let deviceUDID = pairingDict["UDID"] as? String else {
            debugLog("[minimuxer] ERROR: Pairing file missing UDID")
            throw MinimuxerError.invalidPairing(protocol: activeProtocol, reason: "Pairing file is missing UDID value")
        }

        await self.proxyServer.stop()
        do {
            try await self.proxyServer.start(udid: deviceUDID)
        } catch {
            throw (error as? MinimuxerError) ?? MinimuxerError.connect("\(error)")
        }
    }

    // MARK: - Lifecycle

    func start(pairingFile: String, mountPath: String, preferred: PairingProtocol?) async throws(MinimuxerError) {
        let connectionMode = await getConnectionMode()
        if DeviceConnectionMode.notConfigured == connectionMode {
            throw connectionNotConfiguredError()
        }
        await self.network.start()

        // actor serialization scope
        await state.with {
            $0.status = .inprogress
            $0.lastDocsPath = mountPath
            $0.preferredProtocol = preferred
        }

        // let idevice initialize its state
        try await runWithChecks("while starting gateway", catchAll: { .invalidPairing(protocol: self.activeProtocol, reason: $0) }) {
            try await self.gateway.start(pairingFileContent: pairingFile, preferred: preferred)
        }

        if self.gateway.requiresUsbmuxd {
            retargetUsbmuxdAddr()
            try await restartMuxerServer()
        }

        // gateway.pairingFileType and port are now valid here,
        await self.network.refreshEndpoint(force: true)

        try await awaitEndpointReady()

        await self.heartbeat.start()

        try await awaitFirstHeartbeat()

        // mark ready!
        await state.with {
            $0.status = .started
        }
    }

    func stop() async throws(MinimuxerError) {
        await self.heartbeat.stop()

        // actor serialization scope
        let oldTask = await state.with { state -> Task<Bool, Error>? in
            state.status = .inprogress
            let task = state.mountTask
            task?.cancel()
            state.mountTask = nil
            return task
        }
        _ = await oldTask?.result

        if self.gateway.requiresUsbmuxd {
            await self.proxyServer.stop()
        }
        try await runWithChecks("while stopping gateway", catchAll: MinimuxerError.close) {
            try await self.gateway.stop()
        }

        // mark ready!
        await state.with {
            $0.status = .stopped
        }
    }

    private func awaitEndpointReady(
        timeout: TimeInterval = kEndpointReadyTimeoutSeconds
    ) async throws(MinimuxerError) {
        let deadline = Date().addingTimeInterval(timeout)

        verboseLog("[minimuxer] Awaiting device endpoint (timeout: \(timeout)s)...")

        while Date() < deadline {
            if Task.isCancelled {
                throw MinimuxerError.close("start() was cancelled while awaiting endpoint")
            }

            if await self.endpoint.isInitialized {
                verboseLog("[minimuxer] Device endpoint ready")
                return
            }

            // Force refresh so tcpProbe re-runs (bypass manager cache)
            await self.network.refreshEndpoint(force: true)

            // Check again right after refresh
            if await self.endpoint.isInitialized {
                verboseLog("[minimuxer] Device endpoint ready (after force refresh)")
                return
            }

            try? await Task.sleep(nanoseconds: kEndpointReadyPollIntervalNs)
        }

        debugLog("[minimuxer] Device endpoint not initialized after \(timeout)s")
        throw MinimuxerError.noDevice(
            "Device endpoint (tunnel peer IP) was not resolved within \(timeout)s  " +
            "check LocalDevVPN is connected and routing device traffic."
        )
    }

    private func awaitFirstHeartbeat(
        timeout: TimeInterval = kHeartbeatInitialTimeoutSeconds
    ) async throws(MinimuxerError) {
        let deadline = Date().addingTimeInterval(timeout)
        let pollIntervalNs: UInt64 = 100_000_000

        verboseLog("[minimuxer] Awaiting first heartbeat (timeout: \(timeout)s)...")

        while Date() < deadline {
            if Task.isCancelled {
                throw MinimuxerError.close("start() was cancelled while awaiting heartbeat")
            }

            if self.heartbeat.lastBeatSuccessful {
                verboseLog("[minimuxer] First heartbeat succeeded")
                return
            }

            try? await Task.sleep(nanoseconds: pollIntervalNs)
        }

        debugLog("[minimuxer] First heartbeat timed out after \(timeout)s")
        throw MinimuxerError.noDevice(
            "Heartbeat did not succeed within \(timeout)s  device may be unreachable " +
            "or pairing file is invalid. Check LocalDevVPN and pairing file."
        )
    }

    private func restartWith(pairingFile: String, op: String) async throws(MinimuxerError) {
        let (mountPath, preferred) = await state.with { ($0.lastDocsPath, $0.preferredProtocol) }
        guard let mountPath else {
            let activeProtocol = self.gateway.pairingFileType
            throw MinimuxerError.mount(protocol: activeProtocol, reason: "start() should be invoked before requesting \(op). cause: lastDocsPath is nil")
        }
        // stop() halts heartbeat; start() restarts it.
        try await stop()
        try await start(pairingFile: pairingFile, mountPath: mountPath, preferred: preferred)
    }

    func restart() async throws(MinimuxerError) {
        verboseLog("[minimuxer] Restarting services...")
        let activeProtocol = self.gateway.pairingFileType
        guard let pairingData = self.gateway.pairingFileData,
              let pairingFile = String(data: pairingData, encoding: .utf8)
        else {
            debugLog("[minimuxer] restart: no existing pairing file  cannot restart")
            throw MinimuxerError.invalidPairing(protocol: activeProtocol, reason: "No existing pairing file found in gateway during restart")
        }
        try await restartWith(pairingFile: pairingFile, op: "restart")
        await self.network.refreshEndpoint(force: true)
    }

    func reinitializePairingData(pairingFile: String) async throws(MinimuxerError) {
        verboseLog("[minimuxer] Reinitializing with new pairing file...")
        try await restartWith(pairingFile: pairingFile, op: "reinitializePairingData")
    }

    func testDeviceConnection(ifaddr: String, timeout: Int) -> Bool {
        return NetworkUtils.testTCP(ip: ifaddr, port: self.gateway.servicePort, timeoutMs: timeout)
    }

    private func ensureDDIMounted() async throws(MinimuxerError) {
        // FIX: do not swallow errors. A failed query is not the same as "DDI not mounted";
        // trying to (re)upload the DDI over a broken connection only makes things worse.
        let isMounted: Bool
        do {
            isMounted = try await self.gateway.isDDIMounted()
        } catch {
            throw MinimuxerError.mount(protocol: self.gateway.pairingFileType, reason: "Failed to query DDI status: \(error)")
        }
        if isMounted {
            return
        }
        guard let mountPath = await state.lastDocsPath else {
            let activeProtocol = self.gateway.pairingFileType
            throw MinimuxerError.mount(protocol: activeProtocol, reason: "DDI mount path not set")
        }
        verboseLog("[minimuxer] DDI not mounted, mounting now before launching debug session...")
        try await self.mountDDI(docsPath: mountPath)
    }

    @discardableResult
    func mountDDI(docsPath: String) async throws(MinimuxerError) -> Bool {
        try await runWithChecks("while mounting DDI", catchAll: { .mount(protocol: self.activeProtocol, reason: $0) }) {
            let oldTask = await self.state.with { state -> Task<Bool, Error>? in
                state.lastDocsPath = docsPath
                let task = state.mountTask
                task?.cancel()
                state.mountTask = nil
                return task
            }
            _ = await oldTask?.result
            let mounter = self.mounter
            let task = Task.detached(priority: .medium) {
                try await mounter.mount(docsPath: docsPath)
            }
            await self.state.with {
                $0.mountTask = task
            }
            return try await task.value
        }
    }

    func isDDIMounted() async throws(MinimuxerError) -> Bool {
        try await runWithChecks("while checking DDI mount status", catchAll: { .mount(protocol: self.activeProtocol, reason: $0) }) {
            try await self.gateway.isDDIMounted()
        }
    }

    func fetchUDID() async throws(MinimuxerError) -> String {
        try await runWithChecks("while fetching device UDID", catchAll: MinimuxerError.fetchUDID) {
            try await self.gateway.fetchUDID()
        }
    }

    func sendIpaAfc(bundleId: String, ipaBytes: Data) async throws(MinimuxerError) {
        try await runWithChecks("while sending IPA via AFC", catchAll: MinimuxerError.rwAfc) {
            try await self.gateway.sendIpaAfc(bundleId: bundleId, ipaBytes: ipaBytes)
        }
    }

    func sendAppBundleAfc(bundleId: String, appURL: URL) async throws(MinimuxerError) {
        try await runWithChecks("while sending App Bundle via AFC", catchAll: MinimuxerError.rwAfc) {
            try await self.gateway.sendAppBundleAfc(bundleId: bundleId, appURL: appURL)
        }
    }

    func installIpa(bundleId: String) async throws(MinimuxerError) {
        try await runWithChecks("while installing IPA", catchAll: MinimuxerError.installApp) {
            try await self.gateway.installIpa(bundleId: bundleId)
        }
    }

    func installAppBundle(bundleId: String, appName: String) async throws(MinimuxerError) {
        try await runWithChecks("while installing App Bundle", catchAll: MinimuxerError.installApp) {
            try await self.gateway.installAppBundle(bundleId: bundleId, appName: appName)
        }
    }

    func removeApp(bundleId: String) async throws(MinimuxerError) {
        try await runWithChecks("while removing App", catchAll: MinimuxerError.uninstallApp) {
            try await self.gateway.removeApp(bundleId: bundleId)
        }
    }

    func wipeContainer(identifier: String) async throws(MinimuxerError) {
        try await runWithChecks("while wiping container", catchAll: MinimuxerError.uninstallApp) {
            try await self.gateway.wipeContainer(identifier: identifier)
        }
    }

        func debugApp(appId: String) async throws(MinimuxerError) {
        try await runWithChecks("while debugging App", catchAll: MinimuxerError.createDebug) {
            try await self.ensureDDIMounted()

            // FIX: ensure usbmuxd proxy listening.
            // connectDebugProxy uses the usbmuxd C API, which requires the fake
            // usbmuxd proxy to be listening on 127.0.0.1:27015 — even in .lockdown mode
            // where requiresUsbmuxd is false.

            if !self.proxyServer.isListening {
                let udid: String
                if let cached = self.gateway.pairingDataDict?["UDID"] as? String {
                    udid = cached
                } else {
                    udid = try await self.fetchUDID()
                }
                try await self.proxyServer.start(udid: udid)
                var waited: UInt64 = 0
                while !self.proxyServer.isListening && waited < 3_000_000_000 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 100_000_000
                }
                verboseLog("[minimuxer] usbmuxd proxy started (listening=\(self.proxyServer.isListening))")
            }


            // FIX: wait for heartbeat to stabilize before hitting gateway.
            // On iOS 16, heartbeat.start() returns immediately (detached task),
            // so lastBeatSuccessful may still be false when JIT checks isReady().
            let hbReady = await self.heartbeat.waitUntilReady(timeout: 10.0)
            if !hbReady {
                debugLog("[minimuxer] debugApp: heartbeat wait timed out")
                throw MinimuxerError.noDevice("Heartbeat not ready before debugApp")
            }

            do {
                try await self.gateway.debugApp(appId: appId)
            } catch {
                verboseLog("[minimuxer] debugApp failed, restarting heartbeat session...")
                _ = await self.heartbeat.restart(timeout: 5.0)
                throw error
            }

            // FIX: After JIT enabling finishes, stop and restart heartbeat
            // to establish a clean lockdown session for sideloading and other SideStore services.
            verboseLog("[minimuxer] debugApp finished, restarting heartbeat for fresh lockdown session...")
            let restarted = await self.heartbeat.restart(timeout: 8.0)
            verboseLog("[minimuxer] post-debug heartbeat restart result: \(restarted)")
        }
    }

    func attachDebugger(pid: UInt32) async throws(MinimuxerError) {
        try await runWithChecks("while debugging process", catchAll: MinimuxerError.createDebug) {
            try await self.ensureDDIMounted()

            // FIX: ensure usbmuxd proxy listening.
            // connectDebugProxy uses the usbmuxd C API, which requires the fake
            // usbmuxd proxy to be listening on 127.0.0.1:27015 — even in .lockdown mode
            // where requiresUsbmuxd is false.

            if !self.proxyServer.isListening {
                let udid: String
                if let cached = self.gateway.pairingDataDict?["UDID"] as? String {
                    udid = cached
                } else {
                    udid = try await self.fetchUDID()
                }
                try await self.proxyServer.start(udid: udid)
                var waited: UInt64 = 0
                while !self.proxyServer.isListening && waited < 3_000_000_000 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 100_000_000
                }
                verboseLog("[minimuxer] usbmuxd proxy started (listening=\(self.proxyServer.isListening))")
            }

            
            // FIX: wait for heartbeat to stabilize before stopping it for debug.
            let hbReady = await self.heartbeat.waitUntilReady(timeout: 10.0)
            if !hbReady {
                debugLog("[minimuxer] attachDebugger: heartbeat wait timed out")
                throw MinimuxerError.noDevice("Heartbeat not ready before attachDebugger")
            }
            
            do {
                try await self.gateway.debugProcess(pid: pid)
            } catch {
                verboseLog("[minimuxer] attachDebugger failed, restarting heartbeat session...")
                _ = await self.heartbeat.restart(timeout: 5.0)
                throw error
            }

            verboseLog("[minimuxer] attachDebugger finished, restarting heartbeat for fresh lockdown session...")
            let restarted = await self.heartbeat.restart(timeout: 8.0)
            verboseLog("[minimuxer] post-debug heartbeat restart result: \(restarted)")
        }
    }

    func installProvisioningProfile(profile: Data) async throws(MinimuxerError) {
        try await runWithChecks("while installing profile", catchAll: MinimuxerError.profileInstall) {
            try await self.gateway.installProvisioningProfile(profile: profile)
        }
    }

    func removeProvisioningProfile(id: String) async throws(MinimuxerError) {
        try await runWithChecks("while removing profile", catchAll: MinimuxerError.profileRemove) {
            try await self.gateway.removeProvisioningProfile(id: id)
        }
    }

    func dumpProfiles(docsPath: String, mode: ProfileDumpMode = .zip) async throws(MinimuxerError) -> String {
        try await runWithChecks("while dumping profiles", catchAll: MinimuxerError.createMisagent) {
            switch mode {
                case .raw:
                    verboseLog("[minimuxer] dumpProfiles(mode: .raw) dumping to: \(docsPath)")
                    return try await self.gateway.dumpProfiles(docsPath: docsPath)
                case .zip:
                    verboseLog("[minimuxer] dumpProfiles(mode: .zip) staging to temporary directory")
                    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
                    defer {
                        verboseLog("[minimuxer] dumpProfiles(mode: .zip) cleaning up temporary directory: \(tempDir.path)")
                        try? FileManager.default.removeItem(at: tempDir)
                    }

                    let dumpedPath = try await self.gateway.dumpProfiles(docsPath: tempDir.path)
                    let zipURL = URL(fileURLWithPath: docsPath).appendingPathComponent("Profiles-\(ISO8601DateFormatter().string(from: Date())).zip")
                    verboseLog("[minimuxer] dumpProfiles(mode: .zip) compressing \(dumpedPath) -> \(zipURL.path)")
                    try FileManager.default.zipItem(at: URL(fileURLWithPath: dumpedPath), to: zipURL, shouldKeepParent: false)
                    verboseLog("[minimuxer] dumpProfiles(mode: .zip) successfully created archive: \(zipURL.path)")
                    return zipURL.path
            }
        }
    }

    func afcListDirectory(bundleId: String, path: String) async throws(MinimuxerError) -> [String] {
        try await runWithChecks("while listing AFC directory", catchAll: MinimuxerError.createAfc) {
            try await self.gateway.afcListDirectory(bundleId: bundleId, path: path)
        }
    }

    func afcReadFile(bundleId: String, path: String) async throws(MinimuxerError) -> Data {
        try await runWithChecks("while reading AFC file", catchAll: MinimuxerError.rwAfc) {
            try await self.gateway.afcReadFile(bundleId: bundleId, path: path)
        }
    }

    func afcGetFileInfo(bundleId: String, path: String) async throws(MinimuxerError) -> (isDirectory: Bool, fileSize: Int64) {
        try await runWithChecks("while getting AFC file info", catchAll: MinimuxerError.createAfc) {
            try await self.gateway.afcGetFileInfo(bundleId: bundleId, path: path)
        }
    }
}
