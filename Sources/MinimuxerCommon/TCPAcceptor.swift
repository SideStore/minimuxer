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

    public init(port: UInt16 = 0) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var addr = sockaddr_in()
        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_len = UInt8(addrLen)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, addrLen) == 0
            }
        }
        guard bound, listen(fd, 5) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var len = addrLen
        let named = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &len) == 0
            }
        }
        guard named else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        self.serverFd = fd
        self.port = UInt16(bigEndian: addr.sin_port)
    }

    public func accept() throws -> Int32 {
        let fd = Darwin.accept(serverFd, nil, nil)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return fd
    }

    deinit {
        close(serverFd)
    }
}
