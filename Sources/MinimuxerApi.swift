//
//  MinimuxerApi.swift
//  Minimuxer
//
//  Created by Magesh K on 4/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import Combine
import Network
public import MinimuxerCommon
public import DeviceGatewayAPI
import IdeviceGateway
import LibimobiledeviceGateway

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
    public let setTunnelPeerSubnetMask: @Sendable (String?) -> Void
    public let setTunnelPeerReachable: @Sendable (Bool) -> Void
    public let setTunnelIfaceSubnetMask: @Sendable (String?) -> Void
    public let setRemoteReachable: @Sendable (Bool) -> Void
    public let setOverrideTunnelPeerReachable: @Sendable (Bool) -> Void

    public let getConnectionMode: @Sendable () -> DeviceConnectionMode
    public let getOverrideTunnelPeerIp: @Sendable () -> String
    public let getRemoteServerIp: @Sendable () -> String
    public let getTCPProbeTimeoutMs: @Sendable () -> Int

    public init(
        setTunnelIfaceIp: @escaping @Sendable (String?) -> Void,
        setTunnelPeerIp: @escaping @Sendable (String?) -> Void,
        setTunnelPeerSubnetMask: @escaping @Sendable (String?) -> Void,
        setTunnelPeerReachable: @escaping @Sendable (Bool) -> Void,
        setTunnelIfaceSubnetMask: @escaping @Sendable (String?) -> Void,
        getRemoteServerIp: @escaping @Sendable () -> String,
        setRemoteReachable: @escaping @Sendable (Bool) -> Void,
        getOverrideTunnelPeerIp: @escaping @Sendable () -> String,
        setOverrideTunnelPeerReachable: @escaping @Sendable (Bool) -> Void,
        getConnectionMode: @escaping @Sendable () -> DeviceConnectionMode,
        getTCPProbeTimeoutMs: @escaping @Sendable () -> Int = { MinimuxerConstants.defaultTCPProbeTimeoutMs }
    ) {
        self.setTunnelIfaceIp = setTunnelIfaceIp
        self.setTunnelPeerIp = setTunnelPeerIp
        self.setTunnelPeerSubnetMask = setTunnelPeerSubnetMask
        self.setTunnelPeerReachable = setTunnelPeerReachable
        self.setTunnelIfaceSubnetMask = setTunnelIfaceSubnetMask
        self.getRemoteServerIp = getRemoteServerIp
        self.setRemoteReachable = setRemoteReachable
        self.getOverrideTunnelPeerIp = getOverrideTunnelPeerIp
        self.setOverrideTunnelPeerReachable = setOverrideTunnelPeerReachable
        self.getConnectionMode = getConnectionMode
        self.getTCPProbeTimeoutMs = getTCPProbeTimeoutMs
    }
}

public protocol MinimuxerAPI: AnyObject {
    var isrppairing: Bool { get }
    var isLoggingEnabled: Bool { get }
    var isPairingFileLoaded: Bool { get }
    func getPairingFileType() -> PairingProtocol
    
    var statusPublisher: AnyPublisher<Result<Bool, MinimuxerError>, Never> { get }
    
    func getConnectionMode() async -> DeviceConnectionMode
    func isReady(withNetworkCheck: Bool, withDDIMountCheck: Bool) async -> Result<Bool, MinimuxerError>
    func describeError(_ error: MinimuxerError) -> String
    func bindConnectionConfig(_ binding: ConnectionConfigBinding) async
    func setLogging(_ enabled: Bool)

    func start(pairingFile: String, mountPath: String) async throws
    func stop() async throws
    func restart() async throws
    func reinitializePairingData(pairingFile: String) async throws
    func mountDDI(docsPath: String) async throws -> Bool
    func isDDIMounted() async throws -> Bool

    func fetchUDID() async throws -> String?
    func testDeviceConnection(ifaddr: String?) -> Bool

    func sendIpaAfc(bundleId: String, ipaBytes: Data) async throws
    func sendAppBundleAfc(bundleId: String, appURL: URL) async throws
    func installIpa(bundleId: String) async throws
    func installAppBundle(bundleId: String, appName: String) async throws
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

public extension MinimuxerAPI {
    func isReady(withNetworkCheck: Bool = true, withDDIMountCheck: Bool = false) async -> Result<Bool, MinimuxerError> {
        await isReady(withNetworkCheck: withNetworkCheck, withDDIMountCheck: withDDIMountCheck)
    }
}

public protocol MinimuxerFacade: AnyObject, Sendable {
    var core: any MinimuxerAPI { get }
    var network: any NetworkObserverAPI { get }
    var wirelessPair: any WirelessPairAPI { get }
    var emproxy: any EMProxyAPI { get }
    var gateway: any DeviceGatewayAPI { get }
}

public enum GatewayBackend: String, Sendable, CaseIterable {
    case libimobiledevice
    case idevice
}

public final class Minimuxer: MinimuxerFacade, @unchecked Sendable {
    public let core: any MinimuxerAPI
    public let network: any NetworkObserverAPI
    public let wirelessPair: any WirelessPairAPI
    public let emproxy: any EMProxyAPI
    public let gateway: any DeviceGatewayAPI

