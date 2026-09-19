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

public struct ServicePort: Equatable, Hashable, Sendable {
    public let protocolType: PairingProtocol
    public let port: UInt16

    public init(protocolType: PairingProtocol, port: UInt16) {
        self.protocolType = protocolType
        self.port = port
    }
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
    public let resolveServicePort: (@Sendable (ServicePort) async -> ServicePort)?

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
        resolveServicePort: (@Sendable (ServicePort) async -> ServicePort)? = { servicePort in
            ServicePort(protocolType: servicePort.protocolType, port: servicePort.protocolType.defaultPort)
        }
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
        self.resolveServicePort = resolveServicePort
    }
}

public protocol MinimuxerAPI: AnyObject {
    var pairingFileType: PairingProtocol { get }
    var isLoggingEnabled: Bool { get }
    var isPairingFileLoaded: Bool { get }
    var deviceProbeTimeout: Int { get }
    
    var statusPublisher: AnyPublisher<Result<Bool, MinimuxerError>, Never> { get }
    
    func getConnectionMode() async -> DeviceConnectionMode
    func isReady(withNetworkCheck: Bool, withDDIMountCheck: Bool) async -> Result<Bool, MinimuxerError>
    func describeError(_ error: MinimuxerError) -> String
    func bindConnectionConfig(_ binding: ConnectionConfigBinding) async
    func setLogging(_ enabled: Bool)
    func setDeviceProbeTimeout(_ timeoutMs: Int)

    func start(pairingFile: String, mountPath: String) async throws
    func stop() async throws
    func restart() async throws
    func reinitializePairingData(pairingFile: String) async throws
    func mountDDI(docsPath: String) async throws -> Bool
    func isDDIMounted() async throws -> Bool

    func fetchUDID() async throws -> String
    func testDeviceConnection(ifaddr: String, timeout: Int) -> Bool

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

    func testDeviceConnection(ifaddr: String) -> Bool {
        testDeviceConnection(ifaddr: ifaddr, timeout: self.deviceProbeTimeout)
    }
}

public struct MinimuxerParams: Sendable {
    public var backend: GatewayBackend?
    public var remotePairingPort: UInt16?
    public var deviceProbeTimeout: Int?

    public init(
        backend: GatewayBackend? = nil,
        remotePairingPort: UInt16? = nil,
        deviceProbeTimeout: Int? = nil
    ) {
        self.backend = backend
        self.remotePairingPort = remotePairingPort
        self.deviceProbeTimeout = deviceProbeTimeout
    }
}

public protocol MinimuxerFacade: AnyObject, Sendable {
    var core: any MinimuxerAPI { get }
    var network: any NetworkObserverAPI { get }
    var wirelessPair: any WirelessPairAPI { get }
    var emproxy: any EMProxyAPI { get }
    var gateway: any DeviceGatewayAPI { get }
    @discardableResult
    func set(_ params: MinimuxerParams) -> any MinimuxerFacade
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
    let deviceProvider: DeviceProvider
    public var gateway: any DeviceGatewayAPI {
        deviceProvider.gateway
    }

    // singleton
    public static let shared: Minimuxer = {
        createInstance(
            backend: currentBackend,
            deviceProbeTimeout: currentDeviceProbeTimeout,
            remotePairingPort: currentRemotePairingPort
        )
    }()

    private static var currentDeviceProbeTimeout: Int = MinimuxerConstants.defaultTCPProbeTimeoutMs
    private static var currentBackend: GatewayBackend = .idevice
    private static var currentRemotePairingPort: UInt16 = MinimuxerConstants.remotePairingPort
    private static let lock = NSLock()

    private init(
        deviceProvider: DeviceProvider,
        network: any NetworkObserverAPI,
        emproxy: any EMProxyAPI,
        wirelessPair: any WirelessPairAPI,
        core: any MinimuxerAPI
    ) {
        self.deviceProvider = deviceProvider
        self.network = network
        self.emproxy = emproxy
        self.wirelessPair = wirelessPair
        self.core = core
    }

    @discardableResult
    public func set(_ params: MinimuxerParams) -> any MinimuxerFacade {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        if let newBackend = params.backend, newBackend != Self.currentBackend {
            Self.currentBackend = newBackend
            let newGateway = Self.makeGateway(for: newBackend)
            newGateway.setPort(Self.currentRemotePairingPort, for: .rppairing)
            self.deviceProvider.setGateway(newGateway)
        }

        if let newPort = params.remotePairingPort, newPort != Self.currentRemotePairingPort {
            Self.currentRemotePairingPort = newPort
            self.gateway.setPort(newPort, for: .rppairing)
        }

        if let newTimeout = params.deviceProbeTimeout, newTimeout != Self.currentDeviceProbeTimeout {
            Self.currentDeviceProbeTimeout = newTimeout
            self.core.setDeviceProbeTimeout(newTimeout)
        }

        return self
    }

