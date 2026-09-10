//
//  IdeviceGateway.swift
//  SideStore
//
//  Created by Magesh K on 05/07/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import IDevice
import DeviceGatewayAPI
internal import MinimuxerCommon

internal final class IdeviceGatewayError: DeviceGatewayError, @unchecked Sendable {
    override var errorDescription: String? {
        switch code {
        case .connectionFailed:
            return "Failed to connect to device: \(reason)"
        default:
            return super.errorDescription
        }
    }
}



extension String {
    // Un-escapes literal "\\n" and "\\\"" escape sequences into real line breaks and quotes.
    var cleanedErrorFormatting: String {
        return self
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }
}

public final class IdeviceGateway: BaseDeviceGateway, DeviceGatewayAPI {
    public static let shared = IdeviceGateway()
    var lastError: Error? = nil

    private func getRustPlistString(_ node: plist_t) -> String? {
        var valPtr: UnsafeMutablePointer<Int8>? = nil
        plist_get_string_val(node, &valPtr)
        if let ptr = valPtr {
            let val = String(cString: ptr)
            free(ptr)
            return val
        }
        return nil
    }

    private func getErrorMessage(from err: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        if let msgPtr = err.pointee.message {
            return String(cString: msgPtr).cleanedErrorFormatting
        }
        return "Error code \(err.pointee.code)"
    }

    private func safeFreeError(_ err: UnsafeMutablePointer<IdeviceFfiError>?) {
        guard let err = err else { return }
        let addr = Int(bitPattern: err)
        if addr > 0xff {
            idevice_error_free(err)
        }
    }

    private func safeFreePlist(_ plist: plist_t?) {
        guard let plist = plist else { return }
        let addr = Int(bitPattern: plist)
        if addr > 0xff {
            plist_free(plist)
        }
    }

    private var pairingFile: OpaquePointer? = nil
    private var adapter: OpaquePointer? = nil
    private var handshake: OpaquePointer? = nil

    private override init() {
        try! super.init()
    }

    deinit {
        cleanup()
    }

    private func cleanup() {
        debugLog("[IdeviceGateway] cleanup() called")
        setInitialized(false)
        setPairingFileData(nil)
        
        if let pairingFile = self.pairingFile {
            verboseLog("[IdeviceGateway] cleanup() freeing pairingFile")
            if pairingFileType == .rppairing {
                rp_pairing_file_free(pairingFile)
            } else {
                idevice_pairing_file_free(pairingFile)
            }
            self.pairingFile = nil
        }

        setPairingFileType(.unknown)
        lastError = nil
        if let handshake = handshake {
            verboseLog("[IdeviceGateway] cleanup() freeing handshake")
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter = adapter {
            verboseLog("[IdeviceGateway] cleanup() freeing adapter")
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    private func verifyInitialized() throws {
        guard isInitialized else {
            debugLog("[IdeviceGateway] verifyInitialized() failed: Gateway has not been initialized.")
            throw IdeviceGatewayError(.notInitialized)
        }
    }

    public override func invalidateConnection() {
        debugLog("[IdeviceGateway] invalidateConnection() called - clearing stale adapter and handshake")
        if let handshake = handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter = adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    public override func setLogging(_ enabled: Bool) {
        super.setLogging(enabled)
        idevice_init_logger(enabled ? IdeviceLogLevel(rawValue: 1) : IdeviceLogLevel(rawValue: 0), IdeviceLogLevel(rawValue: 0), nil)
        #if DEBUG
        // just comment/uncomment to override above set logging level during local debugging
//        idevice_init_logger(IdeviceLogLevel(rawValue: 4), IdeviceLogLevel(rawValue: 0), nil)
        #endif
    }

    private func syncStart(pairingFileContent: String) throws {
        debugLog("[IdeviceGateway] start() called, pairingFileContent length: \(pairingFileContent.count)")
        cleanup()
        
        #if DEBUG
        setLogging(true)
        #endif

        let parsedPairingFile: any PairingFile
        do {
            parsedPairingFile = try PairingFileParser.parse(content: pairingFileContent)
            setPairingFileData(parsedPairingFile.rawData)
            setPairingFileType(parsedPairingFile.mode)
        } catch {
            debugLog("[IdeviceGateway] start() failed: \(error.localizedDescription)")
            throw error
        }

        let data = parsedPairingFile.rawData

        if pairingFileType == .rppairing {
            try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    verboseLog("[IdeviceGateway] start() calling rp_pairing_file_from_bytes")
                    let err = rp_pairing_file_from_bytes(baseAddress, UInt(data.count), &pairingFile)
                    if err != nil {
                        debugLog("[IdeviceGateway] start() rp_pairing_file_from_bytes failed")
                        throw IdeviceGatewayError(.invalidPairingFile, reason: "rp_pairing_file_from_bytes failed")
                    }
                }
            }
        } else {
            // Traditional usbmuxd / lockdown connection path
            // For pre-iOS 17 devices, a default connection can be established without RPPairing tunnel
            verboseLog("[IdeviceGateway] start() mode = .lockdown")

            // Parse pairing file content XML plist to self.pairingFile IdevicePairingFile*
            try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    verboseLog("[IdeviceGateway] start() loading lockdown pairing file bytes")
                    let err = idevice_pairing_file_from_bytes(baseAddress, UInt(data.count), &pairingFile)
                    if err != nil {
                        debugLog("[IdeviceGateway] start() idevice_pairing_file_from_bytes failed")
                        throw IdeviceGatewayError(.invalidPairingFile, reason: "idevice_pairing_file_from_bytes failed")
                    }
                    verboseLog("[IdeviceGateway] start() loaded lockdown pairingFile successfully")
                }
            }
        }
        isInitialized = true
    }

