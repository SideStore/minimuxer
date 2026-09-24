//
//  NetworkIfaceScanner.swift
//  Minimuxer
//
//  Created by ny on 2/27/26.
//  Reworked by Magesh K on 8/15/26.
//  Copyright © 2026 SideStore. All rights reserved.
//


import Foundation
import Darwin

// MARK: - IPv4 helpers

private func ipv4String(_ value: UInt32) -> String? {
    var addr = in_addr(s_addr: value.bigEndian)
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &addr, &buf, UInt32(INET_ADDRSTRLEN)) != nil else { return nil }
    return String(cString: buf)
}

private func sockaddrIPv4(_ sa: inout sockaddr) -> UInt32? {
    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard getnameinfo(&sa, socklen_t(sa.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0,
          let s = String(validatingUTF8: buf) else { return nil }
    var a = in_addr()
    return inet_pton(AF_INET, s, &a) == 1 ? a.s_addr.bigEndian : nil
}

private func sockaddrIPv6(_ sa: inout sockaddr) -> String? {
    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    guard getnameinfo(&sa, socklen_t(sa.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0,
          let s = String(validatingUTF8: buf) else { return nil }
    return s.components(separatedBy: "%").first ?? s
}

internal struct IPv4Info: Hashable, Sendable {
    let host: String
    let mask: String
    
    fileprivate let hostRaw: UInt32
    fileprivate let maskRaw: UInt32

    init?(ifa: ifaddrs) {
        guard
            var addr = ifa.ifa_addr?.pointee,
            var mask = ifa.ifa_netmask?.pointee,
            let hostRaw = sockaddrIPv4(&addr),
            let maskRaw = sockaddrIPv4(&mask),
            let hostStr = ipv4String(hostRaw),
            let maskStr = ipv4String(maskRaw)
        else { return nil }

        self.hostRaw = hostRaw
        self.maskRaw = maskRaw
        self.host = hostStr
        self.mask = maskStr
    }

    init(host: String, mask: String, hostRaw: UInt32, maskRaw: UInt32) {
        self.host = host
        self.mask = mask
        self.hostRaw = hostRaw
        self.maskRaw = maskRaw
    }

    var networkBase: UInt32 { hostRaw & maskRaw }
    var broadcast: UInt32 { networkBase | ~maskRaw }
}

internal struct IP: Hashable, Sendable, CustomStringConvertible {
    let v4: IPv4Info?
    let v6: String?

    init(v4: IPv4Info? = nil, v6: String? = nil) {
        self.v4 = v4
        self.v6 = v6
    }

    var description: String {
        var parts: [String] = []
        if let v4 = v4 { parts.append("ipv4: \(v4.host) mask: \(v4.mask)") }
        if let v6 = v6 { parts.append("ipv6: \(v6)") }
        return parts.joined(separator: " | ")
    }
}

internal enum TunnelError: Error {
    case invalidTunnelInterface
}

internal enum TunnelType: String, Hashable, Sendable {
    case utun  = "utun"
    case ipsec = "ipsec"

    init(interfaceName: String) throws {
        let lower = interfaceName.lowercased()
        if lower.hasPrefix(Self.utun.rawValue) {
            self = .utun
        } else if lower.hasPrefix(Self.ipsec.rawValue) {
            self = .ipsec
        } else {
            throw TunnelError.invalidTunnelInterface
        }
    }
}

// MARK: - Darwin Routing Definitions (<net/route.h>)

private let RTAX_DST: Int32 = 0
private let RTAX_GATEWAY: Int32 = 1
private let RTAX_NETMASK: Int32 = 2
private let RTAX_GENMASK: Int32 = 3
private let RTAX_IFP: Int32 = 4
private let RTAX_IFA: Int32 = 5
private let RTAX_AUTHOR: Int32 = 6
private let RTAX_BRD: Int32 = 7
private let RTAX_MAX: Int32 = 8

private let RTF_UP: Int32 = 0x1
private let RTF_GATEWAY: Int32 = 0x2
private let RTF_HOST: Int32 = 0x4

private struct rt_metrics {
    var rmx_locks: UInt32 = 0
    var rmx_mtu: UInt32 = 0
    var rmx_hopcount: UInt32 = 0
    var rmx_expire: UInt32 = 0
    var rmx_recvpipe: UInt32 = 0
    var rmx_sendpipe: UInt32 = 0
    var rmx_ssthresh: UInt32 = 0
    var rmx_rtt: UInt32 = 0
    var rmx_rttvar: UInt32 = 0
    var rmx_pksent: UInt32 = 0
    var rmx_filler: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
}

private struct rt_msghdr {
    var rtm_msglen: UInt16
    var rtm_version: UInt8
    var rtm_type: UInt8
    var rtm_index: UInt16
    var rtm_flags: Int32
    var rtm_addrs: Int32
    var rtm_pid: pid_t
    var rtm_seq: Int32
    var rtm_errno: Int32
    var rtm_use: Int32
    var rtm_inits: UInt32
    var rtm_rmx: rt_metrics
}

private func sockaddrNetmaskIPv4(_ cursor: UnsafeRawPointer, saLen: Int) -> UInt32? {
    guard saLen > 0 else { return 0 }
    var rawBytes: [UInt8] = [0, 0, 0, 0]
    let sinAddrOffset = 4
    for b in 0..<4 {
        let bytePos = sinAddrOffset + b
        if bytePos < saLen {
            rawBytes[b] = cursor.load(fromByteOffset: bytePos, as: UInt8.self)
        }
    }
    return (UInt32(rawBytes[0]) << 24) | (UInt32(rawBytes[1]) << 16) | (UInt32(rawBytes[2]) << 8) | UInt32(rawBytes[3])
}

// MARK: - Route table discovery
internal struct RouteEntry: Hashable, Sendable {
    // Destination
    let destinationIPv4: String?
    let destinationIPv4Raw: UInt32?
    let destinationIPv4Mask: String?
    let destinationIPv4MaskRaw: UInt32?
    let destinationIPv6: String?
    // Interface IP
    let interfaceIPv4: String?
    let interfaceIPv4Raw: UInt32?
    let interfaceIPv4Mask: String?
    let interfaceIPv4MaskRaw: UInt32?
    let interfaceIPv6: String?
    // Gateway
    let gatewayIPv4: String?
    let gatewayIPv4Raw: UInt32?
    let gatewayIPv6: String?
    // Metadata
    let interfaceIndex: UInt16
    let flags: Int32
}


internal final class RouteSnapshot: Sendable {
    let entries: [RouteEntry]

    private init() {
        self.entries = Self.dumpRoutes()
    }

    static func captureRoutes() -> RouteSnapshot {
        return RouteSnapshot()
    }

    func routes(for interfaceIndex: UInt16) -> [RouteEntry] {
        entries.filter { $0.interfaceIndex == interfaceIndex }
    }

    func routes(for interfaceName: String) -> [RouteEntry] {
        let idx = UInt16(if_nametoindex(interfaceName) & 0xFFFF)
        guard idx != 0 else { return [] }
        return routes(for: idx)
    }

    func defaultRoute(family: Int32 = AF_INET) -> RouteEntry? {
        if family == AF_INET {
            return entries.first { $0.destinationIPv4 == "default" || $0.destinationIPv4 == "0.0.0.0" }
        } else if family == AF_INET6 {
            return entries.first { $0.destinationIPv6 == "default" || $0.destinationIPv6 == "::" }
        }
        return nil
    }

    private static func roundUp(_ len: Int) -> Int {
        len > 0 ? ((len - 1) | (MemoryLayout<UInt32>.size - 1)) + 1 : MemoryLayout<UInt32>.size
    }

    private static func dumpRoutes() -> [RouteEntry] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_UNSPEC, NET_RT_DUMP, 0]
        var neededLen = 0
        guard sysctl(&mib, u_int(mib.count), nil, &neededLen, nil, 0) == 0, 
              neededLen > 0 else 
        { 
            return [] 
        }

        var buffer = [UInt8](repeating: 0, count: neededLen)
        guard sysctl(&mib, u_int(mib.count), &buffer, &neededLen, nil, 0) == 0 else { 
            return [] 
        }

        var entries: [RouteEntry] = []
        var offset = 0

        buffer.withUnsafeMutableBytes { raw in
            while offset + MemoryLayout<rt_msghdr>.size <= neededLen {
                let msgPtr = raw.baseAddress!.advanced(by: offset)
                let rtm = msgPtr.assumingMemoryBound(to: rt_msghdr.self).pointee
                let msgLen = Int(rtm.rtm_msglen)
                guard msgLen > 0 else { 
                    return 
                }

                var cursor = msgPtr.advanced(by: MemoryLayout<rt_msghdr>.size)
                var destIPv4: String? = nil
                var destIPv4Raw: UInt32? = nil
                var destIPv4Mask: String? = nil
                var destIPv4MaskRaw: UInt32? = nil
                var destIPv6: String? = nil
                
                var ifaceIPv4: String? = nil
                var ifaceIPv4Raw: UInt32? = nil
                var ifaceIPv4Mask: String? = nil
                var ifaceIPv4MaskRaw: UInt32? = nil
                var ifaceIPv6: String? = nil

                var gwIPv4: String? = nil
                var gwIPv4Raw: UInt32? = nil
                var gwIPv6: String? = nil

                for i in 0..<Int(RTAX_MAX) {
                    guard (rtm.rtm_addrs & (1 << i)) != 0 else { continue }

                    let saLenByte = cursor.load(as: UInt8.self)
                    let saLen = saLenByte == 0 ? MemoryLayout<sockaddr>.size : Int(saLenByte)

                    if i == Int(RTAX_NETMASK) {
                        if let raw = sockaddrNetmaskIPv4(cursor, saLen: saLen) {
                            destIPv4MaskRaw = raw
                            destIPv4Mask = ipv4String(raw)
                        }
                    } else if i == Int(RTAX_GENMASK) {
                        if let raw = sockaddrNetmaskIPv4(cursor, saLen: saLen) {
                            ifaceIPv4MaskRaw = raw
                            ifaceIPv4Mask = ipv4String(raw)
                        }
                    } else if i == Int(RTAX_DST) || i == Int(RTAX_IFA) || i == Int(RTAX_GATEWAY) {
                        var sa = cursor.assumingMemoryBound(to: sockaddr.self).pointee
                        if sa.sa_family == UInt8(AF_INET), let raw = sockaddrIPv4(&sa) {
                            let str = ipv4String(raw)
                            if i == Int(RTAX_DST) {
                                destIPv4 = str
                                destIPv4Raw = raw
                            } else if i == Int(RTAX_IFA) {
                                ifaceIPv4 = str
                                ifaceIPv4Raw = raw
                            } else if i == Int(RTAX_GATEWAY) {
                                gwIPv4 = str
                                gwIPv4Raw = raw
                            }
                        } else if sa.sa_family == UInt8(AF_INET6), let str = sockaddrIPv6(&sa) {
                            if i == Int(RTAX_DST) {
                                destIPv6 = str
                            } else if i == Int(RTAX_IFA) {
                                ifaceIPv6 = str
                            } else if i == Int(RTAX_GATEWAY) {
                                gwIPv6 = str
                            }
                        }
                    }

                    cursor = cursor.advanced(by: roundUp(saLen))
                }

                if (rtm.rtm_flags & RTF_HOST) != 0 && destIPv4MaskRaw == nil {
                    destIPv4MaskRaw = 0xFFFFFFFF
                    destIPv4Mask = "255.255.255.255"
                }

                entries.append(RouteEntry(
                    destinationIPv4: destIPv4,
                    destinationIPv4Raw: destIPv4Raw,
                    destinationIPv4Mask: destIPv4Mask,
                    destinationIPv4MaskRaw: destIPv4MaskRaw,
                    destinationIPv6: destIPv6,
                    interfaceIPv4: ifaceIPv4,
                    interfaceIPv4Raw: ifaceIPv4Raw,
                    interfaceIPv4Mask: ifaceIPv4Mask,
                    interfaceIPv4MaskRaw: ifaceIPv4MaskRaw,
                    interfaceIPv6: ifaceIPv6,
                    gatewayIPv4: gwIPv4,
                    gatewayIPv4Raw: gwIPv4Raw,
                    gatewayIPv6: gwIPv6,
                    interfaceIndex: rtm.rtm_index,
                    flags: rtm.rtm_flags
                ))
                offset += msgLen
            }
        }

        return entries
    }
}

internal struct IPAddresses: Hashable, Sendable, CustomStringConvertible {
    let v4: [IPv4Info]
    let v6: [String]

    init(v4: [IPv4Info] = [], v6: [String] = []) {
        self.v4 = v4
        self.v6 = v6
    }

    var description: String {
        var parts: [String] = []
        for item in v4 {
            parts.append("ipv4: \(item.host) mask: \(item.mask)")
        }
        for item in v6 {
            parts.append("ipv6: \(item)")
        }
        return parts.joined(separator: " | ")
    }
}

internal enum LinkType: String, Hashable, Sendable, CustomStringConvertible {
    case pointToPoint = "p2p"
    case subnet = "subnet"
    case loopback = "loopback"
    case none = "none"

    var description: String { rawValue }
}


internal class NetInfo: Hashable, CustomStringConvertible, @unchecked Sendable {
    let name: String
    let interfaceIndex: UInt16
    let interfaceAddresses: IPAddresses
    let interfaceSubnetRoutes: [SubnetRoute]
    let flags: Int32

    init(name: String, interfaceIndex: UInt16, interfaceAddresses: IPAddresses, routes: RouteSnapshot, flags: Int32 = 0) {
        self.name = name
        self.interfaceIndex = interfaceIndex
        self.interfaceAddresses = interfaceAddresses
        self.flags = flags

        let rawRoutes = routes.routes(for: interfaceIndex)
        self.interfaceSubnetRoutes = rawRoutes
            .filter { Self.isSubnetRoute($0, for: interfaceAddresses) }
            .map { SubnetRoute(entry: $0) }
    }

    static func isSubnetRoute(_ entry: RouteEntry, for addresses: IPAddresses) -> Bool {
        let localV4Bases = Set(addresses.v4.filter { $0.mask != "255.255.255.255" }.map { $0.networkBase })
        if let rawV4 = entry.destinationIPv4Raw {
            return localV4Bases.contains(rawV4)
        }
        if let dstV6 = entry.destinationIPv6?.lowercased() {
            let localV6Prefixes = addresses.v6.map { $0.lowercased() }
            return dstV6.hasPrefix("fe80:") || localV6Prefixes.contains(where: { dstV6.hasPrefix($0) || $0.hasPrefix(dstV6) })
        }
        return false
    }

    var isUp: Bool { (flags & IFF_UP) != 0 }
    var isRunning: Bool { (flags & IFF_RUNNING) != 0 }
    var isLoopback: Bool { (flags & IFF_LOOPBACK) != 0 }
    var isPointToPoint: Bool { (flags & IFF_POINTOPOINT) != 0 }

    var linkType: LinkType {
        if isLoopback {
            return .loopback
        }
        if isPointToPoint {
            return .pointToPoint
        }
        if !interfaceSubnetRoutes.isEmpty {
            return .subnet
        }
        return .none
    }

    static func == (lhs: NetInfo, rhs: NetInfo) -> Bool {
        guard type(of: lhs) == type(of: rhs) else { 
            return false 
        }
        return lhs.isEqual(to: rhs)
    }

    func isEqual(to other: NetInfo) -> Bool {
        return self.name == other.name 
            && self.interfaceIndex == other.interfaceIndex 
            && self.interfaceAddresses == other.interfaceAddresses 
            && self.interfaceSubnetRoutes == other.interfaceSubnetRoutes
            && self.flags == other.flags
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(type(of: self)))
        hasher.combine(name)
        hasher.combine(interfaceIndex)
        hasher.combine(interfaceAddresses)
        hasher.combine(interfaceSubnetRoutes)
        hasher.combine(flags)
    }

    var description: String {
        var desc = "\(name) (idx: \(interfaceIndex)) [\(linkType)] | \(interfaceAddresses.description)"
        if !interfaceSubnetRoutes.isEmpty {
            desc += " subnets: [\(interfaceSubnetRoutes.compactMap { $0.destinationIPv4 ?? $0.destinationIPv6 }.joined(separator: ", "))]"
        }
        return desc
    }
}


internal struct SubnetRoute: Hashable, Sendable {
    // Destination (Local Subnet Network Base)
    let destinationIPv4: String?
    let destinationIPv4Raw: UInt32?
    let destinationIPv4Mask: String?
    let destinationIPv4MaskRaw: UInt32?
    let destinationIPv6: String?

    init(entry: RouteEntry) {
        self.destinationIPv4 = entry.destinationIPv4
        self.destinationIPv4Raw = entry.destinationIPv4Raw
        self.destinationIPv4Mask = entry.destinationIPv4Mask
        self.destinationIPv4MaskRaw = entry.destinationIPv4MaskRaw
        self.destinationIPv6 = entry.destinationIPv6
    }
}


internal struct TunnelRoute: Hashable, Sendable {
    // Destination
    let destinationIPv4: String?
    let destinationIPv4Raw: UInt32?
    let destinationIPv4Mask: String?
    let destinationIPv4MaskRaw: UInt32?
    let destinationIPv6: String?
    // Gateway
    let gatewayIPv4: String?
    let gatewayIPv4Raw: UInt32?
    let gatewayIPv6: String?

    init(entry: RouteEntry) {
        self.destinationIPv4 = entry.destinationIPv4
        self.destinationIPv4Raw = entry.destinationIPv4Raw
        self.destinationIPv4Mask = entry.destinationIPv4Mask
        self.destinationIPv4MaskRaw = entry.destinationIPv4MaskRaw
        self.destinationIPv6 = entry.destinationIPv6
        self.gatewayIPv4 = entry.gatewayIPv4
        self.gatewayIPv4Raw = entry.gatewayIPv4Raw
        self.gatewayIPv6 = entry.gatewayIPv6
    }
}


internal final class TunnelNetInfo: NetInfo, @unchecked Sendable {

    let tunnelType: TunnelType
    let linkLayerDestinationIP: IP?

    var destinationIPs: [IP] {
        destinationRoutes.compactMap { route in
            guard route.destinationIPv4 != nil || route.destinationIPv6 != nil else { return nil }
            let v4 = route.destinationIPv4.map {
                IPv4Info(
                    host: $0,
                    mask: route.destinationIPv4Mask ?? "255.255.255.255",
                    hostRaw: route.destinationIPv4Raw ?? 0,
                    maskRaw: route.destinationIPv4MaskRaw ?? 0xFFFFFFFF
                )
            }
            return IP(v4: v4, v6: route.destinationIPv6)
        }
    }

    var destinationGatewayIPs: [IP] {
        destinationRoutes.compactMap { route in
            guard route.gatewayIPv4 != nil || route.gatewayIPv6 != nil else { return nil }
            let v4 = route.gatewayIPv4.map {
                IPv4Info(
                    host: $0,
                    mask: "255.255.255.255",
                    hostRaw: route.gatewayIPv4Raw ?? 0,
                    maskRaw: 0xFFFFFFFF
                )
            }
            return IP(v4: v4, v6: route.gatewayIPv6)
        }
    }

    let destinationRoutes: [TunnelRoute]

    init(name: String, interfaceIndex: UInt16, interfaceAddresses: IPAddresses, linkLayerDestinationIP: IP?, routes: RouteSnapshot, flags: Int32 = 0) throws {
        self.tunnelType = try TunnelType(interfaceName: name)
        self.linkLayerDestinationIP = linkLayerDestinationIP

        let rawRoutes = routes.routes(for: interfaceIndex)
        // Preserves all raw kernel routing table entries for this tunnel interface without filtering.
        // This may include:
        //  • Default routes (0.0.0.0, ::)
        //  • Specific destination / peer routes (e.g. 11.8.0.2, 13.7.0.2)
        //  • Local interface host / self routes
        //  • Local on-link subnet routes (e.g. 15.7.0.0/24)
        //  • Multicast (224.0.0.0/4, ff00::/8) and broadcast (255.255.255.255)
        self.destinationRoutes = rawRoutes.map { TunnelRoute(entry: $0) }

        super.init(name: name, interfaceIndex: interfaceIndex, interfaceAddresses: interfaceAddresses, routes: routes, flags: flags)
    }

    override func isEqual(to other: NetInfo) -> Bool {
        guard let otherTunnel = other as? TunnelNetInfo else { return false }
        return super.isEqual(to: other)
            && self.linkLayerDestinationIP == otherTunnel.linkLayerDestinationIP
            && self.destinationRoutes == otherTunnel.destinationRoutes
    }

    override func hash(into hasher: inout Hasher) {
        super.hash(into: &hasher)
        hasher.combine(linkLayerDestinationIP)
        hasher.combine(destinationRoutes)
    }

    override var linkType: LinkType {
        if isPointToPoint || linkLayerDestinationIP != nil {
            return .pointToPoint
        }
        return super.linkType
    }

    override var description: String {
        var desc = super.description
        if let dst = linkLayerDestinationIP {
            desc += " linkLayerDest: \(dst.description)"
        }
        if !destinationRoutes.isEmpty {
            desc += " destinationRoutes: [\(destinationRoutes.compactMap { $0.destinationIPv4 ?? $0.destinationIPv6 }.joined(separator: ", "))]"
        }
        return desc
    }
}





internal enum NetworkIfaceScanner {

    // MARK: scan
    static func scan(quiet: Bool = false) -> Set<NetInfo> {
        if !quiet {
            debugLog("[minimuxer] [iface] scan requested...")
        }
        
        var head: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        // Captured after getifaddrs to guarantee interfaces precede routes
        var routes = RouteSnapshot.captureRoutes()

        // 1. Group addresses by interface name
        var ifaceAddressesMap = [String: IPAddresses]()
        var linkLayerDestinationIPMap = [String: IP]()
        var flagsMap = [String: Int32]()
        var orderedNames = [String]()
        var seenNames = Set<String>()

        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            let e = p.pointee
            let flags = Int32(e.ifa_flags)
            let isUp = (flags & IFF_UP) != 0

            if isUp, let name = String(utf8String: e.ifa_name) {
                let lowerName = name.lowercased()
                if !seenNames.contains(lowerName) {
                    seenNames.insert(lowerName)
                    orderedNames.append(name)
                    flagsMap[lowerName] = flags
                }

                if let addr = e.ifa_addr {
                    let family = addr.pointee.sa_family
                    if family == UInt8(AF_INET) {
                        if let v4 = IPv4Info(ifa: e) {
                            let cur = ifaceAddressesMap[lowerName] ?? IPAddresses()
                            ifaceAddressesMap[lowerName] = IPAddresses(v4: cur.v4 + [v4], v6: cur.v6)

                            if (flags & IFF_POINTOPOINT) != 0, let dstAddr = e.ifa_dstaddr {
                                var dst = dstAddr.pointee
                                if let dstHost = sockaddrIPv4(&dst), let dstStr = ipv4String(dstHost) {
                                    let dstV4 = IPv4Info(host: dstStr, mask: v4.mask, hostRaw: dstHost, maskRaw: v4.maskRaw)
                                    let prev = linkLayerDestinationIPMap[lowerName]
                                    linkLayerDestinationIPMap[lowerName] = IP(v4: dstV4, v6: prev?.v6)
                                }
                            }
                        }
                    } else if family == UInt8(AF_INET6) {
                        var sa6 = addr.pointee
                        if let ip6 = sockaddrIPv6(&sa6) {
                            let cur = ifaceAddressesMap[lowerName] ?? IPAddresses()
                            ifaceAddressesMap[lowerName] = IPAddresses(v4: cur.v4, v6: cur.v6 + [ip6])
                        }

                        if (flags & IFF_POINTOPOINT) != 0, let dstAddr = e.ifa_dstaddr {
                            var dst6 = dstAddr.pointee
                            if let dstStr6 = sockaddrIPv6(&dst6) {
                                let prev = linkLayerDestinationIPMap[lowerName]
                                linkLayerDestinationIPMap[lowerName] = IP(v4: prev?.v4, v6: dstStr6)
                            }
                        }
                    }
                }
            }
            cur = e.ifa_next
        }

        // 2. Build NetInfo / TunnelNetInfo objects
        var result = Set<NetInfo>()
        for name in orderedNames {
            let lowerName = name.lowercased()
            let ifIndex = UInt16(if_nametoindex(name) & 0xFFFF)
            guard ifIndex != 0 else {
                continue
            }

            guard let ifaceAddresses = ifaceAddressesMap[lowerName],
                  (!ifaceAddresses.v4.isEmpty || !ifaceAddresses.v6.isEmpty) else {
                continue
            }

            let linkLayerDestinationIP = linkLayerDestinationIPMap[lowerName]
            let ifFlags = flagsMap[lowerName] ?? 0

            // Case X: Orphaned route table entries belonging to destroyed interfaces
            //                    are automatically ignored because we iterate strictly 
            //                    over active, alive `orderedNames`.

            // Case Y: If tunnel interface lacks routes in current snapshot but is alive, re-capture
            if (try? TunnelType(interfaceName: name)) != nil && routes.entries.first(where: { $0.interfaceIndex == ifIndex }) == nil {
                routes = RouteSnapshot.captureRoutes()
            }

            if let tunnel = try? TunnelNetInfo(name: name, interfaceIndex: ifIndex, interfaceAddresses: ifaceAddresses, linkLayerDestinationIP: linkLayerDestinationIP, routes: routes, flags: ifFlags) {
                result.insert(tunnel)
            } else {
                let net = NetInfo(name: name, interfaceIndex: ifIndex, interfaceAddresses: ifaceAddresses, routes: routes, flags: ifFlags)
                result.insert(net)
            }
        }
        
        if !quiet {
            verboseLog(formatNetInfoList(result))
            debugLog("[minimuxer] [iface] total: \(result.count)")
        }
        return result
    }
}

// MARK: - Logging Helpers

fileprivate func formatNetInfoList(_ list: Set<NetInfo>) -> String {
    let maxNameLength = list.map { $0.name.count }.max() ?? 0
    return "[minimuxer] [iface] local interfaces list:\n" +
        "---------------------------------------------------\n" +
        list.map { info -> String in
            let paddedName = info.name.padding(toLength: maxNameLength, withPad: " ", startingAt: 0)
            return "  • \(paddedName) \(info.description)"
        }.sorted().joined(separator: "\n") + "\n" +
        "---------------------------------------------------"
}