    private static var currentBackend: GatewayBackend = .idevice
    private static var currentRemotePairingPort: UInt16 = MinimuxerConstants.remotePairingPort
    private static var cachedInstance: Minimuxer?
    private static let lock = NSLock()

    private init(
        gateway: any DeviceGatewayAPI,
        network: any NetworkObserverAPI,
        emproxy: any EMProxyAPI,
        wirelessPair: any WirelessPairAPI,
        core: any MinimuxerAPI
    ) {
        self.gateway = gateway
        self.network = network
        self.emproxy = emproxy
        self.wirelessPair = wirelessPair
        self.core = core
    }

    public static func shared(
        backend: GatewayBackend? = nil,
        remotePairingPort: UInt16? = nil
    ) -> Minimuxer {
        lock.lock()
        defer { lock.unlock() }

        let resolvedBackend = backend ?? currentBackend
        let resolvedPort = remotePairingPort ?? currentRemotePairingPort

        currentBackend = resolvedBackend
        currentRemotePairingPort = resolvedPort

        switch resolvedBackend {
        case .libimobiledevice:
            LibimobiledeviceGateway.shared.setRemotePairingPort(resolvedPort)
        case .idevice:
            IdeviceGateway.shared.setRemotePairingPort(resolvedPort)
        }

        if let cached = cachedInstance, currentBackend == resolvedBackend {
            return cached
        }
        return createInstance(backend: resolvedBackend)
    }

    private static func createInstance(backend: GatewayBackend) -> Minimuxer {
        let gateway: any DeviceGatewayAPI
        switch backend {
        case .libimobiledevice:
            gateway = LibimobiledeviceGateway.shared
        case .idevice:
            gateway = IdeviceGateway.shared
        }

        let emproxy = EMProxyImpl()
        let endpoint = DeviceEndpoint(gateway: gateway)
        let proxyServer = UsbmuxdProxyServer(gateway: gateway)
        let connectionManager = DeviceConnectionManager(gateway: gateway)
        let network = NetworkObserverService(
            connectionManager: connectionManager,
            endpoint: endpoint,
            proxyServer: proxyServer
        )

        let mounter = Mounter(gateway: gateway, proxyServer: proxyServer, endpoint: endpoint)
        let heartbeat = HeartbeatService(
            gateway: gateway,
            proxyServer: proxyServer,
            endpoint: endpoint,
            connectionManager: connectionManager
        )
        let wirelessPair = WirelessPairService(gateway: gateway)

        let impl = MinimuxerImpl(
            gateway: gateway,
            network: network,
            emproxy: emproxy,
            wirelessPair: wirelessPair,
            mounter: mounter,
            proxyServer: proxyServer,
            endpoint: endpoint,
            connectionManager: connectionManager,
            heartbeat: heartbeat
        )

        let instance = Minimuxer(
            gateway: gateway,
            network: network,
            emproxy: emproxy,
            wirelessPair: wirelessPair,
            core: impl
        )

        cachedInstance = instance
        currentBackend = backend
        return instance
    }
}

public protocol EMProxyAPI: AnyObject, Sendable {
    func start(host: String, port: UInt16) async throws
    func setHandshakeClient(host: String, port: UInt16, enabled: Bool)
    func stop() async throws
}

public extension EMProxyAPI {
    func start() async throws {
        try await start(host: MinimuxerConstants.empServerHost, port: MinimuxerConstants.empServerPort)
    }
    func setHandshakeClient(host: String, port: UInt16) {
        setHandshakeClient(host: host, port: port, enabled: true)
    }
}

public enum LocalInterfaceType: String, Hashable, Sendable, CaseIterable, Comparable {
    case vpnUtun = "VPN (uTun)"
    case vpnIpsec = "VPN (IPSec)"
    case wifi = "Wi-Fi"
    case usbLinkLocal = "USB / Link-Local"
    case ethernet = "Ethernet / Adapter"
    case cellular = "Cellular"
    case airdrop = "AirDrop (AWDL)"
    case lowLatencyWLAN = "Low-Latency WLAN"
    case hotspotBridge = "Personal Hotspot / Bridge"
    case loopback = "Loopback"
    case packetCapture = "Packet Capture"
    case other = "Other"