    private func withSockaddr<R>(ip: String, port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> R) throws -> R {
        if ip.contains(":") {
            var addr6 = sockaddr_in6()
            addr6.sin6_len = __uint8_t(MemoryLayout<sockaddr_in6>.size)
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port = port.bigEndian
            
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
                throw IdeviceGatewayError(.invalidTargetEndpoint, reason: "Invalid IPv6 address: \(ip)")
            }
            
            return try withUnsafePointer(to: &addr6) { ptr in
                try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    try body(sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else {
                throw IdeviceGatewayError(.invalidTargetEndpoint, reason: "Invalid IPv4 address: \(ip)")
            }
            
            return try withUnsafePointer(to: &addr) { ptr in
                try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    try body(sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func ensureRPConnection() throws {
        debugLog("[IdeviceGateway] ensureRPConnection() started, adapter: \(String(describing: adapter)), handshake: \(String(describing: handshake))")
        if adapter != nil && handshake != nil {
            verboseLog("[IdeviceGateway] ensureRPConnection() using existing connection")
            return
        }

        guard let pairingFile = pairingFile else {
            debugLog("[IdeviceGateway] ensureRPConnection() failed because pairingFile is nil")
            throw IdeviceGatewayError(.invalidPairingFile, reason: "pairingFile is nil")
        }

        guard let deviceEndpointIp = deviceEndpointIp else {
            debugLog("[IdeviceGateway] ensureRPConnection() failed because deviceEndpointIp is nil")
            throw IdeviceGatewayError(.deviceEndpointIpNotAvailable)
        }

        let hostname = MinimuxerConstants.appName
        var err: UnsafeMutablePointer<IdeviceFfiError>? = nil

        let rpPort = getPort(for: .rppairing)
        verboseLog("[IdeviceGateway] ensureRPConnection() calling tunnel_create_rppairing with deviceEndpointIp: \(deviceEndpointIp):\(rpPort)")
        try hostname.withCString { hostPtr in
            try withSockaddr(ip: deviceEndpointIp, port: rpPort) { sockaddrPtr, sockaddrLen in
                err = tunnel_create_rppairing(
                    sockaddrPtr,
                    sockaddrLen,
                    hostPtr,
                    pairingFile,
                    nil,
                    nil,
                    &adapter,
                    &handshake
                )
            }
        }

        if let err = err {
            let ffiErr = err.pointee
            let code = ffiErr.code
            let subCode = ffiErr.sub_code
            var msg = ""
            if let msgPtr = ffiErr.message {
                msg = String(cString: msgPtr)
            }
            debugLog("[IdeviceGateway] ensureRPConnection() tunnel_create_rppairing failed with code: \(code), subCode: \(subCode), message: \(msg)")
            defer { idevice_error_free(err) }
            
            if isPairingError(err) {
                let reason = "Handshake failed: \(msg.isEmpty ? "Unknown FFI error" : msg)"
                let error = IdeviceGatewayError(.invalidPairingFile, reason: reason)
                lastError = error
                throw error
            } else {
                let error = IdeviceGatewayError(.connectionFailed, reason: msg.isEmpty ? "Tunnel creation failed" : msg)
                lastError = error
                throw error
            }
        }
        debugLog("[IdeviceGateway] ensureRPConnection() tunnel_create_rppairing succeeded, adapter: \(String(describing: adapter)), handshake: \(String(describing: handshake))")
    }

    private func isPairingError(_ err: UnsafeMutablePointer<IdeviceFfiError>) -> Bool {
        let code = err.pointee.code
        // 103: RemotePairing, 18: InvalidHostID, 30: PairingDialogResponsePending, 31: UserDeniedPairing, 32: PasswordProtected
        if code == 103 || code == 18 || code == 30 || code == 31 || code == 32 {
            return true
        }
        
        if let msgPtr = err.pointee.message {
            let msg = String(cString: msgPtr).lowercased()
            if msg.contains("invalidconf") || msg.contains("pairing") || msg.contains("handshake") ||
                msg.contains("connection reset") || msg.contains("connectionreset") {
                return true
            }
        }
        return false
    }

    private func performWithService<T>(
        connect: @escaping (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: @escaping (OpaquePointer?) -> Void,
        serviceName: String,
        action: (OpaquePointer) throws -> T
    ) throws -> T {
        debugLog("[IdeviceGateway] performWithService(\(serviceName)) started")
        try ensureRPConnection()
        var client: OpaquePointer? = nil
        var err = connect(adapter, handshake, &client)
        if let firstErr = err {
            let ffiErr = firstErr.pointee
            let code = ffiErr.code
            let subCode = ffiErr.sub_code
            var msg = ""
            if let msgPtr = ffiErr.message {
                msg = String(cString: msgPtr)
            }
            debugLog("[IdeviceGateway] performWithService(\(serviceName)) connect failed with code: \(code), subCode: \(subCode), message: \(msg)")
            idevice_error_free(firstErr)
            
            invalidateConnection()
            
            // Retry once with a fresh connection tunnel
            debugLog("[IdeviceGateway] performWithService(\(serviceName)) retrying with fresh connection...")
            do {
                try ensureRPConnection()
                err = connect(adapter, handshake, &client)
            } catch {
                let reason = "Service connection retry failed: \(error.localizedDescription)"
                let errObj = IdeviceGatewayError(.serviceError, reason: reason)
                lastError = errObj
                throw errObj
            }
            
            if let secondErr = err {
                let ffiErr = secondErr.pointee
                let code = ffiErr.code
                let subCode = ffiErr.sub_code
                var retryMsg = ""
                if let msgPtr = ffiErr.message {
                    retryMsg = String(cString: msgPtr)
                }
                debugLog("[IdeviceGateway] performWithService(\(serviceName)) retry connect failed with code: \(code), subCode: \(subCode), message: \(retryMsg)")
                defer { idevice_error_free(secondErr) }
                invalidateConnection()
                
                if isPairingError(secondErr) {
                    let reason = "Service connection failed, error: (\(retryMsg.isEmpty ? "Unknown FFI error" : retryMsg))"
                    let error = IdeviceGatewayError(.invalidPairingFile, reason: reason)
                    lastError = error
                    throw error
                } else {
                    let error = IdeviceGatewayError(.serviceError, reason: "Failed to connect to \(serviceName), error: (\(retryMsg.isEmpty ? "Unknown FFI error" : retryMsg))")
                    lastError = error
                    throw error
                }
            }
        }
        guard let client = client else {
            debugLog("[IdeviceGateway] performWithService(\(serviceName)) client is nil")
            throw IdeviceGatewayError(.serviceError, reason: "Connected client for \(serviceName) was nil")
        }
        defer {
            verboseLog("[IdeviceGateway] performWithService(\(serviceName)) performing cleanup")
            cleanup(client)
        }
        verboseLog("[IdeviceGateway] performWithService(\(serviceName)) executing action")
        return try action(client)
    }

    private func performWithUsbmuxdService<T>(
        connect: @escaping (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: @escaping (OpaquePointer?) -> Void,
        serviceName: String,
        action: (OpaquePointer) throws -> T
    ) throws -> T {
        verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) started")
        
        var addr: OpaquePointer? = nil
        var err: UnsafeMutablePointer<IdeviceFfiError>? = nil

        if let envVal = getenv("USBMUXD_SOCKET_ADDRESS") {
            let envAddr = String(cString: envVal)
            verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) using USBMUXD_SOCKET_ADDRESS: \(envAddr)")
            if envAddr.contains(":") {
                let parts = envAddr.split(separator: ":")
                if parts.count == 2, let portVal = UInt16(parts[1]) {
                    let host = String(parts[0])
                    var sockAddr = sockaddr_in()
                    sockAddr.sin_family = sa_family_t(AF_INET)
                    sockAddr.sin_port = portVal.bigEndian
                    sockAddr.sin_addr.s_addr = host.withCString { inet_addr($0) }
                    #if os(macOS) || os(iOS)
                    sockAddr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
                    #endif
                    
                    err = withUnsafePointer(to: &sockAddr) { ptr in
                        ptr.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { reboundPtr in
                            return idevice_usbmuxd_tcp_addr_new(reboundPtr, socklen_t(MemoryLayout<sockaddr_in>.size), &addr)
                        }
                    }
                } else {
                    debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) invalid USBMUXD_SOCKET_ADDRESS format: \(envAddr)")
                }
            } else {
                #if os(macOS) || os(iOS)
                err = envAddr.withCString { pathPtr in
                    return idevice_usbmuxd_unix_addr_new(pathPtr, &addr)
                }
                #else
                debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) Unix socket not supported on this platform")
                #endif
            }
        }

        if addr == nil {
            err = idevice_usbmuxd_default_addr_new(&addr)
        }

        if let err = err {
            let msg = self.getErrorMessage(from: err)
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) addr creation failed: code=\(err.pointee.code), message=\(msg)")
            defer { idevice_error_free(err) }
            throw IdeviceGatewayError(.connectionFailed, reason: "Failed to get usbmuxd addr: \(msg)")
        }
        guard let addr = addr else {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) usbmuxd addr is nil")
            throw IdeviceGatewayError(.connectionFailed, reason: "Usbmuxd addr was nil")
        }
        
        var provider: OpaquePointer? = nil
        var provErr: UnsafeMutablePointer<IdeviceFfiError>? = nil
        
        var conn: OpaquePointer? = nil
        let connErr = idevice_usbmuxd_new_default_connection(0, &conn)
        if let connErr = connErr {
            let msg = self.getErrorMessage(from: connErr)
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) new_default_connection failed: code=\(connErr.pointee.code), message=\(msg)")
            defer { idevice_error_free(connErr) }
            idevice_usbmuxd_addr_free(addr)
            throw IdeviceGatewayError(.connectionFailed, reason: "Failed to connect to usbmuxd: \(msg)")
        }
        
        if let conn = conn {
            defer { idevice_usbmuxd_connection_free(conn) }
            var devices: UnsafeMutablePointer<OpaquePointer?>? = nil
            var count: Int32 = 0
            let devErr = idevice_usbmuxd_get_devices(conn, &devices, &count)
            if let devErr = devErr {
                let msg = self.getErrorMessage(from: devErr)
                debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) get_devices failed: code=\(devErr.pointee.code), message=\(msg)")
                defer { idevice_error_free(devErr) }
                idevice_usbmuxd_addr_free(addr)
                throw IdeviceGatewayError(.connectionFailed, reason: "Failed to list usbmuxd devices: \(msg)")
            }
            verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) found \(count) devices")
            if count > 0, let devicesPtr = devices, let firstDev = devicesPtr.pointee {
                defer { idevice_usbmuxd_device_list_free(devices, count) }
                let udidPtr = idevice_usbmuxd_device_get_udid(firstDev)
                let deviceID = idevice_usbmuxd_device_get_device_id(firstDev)
                verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) creating provider for deviceID: \(deviceID)")
                provErr = usbmuxd_provider_new(addr, 0, udidPtr, deviceID, MinimuxerConstants.appName, &provider)
                if let udidPtr = udidPtr {
                    idevice_string_free(udidPtr)
                }
            } else {
                verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) no devices found on usbmuxd")
                idevice_usbmuxd_addr_free(addr)
                throw IdeviceGatewayError(.connectionFailed, reason: "No devices found on usbmuxd")
            }
        } else {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) usbmuxd connection was nil")
            idevice_usbmuxd_addr_free(addr)
            throw IdeviceGatewayError(.connectionFailed, reason: "Usbmuxd connection was nil")
        }
        
        if let provErr = provErr {
            let msg = self.getErrorMessage(from: provErr)
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) provider creation failed: code=\(provErr.pointee.code), message=\(msg)")
            defer { idevice_error_free(provErr) }
            throw IdeviceGatewayError(.connectionFailed, reason: "Failed to create usbmuxd provider: \(msg)")
        }
        guard let provider = provider else {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) provider is nil")
            throw IdeviceGatewayError(.connectionFailed, reason: "Usbmuxd provider was nil")
        }
        var providerToFree: OpaquePointer? = provider
        defer {
            if let ptr = providerToFree {
                idevice_provider_free(ptr)
            }
        }

        var client: OpaquePointer? = nil
        let connectErr = connect(provider, &client)
        if let connectErr = connectErr {
            providerToFree = nil
            let msg = self.getErrorMessage(from: connectErr)
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) connect failed: code=\(connectErr.pointee.code), message=\(msg)")
            defer { idevice_error_free(connectErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to connect to \(serviceName), error: (\(msg))")
        }
        guard let client = client else {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) client is nil")
            throw IdeviceGatewayError(.serviceError, reason: "Connected client for \(serviceName) was nil")
        }
        defer {
            verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) performing cleanup")
            cleanup(client)
        }
        verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) executing action")
        return try action(client)
    }

    private func performWithTcpService<T>(
        connect: @escaping (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: @escaping (OpaquePointer?) -> Void,
        serviceName: String,
        action: (OpaquePointer) throws -> T
    ) throws -> T {
        verboseLog("[IdeviceGateway] performWithTcpService(\(serviceName)) started")
        
        guard let deviceEndpointIp = deviceEndpointIp else {
            debugLog("[IdeviceGateway] performWithTcpService(\(serviceName)) failed because deviceEndpointIp is nil")
            throw IdeviceGatewayError(.deviceEndpointIpNotAvailable)
        }
        


        guard let pairingFileData = self.pairingFileData else {
            debugLog("[IdeviceGateway] error: pairingFileData is nil")
            throw IdeviceGatewayError(.connectionFailed, reason: "pairingFileData is nil")
        }

        var tempPairingFile: OpaquePointer? = nil
        let parseErr = pairingFileData.withUnsafeBytes { buf in
            return idevice_pairing_file_from_bytes(buf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt(pairingFileData.count), &tempPairingFile)
        }
        if let parseErr = parseErr {
            let msg = self.getErrorMessage(from: parseErr)
            debugLog("[IdeviceGateway] error: Failed to parse temporary pairing file: \(msg)")
            defer { safeFreeError(parseErr) }
            throw IdeviceGatewayError(.connectionFailed, reason: "Failed to parse temporary pairing file: \(msg)")
        }
        guard let tempPairingFile = tempPairingFile else {
            throw IdeviceGatewayError(.connectionFailed, reason: "Temporary pairing file was nil")
        }

        var provider: OpaquePointer? = nil
        let provErr = try withSockaddr(ip: deviceEndpointIp, port: MinimuxerConstants.lockdowndPort) { sockaddrPtr, _ in
            sockaddrPtr.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { reboundPtr in
                return idevice_tcp_provider_new(reboundPtr, tempPairingFile, MinimuxerConstants.appName, &provider)
            }
        }
        if let provErr = provErr {
            let msg = self.getErrorMessage(from: provErr)
            debugLog("[IdeviceGateway] error: Failed to create TCP provider: \(msg)")
            defer { safeFreeError(provErr) }
            throw IdeviceGatewayError(.connectionFailed, reason: "Failed to create TCP provider: \(msg)")
        }
        guard let provider = provider else {
            debugLog("[IdeviceGateway] error: TCP Provider was nil")
            throw IdeviceGatewayError(.connectionFailed, reason: "TCP Provider was nil")
        }
        var providerToFree: OpaquePointer? = provider
        defer {
            if let ptr = providerToFree {
                idevice_provider_free(ptr)
            }
        }

        var client: OpaquePointer? = nil
        let connectErr = connect(provider, &client)
        if let connectErr = connectErr {
            providerToFree = nil
            let msg = self.getErrorMessage(from: connectErr)
            debugLog("[IdeviceGateway] error: \(serviceName) connect failed: code=\(connectErr.pointee.code), message=\(msg)")
            defer { safeFreeError(connectErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to connect to \(serviceName), error: (\(msg))")
        }
        guard let client = client else {
            throw IdeviceGatewayError(.noConnection)
        }
        defer { cleanup(client) }

        return try action(client)
    }

    private func performWithEitherService<T>(
        connectRP: @escaping (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        connectLockdown: @escaping (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: @escaping (OpaquePointer?) -> Void,
        serviceName: String,
        action: (OpaquePointer) throws -> T
    ) throws -> T {
        debugLog("[IdeviceGateway] performWithEitherService(\(serviceName)) started, mode = .\(pairingFileType)")
        if pairingFileType == .rppairing {
            return try performWithService(connect: connectRP, cleanup: cleanup, serviceName: serviceName, action: action)
        } else {
            return try performWithTcpService(connect: connectLockdown, cleanup: cleanup, serviceName: serviceName, action: action)
        }
    }

    private func syncFetchUDID() throws -> String? {
        debugLog("[IdeviceGateway] fetchUDID() started, mode = .\(pairingFileType)")
        try verifyInitialized()
        if pairingFileType == .rppairing {
            do {
                verboseLog("[IdeviceGateway] fetchUDID() calling ensureRPConnection()")
                try ensureRPConnection()
            } catch {
                debugLog("[IdeviceGateway] fetchUDID() ensureRPConnection failed with error: \(error)")
                return nil
            }
            guard let adapter = adapter, let handshake = handshake else {
                debugLog("[IdeviceGateway] fetchUDID() adapter (\(String(describing: adapter))) or handshake (\(String(describing: handshake))) is nil")
                return nil
            }
            var lockdownClient: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] fetchUDID() connecting lockdownd_connect_rsd")
            var connectErr = lockdownd_connect_rsd(adapter, handshake, &lockdownClient)
            if let firstErr = connectErr {
                debugLog("[IdeviceGateway] fetchUDID() lockdownd_connect_rsd failed on existing connection, invalidating and retrying with fresh connection")
                idevice_error_free(firstErr)
                invalidateConnection()
                
                do {
                    try ensureRPConnection()
                    guard let freshAdapter = self.adapter, let freshHandshake = self.handshake else { return nil }
                    connectErr = lockdownd_connect_rsd(freshAdapter, freshHandshake, &lockdownClient)
                    if let secondErr = connectErr {
                        debugLog("[IdeviceGateway] fetchUDID() lockdownd_connect_rsd retry failed")
                        idevice_error_free(secondErr)
                        invalidateConnection()
                        return nil
                    }
                } catch {
                    debugLog("[IdeviceGateway] fetchUDID() retry ensureRPConnection failed with error: \(error)")
                    return nil
                }
            }
            guard let client = lockdownClient else {
                debugLog("[IdeviceGateway] fetchUDID() lockdownClient is nil after connect")
                return nil
            }
            defer { lockdownd_client_free(client) }
            
            var plistVal: plist_t? = nil
            verboseLog("[IdeviceGateway] fetchUDID() calling lockdownd_get_value for UniqueDeviceID")
            let valErr = lockdownd_get_value(client, "UniqueDeviceID", nil, &plistVal)
            if let valErr = valErr {
                debugLog("[IdeviceGateway] fetchUDID() lockdownd_get_value failed")
                safeFreeError(valErr)
                return nil
            }
            if let plistVal = plistVal {
                defer {
                    safeFreePlist(plistVal)
                }
                let udid = getRustPlistString(plistVal)
                verboseLog("[IdeviceGateway] fetchUDID() getRustPlistString returned UDID: \(String(describing: udid))")
                return udid
            }
            debugLog("[IdeviceGateway] fetchUDID() plistVal is nil")
            return nil
        } else {
            var conn: OpaquePointer? = nil
            let err = idevice_usbmuxd_new_default_connection(0, &conn)
            if let err = err {
                let msg = self.getErrorMessage(from: err)
                debugLog("[IdeviceGateway] fetchUDID new_default_connection failed: code=\(err.pointee.code), message=\(msg)")
                idevice_error_free(err)
                return nil
            }
            
            if let conn = conn {
                defer { idevice_usbmuxd_connection_free(conn) }
                var devices: UnsafeMutablePointer<OpaquePointer?>? = nil
                var count: Int32 = 0
                let devErr = idevice_usbmuxd_get_devices(conn, &devices, &count)
                if let devErr = devErr {
                    let msg = self.getErrorMessage(from: devErr)
                    debugLog("[IdeviceGateway] fetchUDID get_devices failed: code=\(devErr.pointee.code), message=\(msg)")
                    idevice_error_free(devErr)
                    return nil
                }
                
                var udidResult: String? = nil
                if count > 0, let devicesPtr = devices, let firstDev = devicesPtr.pointee {
                    defer { idevice_usbmuxd_device_list_free(devices, count) }
                    if let udidPtr = idevice_usbmuxd_device_get_udid(firstDev) {
                        udidResult = String(cString: udidPtr)
                        idevice_string_free(udidPtr)
                    }
                }
                verboseLog("[IdeviceGateway] fetchUDID get_devices count: \(count), udid: \(udidResult ?? "nil")")
                return udidResult
            }
            return nil
        }
    }

    private func syncGetLockdownValue(key: String) throws -> String? {
        debugLog("[IdeviceGateway] getLockdownValue(key: \(key)) started, mode = .\(pairingFileType)")
        try verifyInitialized()

        return try performWithEitherService(
            connectRP: lockdownd_connect_rsd,
            connectLockdown: lockdownd_connect,
            cleanup: lockdownd_client_free,
            serviceName: "lockdownd"
        ) { client in
            var plistVal: plist_t? = nil
            verboseLog("[IdeviceGateway] getLockdownValue calling lockdownd_get_value for \(key)")
            let valErr = lockdownd_get_value(client, key, nil, &plistVal)
            if let valErr = valErr {
                let msg = self.getErrorMessage(from: valErr)
                debugLog("[IdeviceGateway] getLockdownValue lockdownd_get_value failed for \(key): \(msg)")
                defer { safeFreeError(valErr) }
                throw IdeviceGatewayError(.serviceError, reason: "Failed to get lockdown value for key \(key), error: (\(msg))")
            }
            if let plistVal = plistVal {
                defer {
                    safeFreePlist(plistVal)
                }
                let val = getRustPlistString(plistVal)
                verboseLog("[IdeviceGateway] getLockdownValue getRustPlistString returned: \(String(describing: val))")
                return val
            }
            debugLog("[IdeviceGateway] getLockdownValue plistVal is nil for \(key)")
            return nil
        }
    }

    private func syncInstallProvisioningProfile(profile: Data) throws {
        debugLog("[IdeviceGateway] installProvisioningProfile() called, profile length: \(profile.count)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: misagent_connect_rsd,
            connectLockdown: misagent_connect,
            cleanup: misagent_client_free,
            serviceName: "misagent"
        ) { client in
            try profile.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    verboseLog("[IdeviceGateway] installProvisioningProfile() calling misagent_install")
                    let installErr = misagent_install(client, baseAddress, profile.count)
                    if let installErr = installErr {
                        let msg = self.getErrorMessage(from: installErr)
                        debugLog("[IdeviceGateway] installProvisioningProfile() misagent_install failed: \(msg)")
                        defer { safeFreeError(installErr) }
                        throw IdeviceGatewayError(.serviceError, reason: "Failed to install profile, error: (\(msg))")
                    }
                    debugLog("[IdeviceGateway] installProvisioningProfile() misagent_install succeeded")
                }
            }
        }
    }

    private func syncRemoveProvisioningProfile(id: String) throws {
        debugLog("[IdeviceGateway] removeProvisioningProfile() called, id: \(id)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: misagent_connect_rsd,
            connectLockdown: misagent_connect,
            cleanup: misagent_client_free,
            serviceName: "misagent"
        ) { client in
            try id.withCString { idPtr in
                verboseLog("[IdeviceGateway] removeProvisioningProfile() calling misagent_remove")
                let removeErr = misagent_remove(client, idPtr)
                if let removeErr = removeErr {
                    let msg = self.getErrorMessage(from: removeErr)
                    debugLog("[IdeviceGateway] removeProvisioningProfile() misagent_remove failed: \(msg)")
                    defer { safeFreeError(removeErr) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to remove profile, error: (\(msg))")
                }
                debugLog("[IdeviceGateway] removeProvisioningProfile() misagent_remove succeeded")
            }
        }
    }

    private func syncRemoveApp(bundleId: String) throws {
        debugLog("[IdeviceGateway] removeApp() called, bundleId: \(bundleId)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: installation_proxy_connect_rsd,
            connectLockdown: installation_proxy_connect,
            cleanup: installation_proxy_client_free,
            serviceName: "instproxy"
        ) { client in
            try bundleId.withCString { bundleIdPtr in
                verboseLog("[IdeviceGateway] removeApp() calling installation_proxy_uninstall")
                let uninstallErr = installation_proxy_uninstall(client, bundleIdPtr, nil)
                if let uninstallErr = uninstallErr {
                    let msg = self.getErrorMessage(from: uninstallErr)
                    debugLog("[IdeviceGateway] removeApp() installation_proxy_uninstall failed: \(msg)")
                    defer { idevice_error_free(uninstallErr) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to uninstall app, error: (\(msg))")
                }
                debugLog("[IdeviceGateway] removeApp() installation_proxy_uninstall succeeded")
            }
        }
    }

    private func syncsendIpaAfc(bundleId: String, ipaBytes: Data) throws {
        debugLog("[IdeviceGateway] sendIpaAfc() called, bundleId: \(bundleId), ipaBytes size: \(ipaBytes.count)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: afc_client_connect_rsd,
            connectLockdown: afc_client_connect,
            cleanup: afc_client_free,
            serviceName: "AFC client"
        ) { client in
            // Ensure directory
            let stagingDir = MinimuxerConstants.pkgPath
            verboseLog("[IdeviceGateway] sendIpaAfc() creating directory: \(stagingDir)")
            _ = stagingDir.withCString { dirPtr in
                afc_make_directory(client, dirPtr)
            }
            let bundleDir = "\(stagingDir)/\(bundleId)"
            verboseLog("[IdeviceGateway] sendIpaAfc() creating directory: \(bundleDir)")
            _ = bundleDir.withCString { dirPtr in
                afc_make_directory(client, dirPtr)
            }
 
            let path = "\(bundleDir)/app.ipa"
            var fileHandle: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] sendIpaAfc() opening remote file: \(path)")
            let openErr = path.withCString { pathPtr in
                afc_file_open(client, pathPtr, AfcFopenMode(rawValue: 4), &fileHandle) // WrOnly/Wr mode
            }
            if let openErr = openErr {
                let msg = self.getErrorMessage(from: openErr)
                debugLog("[IdeviceGateway] sendIpaAfc() afc_file_open failed: \(msg)")
                defer { idevice_error_free(openErr) }
                throw IdeviceGatewayError(.serviceError, reason: "Failed to open remote AFC file, error: (\(msg))")
            }
            defer {
                verboseLog("[IdeviceGateway] sendIpaAfc() closing remote file handle")
                afc_file_close(fileHandle)
            }
 
            try ipaBytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    verboseLog("[IdeviceGateway] sendIpaAfc() writing data to AFC file")
                    let writeErr = afc_file_write(fileHandle, baseAddress, ipaBytes.count)
                    if let writeErr = writeErr {
                        let msg = self.getErrorMessage(from: writeErr)
                        debugLog("[IdeviceGateway] sendIpaAfc() afc_file_write failed: \(msg)")
                        defer { idevice_error_free(writeErr) }
                        throw IdeviceGatewayError(.serviceError, reason: "Failed to write to AFC file, error: (\(msg))")
                    }
                    debugLog("[IdeviceGateway] sendIpaAfc() afc_file_write succeeded")
                }
            }
        }
    }

    private func syncInstallIpa(bundleId: String) throws {
        debugLog("[IdeviceGateway] installIpa() called, bundleId: \(bundleId)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: installation_proxy_connect_rsd,
            connectLockdown: installation_proxy_connect,
            cleanup: installation_proxy_client_free,
            serviceName: "instproxy"
        ) { client in
            let path = "PublicStaging/\(bundleId)/app.ipa"
            try path.withCString { pathPtr in
                verboseLog("[IdeviceGateway] installIpa() calling installation_proxy_install for path: \(path)")
                let installErr = installation_proxy_install(client, pathPtr, nil)
                if let installErr = installErr {
                    let msg = self.getErrorMessage(from: installErr)
                    debugLog("[IdeviceGateway] installIpa() installation_proxy_install failed: \(msg)")
                    defer { idevice_error_free(installErr) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to install IPA, error: (\(msg))")
                }
                debugLog("[IdeviceGateway] installIpa() installation_proxy_install succeeded")
            }
        }
    }

    private func syncsendAppBundleAfc(bundleId: String, appURL: URL) throws {
        debugLog("[IdeviceGateway] sendAppBundleAfc() called, bundleId: \(bundleId), appURL: \(appURL.path)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: afc_client_connect_rsd,
            connectLockdown: afc_client_connect,
            cleanup: afc_client_free,
            serviceName: "AFC client"
        ) { client in
            let stagingDir = MinimuxerConstants.pkgPath
            verboseLog("[IdeviceGateway] sendAppBundleAfc() creating directory: \(stagingDir)")
            _ = stagingDir.withCString { dirPtr in
                afc_make_directory(client, dirPtr)
            }
            let bundleDir = "\(stagingDir)/\(bundleId)"
            verboseLog("[IdeviceGateway] sendAppBundleAfc() creating directory: \(bundleDir)")
            _ = bundleDir.withCString { dirPtr in
                afc_make_directory(client, dirPtr)
            }
            let remoteAppPath = "\(bundleDir)/\(appURL.lastPathComponent)"
            verboseLog("[IdeviceGateway] sendAppBundleAfc() creating directory: \(remoteAppPath)")
            _ = remoteAppPath.withCString { dirPtr in
                afc_make_directory(client, dirPtr)
            }

            let fileManager = FileManager.default
            guard let enumerator = fileManager.enumerator(
                at: appURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else {
                throw IdeviceGatewayError(.serviceError, reason: "Failed to enumerate \(appURL.path)")
            }

            for case let fileURL as URL in enumerator {
                let relativePath = fileURL.path.replacingOccurrences(of: appURL.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let remoteItemPath = "\(remoteAppPath)/\(relativePath)"

                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)

                if isDirectory.boolValue {
                    _ = remoteItemPath.withCString { pathPtr in
                        afc_make_directory(client, pathPtr)
                    }
                } else {
                    var fileHandle: OpaquePointer? = nil
                    let openErr = remoteItemPath.withCString { pathPtr in
                        afc_file_open(client, pathPtr, AfcFopenMode(rawValue: 4), &fileHandle)
                    }
                    if let openErr = openErr {
                        let msg = self.getErrorMessage(from: openErr)
                        defer { idevice_error_free(openErr) }
                        throw IdeviceGatewayError(.serviceError, reason: "Failed to open remote AFC file \(remoteItemPath): \(msg)")
                    }
                    defer {
                        if let fileHandle = fileHandle {
                            afc_file_close(fileHandle)
                        }
                    }

                    let fileData = try Data(contentsOf: fileURL, options: .alwaysMapped)
                    if !fileData.isEmpty {
                        try fileData.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                            if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                                let writeErr = afc_file_write(fileHandle, baseAddress, fileData.count)
                                if let writeErr = writeErr {
                                    let msg = self.getErrorMessage(from: writeErr)
                                    defer { idevice_error_free(writeErr) }
                                    throw IdeviceGatewayError(.serviceError, reason: "Failed to write to AFC file \(remoteItemPath): \(msg)")
                                }
                            }
                        }
                    }
                }
            }
            debugLog("[IdeviceGateway] sendAppBundleAfc() uploaded \(appURL.lastPathComponent) successfully")
        }
    }

    private func syncInstallAppBundle(bundleId: String, appName: String) throws {
        debugLog("[IdeviceGateway] installAppBundle() called, bundleId: \(bundleId), appName: \(appName)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: installation_proxy_connect_rsd,
            connectLockdown: installation_proxy_connect,
            cleanup: installation_proxy_client_free,
            serviceName: "instproxy"
        ) { client in
            let path = "\(MinimuxerConstants.pkgPath)/\(bundleId)/\(appName)"
            try path.withCString { pathPtr in
                verboseLog("[IdeviceGateway] installAppBundle() calling installation_proxy_install for path: \(path)")
                let options = plist_new_dict()
                defer { plist_free(options) }
                plist_dict_set_item(options, "PackageType", plist_new_string("Developer"))

                let installErr = installation_proxy_install(client, pathPtr, options)
                if let installErr = installErr {
                    let msg = self.getErrorMessage(from: installErr)
                    debugLog("[IdeviceGateway] installAppBundle() installation_proxy_install failed: \(msg)")
                    defer { idevice_error_free(installErr) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to install App directory, error: (\(msg))")
                }
                debugLog("[IdeviceGateway] installAppBundle() installation_proxy_install succeeded")
            }
        }
    }

    private func getAppPaths(appId: String) throws -> (container: String, bundlePath: String) {
        debugLog("[IdeviceGateway] getAppPaths() called, appId: \(appId)")
        return try performWithEitherService(
            connectRP: installation_proxy_connect_rsd,
            connectLockdown: installation_proxy_connect,
            cleanup: installation_proxy_client_free,
            serviceName: "instproxy"
        ) { client in
            var outResult: UnsafeMutableRawPointer? = nil
            var outLen: Int = 0
            
            try appId.withCString { appPtr in
                var bundleIds: [UnsafePointer<Int8>?] = [appPtr]
                verboseLog("[IdeviceGateway] getAppPaths() calling installation_proxy_get_apps")
                let err = installation_proxy_get_apps(client, nil, &bundleIds, 1, &outResult, &outLen)
                if let err = err {
                    let msg = self.getErrorMessage(from: err)
                    debugLog("[IdeviceGateway] getAppPaths() installation_proxy_get_apps failed: \(msg)")
                    defer { idevice_error_free(err) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to lookup app paths, error: (\(msg))")
                }
            }
            
            verboseLog("[IdeviceGateway] getAppPaths() installation_proxy_get_apps returned outLen: \(outLen)")
            guard let resultPtr = outResult, outLen > 0 else {
                verboseLog("[IdeviceGateway] getAppPaths() app not found")
                throw IdeviceGatewayError(.serviceError, reason: "App not found: \(appId)")
            }
            
            let plistArray = resultPtr.assumingMemoryBound(to: plist_t?.self)
            var container = ""
            var bundlePath = ""
            
            for i in 0..<outLen {
                if let plistVal = plistArray[i] {
                    // Container
                    let containerPlist = plist_dict_get_item(plistVal, "Container")
                    if let containerPlist = containerPlist {
                        if let ptr = getRustPlistString(containerPlist) {
                            container = ptr
                            verboseLog("[IdeviceGateway] getAppPaths() found Container path: \(container)")
                        }
                    }
                    
                    // Path
                    let pathPlist = plist_dict_get_item(plistVal, "Path")
                    if let pathPlist = pathPlist {
                        if let ptr = getRustPlistString(pathPlist) {
                            bundlePath = ptr
                            verboseLog("[IdeviceGateway] getAppPaths() found Path: \(bundlePath)")
                        }
                    }
                }
            }
            free(outResult)
            
            if container.isEmpty || bundlePath.isEmpty {
                debugLog("[IdeviceGateway] getAppPaths() container or bundlePath is empty")
                throw IdeviceGatewayError(.serviceError, reason: "Failed to resolve app paths")
            }
            return (container, bundlePath)
        }
    }
    
    private func sendDebugProxyCommand(client: OpaquePointer, name: String, args: [String]) throws {
        debugLog("[IdeviceGateway] sendDebugProxyCommand() called, name: \(name), args: \(args)")
        try name.withCString { namePtr in
            var argPtrs = args.map { UnsafePointer<Int8>(strdup($0)) }
            defer {
                for ptr in argPtrs {
                    free(UnsafeMutablePointer(mutating: ptr))
                }
            }
            
            let cmdHandle = debugserver_command_new(namePtr, &argPtrs, UInt(argPtrs.count))
            if let cmdHandle = cmdHandle {
                defer { debugserver_command_free(cmdHandle) }
                var response: UnsafeMutablePointer<Int8>? = nil
                verboseLog("[IdeviceGateway] sendDebugProxyCommand() sending command \(name)")
                let sendErr = debug_proxy_send_command(client, cmdHandle, &response)
                if let sendErr = sendErr {
                    let msg = self.getErrorMessage(from: sendErr)
                    debugLog("[IdeviceGateway] sendDebugProxyCommand() failed for command \(name): \(msg)")
                    defer { idevice_error_free(sendErr) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to send command to debug proxy: \(name), error: (\(msg))")
                }
                if let response = response {
                    let respStr = String(cString: response)
                    verboseLog("[IdeviceGateway] sendDebugProxyCommand() got response: \(respStr)")
                    free(response)
                } else {
                    debugLog("[IdeviceGateway] sendDebugProxyCommand() got empty response")
                }
            } else {
                debugLog("[IdeviceGateway] sendDebugProxyCommand() failed to construct command \(name)")
                throw IdeviceGatewayError(.serviceError, reason: "Failed to construct debug proxy command: \(name)")
            }
        }
    }
    
    private func launchAppPre17(appId: String) throws {
        debugLog("[IdeviceGateway] launchAppPre17() called for appId: \(appId)")
        let (container, bundlePath) = try getAppPaths(appId: appId)
        
        try performWithEitherService(
            connectRP: lockdownd_connect_rsd,
            connectLockdown: lockdownd_connect,
            cleanup: lockdownd_client_free,
            serviceName: "lockdownd"
        ) { lockdownClient in
            var port: UInt16 = 0
            var ssl: Bool = false
            
            verboseLog("[IdeviceGateway] launchAppPre17() starting debugserver service")
            let err = "com.apple.debugserver".withCString { serviceNamePtr in
                return lockdownd_start_service(lockdownClient, serviceNamePtr, &port, &ssl)
            }
            if let err = err {
                let msg = self.getErrorMessage(from: err)
                debugLog("[IdeviceGateway] launchAppPre17() failed to start debugserver: \(msg)")
                defer { idevice_error_free(err) }
                throw IdeviceGatewayError(.serviceError, reason: "Failed to start debugserver service, error: (\(msg))")
            }
            debugLog("[IdeviceGateway] launchAppPre17() debugserver started on port: \(port)")
            
            var addr: OpaquePointer? = nil
            var addrErr = idevice_usbmuxd_default_addr_new(&addr)
            if let addrErr = addrErr {
                debugLog("[IdeviceGateway] launchAppPre17() default_addr_new failed")
                defer { idevice_error_free(addrErr) }
                throw IdeviceGatewayError(.connectionFailed, reason: "Failed to get usbmuxd default addr")
            }
            guard let addr = addr else {
                debugLog("[IdeviceGateway] launchAppPre17() usbmuxd default addr is nil")
                throw IdeviceGatewayError(.connectionFailed, reason: "Usbmuxd default addr was nil")
            }
            defer { idevice_usbmuxd_addr_free(addr) }
            
            var conn: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] launchAppPre17() creating default usbmuxd connection")
            let connErr = idevice_usbmuxd_new_default_connection(0, &conn)
            if let connErr = connErr {
                debugLog("[IdeviceGateway] launchAppPre17() new_default_connection failed")
                defer { idevice_error_free(connErr) }
                throw IdeviceGatewayError(.connectionFailed, reason: "Failed to create usbmuxd connection")
            }
            guard let conn = conn else {
                debugLog("[IdeviceGateway] launchAppPre17() usbmuxd connection is nil")
                throw IdeviceGatewayError(.connectionFailed, reason: "Usbmuxd connection was nil")
            }
            var connNeedsFree = true
            defer {
                if connNeedsFree {
                    idevice_usbmuxd_connection_free(conn)
                }
            }
            
            var devices: UnsafeMutablePointer<OpaquePointer?>? = nil
            var count: Int32 = 0
            let devErr = idevice_usbmuxd_get_devices(conn, &devices, &count)
            if let devErr = devErr {
                debugLog("[IdeviceGateway] launchAppPre17() get_devices failed")
                defer { idevice_error_free(devErr) }
                throw IdeviceGatewayError(.connectionFailed, reason: "Failed to list usbmuxd devices")
            }
            
            guard count > 0, let devicesPtr = devices, let firstDev = devicesPtr.pointee else {
                verboseLog("[IdeviceGateway] launchAppPre17() no devices found on usbmuxd")
                throw IdeviceGatewayError(.connectionFailed, reason: "No devices found on usbmuxd")
            }
            defer { idevice_usbmuxd_device_list_free(devices, count) }
            
            let deviceID = idevice_usbmuxd_device_get_device_id(firstDev)
            verboseLog("[IdeviceGateway] launchAppPre17() connecting to deviceID \(deviceID) debugserver port \(port)")
            
            var debugDevice: OpaquePointer? = nil
            let connectErr = "minimuxer-debug".withCString { labelPtr in
                return idevice_usbmuxd_connect_to_device(conn, deviceID, port, labelPtr, &debugDevice)
            }
            if let connectErr = connectErr {
                debugLog("[IdeviceGateway] launchAppPre17() connect_to_device failed")
                defer { idevice_error_free(connectErr) }
                throw IdeviceGatewayError(.connectionFailed, reason: "Failed to connect to debugserver port \(port)")
            }
            connNeedsFree = false
            
            guard let debugDevice = debugDevice else {
                debugLog("[IdeviceGateway] launchAppPre17() debug device handle is nil")
                throw IdeviceGatewayError(.connectionFailed, reason: "Debug device handle was nil")
            }
            var debugDeviceNeedsFree = true
            defer {
                if debugDeviceNeedsFree {
                    idevice_free(debugDevice)
                }
            }
            
            var stream: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] launchAppPre17() converting debug device connection to stream")
           let streamErr = idevice_to_stream(debugDevice, &stream)
           if let streamErr = streamErr {
               debugLog("[IdeviceGateway] launchAppPre17() idevice_to_stream failed")
               defer { idevice_error_free(streamErr) }
               throw IdeviceGatewayError(.serviceError, reason: "Failed to convert device connection to stream")
           }
            debugDeviceNeedsFree = false
            
            guard let stream = stream else {
                debugLog("[IdeviceGateway] launchAppPre17() stream is nil")
                throw IdeviceGatewayError(.serviceError, reason: "Stream was nil")
            }
            var streamNeedsFree = true
            defer {
                if streamNeedsFree {
                    idevice_stream_free(stream)
                }
            }
            
            var debugProxyClient: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] launchAppPre17() creating debug proxy client")
            let proxyErr = debug_proxy_new(stream, &debugProxyClient)
            if let proxyErr = proxyErr {
                let msg = self.getErrorMessage(from: proxyErr)
                debugLog("[IdeviceGateway] launchAppPre17() debug_proxy_new failed: \(msg)")
                defer { idevice_error_free(proxyErr) }
                throw IdeviceGatewayError(.serviceError, reason: "Failed to create debug proxy client, error: (\(msg))")
            }
            streamNeedsFree = false
            
            guard let debugProxyClient = debugProxyClient else {
                debugLog("[IdeviceGateway] launchAppPre17() debugProxyClient is nil")
                throw IdeviceGatewayError(.serviceError, reason: "Debug proxy client was nil")
            }
            defer { debug_proxy_free(debugProxyClient) }
            
            verboseLog("[IdeviceGateway] launchAppPre17() configuring debug proxy workspace")
            try self.sendDebugProxyCommand(client: debugProxyClient, name: "QSetMaxPacketSize", args: ["\(MinimuxerConstants.maxPacketSize)"])
            try self.sendDebugProxyCommand(client: debugProxyClient, name: "QSetWorkingDir", args: [container])
            
            try bundlePath.withCString { bundlePathPtr in
                var argvptrs: [UnsafePointer<Int8>?] = [bundlePathPtr, bundlePathPtr]
                var response: UnsafeMutablePointer<Int8>? = nil
                verboseLog("[IdeviceGateway] launchAppPre17() setting argv for \(bundlePath)")
                let argvErr = debug_proxy_set_argv(debugProxyClient, &argvptrs, UInt(argvptrs.count), &response)
                if let argvErr = argvErr {
                    let msg = self.getErrorMessage(from: argvErr)
                    debugLog("[IdeviceGateway] launchAppPre17() debug_proxy_set_argv failed: \(msg)")
                    defer { idevice_error_free(argvErr) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to set debug proxy argv, error: (\(msg))")
                }
                if let response = response {
                    let respStr = String(cString: response)
                    verboseLog("[IdeviceGateway] launchAppPre17() argv response: \(respStr)")
                    free(response)
                }
            }
            
            verboseLog("[IdeviceGateway] launchAppPre17() launching application")
            try self.sendDebugProxyCommand(client: debugProxyClient, name: "qLaunchSuccess", args: [])
            try self.sendDebugProxyCommand(client: debugProxyClient, name: "D", args: [])
            debugLog("[IdeviceGateway] launchAppPre17() app launched successfully")
        }
    }

    private func getDummyffiError() -> UnsafeMutablePointer<IdeviceFfiError>? {
        debugLog("[IdeviceGateway] getDummyffiError() called")
        var client: OpaquePointer? = nil
        let err = lockdownd_connect(nil, &client)
        debugLog("[IdeviceGateway] getDummyffiError() returned: \(String(describing: err))")
        return err
    }

    private func syncDebugApp(appId: String) throws {
        debugLog("[IdeviceGateway] debugApp() called, appId: \(appId)")
        try verifyInitialized()
        guard let versionStr = try syncGetLockdownValue(key: "ProductVersion"),
              let majorStr = versionStr.split(separator: ".").first,
              let major = Int(majorStr) else {
            debugLog("[IdeviceGateway] debugApp() failed to get ProductVersion")
            throw IdeviceGatewayError(.serviceError, reason: "Failed to get product version for JIT")
        }
        
        verboseLog("[IdeviceGateway] debugApp() ProductVersion major: \(major)")
        if major < 17 {
            try launchAppPre17(appId: appId)
        } else {
            try performWithEitherService(
                connectRP: debug_proxy_connect_rsd,
                connectLockdown: { [weak self] _, _ in
                    debugLog("[IdeviceGateway] debugApp() lockdown placeholder called")
                    return self?.getDummyffiError()
                },
                cleanup: debug_proxy_free,
                serviceName: "debug proxy"
            ) { client in
                debugLog("[IdeviceGateway] debugApp() connection validation succeeded")
            }
        }
    }

    private func syncDebugProcess(pid: UInt32) throws {
        debugLog("[IdeviceGateway] debugProcess() called, pid: \(pid)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: debug_proxy_connect_rsd,
            connectLockdown: { [weak self] _, _ in
                debugLog("[IdeviceGateway] debugProcess() lockdown placeholder called")
                return self?.getDummyffiError()
            },
            cleanup: debug_proxy_free,
            serviceName: "debug proxy"
        ) { client in
            let commands = [("vAttach", [String(format: "%02X", pid)]), ("D", [])]
            for (name, args) in commands {
                try sendDebugProxyCommand(client: client, name: name, args: args)
            }
        }
    }

    private func syncDumpProfiles(docsPath: String) throws -> String {
        debugLog("[IdeviceGateway] dumpProfiles() called, docsPath: \(docsPath)")
        try verifyInitialized()
        return try performWithEitherService(
            connectRP: misagent_connect_rsd,
            connectLockdown: misagent_connect,
            cleanup: misagent_client_free,
            serviceName: "misagent"
        ) { client in
            var outProfiles: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>? = nil
            var outProfilesLen: UnsafeMutablePointer<Int>? = nil
            var outCount: Int = 0

            verboseLog("[IdeviceGateway] dumpProfiles() calling misagent_copy_all")
            let copyErr = misagent_copy_all(client, &outProfiles, &outProfilesLen, &outCount)
            if let copyErr = copyErr {
                let msg = self.getErrorMessage(from: copyErr)
                debugLog("[IdeviceGateway] dumpProfiles() misagent_copy_all failed: \(msg)")
                defer { idevice_error_free(copyErr) }
                throw IdeviceGatewayError(.serviceError, reason: "Failed to copy profiles from misagent, error: (\(msg))")
            }

            let path = docsPath.hasPrefix("file://") ? String(docsPath.dropFirst(7)) : docsPath
            let dumpDir = "\(path)/PROVISION"
            verboseLog("[IdeviceGateway] dumpProfiles() writing profiles to: \(dumpDir), count: \(outCount)")
            try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)

            if let outProfiles = outProfiles, let outProfilesLen = outProfilesLen, outCount > 0 {
                let xmlPrefix = "<?xml version=".data(using: .utf8)!
                let xmlSuffix = "</plist>".data(using: .utf8)!

                for i in 0..<outCount {
                    guard let profPtr = outProfiles[i] else { continue }
                    let len = outProfilesLen[i]
                    let profileData = Data(bytes: profPtr, count: len)

                    guard let prefixRange = profileData.range(of: xmlPrefix) else { continue }
                    guard let suffixRange = profileData.range(of: xmlSuffix, options: [], in: prefixRange.lowerBound..<profileData.count) else { continue }

                    let plistBytes = profileData.subdata(in: prefixRange.lowerBound..<suffixRange.upperBound)

                    if let innerPlist = try? PropertyListSerialization.propertyList(from: plistBytes, options: [], format: nil) as? [String: Any],
                       let uuid = innerPlist["UUID"] as? String {
                        try? profileData.write(to: URL(fileURLWithPath: "\(dumpDir)/\(uuid).mobileprovision"))
                        try? plistBytes.write(to: URL(fileURLWithPath: "\(dumpDir)/\(uuid).plist"))
                    } else {
                        try? profileData.write(to: URL(fileURLWithPath: "\(dumpDir)/unknown_\(i).mobileprovision"))
                    }
                }
                misagent_free_profiles(outProfiles, outProfilesLen, outCount)
            }
            debugLog("[IdeviceGateway] dumpProfiles() complete")
            return dumpDir
        }
    }

    private func syncPerformHeartbeat(interval: UInt64, newInterval: UnsafeMutablePointer<UInt64>) throws {
       debugLog("[IdeviceGateway] performHeartbeat() called, interval: \(interval)")
       try verifyInitialized()
       try performWithEitherService(
           connectRP: heartbeat_connect_rsd,
           connectLockdown: heartbeat_connect,
           cleanup: heartbeat_client_free,
           serviceName: "heartbeat"
       ) { client in
           verboseLog("[IdeviceGateway] performHeartbeat() calling heartbeat_get_marco")
           let getErr = heartbeat_get_marco(client, interval, newInterval)
           if let getErr = getErr {
               let msg = self.getErrorMessage(from: getErr)
               debugLog("[IdeviceGateway] performHeartbeat() heartbeat_get_marco failed: \(msg)")
               defer { idevice_error_free(getErr) }
               throw IdeviceGatewayError(.serviceError, reason: "Heartbeat receive failed, error: (\(msg))")
           }
           verboseLog("[IdeviceGateway] performHeartbeat() calling heartbeat_send_polo")
           let sendErr = heartbeat_send_polo(client)
           if let sendErr = sendErr {
               let msg = self.getErrorMessage(from: sendErr)
               debugLog("[IdeviceGateway] performHeartbeat() heartbeat_send_polo failed: \(msg)")
               defer { idevice_error_free(sendErr) }
               throw IdeviceGatewayError(.serviceError, reason: "Heartbeat send failed, error: (\(msg))")
           }
           debugLog("[IdeviceGateway] performHeartbeat() succeeded, newInterval: \(newInterval.pointee)")
       }
    }

    private func syncMountPersonalizedDdi(image: Data, trustcache: Data, manifest: Data) throws {
        debugLog("[IdeviceGateway] mountPersonalizedDdi() called, image size: \(image.count), trustcache size: \(trustcache.count), manifest size: \(manifest.count)")
        try verifyInitialized()

        if pairingFileType == .rppairing {
            try mountPersonalizedDdiRsd(image: image, trustcache: trustcache, manifest: manifest)
            return
        }

        try mountPersonalizedDdiIdevice(image: image, trustcache: trustcache, manifest: manifest)
    }

    private func mountPersonalizedDdiRsd(image: Data, trustcache: Data, manifest: Data) throws {
        var chipID: UInt64 = 0
        try performWithService(connect: lockdownd_connect_rsd, cleanup: { client in
            lockdownd_client_free(client)
        }, serviceName: "lockdownd") { lockdownClient in
            var plistVal: plist_t? = nil
            verboseLog("[IdeviceGateway] mountPersonalizedDdiRsd() getting UniqueChipID")
            let valErr = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &plistVal)
            if let valErr = valErr {
                debugLog("[IdeviceGateway] mountPersonalizedDdiRsd() lockdownd_get_value failed")
                defer { idevice_error_free(valErr) }
                throw IdeviceGatewayError(.serviceError, reason: "Failed to get UniqueChipID")
            }
            if let plistVal = plistVal {
                defer { plist_free(plistVal) }
                var val: UInt64 = 0
                plist_get_uint_val(plistVal, &val)
                chipID = val
                verboseLog("[IdeviceGateway] mountPersonalizedDdiRsd() got chipID: \(chipID)")
            }
        }

        try performWithService(connect: image_mounter_connect_rsd, cleanup: image_mounter_free, serviceName: "image mounter") { mounterClient in
//            if try isDeveloperDiskImageMounted(mounterClient: mounterClient) {
//                verboseLog("[IdeviceGateway] DeveloperDiskImage already mounted. Bypassing personalization.")
//                return
//            }
            try image.withUnsafeBytes { imgBuf in
                try trustcache.withUnsafeBytes { tcBuf in
                    try manifest.withUnsafeBytes { manBuf in
                        verboseLog("[IdeviceGateway] mountPersonalizedDdiRsd() mounting image on Remote Pairing client")
                        let mountErr = image_mounter_mount_personalized_rsd(
                            mounterClient,
                            adapter,
                            handshake,
                            imgBuf.bindMemory(to: UInt8.self).baseAddress,
                            image.count,
                            tcBuf.bindMemory(to: UInt8.self).baseAddress,
                            trustcache.count,
                            manBuf.bindMemory(to: UInt8.self).baseAddress,
                            manifest.count,
                            nil,
                            chipID
                        )
                        if let mountErr = mountErr {
                            let msg = self.getErrorMessage(from: mountErr)
                            debugLog("[IdeviceGateway] mountPersonalizedDdiRsd() mount failed: code=\(mountErr.pointee.code), message=\(msg)")
                            defer { idevice_error_free(mountErr) }
                            throw IdeviceGatewayError(.serviceError, reason: "Failed to mount personalized DDI, error: (\(msg))")
                        }
                        debugLog("[IdeviceGateway] mountPersonalizedDdiRsd() mount succeeded")
                    }
                }
            }
        }
    }

    private func mountPersonalizedDdiIdevice(image: Data, trustcache: Data, manifest: Data) throws {
        verboseLog("[IdeviceGateway] mountPersonalizedDdiIdevice() starting traditional/TCP provider mounting")

        guard let deviceEndpointIp = deviceEndpointIp else {
            debugLog("[IdeviceGateway] mountPersonalizedDdiIdevice() failed because deviceEndpointIp is nil")
            throw IdeviceGatewayError(.deviceEndpointIpNotAvailable)
        }



        guard let pairingFileData = self.pairingFileData else {
            debugLog("[IdeviceGateway] error: pairingFileData is nil")
            throw IdeviceGatewayError(.connectionFailed, reason: "pairingFileData is nil")
        }

        var tempPairingFile: OpaquePointer? = nil
        let parseErr = pairingFileData.withUnsafeBytes { buf in
            return idevice_pairing_file_from_bytes(buf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt(pairingFileData.count), &tempPairingFile)
        }
        if let parseErr = parseErr {
            let msg = self.getErrorMessage(from: parseErr)
            debugLog("[IdeviceGateway] error: Failed to parse temporary pairing file: \(msg)")
            defer { safeFreeError(parseErr) }
            throw IdeviceGatewayError(.connectionFailed, reason: "Failed to parse temporary pairing file: \(msg)")
        }
        guard let tempPairingFile = tempPairingFile else {
            throw IdeviceGatewayError(.connectionFailed, reason: "Temporary pairing file was nil")
        }

        verboseLog("[IdeviceGateway] creating TCP provider to \(deviceEndpointIp):\(MinimuxerConstants.lockdowndPort)...")
        var provider: OpaquePointer? = nil
        let provErr = try withSockaddr(ip: deviceEndpointIp, port: MinimuxerConstants.lockdowndPort) { sockaddrPtr, _ in
            sockaddrPtr.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { reboundPtr in
                return idevice_tcp_provider_new(reboundPtr, tempPairingFile, MinimuxerConstants.appName, &provider)
            }
        }
        if let provErr = provErr {
            debugLog("[IdeviceGateway] error: Failed to create TCP provider")
            defer { safeFreeError(provErr) }
            throw IdeviceGatewayError(.connectionFailed, reason: "Failed to create TCP provider")
        }
        guard let provider = provider else {
            debugLog("[IdeviceGateway] error: TCP Provider was nil")
            throw IdeviceGatewayError(.connectionFailed, reason: "TCP Provider was nil")
        }

        var providerToFree: OpaquePointer? = provider
        defer {
            if let ptr = providerToFree {
                idevice_provider_free(ptr)
            }
        }

        var chipID: UInt64 = 0
        do {
            verboseLog("[IdeviceGateway] connecting lockdownd...")
            var lockdownClient: OpaquePointer? = nil
            let connectErr = lockdownd_connect(provider, &lockdownClient)
            if let connectErr = connectErr {
                debugLog("[IdeviceGateway] error: lockdownd_connect failed")
                providerToFree = nil
                defer { idevice_error_free(connectErr) }
                throw IdeviceGatewayError(.noConnection)
            }
            guard let lockdownClient = lockdownClient else {
                debugLog("[IdeviceGateway] error: lockdownClient was nil after connect")
                throw IdeviceGatewayError(.noConnection)
            }
            defer {
                verboseLog("[IdeviceGateway] mountPersonalizedDdiIdevice() freeing lockdown client before mounter connect")
                lockdownd_client_free(lockdownClient)
            }

            var plistVal: plist_t? = nil
            verboseLog("[IdeviceGateway] querying UniqueChipID from lockdown...")
            let valErr = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &plistVal)
            if let valErr = valErr {
                verboseLog("[IdeviceGateway] No existing lockdown session exists, starting new session...")
                idevice_error_free(valErr)
                var pf: OpaquePointer? = nil
                let getPfErr = idevice_provider_get_pairing_file(provider, &pf)
                if let getPfErr = getPfErr {
                    defer { idevice_error_free(getPfErr) }
                    throw IdeviceGatewayError(.connectionFailed, reason: "Failed to get pairing file for session retry")
                }
                guard let pf = pf else {
                    throw IdeviceGatewayError(.connectionFailed, reason: "Pairing file nil for session retry")
                }
                defer { idevice_pairing_file_free(pf) }
                let sessionErr = lockdownd_start_session(lockdownClient, pf)
                if let sessionErr = sessionErr {
                    debugLog("[IdeviceGateway] error: lockdownd_start_session failed")
                    defer { idevice_error_free(sessionErr) }
                    throw IdeviceGatewayError(.noConnection)
                }
                verboseLog("[IdeviceGateway] session started. Querying UniqueChipID again...")
                let valErr2 = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &plistVal)
                if let valErr2 = valErr2 {
                    debugLog("[IdeviceGateway] error: lockdownd_get_value failed with session too")
                    defer { idevice_error_free(valErr2) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to get UniqueChipID")
                }
            }
            if let plistVal = plistVal {
                defer { plist_free(plistVal) }
                if plist_dict_get_item(plistVal, "Error") != nil {
                    debugLog("[IdeviceGateway] error: UniqueChipID returned error plist")
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to get UniqueChipID: Prohibited")
                }
                var val: UInt64 = 0
                plist_get_uint_val(plistVal, &val)
                chipID = val
                verboseLog("[IdeviceGateway] UniqueChipID (chipID) = \(chipID)")
            }
        }

        verboseLog("[IdeviceGateway] connecting to image mounter service...")
        var mounterClient: OpaquePointer? = nil
        let mounterConnectErr = image_mounter_connect(provider, &mounterClient)
        if let mounterConnectErr = mounterConnectErr {
            debugLog("[IdeviceGateway] error: image_mounter_connect failed")
            providerToFree = nil
            defer { idevice_error_free(mounterConnectErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to connect to image mounter")
        }
        guard let mounterClient = mounterClient else {
            debugLog("[IdeviceGateway] error: mounterClient was nil")
            throw IdeviceGatewayError(.serviceError, reason: "Mounter client was nil")
        }
        defer { image_mounter_free(mounterClient) }

//        if try isDeveloperDiskImageMounted(mounterClient: mounterClient) {
//            verboseLog("[IdeviceGateway] DeveloperDiskImage already mounted. Bypassing personalization.")
//            return
//        }

        try image.withUnsafeBytes { imgBuf in
            try trustcache.withUnsafeBytes { tcBuf in
                try manifest.withUnsafeBytes { manBuf in
                    verboseLog("[IdeviceGateway] mountPersonalizedDdiIdevice() mounting personalized image via idevice")
                    let mountErr = image_mounter_mount_personalized(
                        mounterClient,
                        provider,
                        imgBuf.bindMemory(to: UInt8.self).baseAddress,
                        image.count,
                        tcBuf.bindMemory(to: UInt8.self).baseAddress,
                        trustcache.count,
                        manBuf.bindMemory(to: UInt8.self).baseAddress,
                        manifest.count,
                        nil,
                        chipID
                    )
                    if let mountErr = mountErr {
                        let msg = self.getErrorMessage(from: mountErr)
                        debugLog("[IdeviceGateway] mountPersonalizedDdiIdevice() mount failed: code=\(mountErr.pointee.code), message=\(msg)")
                        defer { idevice_error_free(mountErr) }
                        throw IdeviceGatewayError(.serviceError, reason: "Failed to mount personalized DDI, error: (\(msg))")
                    }
                    verboseLog("[IdeviceGateway] mountPersonalizedDdiIdevice() mount succeeded")
                }
            }
        }
    }

    private func syncIsDDIMounted() throws -> Bool {
        debugLog("[IdeviceGateway] isDDIMounted() called")
        try verifyInitialized()
        return try performWithEitherService(
            connectRP: image_mounter_connect_rsd,
            connectLockdown: image_mounter_connect,
            cleanup: image_mounter_free,
            serviceName: "image mounter"
        ) { client in
            try isDeveloperDiskImageMounted(mounterClient: client)
        }
    }

    private func isDeveloperDiskImageMounted(mounterClient: OpaquePointer) throws -> Bool {
        var devicesPtr: UnsafeMutablePointer<plist_t?>? = nil
        var devicesLen: Int = 0
        let err = image_mounter_copy_devices(mounterClient, &devicesPtr, &devicesLen)
        if let err = err {
            let ffiErr = err.pointee
            let code = ffiErr.code
            let subCode = ffiErr.sub_code
            var msg = ""
            if let msgPtr = ffiErr.message {
                msg = String(cString: msgPtr)
            }
            debugLog("[IdeviceGateway] copy_devices failed: code=\(code), subCode=\(subCode), message=\(msg)")
            defer { idevice_error_free(err) }
            return false
        }
        guard let devicesPtr = devicesPtr, devicesLen > 0 else {
            return false
        }
        defer {
            for i in 0..<devicesLen {
                if let p = devicesPtr[i] {
                    plist_free(p)
                }
            }
            free(devicesPtr)
        }
        
        for i in 0..<devicesLen {
            guard let p = devicesPtr[i],
                  let xml = plistNodeToData(p),
                  let dict = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil) as? [String: Any]
            else { continue }
            
            let mountPath = dict["MountPath"] as? String
            let imageType = dict["PersonalizedImageType"] as? String
            let diskType = dict["DiskImageType"] as? String
            
            let mountPathMatches = mountPath == "/System/Developer"
            let imageTypeMatches = imageType == "DeveloperDiskImage"
            let diskTypeMatches = (diskType == nil || diskType == "Personalized")
            
            if mountPathMatches && imageTypeMatches && diskTypeMatches {
                return true
            }
        }
        return false
    }

    private func plistNodeToData(_ node: plist_t) -> Data? {
        var xmlPtr: UnsafeMutablePointer<Int8>? = nil
        var xmlLen: UInt32 = 0
        let err = plist_to_xml(node, &xmlPtr, &xmlLen)
        guard err == PLIST_ERR_SUCCESS, let xmlPtr else {
            return nil
        }
        defer { free(xmlPtr) }
        return Data(bytes: xmlPtr, count: Int(xmlLen))
    }

    private func syncMountDeveloperImage(image: Data, signature: Data) throws {
        debugLog("[IdeviceGateway] mountDeveloperImage() called, image size: \(image.count), signature size: \(signature.count)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: image_mounter_connect_rsd,
            connectLockdown: image_mounter_connect,
            cleanup: image_mounter_free,
            serviceName: "image mounter"
        ) { client in
            // 1. Upload
            try image.withUnsafeBytes { imgBuf in
                try signature.withUnsafeBytes { sigBuf in
                    verboseLog("[IdeviceGateway] mountDeveloperImage() uploading image")
                    let uploadErr = image_mounter_upload_image(
                        client,
                        "Developer",
                        imgBuf.bindMemory(to: UInt8.self).baseAddress,
                        image.count,
                        sigBuf.bindMemory(to: UInt8.self).baseAddress,
                        signature.count
                    )
                    if let uploadErr = uploadErr {
                        let msg = self.getErrorMessage(from: uploadErr)
                        debugLog("[IdeviceGateway] mountDeveloperImage() upload failed: \(msg)")
                        defer { idevice_error_free(uploadErr) }
                        throw IdeviceGatewayError(.serviceError, reason: "Failed to upload developer image, error: (\(msg))")
                    }
                    debugLog("[IdeviceGateway] mountDeveloperImage() upload succeeded")
                }
            }

            // 2. Mount
            try signature.withUnsafeBytes { sigBuf in
                verboseLog("[IdeviceGateway] mountDeveloperImage() mounting image")
                let mountErr = image_mounter_mount_image(
                    client,
                    "Developer",
                    sigBuf.bindMemory(to: UInt8.self).baseAddress,
                    signature.count,
                    nil,
                    0,
                    nil
                )
                if let mountErr = mountErr {
                    let msg = self.getErrorMessage(from: mountErr)
                    debugLog("[IdeviceGateway] mountDeveloperImage() mount failed: code=\(mountErr.pointee.code), message=\(msg)")
                    defer { idevice_error_free(mountErr) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to mount developer image, error: (\(msg))")
                }
                debugLog("[IdeviceGateway] mountDeveloperImage() mount succeeded")
            }
        }
    }

    private func generatePairingFile(hostName: String) throws -> (OpaquePointer, String) {
        var rpf: OpaquePointer? = nil
        verboseLog("[IdeviceGateway] generatePairingFile() generating pairing file")
        let genErr = rp_pairing_file_generate(hostName, &rpf)
        if let genErr = genErr {
            debugLog("[IdeviceGateway] generatePairingFile() rp_pairing_file_generate failed")
            defer { idevice_error_free(genErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to generate pairing file")
        }
        guard let rpf = rpf else {
            throw IdeviceGatewayError(.serviceError, reason: "Generated pairing file is nil")
        }

        var dataPtr: UnsafeMutablePointer<UInt8>? = nil
        var dataLen: UInt = 0
        verboseLog("[IdeviceGateway] generatePairingFile() serializing pairing file to bytes")
        let toBytesErr = rp_pairing_file_to_bytes(rpf, &dataPtr, &dataLen)
        if let toBytesErr = toBytesErr {
            debugLog("[IdeviceGateway] generatePairingFile() rp_pairing_file_to_bytes failed")
            defer { idevice_error_free(toBytesErr) }
            rp_pairing_file_free(rpf)
            throw IdeviceGatewayError(.serviceError, reason: "Failed to serialize pairing file to bytes")
        }

        var identifier = ""
        if let dataPtr = dataPtr {
            let plistData = Data(bytes: dataPtr, count: Int(dataLen))
            idevice_data_free(dataPtr, dataLen)
            if let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
                identifier = plist["identifier"] as? String ?? ""
                verboseLog("[IdeviceGateway] generatePairingFile() parsed identifier: \(identifier)")
            }
        }

        if identifier.isEmpty {
            debugLog("[IdeviceGateway] generatePairingFile() failed: parsed identifier is empty")
            rp_pairing_file_free(rpf)
            throw IdeviceGatewayError(.serviceError, reason: "Failed to parse identifier from pairing file")
        }

        return (rpf, identifier)
    }

    private func findFreePort() -> UInt16 {
        var actualPort: UInt16 = 0
        verboseLog("[IdeviceGateway] findFreePort() finding free port")
        let socketFd = socket(AF_INET, SOCK_STREAM, 0)
        if socketFd >= 0 {
            var addr = sockaddr_in()
            addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = INADDR_ANY
            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socketFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindRes == 0 {
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let nameRes = withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getsockname(socketFd, $0, &len)
                    }
                }
                if nameRes == 0 {
                    actualPort = UInt16(bigEndian: addr.sin_port)
                    verboseLog("[IdeviceGateway] findFreePort() bound to port: \(actualPort)")
                }
            }
            close(socketFd)
        }

        if actualPort == 0 {
            actualPort = 5555 // fallback
            verboseLog("[IdeviceGateway] findFreePort() fallback to port: \(actualPort)")
        }
        return actualPort
    }

    private func finalizeAndSavePairedDevice(
        rpf: OpaquePointer,
        hostName: String,
        hostModel: String,
        outPath: String,
        fallbackUdid: String,
        initialAltIrk: [UInt8]? = nil
    ) throws -> PairedDeviceRecord {
        verboseLog("[IdeviceGateway] finalizeAndSavePairedDevice() writing pairing file to: \(outPath)")
        let writeErr = rp_pairing_file_write(rpf, outPath)
        if let writeErr = writeErr {
            debugLog("[IdeviceGateway] finalizeAndSavePairedDevice() rp_pairing_file_write failed")
            defer { idevice_error_free(writeErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to write pairing file to path")
        }

        var pairedDataPtr: UnsafeMutablePointer<UInt8>? = nil
        var pairedDataLen: UInt = 0
        verboseLog("[IdeviceGateway] finalizeAndSavePairedDevice() serializing paired file to bytes")
        let serializeErr = rp_pairing_file_to_bytes(rpf, &pairedDataPtr, &pairedDataLen)
        if let serializeErr = serializeErr {
            debugLog("[IdeviceGateway] finalizeAndSavePairedDevice() rp_pairing_file_to_bytes failed")
            defer { idevice_error_free(serializeErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to serialize paired file")
        }

        var altIrkHex = initialAltIrk?.map { String(format: "%02x", $0) }.joined() ?? ""
        var pairedUdid = ""
        var parsedPairingFile: (any PairingFile)? = nil
        if let pairedDataPtr = pairedDataPtr {
            let plistData = Data(bytes: pairedDataPtr, count: Int(pairedDataLen))
            idevice_data_free(pairedDataPtr, pairedDataLen)
            if let content = String(data: plistData, encoding: .utf8) {
                parsedPairingFile = try? PairingFileParser.parse(content: content)
            }
            if let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
                pairedUdid = plist["identifier"] as? String ?? ""
                if let altIrkData = plist["alt_irk"] as? Data {
                    altIrkHex = altIrkData.map { String(format: "%02x", $0) }.joined()
                }
                verboseLog("[IdeviceGateway] finalizeAndSavePairedDevice() parsed pairedUdid: \(pairedUdid), altIrkHex length: \(altIrkHex.count)")
            }
        }

        let resolvedPairingFile: any PairingFile
        if let parsed = parsedPairingFile {
            resolvedPairingFile = parsed
        } else {
            let diskContent = try String(contentsOfFile: outPath, encoding: .utf8)
            resolvedPairingFile = try PairingFileParser.parse(content: diskContent)
        }

        debugLog("[IdeviceGateway] finalizeAndSavePairedDevice() pairing complete")
        return PairedDeviceRecord(
            name: hostName,
            model: hostModel,
            pairingFilePath: outPath,
            pairingFile: resolvedPairingFile
        )
    }

    private func syncStartWirelessPair(
        hostName: String,
        hostModel: String,
        outPath: String,
        onReady: @escaping (String, UInt16, [String: String]) -> Void,
        onPin: @escaping (String) -> Void
    ) throws -> PairedDeviceRecord {
        debugLog("[IdeviceGateway] startWirelessPair() called, hostName: \(hostName), hostModel: \(hostModel), outPath: \(outPath)")
        
        let (rpf, identifier) = try generatePairingFile(hostName: hostName)
        defer { rp_pairing_file_free(rpf) }

        let actualPort = findFreePort()

        let txtRecords = [
            "txtvers": "1",
            "id": identifier,
            "model": hostModel,
            "name": hostName
        ]
        verboseLog("[IdeviceGateway] startWirelessPair() invoking onReady")
        onReady(identifier, actualPort, txtRecords)

        var pairedRpf: OpaquePointer? = nil
        var hostAltIrk = [UInt8](repeating: 0, count: 16)

        class PinContext {
            let callback: (String) -> Void
            init(_ callback: @escaping (String) -> Void) {
                self.callback = callback
            }
        }
        let pinContextObj = PinContext(onPin)
        let pinContextPtr = Unmanaged.passRetained(pinContextObj).toOpaque()
        defer { Unmanaged<PinContext>.fromOpaque(pinContextPtr).release() }

        verboseLog("[IdeviceGateway] startWirelessPair() waiting for connection via pairable_host_accept...")
        let acceptErr = pairable_host_accept(
            hostName,
            hostModel,
            actualPort,
            { pin, context in
                guard let pin = pin, let context = context else { return }
                let ctxObj = Unmanaged<PinContext>.fromOpaque(context).takeUnretainedValue()
                let pinStr = String(cString: pin)
                verboseLog("[IdeviceGateway] startWirelessPair() received pin: \(pinStr)")
                ctxObj.callback(pinStr)
            },
            pinContextPtr,
            &hostAltIrk,
            &pairedRpf
        )

        if let acceptErr = acceptErr {
            debugLog("[IdeviceGateway] startWirelessPair() pairable_host_accept failed")
            defer { idevice_error_free(acceptErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Pairing failed or cancelled")
        }

        guard let pairedRpf = pairedRpf else {
            debugLog("[IdeviceGateway] startWirelessPair() pairedRpf is nil")
            throw IdeviceGatewayError(.serviceError, reason: "No pairing file returned")
        }
        defer { rp_pairing_file_free(pairedRpf) }

        return try finalizeAndSavePairedDevice(
            rpf: pairedRpf,
            hostName: hostName,
            hostModel: hostModel,
            outPath: outPath,
            fallbackUdid: identifier,
            initialAltIrk: hostAltIrk
        )
    }

    private func syncTriggerWirelessPair(
        targetIp: String,
        targetPort: UInt16,
        hostName: String,
        hostModel: String,
        outPath: String,
        onRequestPin: @escaping (@escaping (String) -> Void) -> Void
    ) throws -> PairedDeviceRecord {
        debugLog("[IdeviceGateway] triggerWirelessPair() called, targetIp: \(targetIp), targetPort: \(targetPort), hostName: \(hostName), hostModel: \(hostModel), outPath: \(outPath)")
        
        let (rpf, identifier) = try generatePairingFile(hostName: hostName)
        defer { rp_pairing_file_free(rpf) }

        guard !targetIp.isEmpty, targetPort > 0 else {
            debugLog("[IdeviceGateway] triggerWirelessPair() failed because target endpoint is invalid: \(targetIp):\(targetPort)")
            throw IdeviceGatewayError(.invalidTargetEndpoint, reason: "Target endpoint IP (\(targetIp)) or port (\(targetPort)) is invalid")
        }

        class PinContext {
            let onRequestPin: (@escaping (String) -> Void) -> Void
            init(_ onRequestPin: @escaping (@escaping (String) -> Void) -> Void) {
                self.onRequestPin = onRequestPin
            }
        }
        let pinContextObj = PinContext(onRequestPin)
        let pinContextPtr = Unmanaged.passRetained(pinContextObj).toOpaque()
        defer { Unmanaged<PinContext>.fromOpaque(pinContextPtr).release() }

        var err: UnsafeMutablePointer<IdeviceFfiError>? = nil
        var peerDevicePtr: UnsafeMutablePointer<RpPairingPeerDeviceC>? = nil

        verboseLog("[IdeviceGateway] triggerWirelessPair() pairing via rppairing_pair_network to \(targetIp):\(targetPort)...")
        try hostName.withCString { hostPtr in
            try withSockaddr(ip: targetIp, port: targetPort) { sockaddrPtr, sockaddrLen in
                err = rppairing_pair_network(
                    sockaddrPtr,
                    sockaddrLen,
                    hostPtr,
                    rpf,
                    { context in
                        guard let context = context else { return nil }
                        let ctxObj = Unmanaged<PinContext>.fromOpaque(context).takeUnretainedValue()
                        let sema = DispatchSemaphore(value: 0)
                        var enteredPin: String? = nil
                        debugLog("[IdeviceGateway] pin_callback invoked, requesting PIN from user UI...")
                        ctxObj.onRequestPin { pin in
                            debugLog("[IdeviceGateway] pin_callback received user entered PIN: '\(pin)'")
                            enteredPin = pin
                            sema.signal()
                        }
                        let waitResult = sema.wait(timeout: .now() + 60.0)
                        if waitResult == .timedOut {
                            debugLog("[IdeviceGateway] pin_callback timed out waiting for user input")
                        }
                        guard let pinStr = enteredPin, let p = strdup(pinStr) else { return nil }
                        return UnsafePointer(p)
                    },
                    pinContextPtr,
                    &peerDevicePtr
                )
            }
        }

        if let err = err {
            let msg = err.pointee.message != nil ? String(cString: err.pointee.message!) : "Pairing failed"
            debugLog("[IdeviceGateway] triggerWirelessPair() pairing failed: \(msg)")
            defer { idevice_error_free(err) }
            throw IdeviceGatewayError(.serviceError, reason: msg)
        }

        var peerName = hostName
        var peerModel = hostModel
        var peerUdid: String? = nil
        var peerAltIrk: [UInt8]? = nil

        if let peer = peerDevicePtr {
            defer { rppairing_peer_device_free(peer) }
            let p = peer.pointee
            if let namePtr = p.name {
                peerName = String(cString: namePtr)
            }
            if let modelPtr = p.model {
                peerModel = String(cString: modelPtr)
            }
            if let udidPtr = p.udid {
                peerUdid = String(cString: udidPtr)
            }
            peerAltIrk = withUnsafeBytes(of: p.alt_irk) { Array($0) }
        }

        return try finalizeAndSavePairedDevice(
            rpf: rpf,
            hostName: peerName,
            hostModel: peerModel,
            outPath: outPath,
            fallbackUdid: peerUdid ?? identifier,
            initialAltIrk: peerAltIrk
        )
    }

    private func startHouseArrestAfc(bundleId: String) throws -> OpaquePointer {
        debugLog("[IdeviceGateway] startHouseArrestAfc() called, bundleId: \(bundleId)")
        try verifyInitialized()
        
        var afcHandle: OpaquePointer? = nil
        try performWithEitherService(
            connectRP: house_arrest_client_connect_rsd,
            connectLockdown: house_arrest_client_connect,
            cleanup: { _ in }, // no need to free, house_arrest takes ownership of the pointer
            serviceName: "house_arrest"
        ) { client in
            verboseLog("[IdeviceGateway] startHouseArrestAfc() calling house_arrest_vend_container")
            let err = bundleId.withCString { bundleIdPtr in
                house_arrest_vend_container(client, bundleIdPtr, &afcHandle)
            }
            if let err = err {
                let msg = self.getErrorMessage(from: err)
                debugLog("[IdeviceGateway] startHouseArrestAfc() house_arrest_vend_container failed: \(msg)")
                defer { safeFreeError(err) }
                throw IdeviceGatewayError(.serviceError, reason: "Failed to vend container for \(bundleId), error: (\(msg))")
            }
            debugLog("[IdeviceGateway] startHouseArrestAfc() house_arrest_vend_container succeeded")
        }
        
        guard let resultHandle = afcHandle else {
            debugLog("[IdeviceGateway] startHouseArrestAfc() resulting AFC handle is nil")
            throw IdeviceGatewayError(.serviceError, reason: "AFC handle is nil after vend_container")
        }
        return resultHandle
    }

    private func afcListDirectory(client: OpaquePointer, path: String) throws -> [String] {
        verboseLog("[IdeviceGateway] afcListDirectory() called, path: \(path)")
        var entriesRaw: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        var count: Int = 0
        let err = path.withCString { pathPtr in
            afc_list_directory(client, pathPtr, &entriesRaw, &count)
        }
        if let err = err {
            let msg = self.getErrorMessage(from: err)
            debugLog("[IdeviceGateway] afcListDirectory() afc_list_directory failed for: \(path), error: (\(msg))")
            defer { safeFreeError(err) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to list directory: \(path), error: (\(msg))")
        }
        var items: [String] = []
        if let entries = entriesRaw {
            for i in 0..<count {
                if let cStr = entries[i] {
                    items.append(String(cString: cStr))
                    idevice_string_free(cStr)
                }
            }
            free(entries)
        }
        verboseLog("[IdeviceGateway] afcListDirectory() succeeded, count: \(items.count)")
        return items
    }

    private func afcReadFile(client: OpaquePointer, path: String) throws -> Data {
        debugLog("[IdeviceGateway] afcReadFile() called, path: \(path)")
        var fileHandle: OpaquePointer? = nil
        let openErr = path.withCString { pathPtr in
            afc_file_open(client, pathPtr, AfcFopenMode(rawValue: 1), &fileHandle) // RdOnly mode
        }
        if let openErr = openErr {
            let msg = self.getErrorMessage(from: openErr)
            debugLog("[IdeviceGateway] afcReadFile() afc_file_open failed for: \(path), error: (\(msg))")
            defer { safeFreeError(openErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to open file: \(path), error: (\(msg))")
        }
        defer {
            verboseLog("[IdeviceGateway] afcReadFile() closing file handle")
            _ = afc_file_close(fileHandle)
        }
        
        var dataPtr: UnsafeMutablePointer<UInt8>? = nil
        var length: Int = 0
        let readErr = afc_file_read_entire(fileHandle, &dataPtr, &length)
        if let readErr = readErr {
            let msg = self.getErrorMessage(from: readErr)
            debugLog("[IdeviceGateway] afcReadFile() afc_file_read_entire failed, error: (\(msg))")
            defer { safeFreeError(readErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to read file: \(path), error: (\(msg))")
        }
        
        if let ptr = dataPtr {
            let data = Data(bytes: ptr, count: length)
            afc_file_read_data_free(ptr, length)
            debugLog("[IdeviceGateway] afcReadFile() succeeded, read size: \(data.count) bytes")
            return data
        } else {
            debugLog("[IdeviceGateway] afcReadFile() read completed with empty data")
            return Data()
        }
    }

    private func afcGetFileInfo(client: OpaquePointer, path: String) throws -> (isDirectory: Bool, fileSize: Int64) {
        verboseLog("[IdeviceGateway] afcGetFileInfo() called, path: \(path)")
        var info = AfcFileInfo()
        let err = path.withCString { pathPtr in
            afc_get_file_info(client, pathPtr, &info)
        }
        if let err = err {
            debugLog("[IdeviceGateway] afcGetFileInfo() afc_get_file_info failed for: \(path)")
            defer { safeFreeError(err) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to get info for path: \(path)")
        }
        defer {
            var mutableInfo = info
            afc_file_info_free(&mutableInfo)
        }
        
        let isDirectory = info.st_ifmt != nil && String(cString: info.st_ifmt).contains("S_IFDIR")
        let size = Int64(info.size)
        verboseLog("[IdeviceGateway] afcGetFileInfo() succeeded, isDirectory: \(isDirectory), size: \(size)")
        return (isDirectory, size)
    }

    private func syncAfcListDirectory(bundleId: String, path: String) throws -> [String] {
        let client = try startHouseArrestAfc(bundleId: bundleId)
        defer { afcClientFree(client: client) }
        return try afcListDirectory(client: client, path: path)
    }

    private func syncAfcReadFile(bundleId: String, path: String) throws -> Data {
        let client = try startHouseArrestAfc(bundleId: bundleId)
        defer { afcClientFree(client: client) }
        return try afcReadFile(client: client, path: path)
    }

    private func syncAfcGetFileInfo(bundleId: String, path: String) throws -> (isDirectory: Bool, fileSize: Int64) {
        let client = try startHouseArrestAfc(bundleId: bundleId)
        defer { afcClientFree(client: client) }
        return try afcGetFileInfo(client: client, path: path)
    }

        private func afcRemovePathRecursive(client: OpaquePointer, path: String) throws {
        let (isDirectory, _) = try afcGetFileInfo(client: client, path: path)
        if isDirectory {
            let contents = try afcListDirectory(client: client, path: path)
            for item in contents {
                if item == "." || item == ".." { continue }
                let itemPath = path == "/" ? "/\(item)" : "\(path)/\(item)"
                try afcRemovePathRecursive(client: client, path: itemPath)
            }
        }
        
        let err = path.withCString { pathPtr in
            afc_remove_path(client, pathPtr)
        }
        if let err = err {
            verboseLog("[IdeviceGateway] afcRemovePathRecursive() afc_remove_path failed for: \(path)")
            defer { safeFreeError(err) }
        }
    }

    private func syncWipeContainer(identifier: String) throws {
        debugLog("[IdeviceGateway] wipeContainer() called, identifier: \(identifier)")
        let client = try startHouseArrestAfc(bundleId: identifier)
        defer { afcClientFree(client: client) }
        
        let contents = try afcListDirectory(client: client, path: "/")
        for item in contents {
            if item == "." || item == ".." { continue }
            try afcRemovePathRecursive(client: client, path: "/\(item)")
        }
        debugLog("[IdeviceGateway] wipeContainer() completed, identifier: \(identifier)")
    }

    private func afcClientFree(client: OpaquePointer) {
        debugLog("[IdeviceGateway] afcClientFree() freeing AFC client handle")
        afc_client_free(client)
    }
}

// Async FFI Dispatcher Extensions
extension IdeviceGateway {
    public func start(pairingFileContent: String) async throws {
        try await withFFIDispatch {
            try self.syncStart(pairingFileContent: pairingFileContent)
        }
    }

    public func fetchUDID() async throws -> String? {
        try await withFFIDispatch {
            try self.syncFetchUDID()
        }
    }

    public func getLockdownValue(key: String) async throws -> String? {
        try await withFFIDispatch {
            try self.syncGetLockdownValue(key: key)
        }
    }

    public func installProvisioningProfile(profile: Data) async throws {
        try await withFFIDispatch {
            try self.syncInstallProvisioningProfile(profile: profile)
        }
    }

    public func removeProvisioningProfile(id: String) async throws {
        try await withFFIDispatch {
            try self.syncRemoveProvisioningProfile(id: id)
        }
    }

    public func removeApp(bundleId: String) async throws {
        try await withFFIDispatch {
            try self.syncRemoveApp(bundleId: bundleId)
        }
    }

    public func sendIpaAfc(bundleId: String, ipaBytes: Data) async throws {
        try await withFFIDispatch {
            try self.syncsendIpaAfc(bundleId: bundleId, ipaBytes: ipaBytes)
        }
    }

    public func sendAppBundleAfc(bundleId: String, appURL: URL) async throws {
        try await withFFIDispatch {
            try self.syncsendAppBundleAfc(bundleId: bundleId, appURL: appURL)
        }
    }

    public func installIpa(bundleId: String) async throws {
        try await withFFIDispatch {
            try self.syncInstallIpa(bundleId: bundleId)
        }
    }

    public func installAppBundle(bundleId: String, appName: String) async throws {
        try await withFFIDispatch {
            try self.syncInstallAppBundle(bundleId: bundleId, appName: appName)
        }
    }

    public func debugApp(appId: String) async throws {
        try await withFFIDispatch {
            try self.syncDebugApp(appId: appId)
        }
    }

    public func debugProcess(pid: UInt32) async throws {
        try await withFFIDispatch {
            try self.syncDebugProcess(pid: pid)
        }
    }

    public func dumpProfiles(docsPath: String) async throws -> String {
        try await withFFIDispatch {
            try self.syncDumpProfiles(docsPath: docsPath)
        }
    }

    public func performHeartbeat(interval: UInt64) async throws -> UInt64 {
        try await withFFIDispatch {
            var newInterval: UInt64 = 0
            try self.syncPerformHeartbeat(interval: interval, newInterval: &newInterval)
            return newInterval > 0 ? newInterval : 1000
        }
    }

    public func mountPersonalizedDdi(image: Data, trustcache: Data, manifest: Data) async throws {
        try await withFFIDispatch {
            try self.syncMountPersonalizedDdi(image: image, trustcache: trustcache, manifest: manifest)
        }
    }

    public func isDDIMounted() async throws -> Bool {
        try await withFFIDispatch {
            try self.syncIsDDIMounted()
        }
    }

    public func mountDeveloperImage(image: Data, signature: Data) async throws {
        try await withFFIDispatch {
            try self.syncMountDeveloperImage(image: image, signature: signature)
        }
    }

    public func startWirelessPair(
        hostName: String,
        hostModel: String,
        outPath: String,
        onReady: @escaping @Sendable (String, UInt16, [String: String]) -> Void,
        onPin: @escaping @Sendable (String) -> Void
    ) async throws -> PairedDeviceRecord {
        try await withFFIDispatch {
            try self.syncStartWirelessPair(
                hostName: hostName,
                hostModel: hostModel,
                outPath: outPath,
                onReady: onReady,
                onPin: onPin
            )
        }
    }

    public func triggerWirelessPair(
        targetIp: String,
        targetPort: UInt16,
        hostName: String,
        hostModel: String,
        outPath: String,
        onRequestPin: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> Void
    ) async throws -> PairedDeviceRecord {
        try await withFFIDispatch {
            try self.syncTriggerWirelessPair(
                targetIp: targetIp,
                targetPort: targetPort,
                hostName: hostName,
                hostModel: hostModel,
                outPath: outPath,
                onRequestPin: onRequestPin
            )
        }
    }

    public func afcListDirectory(bundleId: String, path: String) async throws -> [String] {
        try await withFFIDispatch {
            try self.syncAfcListDirectory(bundleId: bundleId, path: path)
        }
    }

    public func afcReadFile(bundleId: String, path: String) async throws -> Data {
        try await withFFIDispatch {
            try self.syncAfcReadFile(bundleId: bundleId, path: path)
        }
    }

    public func afcGetFileInfo(bundleId: String, path: String) async throws -> (isDirectory: Bool, fileSize: Int64) {
        try await withFFIDispatch {
            try self.syncAfcGetFileInfo(bundleId: bundleId, path: path)
        }
    }

    public func wipeContainer(identifier: String) async throws {
        try await withFFIDispatch {
            try self.syncWipeContainer(identifier: identifier)
        }
    }
}
