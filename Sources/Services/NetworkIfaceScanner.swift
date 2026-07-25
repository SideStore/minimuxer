//
//  NetworkIfaceScanner.swift
//  Minimuxer
//
//  Created by ny on 2/27/26.
//  Copyright © 2026 SideStore. All rights reserved.
//


import Foundation
import Darwin

// MARK: - IPv4 helpers

@inline(__always)
private func ipv4String(_ value: UInt32) -> String? {
    var addr = in_addr(s_addr: value.bigEndian)
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &addr, &buf, UInt32(INET_ADDRSTRLEN)) != nil else { return nil }
    return String(cString: buf)
}

@inline(__always)
private func sockaddrIPv4(_ sa: inout sockaddr) -> UInt32? {
    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard getnameinfo(&sa, socklen_t(sa.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0,
          let s = String(validatingUTF8: buf) else { return nil }
    var a = in_addr()
    return inet_pton(AF_INET, s, &a) == 1 ? a.s_addr.bigEndian : nil
}

// MARK: - NetInfo


internal struct NetInfo: Hashable, CustomStringConvertible, Sendable {

    let name: String
    let hostIP: String
    let maskIP: String
    let destinationIP: String?

    fileprivate let host: UInt32
    fileprivate let mask: UInt32

    init?(ifa: ifaddrs) {
        guard
            let name = String(utf8String: ifa.ifa_name),
            var addr = ifa.ifa_addr?.pointee,
            var mask = ifa.ifa_netmask?.pointee,
            let host = sockaddrIPv4(&addr),
            let maskU = sockaddrIPv4(&mask),
            let hostStr = ipv4String(host),
            let maskStr = ipv4String(maskU)
        else { return nil }

        self.name = name
        self.host = host
        self.mask = maskU
        self.hostIP = hostStr
        self.maskIP = maskStr

        let flags = Int32(ifa.ifa_flags)
        if (flags & IFF_POINTOPOINT) != 0, let dstAddr = ifa.ifa_dstaddr {
            var dst = dstAddr.pointee
            if let dstHost = sockaddrIPv4(&dst) {
                self.destinationIP = ipv4String(dstHost)
            } else {
                self.destinationIP = nil
            }
        } else {
            self.destinationIP = nil
        }
    }
    
    var reportedPeer: String? {
        destinationIP
    }

    var derivedPeer: String? {
        guard let peer = reportedPeer, peer == hostIP else { return nil }
        let netBase = host & mask
        let firstHost = netBase + 1
        if firstHost != host {
            return ipv4String(firstHost)
        } else {
            return ipv4String(netBase + 2)
        }
    }

    var linkType: String {
        maskIP == "255.255.255.255" ? "p2pLink" : "subnetLink"
    }

    var networkBase: UInt32 { host & mask }
    var broadcast: UInt32 { networkBase | ~mask }

    var description: String {
        var desc = "\(name) | ip: \(hostIP) mask: \(maskIP) linkType: \(linkType)"
        if let rep = reportedPeer {
            desc += " reportedPeer: \(rep)"
        }
        if let der = derivedPeer {
            desc += " derivedPeer: \(der)"
        }
        return desc
    }
    
}

internal enum PeerSource: Equatable, Sendable {
    case tunnel
    case manualOverride
}

internal struct PeerResolution: Equatable, Sendable {
    let ip: String
    let source: PeerSource

    var requiresLocalVPNInterfaces: Bool {
        source == .tunnel
    }
}

actor NetworkIfaceScanner {

    static let shared = NetworkIfaceScanner()

    private var interfacesCache: Set<NetInfo> = []
    private var refreshed = false
    private var tunnelConfigCache: TunnelConfigBinding?
    private(set) var activePeerResolution: PeerResolution?

    func bindTunnelConfig(_ binding: TunnelConfigBinding) async {
        tunnelConfigCache = binding
        // A newly supplied override must be evaluated even if the interfaces did
        // not change since the previous scan.
        refreshed = false
        await Minimuxer.network.refreshEndpoint()
    }

    var cachedOverridePeerIp: String? {
        tunnelConfigCache?.getOverridePeerIp()
    }

    private init() {}

    @discardableResult
    func refresh(quietScan: Bool = false) async -> Bool {
        let scannedInterfaces = Self.scan(quiet: quietScan)
        
        let isTunnelPeerInitialized = await TunnelPeer.shared.isInitialized
        if refreshed && scannedInterfaces == interfacesCache && isTunnelPeerInitialized {
            debugLog("[minimuxer] [iface] no interface changes detected, skipping scan refresh")
            return false
        }
        debugLog(formatNetInfoList(scannedInterfaces))
        
        interfacesCache = scannedInterfaces
        refreshed = true

        let vpnIface = try? probableVPN()
        tunnelConfigCache?.setTunnelIfaceIp(vpnIface?.hostIP)
        tunnelConfigCache?.setSubnetMask(vpnIface?.maskIP)
        let peerResolution = resolvePeer(for: vpnIface)
        activePeerResolution = peerResolution
        let isOverrideActive = peerResolution?.ip != nil
            && peerResolution?.ip == tunnelConfigCache?.getOverridePeerIp()
        tunnelConfigCache?.setTunnelPeerIp(peerResolution?.ip)
        tunnelConfigCache?.setOverrideEffective(isOverrideActive)
        
        debugLog("""
        [minimuxer] [iface] rescan routes
          • interfaces: \(interfacesCache.count)
          • vpn host: \(vpnIface?.hostIP ?? "nil")
          • vpn mask: \(vpnIface?.maskIP ?? "nil")
          • active peer: \(peerResolution?.ip ?? "nil")
          • peer source: \(peerResolution.map { String(describing: $0.source) } ?? "nil")
          • cachedOverridePeerIp: \(tunnelConfigCache?.getOverridePeerIp() ?? "nil")
          • overrideEffective: \(isOverrideActive)
          • refreshed: \(refreshed)
        """)
        return true
    }

    var interfaces: Set<NetInfo> {
        interfacesCache
    }

    private func ensureReady() throws {
        guard refreshed else { 
            throw MinimuxerInternalError.networkIfaceNotRefreshed 
        }
    }

    func probableVPN() throws -> NetInfo? {
        try ensureReady()
        // TODO: @mahee96: we shouldn't return just the first coz user can have multiple uTUN lets revisit later to have a proper option
        return interfacesCache.first { $0.name.hasPrefix("utun") }
    }

    func probableLAN() throws -> NetInfo? {
         try ensureReady()
        return interfacesCache.first { $0.name.hasPrefix("en") }
   }

    // MARK: scan
    static func scan(quiet: Bool = false) -> Set<NetInfo> {
        if !quiet{
            debugLog("[minimuxer] [iface] scan requested...")
        }
        
        var result = Set<NetInfo>()
        var head: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            let e = p.pointee
            let flags = Int32(e.ifa_flags)

            let ipv4 = e.ifa_addr?.pointee.sa_family == UInt8(AF_INET)
            let active = (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING)

            if ipv4, active, let info = NetInfo(ifa: e) {
                result.insert(info)
            }
            cur = e.ifa_next
        }
        
        if !quiet{
            debugLog("[minimuxer] [iface] total: \(result.count)")
        }
        return result
    }

    func resolvePeer(for iface: NetInfo?) -> PeerResolution? {
        Self.selectPeer(
            autoPeerIp: iface?.derivedPeer,
            overridePeerIp: cachedOverridePeerIp
        ) { candidate in
            Minimuxer.shared.testDeviceConnection(ifaddr: candidate)
        }
    }

    nonisolated static func selectPeer(
        autoPeerIp: String?,
        overridePeerIp: String?,
        isReachable: (String) -> Bool
    ) -> PeerResolution? {
        if let autoPeerIp {
            if isReachable(autoPeerIp) {
                debugLog("[minimuxer] [iface] auto-discovered peer reachable at: \(autoPeerIp)")
                return PeerResolution(ip: autoPeerIp, source: .tunnel)
            }
            debugLog("[minimuxer] [iface] auto-discovered peer NOT reachable at: \(autoPeerIp)")
        }

        if let overridePeerIp, !overridePeerIp.isEmpty {
            if isReachable(overridePeerIp) {
                debugLog("[minimuxer] [iface] override peer reachable at: \(overridePeerIp)")
                return PeerResolution(ip: overridePeerIp, source: .manualOverride)
            }
            debugLog("[minimuxer] [iface] override peer NOT reachable at: \(overridePeerIp)")
        } else {
            debugLog("[minimuxer] [iface] no override peer configured")
        }

        debugLog("[minimuxer] [iface] no reachable peer found")
        return nil
    }

}

// MARK: - Logging Helpers

fileprivate func formatNetInfoList(_ list: Set<NetInfo>) -> String {
    let maxNameLength = list.map { $0.name.count }.max() ?? 0
    let maxIPLength = list.map { $0.hostIP.count }.max() ?? 0
    return "[minimuxer] [iface] local interfaces list:\n" +
        "---------------------------------------------------\n" +
        list.map { info -> String in
            let paddedName = info.name.padding(toLength: maxNameLength, withPad: " ", startingAt: 0)
            let paddedIP = info.hostIP.padding(toLength: maxIPLength, withPad: " ", startingAt: 0)
            return "  • \(paddedName) ip: \(paddedIP) : \(info.maskIP)"
        }.sorted().joined(separator: "\n") + "\n" +
        "---------------------------------------------------"
}
