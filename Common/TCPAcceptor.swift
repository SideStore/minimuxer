//
//  TCPAcceptor.swift
//  MinimuxerCommon
//
//  Created by Magesh K on 19/09/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

public final class TCPAcceptor {
    private let serverFd: Int32
    public let port: UInt16

    public init() throws {
        serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            throw NSError(domain: "TCPAcceptor", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "socket() failed with errno: \(errno)"])
        }

        var yes: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var addr = sockaddr_in()
        addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0, listen(serverFd, 5) == 0 else {
            let err = errno
            close(serverFd)
            throw NSError(domain: "TCPAcceptor", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "bind/listen failed with errno: \(err)"])
        }

        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRes = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(serverFd, $0, &len)
            }
        }
        guard nameRes == 0 else {
            let err = errno
            close(serverFd)
            throw NSError(domain: "TCPAcceptor", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "getsockname failed with errno: \(err)"])
        }
        self.port = UInt16(bigEndian: assigned.sin_port)
    }

    public func accept() throws -> Int32 {
        var clientAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(serverFd, $0, &len)
            }
        }
        guard fd >= 0 else {
            throw NSError(domain: "TCPAcceptor", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "accept() failed with errno: \(errno)"])
        }
        return fd
    }

    deinit {
        close(serverFd)
    }
}
