//
//  NetworkObserverService.swift
//  Minimuxer
//
//  Created by Magesh K on 02/03/26.
//

import Network
import Foundation
import Combine

final internal class NetworkObserverService: NetworkObserverAPI, @unchecked Sendable {

    var onNetworkChanged: (() async -> Void)?

    public let pathSubject = PassthroughSubject<NWPath, Never>()
    public var pathPublisher: AnyPublisher<NWPath, Never> {
        pathSubject.eraseToAnyPublisher()
    }

    let connectionManager: DeviceConnectionManager
    let endpoint: DeviceEndpoint
    let proxyServer: UsbmuxdProxyServer

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "net.monitor")
    private let state = State()

    init(
        connectionManager: DeviceConnectionManager,
        endpoint: DeviceEndpoint,
        proxyServer: UsbmuxdProxyServer
    ) {
        self.connectionManager = connectionManager
        self.endpoint = endpoint
        self.proxyServer = proxyServer
    }
    
    private actor State {
        var started = false
        var observationTask: Task<Void, Never>? = nil
        
        func with<T>(_ body: (isolated State) throws -> T) rethrows -> T {
            try body(self)
        }
    }

    @discardableResult
    func start() async -> Bool {
        let alreadyStarted = await state.with { $0.started }
        guard !alreadyStarted else {
            verboseLog("[minimuxer] [net] monitor already started")
            return false
        }

        await state.with { $0.started = true }
        verboseLog("[minimuxer] [net] monitor started")

        let paths = AsyncStream<NWPath> { [weak self] continuation in
            guard let self = self else {
                continuation.finish()
                return
            }
            self.monitor.pathUpdateHandler = { path in
                self.pathSubject.send(path)
                continuation.yield(path)
            }
        }

        self.monitor.start(queue: self.queue)

        let task = Task.detached { [weak self] in
            for await path in paths {
                verboseLog("[minimuxer] [net] path changed, status: \(path.status)")
                await self?.handleNetworkChange()
            }
        }
        await state.with { $0.observationTask = task }

        return true
    }
    
    private func handleNetworkChange() async {
        await refreshEndpoint()
        
        // Always re-evaluate and publish network change events as is
        debugLog("[minimuxer] [net] dispatching status update to subscribers")
        await onNetworkChanged?()
    }
    
    func refreshEndpoint() async {
        let manager = self.connectionManager
        verboseLog("[minimuxer] [net] refreshing interfaces list and peers")
        let ifacesChanged = await manager.refresh()
        
        guard ifacesChanged else {
            return
        }
        
        let connectionMode = await manager.getPreferredConnectionMode()
        switch connectionMode {
            case .notConfigured:
                debugLog("[minimuxer] [net] connection mode not configured. skipping endpoint update...")
                return
                
            case .localVPN:
                verboseLog("[minimuxer] [net] retrive the first uTun vpn interface info")
                if let info = await manager.vpnIface {
                    verboseLog("""
                    [minimuxer] [net] vpn interface detected
                      • name: \(info.name)
                      • addresses: \(info.interfaceAddresses.description)
                      • linkType: \(info.linkType)
                      • linkLayerDestinationIP: \(info.linkLayerDestinationIP?.description ?? "nil")
                      • destinationIPs: [\(info.destinationIPs.map { $0.description }.joined(separator: ", "))]
                      • destinationGatewayIPs: [\(info.destinationGatewayIPs.map { $0.description }.joined(separator: ", "))]
                    
                    """)

                    let overrideIp = await manager.overridePeerIp
                    let isOverridden = !(overrideIp ?? "").isEmpty

                    let effectiveIp = await isOverridden
                            ? (manager.isOverridePeerIpReachable ? overrideIp : nil)            // when override active, we don't question user intent
                            : (manager.isDerivedPeerIpReachable ? manager.derivedPeerIp : nil)  // only if not overriden, we try to use auto discovered
                    let effectivePeer = isOverridden ? "overridePeer" : "derivedPeerIp"

                    if let peer = effectiveIp {
                        verboseLog("[minimuxer] [net] update device IP with effective tunnel peer: '\(effectivePeer)'")
                        await self.endpoint.update(peer)
                        self.proxyServer.notifyDeviceAttached(tunnelPeerIp: peer)
                    } else {
                        verboseLog("[minimuxer] [net] peer not available for \(info.name)")
                        await self.endpoint.clear()
                        self.proxyServer.notifyDeviceDetached()
                    }

                } else {
                    verboseLog("[minimuxer] [net] no local VPN interface detected")
                    await self.endpoint.clear()
                    self.proxyServer.notifyDeviceDetached()
                }
            
            case .remoteServer:
                let isReachable = await manager.isRemoteServerIpReachable
                if let remoteIp = await manager.remoteServerIp {
                    verboseLog("""
                    [minimuxer] [net] remote server endpoint detected \(isReachable ? "and reachable" : "but unreachable")
                      • remoteServerIp: \(remoteIp)
                    
                    """)
                    if isReachable {
                        await self.endpoint.update(remoteIp)
                        self.proxyServer.notifyDeviceAttached(tunnelPeerIp: remoteIp)
                    } else {
                        await self.endpoint.clear()
                        self.proxyServer.notifyDeviceDetached()
                    }
                } else {
                    verboseLog("[minimuxer] [net] remote server endpoint unreachable")
                    await self.endpoint.clear()
                    self.proxyServer.notifyDeviceDetached()
                }
            }
    }
    
    @discardableResult
    func stop() async -> Bool {
        let isStarted = await state.with { $0.started }
        guard isStarted else {
            verboseLog("[minimuxer] [net] monitor already stopped")
            return false
        }

        self.monitor.cancel()
        await state.with {
            $0.observationTask?.cancel()
            $0.observationTask = nil
            $0.started = false
        }
        
        verboseLog("[minimuxer] [net] monitor stopped")
        return true
    }
    
    var isWifiSatisfied: Bool {
        let path = monitor.currentPath
        return path.status == .satisfied && path.usesInterfaceType(.wifi)
    }
    
    var isWiredSatisfied: Bool {
        let path = monitor.currentPath
        return path.status == .satisfied && path.usesInterfaceType(.wiredEthernet)
    }
    
    var isUsbSatisfied: Bool {
        return NetworkIfaceScanner.scan(quiet: true).contains { info in
            let name = info.name.lowercased()
            return name.hasPrefix("en") && name != "en0" && (info.interfaceAddresses.v4.first?.host.hasPrefix("169.254.") == true)
        }
    }
    
    var isBridgeSatisfied: Bool {
        let path = monitor.currentPath
        if path.status == .satisfied && path.usesInterfaceType(.other) {
            return true
        }
        
        return NetworkIfaceScanner.scan(quiet: true).contains { info in
            info.name.lowercased().contains("bridge") ||
            info.name.lowercased().contains("ap")
        }
    }

    // True when at least one `utun*` interface is active (userspace VPN — ex: wireguard).
    var isUTunAvailable: Bool {
        return NetworkIfaceScanner.scan(quiet: true).contains { $0.name.lowercased().hasPrefix("utun") }
    }

    // True when at least one `ipsec*` interface is active (IKEv2/IPSec kernel VPN).
    var isIKEv2IPSecAvailable: Bool {
        return NetworkIfaceScanner.scan(quiet: true).contains { $0.name.lowercased().hasPrefix("ipsec") }
    }

    var activeInterfaces: [LocalInterfaceInfo] {
        return NetworkIfaceScanner.scan(quiet: true).map { info in
            let isLinkLocal = info.interfaceAddresses.v4.first?.host.hasPrefix("169.254.") == true
            let type = LocalInterfaceType(name: info.name, isLinkLocal: isLinkLocal)
            let v4 = info.interfaceAddresses.v4.first
            let v6 = info.interfaceAddresses.v6.first
            
            return LocalInterfaceInfo(
                name: info.name,
                ip: v4?.host ?? (v6 ?? ""),
                ipv6: v6,
                subnet: v4?.mask ?? "",
                type: type
            )
        }.sorted {
            if $0.type != $1.type {
                return $0.type < $1.type
            }
            return $0.name.lowercased().localizedCompare($1.name.lowercased()) == .orderedAscending
        }
    }
}