    private static let priorityOrder: [LocalInterfaceType] = [
        .wifi,
        .vpnUtun,
        .vpnIpsec,
        .usbLinkLocal,
        .cellular,
        .hotspotBridge,
        .ethernet,
        .airdrop,
        .lowLatencyWLAN,
        .loopback,
        .packetCapture,
        .other
    ]

    public var priority: Int {
        Self.priorityOrder.firstIndex(of: self) ?? Int.max
    }

    public static func < (lhs: LocalInterfaceType, rhs: LocalInterfaceType) -> Bool {
        lhs.priority < rhs.priority
    }

    public var isVPN: Bool {
        self == .vpnUtun || self == .vpnIpsec
    }

    public var symbolName: String {
        switch self {
        case .vpnUtun, .vpnIpsec: return "lock.shield"
        case .wifi, .lowLatencyWLAN: return "wifi"
        case .usbLinkLocal, .ethernet: return "cable.connector"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .loopback: return "arrow.triangle.2.circlepath"
        case .airdrop: return "airdrop"
        case .hotspotBridge: return "personalhotspot"
        case .packetCapture: return "waveform.path.ecg"
        case .other: return "network"
        }
    }

    private struct Prefix {
        let value: String
        init(_ value: String) { self.value = value }
        static func ~= (pattern: Prefix, text: String) -> Bool {
            text.hasPrefix(pattern.value)
        }
    }

    public init(name: String, isLinkLocal: Bool = false) {
        let lower = name.lowercased()
        switch lower {
            case "en0":             self = .wifi
            case Prefix("en"):      self = isLinkLocal ? .usbLinkLocal : .ethernet
            case Prefix("utun"):    self = .vpnUtun
            case Prefix("ipsec"):   self = .vpnIpsec
            case Prefix("pdp"):     self = .cellular
            case Prefix("awdl"):    self = .airdrop
            case Prefix("llw"):     self = .lowLatencyWLAN
            case Prefix("bridge"),
                 Prefix("ap"):      self = .hotspotBridge
            case Prefix("lo"):      self = .loopback
            case Prefix("pktap"):   self = .packetCapture
            default:                self = .other
        }
    }
}

public struct LocalInterfaceInfo: Hashable, Identifiable, Sendable {
    public var id: String { name.lowercased() + "-" + ip }
    public let name: String
    public let ip: String
    public let ipv6: String?
    public let subnet: String
    public let type: LocalInterfaceType

    public init(name: String, ip: String, ipv6: String? = nil, subnet: String, type: LocalInterfaceType) {
        self.name = name
        self.ip = ip
        self.ipv6 = ipv6
        self.subnet = subnet
        self.type = type
    }
}

public protocol NetworkObserverAPI: AnyObject {
    var isWifiSatisfied: Bool { get }
    var isWiredSatisfied: Bool { get }
    var isUsbSatisfied: Bool { get }
    var isBridgeSatisfied: Bool { get }
    var isUTunAvailable: Bool { get }
    var isIKEv2IPSecAvailable: Bool { get }

    var pathPublisher: AnyPublisher<NWPath, Never> { get }
    var activeInterfaces: [LocalInterfaceInfo] { get }

    @discardableResult
    func start() async -> Bool
    
    @discardableResult
    func stop() async -> Bool

    func refreshEndpoint() async
}

// MARK: - Wireless Pair API

public protocol WirelessPairAPI: AnyObject {
    var onPinReceived: ((String) -> Void)? { get set }
    var onReadyToPair: ((String, Int) -> Void)? { get set }
    var onRequestPin: ((@escaping (String) -> Void) -> Void)? { get set }
    
    func start(
        hostName: String,
        hostModel: String,
        outPath: String,
        completion: @escaping (Result<PairedDeviceRecord, Swift.Error>) -> Void
    )
    
    func trigger(
        targetIp: String,
        targetPort: UInt16,
        hostName: String,
        hostModel: String,
        outPath: String,
        completion: @escaping (Result<PairedDeviceRecord, Swift.Error>) -> Void
    )
    
    func stop()
}

public extension WirelessPairAPI {
    func start(
        outPath: String,
        completion: @escaping (Result<PairedDeviceRecord, Swift.Error>) -> Void
    ){
        start(
            hostName: MinimuxerConstants.defaultHostName,
            hostModel: MinimuxerConstants.defaultHostModel,
            outPath: outPath,
            completion: completion
        )
    }
}

public typealias MinimuxerConstants = MinimuxerCommon.MinimuxerConstants

