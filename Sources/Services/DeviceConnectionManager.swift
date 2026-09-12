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

    nonisolated private func tcpProbe(_ ip: String?) -> Bool {
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
                
                let (resolvedTunnel, candidatePeer, isDerivedReachable) = await resolveLocalVPNTunnel(from: interfacesCache)
                let interfaceAddress = resolvedTunnel.map(Self.preferredInterfaceAddress)
                vpnIface = resolvedTunnel
                reportedPeerIp = resolvedTunnel?.linkLayerDestinationIP?.v4?.host ?? resolvedTunnel?.linkLayerDestinationIP?.v6
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
                connectionConfigCache?.setTunnelIfaceIp(interfaceAddress?.ip)
                connectionConfigCache?.setTunnelIfaceSubnetMask(interfaceAddress?.mask)
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
                  • probable-vpn host: \(interfaceAddress?.ip ?? "nil")
                  • probable-vpn mask: \(interfaceAddress?.mask ?? "nil")
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

    struct CandidatePeer: Equatable, Sendable {
        let tunnel: TunnelNetInfo
        let ip: String
        let mask: String?
    }

    nonisolated static func isEligibleLocalVPNTunnel(_ tunnel: TunnelNetInfo) -> Bool {
        tunnel.tunnelType == .utun &&
            (!tunnel.interfaceAddresses.v4.isEmpty || !tunnel.interfaceAddresses.v6.isEmpty)
    }

    nonisolated static func preferredInterfaceAddress(for tunnel: TunnelNetInfo) -> (ip: String?, mask: String?) {
        if let ipv4 = tunnel.interfaceAddresses.v4.first {
            return (ipv4.host, ipv4.mask)
        }
        return (tunnel.interfaceAddresses.v6.first, nil)
    }

    private func resolveLocalVPNTunnel(from interfaces: Set<NetInfo>) async -> (tunnel: TunnelNetInfo?, candidatePeer: CandidatePeer?, isReachable: Bool) {
        // Device connection operates on utun tunnels with at least one IP address.
        let tunnels = interfaces
            .compactMap { $0 as? TunnelNetInfo }
            .filter(Self.isEligibleLocalVPNTunnel)
            .sorted { $0.name < $1.name }
        guard !tunnels.isEmpty else { return (nil, nil, false) }

        // pick all candidate peer ips
        let candidates = tunnels.flatMap(Self.resolveCandidatePeers)
        guard !candidates.isEmpty else { return (nil, nil, false) }

        // parallelized tcp service port probing on all candidate ips
        let resolved = await withTaskGroup(of: CandidatePeer?.self, returning: CandidatePeer?.self) { group in
            for candidate in candidates {
                group.addTask { self.tcpProbe(candidate.ip) ? candidate : nil }
            }
            for await case let candidate? in group {
                group.cancelAll()
                return candidate
            }
            return nil
        }

        if let resolved {
            return (resolved.tunnel, resolved, true)
        }

        return (nil, nil, false)
    }

    nonisolated private static func normalizedIPAddress(_ ip: String) -> String {
        let address = ip.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ""
        return address.lowercased()
    }

    nonisolated static func isValidCandidatePeer(_ ip: String, for tunnel: TunnelNetInfo) -> Bool {
        let normalizedIP = normalizedIPAddress(ip)
        guard !normalizedIP.isEmpty,
              normalizedIP != "0.0.0.0",         // reject catch all addr (not unicast connectable)
              normalizedIP != "default",         // reject default addr (not unicast connectable)
              normalizedIP != "255.255.255.255", // reject broadcast addr (not unicast connectable)
              normalizedIP != "::",              // reject IPv6 unspecified addr (not unicast connectable)
              normalizedIP != "::1",             // reject IPv6 localhost addr (not preferred coz ourself)
              !normalizedIP.hasPrefix("127."),    // reject IPv4 localhost addr (not preferred coz ourself)
              !normalizedIP.hasPrefix("224."),    // reject IPv4 multicast addr (not unicast connectable)
              !normalizedIP.hasPrefix("239."),    // reject IPv4 private multicast addr (not unicast connectable)
              !normalizedIP.hasPrefix("ff") else  // reject IPv6 multicast addr (not unicast connectable)
        {
            return false
        }

        // Reject self-addresses
        let isIPv4Self = tunnel.interfaceAddresses.v4.contains {
            normalizedIPAddress($0.host) == normalizedIP
        }
        let isIPv6Self = tunnel.interfaceAddresses.v6.contains {
            normalizedIPAddress($0) == normalizedIP
        }
        return !isIPv4Self && !isIPv6Self
    }

    nonisolated static func resolveCandidatePeers(for tunnel: TunnelNetInfo) -> [CandidatePeer] {
        var candidates: [CandidatePeer] = []
        var seen = Set<String>()

        func addCandidate(_ ip: String?, mask: String?) {
            guard let ip = ip, isValidCandidatePeer(ip, for: tunnel) else { return }
            let normalizedIP = normalizedIPAddress(ip)
            guard !seen.contains(normalizedIP) else { return }
            seen.insert(normalizedIP)
            let candidate = CandidatePeer(tunnel: tunnel, ip: ip, mask: mask)
            candidates.append(candidate)
        }

        // Prefer IPv4 candidates while considering the same sources for IPv6.
        for route in tunnel.destinationRoutes {
            addCandidate(route.gatewayIPv4, mask: "255.255.255.255")
        }
        for route in tunnel.destinationRoutes {
            addCandidate(route.destinationIPv4, mask: route.destinationIPv4Mask)
        }
        addCandidate(tunnel.linkLayerDestinationIP?.v4?.host, mask: "255.255.255.255")
        for route in tunnel.destinationRoutes {
            addCandidate(route.gatewayIPv6, mask: nil)
        }
        for route in tunnel.destinationRoutes {
            addCandidate(route.destinationIPv6, mask: nil)
        }
        addCandidate(tunnel.linkLayerDestinationIP?.v6, mask: nil)

        return candidates
    }
}
