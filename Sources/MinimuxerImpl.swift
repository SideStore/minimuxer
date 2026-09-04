//
//  self.swift
//  Minimuxer
//
//  Created by Magesh K on 4/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import Combine
internal import DeviceGatewayAPI
internal import MinimuxerCommon

private enum MinimuxerStatus{
    case started, inprogress, stopped
}

final internal class MinimuxerImpl: MinimuxerAPI {
    public let statusSubject = PassthroughSubject<Result<Bool, MinimuxerError>, Never>()
    public var statusPublisher: AnyPublisher<Result<Bool, MinimuxerError>, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    let gateway: any DeviceGatewayAPI
    let network: any NetworkObserverAPI
    let emproxy: any EMProxyAPI
    let wirelessPair: any WirelessPairAPI
    let mounter: Mounter
    let proxyServer: UsbmuxdProxyServer
    let endpoint: DeviceEndpoint
    let connectionManager: DeviceConnectionManager
    let heartbeat: HeartbeatService

    init(
        gateway: any DeviceGatewayAPI,
        network: any NetworkObserverAPI,
        emproxy: any EMProxyAPI,
        wirelessPair: any WirelessPairAPI,
        mounter: Mounter,
        proxyServer: UsbmuxdProxyServer,
        endpoint: DeviceEndpoint,
        connectionManager: DeviceConnectionManager,
        heartbeat: HeartbeatService
    ) {
        self.gateway = gateway
        self.network = network
        self.emproxy = emproxy
        self.wirelessPair = wirelessPair
        self.mounter = mounter
        self.proxyServer = proxyServer
        self.endpoint = endpoint
        self.connectionManager = connectionManager
        self.heartbeat = heartbeat

        if let netService = network as? NetworkObserverService {
            netService.onNetworkChanged = { [weak self] in
                guard let self = self else { return }
                let readyResult = await self.isReady()
                debugLog("[minimuxer] [net] publishing status update to subscribers")
                self.statusSubject.send(readyResult)
            }
        }
    }

    private actor State {
        var status: MinimuxerStatus = .stopped
        var mountTask: Task<Bool, Error>? = nil
        var lastDocsPath: String? = nil
        
        func with<T>(_ body: (isolated State) throws -> T) rethrows -> T {
            try body(self)
        }
    }
    private let state = State()
    
    var isrppairing: Bool { self.gateway.isRPPairing }
    
    var isLoggingEnabled: Bool { MinimuxerLogging.isLoggingEnabled }
    
    var isPairingFileLoaded: Bool {
        return getPairingFileType() != .unknown
    }
    
    func getPairingFileType() -> PairingProtocol {
        return self.gateway.getPairingFileType()
    }


    func describeError(_ error: MinimuxerError) -> String {
        return error.description
    }
    
    func getConnectionMode() async -> DeviceConnectionMode {
        await self.connectionManager.getPreferredConnectionMode()
    }
    
    func bindConnectionConfig(_ binding: ConnectionConfigBinding) async {
        await self.connectionManager.bindConnectionConfig(binding)
        await self.network.refreshEndpoint()
    }
    
    @discardableResult
    private func checkDDIMountStatus() async throws(MinimuxerError) -> Bool {
        let activeProtocol: PairingProtocol = isrppairing ? .rppairing : .lockdown
        let ddiMounted = try await runIdeviceCheckingVPN("while checking DDI mount status", fallback: false) {
            try await isDDIMounted()
        }
        guard ddiMounted else {
            let msg = isrppairing ? "dmg=\(ddiMounted) started=\(self.proxyServer.isListening)" : "DeveloperDiskImage is not mounted"
            if isrppairing {
                verboseLog("minimuxer not ready (\(activeProtocol)): \(msg)")
            }
            throw MinimuxerError.mount(protocol: activeProtocol, reason: msg)
        }
        return true
    }

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

        // check connection status first
        if withNetworkCheck && !(
            self.network.isWifiSatisfied   /* ||
            self.network.isWiredSatisfied     ||
            self.network.isUsbSatisfied       ||
            self.network.isBridgeSatisfied */
        ){
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
                    return .failure(.noVPN("No utun interface detected — LocalDevVPN is not connected"))
                }

