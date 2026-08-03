//
//  MinimuxerApi.swift
//  Minimuxer
//
//  Created by Magesh K on 4/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

public enum MinimuxerComponent: String {
    case heartbeat
    case mounter
}

public enum DeviceConnectionMode: String, Codable, Sendable {
    case localVPN      // On-device loopback VPN
    case remoteServer  // Remote server endpoint ex: externalServer on VPN, on LAN, on router, etc
    // invalid state
    case notConfigured
}

public struct ConnectionConfigBinding: Sendable {
    public let setTunnelIfaceIp: @Sendable (String?) -> Void
    public let setTunnelPeerIp: @Sendable (String?) -> Void
    public let setTunnelIfaceSubnetMask: @Sendable (String?) -> Void
    public let setRemoteReachable: @Sendable (Bool) -> Void
    public let setOverrideTunnelPeerReachable: @Sendable (Bool) -> Void

    public let getConnectionMode: @Sendable () -> DeviceConnectionMode
    public let getOverrideTunnelPeerIp: @Sendable () -> String
    public let getRemoteServerIp: @Sendable () -> String

    public init(
        setTunnelIfaceIp: @escaping @Sendable (String?) -> Void,
        setTunnelPeerIp: @escaping @Sendable (String?) -> Void,
        setTunnelIfaceSubnetMask: @escaping @Sendable (String?) -> Void,
        getRemoteServerIp: @escaping @Sendable () -> String,
        setRemoteReachable: @escaping @Sendable (Bool) -> Void,
        getOverrideTunnelPeerIp: @escaping @Sendable () -> String,
        setOverrideTunnelPeerReachable: @escaping @Sendable (Bool) -> Void,
        getConnectionMode: @escaping @Sendable () -> DeviceConnectionMode
    ) {
        self.setTunnelIfaceIp = setTunnelIfaceIp
        self.setTunnelPeerIp = setTunnelPeerIp
        self.setTunnelIfaceSubnetMask = setTunnelIfaceSubnetMask
        self.getRemoteServerIp = getRemoteServerIp
        self.setRemoteReachable = setRemoteReachable
        self.getOverrideTunnelPeerIp = getOverrideTunnelPeerIp
        self.setOverrideTunnelPeerReachable = setOverrideTunnelPeerReachable
        self.getConnectionMode = getConnectionMode
    }
}

public protocol MinimuxerAPI: AnyObject {
    var isrppairing: Bool { get }
    var isLoggingEnabled: Bool { get }
    var isPairingFileLoaded: Bool { get }
    func getPairingFileType() -> PairingProtocol
    
    func getConnectionMode() async -> DeviceConnectionMode
    func isReady() async -> Result<Bool, MinimuxerError>
    func describeError(_ error: MinimuxerError) -> String
    func bindConnectionConfig(_ binding: ConnectionConfigBinding) async
    func setLogging(_ enabled: Bool)
    /// Restarts the Lockdown heartbeat after a foreground transition.
    /// Remote Pairing sessions are unchanged.
    func revalidateConnectivitySessionAfterForeground() async

    func start(pairingFile: String, mountPath: String) async throws
    func stop() async throws
    func restart() async throws
    func reinitializePairingData(pairingFile: String) async throws
    func mountDDI(docsPath: String) async throws -> Bool
    func isDDIMounted() async throws -> Bool

    func fetchUDID() async throws -> String?
    func testDeviceConnection(ifaddr: String?) -> Bool

    func yeetAppAfc(bundleId: String, ipaBytes: Data) async throws
    func installIpa(bundleId: String) async throws
    func removeApp(bundleId: String) async throws
    func wipeContainer(identifier: String) async throws
    func debugApp(appId: String) async throws
    func attachDebugger(pid: UInt32) async throws
    func installProvisioningProfile(profile: Data) async throws
    func removeProvisioningProfile(id: String) async throws
    func dumpProfiles(docsPath: String) async throws -> String

    func afcListDirectory(bundleId: String, path: String) async throws -> [String]
    func afcReadFile(bundleId: String, path: String) async throws -> Data
    func afcGetFileInfo(bundleId: String, path: String) async throws -> (isDirectory: Bool, fileSize: Int64)
}

public enum Minimuxer {
    public static let shared: any MinimuxerAPI = MinimuxerImpl()
    public static let network: any NetworkObserverAPI = NetworkObserverService()
    public static let wirelessPair: any WirelessPairAPI = WirelessPairService()
}

// MARK: - Network Observer API

public protocol NetworkObserverAPI: AnyObject {
    var isWifiSatisfied: Bool { get }
    var isWiredSatisfied: Bool { get }
    var isUsbSatisfied: Bool { get }
    var isBridgeSatisfied: Bool { get }
    var isUTunAvailable: Bool { get }
    var isIKEv2IPSecAvailable: Bool { get }

    @discardableResult
    func start() async -> Bool
    
    @discardableResult
    func stop() async -> Bool

    func refreshEndpoint() async
}

// MARK: - Wireless Pair API

public struct WirelessPairPairedDevice: Sendable {
    public let name: String
    public let model: String
    public let udid: String
    public let pairingFilePath: String
    
    public init(name: String, model: String, udid: String, pairingFilePath: String) {
        self.name = name
        self.model = model
        self.udid = udid
        self.pairingFilePath = pairingFilePath
    }
}

public protocol WirelessPairAPI: AnyObject {
    var onPinReceived: ((String) -> Void)? { get set }
    var onReadyToPair: ((String, Int) -> Void)? { get set }
    
    func start(
        hostName: String,
        hostModel: String,
        outPath: String,
        completion: @escaping (Result<WirelessPairPairedDevice, Swift.Error>) -> Void
    )
    
    func stop()
}

public extension WirelessPairAPI {
    func start(
        outPath: String,
        completion: @escaping (Result<WirelessPairPairedDevice, Swift.Error>) -> Void
    ){
        start(
            hostName: MinimuxerConstants.defaultHostName,
            hostModel: MinimuxerConstants.defaultHostModel,
            outPath: outPath,
            completion: completion
        )
    }
}
