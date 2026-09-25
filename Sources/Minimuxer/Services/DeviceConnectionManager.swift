//
//  DeviceConnectionManager.swift
//  Minimuxer
//
//  Created by Magesh K on 16/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
internal import MinimuxerCommon
internal import DeviceGateway
import Logging

actor DeviceConnectionManager {
    let deviceProvider: DeviceProvider
    var gateway: any DeviceGateway {
        deviceProvider.gateway
    }

    private var interfacesCache: Set<NetInfo> = []
    private var connectionConfigCache: ConnectionConfigBinding?
    private var lastConnectionMode: DeviceConnectionMode? = nil
    
    // local vpn params
    var vpnIface: TunnelNetInfo?
    var reportedPeerIp: String?
    var derivedPeerIp: String?
    var derivedPeerSubnetMask: String?
    var isDerivedPeerIpReachable = false
    var overridePeerIp: String?
    var isOverridePeerIpReachable = false

    // remote server params
    var remoteServerIp: String?
    var isRemoteServerIpReachable = false

    var deviceProbeTimeout: Int
    let logger = DeviceGatewayLogging.logger

    func setDeviceProbeTimeout(_ timeoutMs: Int) {
        deviceProbeTimeout = timeoutMs
    }

    init(deviceProvider: DeviceProvider, deviceProbeTimeout: Int = MinimuxerConstants.defaultTCPProbeTimeoutMs) {
        self.deviceProvider = deviceProvider
        self.deviceProbeTimeout = deviceProbeTimeout
    }

    func bindConnectionConfig(_ binding: ConnectionConfigBinding) {
        connectionConfigCache = binding
        // ensure started if not started already
        let connectionMode = binding.getConnectionMode()
        logger.trace("""
        [minimuxer] [iface] preferred connection mode set in binding
          • mode: .\(connectionMode) 
          • overrideTunnelPeerIp: \(binding.getOverrideTunnelPeerIp()) 
          • remoteServerIp: \(binding.getRemoteServerIp()) 
        
        """)
    }
    
    func getPreferredConnectionMode() -> DeviceConnectionMode {
        connectionConfigCache?.getConnectionMode() ?? .notConfigured
    }

    private func tcpProbe(_ ip: String?) async -> Bool {
        guard let ip, !ip.isEmpty else {
            logger.debug("[minimuxer] [iface] tcpProbe skipped — IP is nil or empty")
            return false
        }
        let currentProtocol = gateway.pairingFileType
        let currentPort = gateway.servicePort
        var reachable = NetworkUtils.testTCP(ip: ip, port: currentPort, timeoutMs: deviceProbeTimeout)

        if !reachable, let resolver = connectionConfigCache?.resolveServicePort {
            let current = ServicePort(protocolType: currentProtocol, port: currentPort)
            let resolved = await resolver(current)

            if resolved.port != currentPort {
                // retry probe after resolving new target port
                let newPortReachable = NetworkUtils.testTCP(ip: ip, port: resolved.port, timeoutMs: deviceProbeTimeout)
                if newPortReachable {
                    gateway.setPort(resolved.port, for: currentProtocol)
                    reachable = true
                }
            }
        }
        logger.debug("[minimuxer] [iface] tcpProbe \(ip):\(gateway.servicePort) (protocol: .\(gateway.pairingFileType)) -> \(reachable ? "reachable" : "unreachable")")
        return reachable
    }

    @discardableResult
    func refresh(quietScan: Bool = false) async -> Bool {
        let connectionMode = getPreferredConnectionMode()
        defer { lastConnectionMode = connectionMode }

        switch connectionMode {
            case .notConfigured:
                logger.debug("[minimuxer] [iface] connection mode not configured. skipping refresh...")
                return false
            
            case .localVPN:
                // cache last state in locals
                let lastInterfacesCache = interfacesCache
                let lastVpnIface = vpnIface
                let lastReportedPeer = reportedPeerIp
                let lastDerivedPeer = derivedPeerIp
                let lastDerivedPeerMask = derivedPeerSubnetMask
                let lastOverrideIp = overridePeerIp
                let lastIsDerivedPeerIpReachable = isDerivedPeerIpReachable
                let lastIsOverridePeerIpReachable = isOverridePeerIpReachable
                // set new states
                interfacesCache = NetworkIfaceScanner.scan(quiet: quietScan)
                
                let candidatePeer = await resolveLocalVPNTunnel(from: interfacesCache)
                let (resolvedTunnel, isDerivedReachable) = (candidatePeer?.tunnel, candidatePeer != nil)
                vpnIface = resolvedTunnel
                reportedPeerIp = resolvedTunnel?.linkLayerDestinationIP?.v4?.host
                derivedPeerIp = candidatePeer?.ip
                derivedPeerSubnetMask = candidatePeer?.mask
                isDerivedPeerIpReachable = isDerivedReachable

                let rawOverrideIp = connectionConfigCache?.getOverrideTunnelPeerIp()
                overridePeerIp = (rawOverrideIp?.isEmpty ?? true) ? nil : rawOverrideIp
                isOverridePeerIpReachable = await tcpProbe(overridePeerIp)
            
                let isOverrideIpUnchanged = lastOverrideIp == overridePeerIp
                let isDerivedIpUnchanged = lastDerivedPeer == derivedPeerIp && lastDerivedPeerMask == derivedPeerSubnetMask
                let isReportedIpUnchanged = lastReportedPeer == reportedPeerIp
                if lastConnectionMode == connectionMode &&
                    lastInterfacesCache == interfacesCache &&
                    isOverrideIpUnchanged && isDerivedIpUnchanged && isReportedIpUnchanged &&
                    lastIsDerivedPeerIpReachable == isDerivedPeerIpReachable &&
                    lastIsOverridePeerIpReachable == isOverridePeerIpReachable
                {
                    logger.debug("[minimuxer] [iface] no interface state changes detected, skipping refresh")
                    return false
                }
                
                // continue updating
                logger.debug("[minimuxer] [iface] using the first uTun vpn interface info")
                // set states for this mode
                // NOTE: we do not alter user configured remote override peer IP
                connectionConfigCache?.setTunnelIfaceIp(vpnIface?.interfaceAddresses.v4.first?.host)
                connectionConfigCache?.setTunnelIfaceSubnetMask(vpnIface?.interfaceAddresses.v4.first?.mask)
                connectionConfigCache?.setTunnelPeerIp(derivedPeerIp)
                connectionConfigCache?.setTunnelPeerSubnetMask(derivedPeerSubnetMask)
                connectionConfigCache?.setTunnelPeerReachable(isDerivedPeerIpReachable)
                connectionConfigCache?.setOverrideTunnelPeerReachable(isOverridePeerIpReachable)
                // clear auto discovered reachability state
                connectionConfigCache?.setRemoteReachable(false)
            
                logger.debug("""
                [minimuxer] [iface] refresh - rescan routes
                  • mode: .\(connectionMode)
                  • local iface count: \(interfacesCache.count)
                  • probable-vpn host: \(vpnIface?.interfaceAddresses.v4.first?.host ?? "nil")
                  • probable-vpn mask: \(vpnIface?.interfaceAddresses.v4.first?.mask ?? "nil")
                  • probable-vpn destination gateway IP: \(reportedPeerIp ?? "nil")
                  • probable-vpn derived peer IP: \(derivedPeerIp ?? "nil")
                  • probable-vpn derived peer mask: \(derivedPeerSubnetMask ?? "nil")
                  • override peer IP: \(overridePeerIp ?? "nil")
                  • override peer reachable: \(isOverridePeerIpReachable)
                
                """)
                return true

            case .remoteServer:
                let rawServerIp = connectionConfigCache?.getRemoteServerIp()
                let serverIp = (rawServerIp?.isEmpty ?? true) ? nil : rawServerIp
                let reachable = await tcpProbe(serverIp)
                if self.lastConnectionMode == connectionMode && serverIp == remoteServerIp && reachable == isRemoteServerIpReachable {
                    logger.debug("[minimuxer] [iface] no remote server state changes detected, skipping refresh")
                    return false
                }
                remoteServerIp = serverIp
                isRemoteServerIpReachable = reachable
                // set states for this mode
                // NOTE: we do not alter user configured remote server IP
                connectionConfigCache?.setRemoteReachable(reachable)
                // clear auto discovered states but not explicit override!
                connectionConfigCache?.setTunnelIfaceIp(nil)
                connectionConfigCache?.setTunnelIfaceSubnetMask(nil)
                connectionConfigCache?.setTunnelPeerIp(nil)
                connectionConfigCache?.setTunnelPeerSubnetMask(nil)
                connectionConfigCache?.setTunnelPeerReachable(false)
                connectionConfigCache?.setOverrideTunnelPeerReachable(false)
                reportedPeerIp = nil
            
                logger.debug("""
                [minimuxer] [iface] refresh
                  • mode: .\(connectionMode)
                  • remote server IP: \(remoteServerIp ?? "nil")
                  • remote server reachable: \(isRemoteServerIpReachable)
                
                """)
                return true
        }
    }

    struct CandidatePeer: Equatable, Sendable {
        let tunnel: TunnelNetInfo
        let ip: String
        let mask: String?
    }

    static func resolveCandidateTunnels(from interfaces: Set<NetInfo>, _ filter: ((TunnelNetInfo) -> Bool)? = nil) -> [TunnelNetInfo] {
        let filter = filter ?? {
            $0.tunnelType == .utun && 
            !$0.interfaceAddresses.v4.isEmpty && $0.interfaceAddresses.v6.isEmpty
        }
        return interfaces
            .compactMap { $0 as? TunnelNetInfo }
            .filter(filter)
            .sorted { $0.name < $1.name }
    }

    static func resolveCandidatePeers(from interfaces: Set<NetInfo>, _ filter: ((TunnelNetInfo) -> Bool)? = nil) -> [CandidatePeer] {
        return resolveCandidateTunnels(from: interfaces, filter)
            .sorted { $0.name < $1.name }
            .flatMap { resolveCandidatePeers(for: $0) }
    }

    private func resolveLocalVPNTunnel(from interfaces: Set<NetInfo>) async -> CandidatePeer? {
        // pick all candidate peer ips
        let candidates = Self.resolveCandidatePeers(from: interfaces)
        guard !candidates.isEmpty else { return nil }

        // parallelized tcp service port probing on all candidate ips
        let resolved = await withTaskGroup(of: CandidatePeer?.self, returning: CandidatePeer?.self) { group in
            for candidate in candidates {
                group.addTask { await self.tcpProbe(candidate.ip) ? candidate : nil }
            }
            for await case let candidate? in group {
                group.cancelAll()
                return candidate
            }
            return nil
        }

        return resolved
    }

    private static func isValidCandidatePeer(_ ip: String, for tunnel: TunnelNetInfo) -> Bool {
        // reject empty/catch all/default/broadcast
        !["", "default", "0.0.0.0", "255.255.255.255"].contains { $0 == ip } &&
        // localhost/multicast/private multicast
        !["127.", "224.", "239."].contains { ip.hasPrefix($0) } && 
        // Reject self-addresses
        !tunnel.interfaceAddresses.v4.contains { $0.host == ip }
    }

    private static func resolveCandidatePeers(for tunnel: TunnelNetInfo) -> [CandidatePeer] {
        // TODO: If we are going to add priority, that should be shown in the data structure
        var candidates: [CandidatePeer] = []
        var seen = Set<String>()

        for route in tunnel.destinationRoutes {
            if let gate = route.gatewayIPv4, !seen.contains(gate) && isValidCandidatePeer(gate, for: tunnel)  {
                seen.insert(gate)
                candidates.append(CandidatePeer(tunnel: tunnel, ip: gate, mask: "255.255.255.255"))
            }
            if let dest = route.destinationIPv4, !seen.contains(dest) && isValidCandidatePeer(dest, for: tunnel) {
                seen.insert(dest)
                candidates.append(CandidatePeer(tunnel: tunnel, ip: dest, mask: route.destinationIPv4Mask))
            }
        }

        if let host = tunnel.linkLayerDestinationIP?.v4?.host {
            candidates.append(CandidatePeer(tunnel: tunnel, ip: host, mask: "255.255.255.255"))
        }

        return candidates
    }
}
