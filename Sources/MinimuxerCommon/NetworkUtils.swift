//
//  NetworkUtils.swift
//  MinimuxerCommon
//
//  Created by Magesh K on 23/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

public enum NetworkUtils {
    // Probes whether a TCP port is open on IPv4 or IPv6 with a timeout
    public static func testTCP(ip: String, port: UInt16, timeoutMs: Int = MinimuxerConstants.defaultTCPProbeTimeoutMs) -> Bool {
        guard !ip.isEmpty else {
            verboseLog("[minimuxer] [net] testTCP empty IP address")
            return false
        }
        guard !ip.contains("/") else {
            verboseLog("[minimuxer] [net] testTCP(\(ip):\(port)) invalid IP format (contains subnet/CIDR slash)")
            return false
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let isIPv6 = ip.contains(":")
        var addr4 = sockaddr_in()
        var addr6 = sockaddr_in6()

        if isIPv6 {
            var cleanIp = ip
            if let scopeRange = cleanIp.range(of: "%") {
                let ifaceName = String(cleanIp[scopeRange.upperBound...])
                cleanIp = String(cleanIp[..<scopeRange.lowerBound])
                addr6.sin6_scope_id = if_nametoindex(ifaceName)
            } else if cleanIp.lowercased().hasPrefix("fe80:") {
                let en0Idx = if_nametoindex("en0")
                if en0Idx != 0 {
                    addr6.sin6_scope_id = en0Idx
                } else {
                    let awdl0Idx = if_nametoindex("awdl0")
                    addr6.sin6_scope_id = awdl0Idx != 0 ? awdl0Idx : if_nametoindex("lo0")
                }
            }

            guard inet_pton(AF_INET6, cleanIp, &addr6.sin6_addr) == 1 else {
                verboseLog("[minimuxer] [net] testTCP(\(ip):\(port)) invalid IPv6 address")
                return false
            }
            #if os(macOS) || os(iOS)
            addr6.sin6_len = __uint8_t(MemoryLayout<sockaddr_in6>.size)
            #endif
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port = port.bigEndian
        } else {
            guard inet_pton(AF_INET, ip, &addr4.sin_addr) == 1 else {
                verboseLog("[minimuxer] [net] testTCP(\(ip):\(port)) invalid IPv4 address")
                return false
            }
            addr4.sin_family = sa_family_t(AF_INET)
            addr4.sin_port = port.bigEndian
        }

        let family = isIPv6 ? AF_INET6 : AF_INET
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else {
            verboseLog("[minimuxer] [net] testTCP(\(ip):\(port)) socket creation failed (errno=\(errno))")
            return false
        }
        defer { close(fd) }

        // Non-blocking mode
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        if isIPv6 {
            _ = withUnsafePointer(to: &addr6) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            _ = withUnsafePointer(to: &addr4) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let result = poll(&pfd, 1, Int32(timeoutMs))
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

        let hasOutput = (pfd.revents & Int16(POLLOUT)) != 0
        let hasError = (pfd.revents & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL))) != 0

        if result > 0 && hasOutput && !hasError {
            var socketError: Int32 = 0
            var errorLen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLen)
            let isSuccess = socketError == 0
            verboseLog("[minimuxer] [net] testTCP(\(ip):\(port)) -> \(isSuccess ? "connected" : "socket error \(socketError)") (took \(elapsedMs)ms)")
            return isSuccess
        }

        let reason = result == 0 ? "timed out (\(timeoutMs)ms)" : "poll error (result=\(result), revents=0x\(String(pfd.revents, radix: 16)))"
        verboseLog("[minimuxer] [net] testTCP(\(ip):\(port)) -> failed: \(reason) (took \(elapsedMs)ms)")
        return false
    }
}