                // check iKEv2 too if in lockdown mode and ios >= 26.4
                if !isrppairing && !net.isIKEv2IPSecAvailable {
                    if #available(iOS 26.4, *) {
                        debugLog("[minimuxer] minimuxer not ready: no ipsec interface (required for lockdown on iOS 26.4+)")
                        return .failure(.invalidVPN("utun is present but no ipsec/IKEv2 interface found — LocalDevVPN may not support the lockdown protocol on iOS 26.4+"))
                    }
                }

            case .remoteServer:
                break
        }

        // check if pairing file is loaded
        let pairingType = getPairingFileType()
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
                return .failure(.noDevice("VPN tunnel iface is up but tunnel peer IP is not yet reachable — VPN may not be routing device traffic correctly. Cause: \(error.localizedDescription)"))
            case .remoteServer:
                debugLog("[minimuxer] minimuxer not ready: remote endpoint IP is not configured or reachable")
                return .failure(.noDevice("Remote endpoint IP is not configured or reachable. Cause: \(error.localizedDescription)"))
            case .notConfigured:
                return .failure(connectionNotConfiguredError())
            }
        }
        
        let peerReachable = await connectionManager.testDeviceConnection(ifaddr: deviceIp)
        if !peerReachable {
            switch connectionMode {
            case .localVPN:
                debugLog("[minimuxer] minimuxer not ready: failed to connect to tunnel peer IP")
                return .failure(.invalidVPN("VPN tunnel iface is up and tunnel peer IP \(deviceIp) is known, but TCP port poll failed — device may be unreachable on this interface"))
            case .remoteServer:
                debugLog("[minimuxer] minimuxer not ready: failed to connect to remote endpoint IP \(deviceIp)")
                return .failure(.notReachable("Remote endpoint \(deviceIp) is configured, but TCP port poll failed — target device is unreachable"))
            case .notConfigured:
                return .failure(connectionNotConfiguredError())
            }
        }

        let activeProtocol: PairingProtocol = isrppairing ? .rppairing : .lockdown

        let deviceUDID: String?
        do {
            deviceUDID = try await runIdeviceCheckingVPN("while fetching device UDID", fallback: nil) {
                try await fetchUDID()
            }
        } catch {
            return .failure(error)
        }

        verboseLog(
            "minimuxer status (.\(activeProtocol)): " +
            "deviceUDID=\(deviceUDID ?? "nil") " +
            "started=\(self.proxyServer.isListening) "
        )
        guard deviceUDID != nil else {
            return .failure(.invalidPairing(protocol: activeProtocol, reason: ".\(activeProtocol) UDID not found"))
        }

        if !isrppairing {
            guard self.proxyServer.isListening else {
                return .failure(.muxerNotListening("Usbmuxd fake server is not listening"))
            }
        }

        // end of core validation

        if withDDIMountCheck {
            do {
                try await checkDDIMountStatus()
            } catch {
                if case .mount = error {
                    return .failure(error)
                }
                return .failure(.mount(protocol: activeProtocol, reason: error.description))
            }
        }

        return .success(true)
    } 

    private func runIdeviceCheckingVPN<T>(_ context: String, fallback: T, action: () async throws -> T) async throws(MinimuxerError) -> T {
        do {
            return try await action()
        } catch let err as DeviceGatewayError {
            if err.code == .connectionFailed,
               err.reason.lowercased().contains("broken pipe") || err.reason.lowercased().contains("brokenpipe") {
                throw MinimuxerError.noVPN("VPN tunnel connection severed \(context). Cause: \(err.reason)")
            }
            return fallback
        } catch {
            return fallback
        }
    }

    func setLogging(_ enabled: Bool) {
        MinimuxerLogging.setLogging(enabled)
        self.gateway.setLogging(enabled)
    }
    
    func retargetUsbmuxdAddr() {
        verboseLog("[minimuxer] unsetenv(USBMUXD_SOCKET_ADDRESS)")
        unsetenv(MinimuxerConstants.usbmuxdEnvKey)
        verboseLog("[minimuxer] setenv(USBMUXD_SOCKET_ADDRESS, \(MinimuxerConstants.usbmuxdSocket))")
        setenv(MinimuxerConstants.usbmuxdEnvKey, MinimuxerConstants.usbmuxdSocket, 1)
        let value = String(cString: getenv(MinimuxerConstants.usbmuxdEnvKey))
        verboseLog("[minimuxer] getenv(USBMUXD_SOCKET_ADDRESS) = \(value)")
    }
    
    private func connectionNotConfiguredError() -> MinimuxerError{
        let modes: [DeviceConnectionMode] = [.localVPN, .remoteServer]
        debugLog("[minimuxer] minimuxer not ready: connection mode not configured. Supported modes: \(modes)")
        return MinimuxerError.connectionModeNotConfigured("Connection mode not configured. Supported modes: \(modes)")
    }
    
    
    private func restartMuxerServer() async throws {
        guard !isrppairing else { return }
        // restartMuxerServer only applies to the lockdown protocol path
        guard let pairingDict = self.gateway.pairingDataDict else {
            debugLog("[minimuxer] ERROR: Pairing DICT missing...ignoring restart MuxerServer")
            throw MinimuxerError.invalidPairing(protocol: .lockdown, reason: "Pairing dictionary is missing in gateway")
        }
        verboseLog("[minimuxer] loaded pairing file keys: \(pairingDict.keys)")

        guard let deviceUDID = pairingDict["UDID"] as? String else {
            debugLog("[minimuxer] ERROR: Pairing file missing UDID")
            throw MinimuxerError.invalidPairing(protocol: .lockdown, reason: "Pairing file is missing UDID value")
        }

        // restart muxer
        await self.proxyServer.stop()
        try await self.proxyServer.start(udid: deviceUDID)
    }
    
    
    
    func start(pairingFile: String, mountPath: String) async throws {
        let connectionMode = await getConnectionMode()
        if DeviceConnectionMode.notConfigured == connectionMode {
            throw connectionNotConfiguredError()
        }
        await self.network.start()

        // actor serialization scope
        await state.with{
            $0.status = .inprogress     // mark inprogress
            $0.lastDocsPath = mountPath // record the mountPath
        }
        // let idevice initialize its state and set isRPPairing
        try await matchingPriority {
            try await self.gateway.start(pairingFileContent: pairingFile)
        }
        // retarget usbmuxd to our fake usbmuxd server (over network)
        retargetUsbmuxdAddr()
        // start our fake usbmuxd server for lockdown protocol based clients if required
        try await restartMuxerServer()
        
        // mark ready!
        await state.with{
            $0.status = .started
        }
    }

    func stop() async {
        // actor serialization scope
        let oldTask = await state.with { state -> Task<Bool, Error>? in
            state.status = .inprogress  // mark inprogress
            let task = state.mountTask
            task?.cancel()              // cancel the task
            state.mountTask = nil
            return task
        }
        _ = await oldTask?.result       // await cancelled mount task completion
        await self.proxyServer.stop()
        // mark ready!
        await state.with {
            $0.status = .stopped
        }
    }
    
    private func restartWith(pairingFile: String, op: String) async throws {
        let activeProtocol: PairingProtocol = isrppairing ? .rppairing : .lockdown
        guard let mountPath = await state.lastDocsPath else {
            throw MinimuxerError.mount(protocol: activeProtocol, reason: "start() should be invoked before requesting \(op). cause: lastDocsPath is nil")
        }
        await stop()
        try await start(pairingFile: pairingFile, mountPath: mountPath)
    }

    func restart() async throws {
        verboseLog("[minimuxer] Restarting services...")
        let activeProtocol: PairingProtocol = isrppairing ? .rppairing : .lockdown
        guard let pairingData = self.gateway.pairingFileData,
              let pairingFile = String(data: pairingData, encoding: .utf8) else {
            debugLog("[minimuxer] restart: no existing pairing file — cannot restart")
            throw MinimuxerError.invalidPairing(protocol: activeProtocol, reason: "No existing pairing file found in gateway during restart")
        }
        try await restartWith(pairingFile: pairingFile, op: "restart")
        await self.network.refreshEndpoint()
    }

    func reinitializePairingData(pairingFile: String) async throws {
        verboseLog("[minimuxer] Reinitializing with new pairing file...")
        try await restartWith(pairingFile: pairingFile, op: "reinitializePairingData")
    }
  
    func testDeviceConnection(ifaddr: String?) -> Bool {
        NetworkUtils.testDeviceConnection(ifaddr: ifaddr, isRPPairing: self.isrppairing)
    }

    private func ensureDDIMounted() async throws {
        let isMounted = (try? await self.gateway.isDDIMounted()) ?? false
        if isMounted {
            return
        }
        guard let mountPath = await state.lastDocsPath else {
            let activeProtocol: PairingProtocol = isrppairing ? .rppairing : .lockdown
            throw MinimuxerError.mount(protocol: activeProtocol, reason: "DDI mount path not set")
        }
        verboseLog("[minimuxer] DDI not mounted, mounting now before launching debug session...")
        try await self.mounter.mount(docsPath: mountPath)
    }

    
    @discardableResult
    func mountDDI(docsPath: String) async throws -> Bool {
        // actor serialization scope
        let oldTask = await state.with { state -> Task<Bool, Error>? in
            state.lastDocsPath = docsPath   // record the mountPath
            let task = state.mountTask
            task?.cancel()                  // cancel the task
            state.mountTask = nil
            return task
        }
        _ = await oldTask?.result           // await cancelled mount task completion
        let mounter = self.mounter
        let task = Task.detached(priority: .medium) {
            try await mounter.mount(docsPath: docsPath)
        }
        await state.with {
            $0.mountTask = task
        }
        return try await task.value
    }

    func isDDIMounted() async throws -> Bool {
        try await matchingPriority{
            try await self.gateway.isDDIMounted()
        }
    }

    func fetchUDID() async throws -> String? {
        try await matchingPriority{
            try await self.gateway.fetchUDID()
        }
    }

    func sendIpaAfc(bundleId: String, ipaBytes: Data) async throws {
        try await matchingPriority{
            try await self.gateway.sendIpaAfc(bundleId: bundleId, ipaBytes: ipaBytes)
        }
    }

    func sendAppBundleAfc(bundleId: String, appURL: URL) async throws {
        try await matchingPriority {
            try await self.gateway.sendAppBundleAfc(bundleId: bundleId, appURL: appURL)
        }
    }

    func installIpa(bundleId: String) async throws {
        try await matchingPriority{
            try await self.gateway.installIpa(bundleId: bundleId)
        }
    }

    func installAppBundle(bundleId: String, appName: String) async throws {
        try await matchingPriority {
            try await self.gateway.installAppBundle(bundleId: bundleId, appName: appName)
        }
    }

    func removeApp(bundleId: String) async throws {
        try await matchingPriority{
            try await self.gateway.removeApp(bundleId: bundleId)
        }
    }

    func wipeContainer(identifier: String) async throws {
        try await matchingPriority{
            try await self.gateway.wipeContainer(identifier: identifier)
        }
    }

    func debugApp(appId: String) async throws {
        try await matchingPriority{
            try await self.ensureDDIMounted()
            try await self.gateway.debugApp(appId: appId)
        }
    }

    func attachDebugger(pid: UInt32) async throws {
        try await matchingPriority{
            try await self.ensureDDIMounted()
            try await self.gateway.debugProcess(pid: pid)
        }
    }

    func installProvisioningProfile(profile: Data) async throws {
        try await matchingPriority{
            try await self.gateway.installProvisioningProfile(profile: profile)
        }
    }

    func removeProvisioningProfile(id: String) async throws {
        try await matchingPriority{
            try await self.gateway.removeProvisioningProfile(id: id)
        }
    }

    func dumpProfiles(docsPath: String) async throws -> String {
        try await matchingPriority{
            try await self.gateway.dumpProfiles(docsPath: docsPath)
        }
    }

    func afcListDirectory(bundleId: String, path: String) async throws -> [String] {
        try await matchingPriority {
            try await self.gateway.afcListDirectory(bundleId: bundleId, path: path)
        }
    }

    func afcReadFile(bundleId: String, path: String) async throws -> Data {
        try await matchingPriority {
            try await self.gateway.afcReadFile(bundleId: bundleId, path: path)
        }
    }

    func afcGetFileInfo(bundleId: String, path: String) async throws -> (isDirectory: Bool, fileSize: Int64) {
        try await matchingPriority {
            try await self.gateway.afcGetFileInfo(bundleId: bundleId, path: path)
        }
    }
}
