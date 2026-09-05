//
//  DeviceConnectionManager.swift
//  Minimuxer
//
//  Created by Magesh K on 16/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
internal import MinimuxerCommon
internal import DeviceGatewayAPI

actor DeviceConnectionManager {
    let gateway: any DeviceGatewayAPI

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

    private let lock = NSLock()
    private nonisolated(unsafe) var cachedDeviceProbeTimeout: Int

    nonisolated var deviceProbeTimeout: Int {
        get { lock.withLock { cachedDeviceProbeTimeout } }
        set { lock.withLock { cachedDeviceProbeTimeout = newValue } }
    }

    init(gateway: any DeviceGatewayAPI, deviceProbeTimeout: Int = MinimuxerConstants.defaultTCPProbeTimeoutMs) {
        self.gateway = gateway
        self.cachedDeviceProbeTimeout = deviceProbeTimeout
    }

    func bindConnectionConfig(_ binding: ConnectionConfigBinding) {
        connectionConfigCache = binding
        // ensure started if not started already
        let connectionMode = binding.getConnectionMode()
        verboseLog("""
        [minimuxer] [iface] preferred connection mode set in binding
          • mode: .\(connectionMode) 
          • overrideTunnelPeerIp: \(binding.getOverrideTunnelPeerIp()) 
          • remoteServerIp: \(binding.getRemoteServerIp()) 
        
        """)
    }
    
    func getPreferredConnectionMode() -> DeviceConnectionMode {
        connectionConfigCache?.getConnectionMode() ?? .notConfigured
    }

    private func tcpProbe(_ ip: String?) -> Bool {
        guard let ip, !ip.isEmpty else {
            debugLog("[minimuxer] [iface] tcpProbe skipped — IP is nil or empty")
            return false
        }
        let port = gateway.servicePort
        let reachable = NetworkUtils.testTCP(ip: ip, port: port, timeoutMs: deviceProbeTimeout)
        debugLog("[minimuxer] [iface] tcpProbe \(ip):\(port) (protocol: .\(gateway.pairingFileType)) -> \(reachable ? "reachable" : "unreachable")")
        return reachable
    }

    @discardableResult
    func refresh(quietScan: Bool = false) async -> Bool {
        let connectionMode = getPreferredConnectionMode()
        defer { lastConnectionMode = connectionMode }

        switch connectionMode {
            case .notConfigured:
                debugLog("[minimuxer] [iface] connection mode not configured. skipping refresh...")
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
                
                let (resolvedTunnel, candidatePeer, isDerivedReachable) = resolveLocalVPNTunnel(from: interfacesCache)
                vpnIface = resolvedTunnel
                reportedPeerIp = resolvedTunnel?.linkLayerDestinationIP?.v4?.host
                derivedPeerIp = candidatePeer?.ip
                derivedPeerSubnetMask = candidatePeer?.mask
                isDerivedPeerIpReachable = isDerivedReachable

                let rawOverrideIp = connectionConfigCache?.getOverrideTunnelPeerIp()
                overridePeerIp = (rawOverrideIp?.isEmpty ?? true) ? nil : rawOverrideIp
                isOverridePeerIpReachable = tcpProbe(overridePeerIp)
            
                let isOverrideIpUnchanged = lastOverrideIp == overridePeerIp
                let isDerivedIpUnchanged = lastDerivedPeer == derivedPeerIp && lastDerivedPeerMask == derivedPeerSubnetMask
                let isReportedIpUnchanged = lastReportedPeer == reportedPeerIp
                if lastConnectionMode == connectionMode &&
                    lastInterfacesCache == interfacesCache &&
                    isOverrideIpUnchanged && isDerivedIpUnchanged && isReportedIpUnchanged &&
                    lastIsDerivedPeerIpReachable == isDerivedPeerIpReachable &&
                    lastIsOverridePeerIpReachable == isOverridePeerIpReachable
                {
                    debugLog("[minimuxer] [iface] no interface state changes detected, skipping refresh")
                    return false
                }
                
                // continue updating
                debugLog("[minimuxer] [iface] using the first uTun vpn interface info")
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
            
                debugLog("""
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
                let reachable = tcpProbe(serverIp)
                if self.lastConnectionMode == connectionMode && serverIp == remoteServerIp && reachable == isRemoteServerIpReachable {
                    debugLog("[minimuxer] [iface] no remote server state changes detected, skipping refresh")
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
            
                debugLog("""
                [minimuxer] [iface] refresh
                  • mode: .\(connectionMode)
                  • remote server IP: \(remoteServerIp ?? "nil")
                  • remote server reachable: \(isRemoteServerIpReachable)
                
                """)
                return true
        }
    }

    private struct CandidatePeer: Equatable {
        let ip: String
        let mask: String?
    }

    private func resolveLocalVPNTunnel(from interfaces: Set<NetInfo>) -> (tunnel: TunnelNetInfo?, candidatePeer: CandidatePeer?, isReachable: Bool) {
        // Device connection strictly operates on IPv4 utun tunnels only
        let tunnels = interfaces
            .compactMap { $0 as? TunnelNetInfo }
            .filter { 
                 $0.tunnelType == .utun && 
                !$0.interfaceAddresses.v4.isEmpty && $0.interfaceAddresses.v6.isEmpty 
            }
            .sorted { $0.name < $1.name }
        guard !tunnels.isEmpty else { return (nil, nil, false) }

        // 1. Evaluate candidate tunnels against reachable endpoints
        for tunnel in tunnels {
            let candidates = resolveCandidatePeers(for: tunnel)
            for candidate in candidates {
                if tcpProbe(candidate.ip) {
                    return (tunnel, candidate, true)
                }
            }
        }

        // 2. Fallback to preferred IPv4 tunnel candidate
        let fallbackTunnel = tunnels.first
        let fallbackPeer = fallbackTunnel.flatMap { resolveCandidatePeers(for: $0).first }
        return (fallbackTunnel, fallbackPeer, false)
    }

    private func isValidCandidatePeer(_ ip: String, for tunnel: TunnelNetInfo) -> Bool {
        guard !ip.isEmpty,
              ip != "0.0.0.0",
              ip != "default",
              ip != "255.255.255.255",
              !ip.hasPrefix("127."),
              !ip.hasPrefix("224."),
              !ip.hasPrefix("239.") else {
            return false
        }
        // Reject self-addresses
        let isSelf = tunnel.interfaceAddresses.v4.contains { $0.host == ip }
        return !isSelf
    }

    private func resolveCandidatePeers(for tunnel: TunnelNetInfo) -> [CandidatePeer] {
        var candidates: [CandidatePeer] = []
        var seen = Set<String>()

        func addCandidate(_ ip: String?, mask: String?) {
            guard let ip = ip, isValidCandidatePeer(ip, for: tunnel), !seen.contains(ip) else { return }
            seen.insert(ip)
            candidates.append(CandidatePeer(ip: ip, mask: mask))
        }

        // Priority 1: Destination Gateway from route table
        for route in tunnel.destinationRoutes {
            addCandidate(route.gatewayIPv4, mask: "255.255.255.255")
        }
        // Priority 2: Target Destination IP from route table (preserves route destination subnet mask)
        for route in tunnel.destinationRoutes {
            addCandidate(route.destinationIPv4, mask: route.destinationIPv4Mask)
        }
        // Priority 3: Point-to-point link layer destination
        addCandidate(tunnel.linkLayerDestinationIP?.v4?.host, mask: "255.255.255.255")

        return candidates
    }
}