    private static func makeGateway(for backend: GatewayBackend) -> any DeviceGatewayAPI {
        switch backend {
            case .libimobiledevice:
                return LibimobiledeviceGateway()
            case .idevice:
                return IdeviceGateway()
        }
    }

    private static func createInstance(
        backend: GatewayBackend,
        deviceProbeTimeout: Int,
        remotePairingPort: UInt16
    ) -> Minimuxer {
        let gateway = makeGateway(for: backend)
        gateway.setPort(remotePairingPort, for: .rppairing)
        let deviceProvider = DeviceProvider(gateway: gateway)

        let emproxy = EMProxyImpl()
        let endpoint = DeviceEndpoint(deviceProvider: deviceProvider)
        let proxyServer = UsbmuxdProxyServer(deviceProvider: deviceProvider)
        let connectionManager = DeviceConnectionManager(deviceProvider: deviceProvider, deviceProbeTimeout: deviceProbeTimeout)
        let network = NetworkObserverService(
            connectionManager: connectionManager,
            endpoint: endpoint,
            proxyServer: proxyServer
        )

        let mounter = Mounter(deviceProvider: deviceProvider, proxyServer: proxyServer, endpoint: endpoint)
        let heartbeat = HeartbeatService(deviceProvider: deviceProvider, proxyServer: proxyServer, endpoint: endpoint)
        let wirelessPair = WirelessPairService(deviceProvider: deviceProvider)

        let impl = MinimuxerImpl(
            deviceProvider: deviceProvider,
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
            deviceProvider: deviceProvider,
            network: network,
            emproxy: emproxy,
            wirelessPair: wirelessPair,
            core: impl
        )

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
    case vpnUtun        = "VPN (uTun)"
    case vpnIpsec       = "VPN (IPSec)"
    case wifi           = "Wi-Fi"
    case usbLinkLocal   = "USB / Link-Local"
    case ethernet       = "Ethernet / Adapter"
    case cellular       = "Cellular"
    case airdrop        = "AirDrop (AWDL)"
    case lowLatencyWLAN = "Low-Latency WLAN"
    case hotspotBridge  = "Personal Hotspot / Bridge"
    case loopback       = "Loopback"
    case packetCapture  = "Packet Capture"
    case other          = "Other"

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
        case .vpnUtun, .vpnIpsec:      return "lock.shield"
        case .wifi, .lowLatencyWLAN:   return "wifi"
        case .usbLinkLocal, .ethernet: return "cable.connector"
        case .cellular:                return "antenna.radiowaves.left.and.right"
        case .loopback:                return "arrow.triangle.2.circlepath"
        case .airdrop:                 return "airdrop"
        case .hotspotBridge:           return "personalhotspot"
        case .packetCapture:           return "waveform.path.ecg"
        case .other:                   return "network"
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
        resolveFileName: (@Sendable (String, String) -> String)?,
        completion: @escaping (Result<PairedDeviceRecord, Swift.Error>) -> Void
    )
    
    func trigger(
        targetIp: String,
        targetPort: UInt16,
        hostName: String,
        hostModel: String,
        outPath: String,
        resolveFileName: (@Sendable (String, String) -> String)?,
        completion: @escaping (Result<PairedDeviceRecord, Swift.Error>) -> Void
    )
    
    func stop()
}

public extension WirelessPairAPI {
    func start(
        outPath: String,
        resolveFileName: (@Sendable (String, String) -> String)? = nil,
        completion: @escaping (Result<PairedDeviceRecord, Swift.Error>) -> Void
    ) {
        start(
            hostName: MinimuxerConstants.defaultHostName,
            hostModel: MinimuxerConstants.defaultHostModel,
            outPath: outPath,
            resolveFileName: resolveFileName,
            completion: completion
        )
    }

    func trigger(
        targetIp: String,
        targetPort: UInt16,
        outPath: String,
        resolveFileName: (@Sendable (String, String) -> String)? = nil,
        completion: @escaping (Result<PairedDeviceRecord, Swift.Error>) -> Void
    ) {
        trigger(
            targetIp: targetIp,
            targetPort: targetPort,
            hostName: MinimuxerConstants.defaultHostName,
            hostModel: MinimuxerConstants.defaultHostModel,
            outPath: outPath,
            resolveFileName: resolveFileName,
            completion: completion
        )
    }
}

public typealias MinimuxerConstants = MinimuxerCommon.MinimuxerConstants

