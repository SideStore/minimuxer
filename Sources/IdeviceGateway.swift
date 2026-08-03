//
//  IdeviceGateway.swift
//  SideStore
//
//  Created by Magesh K on 05/07/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import IDevice

internal enum IdeviceGatewayError: LocalizedError {
    case invalidPairingFile(reason: String)
    case connectionFailed(String)
    case serviceError(String)
    case noConnection
    case notInitialized
    case deviceEndpointIpNotAvailable

    var errorDescription: String? {
        switch self {
        case .invalidPairingFile(let reason):
            return "The pairing file is invalid: \(reason)"
        case .connectionFailed(let reason):
            return "Failed to connect to device: \(reason)"
        case .serviceError(let reason):
            return "Service operation failed: \(reason)"
        case .noConnection:
            return "No connection to the device."
        case .notInitialized:
            return "IdeviceGateway not initialized. start() should be called first."
        case .deviceEndpointIpNotAvailable:
            return "Device endpoint IP is not available."
        }
    }

    var failureReason: String? {
        return errorDescription
    }
}

internal final class IdeviceGateway {
    static let shared = IdeviceGateway()
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
            return String(cString: msgPtr)
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
    private var deviceEndpointIp: String? = nil
    private var isInitialized = false

    private(set) var isRPPairing: Bool = false
    private(set) var pairingFileType: PairingProtocol = .unknown
    
    func getPairingFileType() -> PairingProtocol {
        return pairingFileType
    }

    static func validatePairingFile(from plist: [String: Any]?) throws -> PairingProtocol {
        guard let plist = plist else {
            throw IdeviceGatewayError.invalidPairingFile(reason: "The file could not be parsed as a property list (plist).")
        }

        let requiredRPKeys = ["private_key", "public_key", "identifier"]
        let missingRPKeys = requiredRPKeys.filter { plist[$0] == nil }
        if missingRPKeys.isEmpty {
            return .rppairing
        }

        let requiredLockdownKeys = [
            "WiFiMACAddress", "SystemBUID", "RootPrivateKey", "HostPrivateKey",
            "HostID", "RootCertificate", "UDID", "EscrowBag", "HostCertificate",
            "DeviceCertificate"
        ]
        let missingLockdownKeys = requiredLockdownKeys.filter { plist[$0] == nil }
        if missingLockdownKeys.isEmpty {
            return .lockdown
        }

        throw IdeviceGatewayError.invalidPairingFile(
            reason: "The pairing file is incomplete. Missing Remote Pairing attributes: \(missingRPKeys.joined(separator: ", ")); missing Lockdown attributes: \(missingLockdownKeys.joined(separator: ", "))."
        )
    }
    private(set) var pairingFileData: Data? = nil{
        didSet {
            var pairingDict: [String: Any]? = nil
            if let pairingFileData {
                pairingDict = try? PropertyListSerialization.propertyList(
                    from: pairingFileData,
                    options: [], format: nil
                ) as? [String: Any]
            }
            self.pairingDataDict = pairingDict
        }
    }
    private(set) var pairingDataDict: [String: Any]? = nil

    private init() {}

    deinit {
        cleanup()
    }

    private func cleanup() {
        debugLog("[IdeviceGateway] cleanup() called")
        isInitialized = false
        self.pairingFileData = nil
        
        if let pairingFile = self.pairingFile {
            verboseLog("[IdeviceGateway] cleanup() freeing pairingFile")
            if isRPPairing {
                rp_pairing_file_free(pairingFile)
            } else {
                idevice_pairing_file_free(pairingFile)
            }
            self.pairingFile = nil
        }

        isRPPairing = false
        pairingFileType = .unknown
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
            throw IdeviceGatewayError.notInitialized
        }
    }

    private func invalidateConnection() {
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

    func setDeviceEndpointIp(_ ip: String?) {
        debugLog("[IdeviceGateway] setDeviceEndpointIp(\(ip ?? "nil")) called")
        guard self.deviceEndpointIp != ip else {
            debugLog("[IdeviceGateway] setDeviceEndpointIp: IP is already \(ip ?? "nil"), skipping invalidation")
            return
        }
        self.deviceEndpointIp = ip
        
        // Invalidate current cached connections
        if handshake != nil {
            debugLog("[IdeviceGateway] setDeviceEndpointIp invalidating handshake")
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if adapter != nil {
            debugLog("[IdeviceGateway] setDeviceEndpointIp invalidating adapter")
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    func setLogging(_ enabled: Bool) {
        debugLog("[IdeviceGateway] setLogging(\(enabled)) called")
        idevice_init_logger(enabled ? IdeviceLogLevel(rawValue: 1) : IdeviceLogLevel(rawValue: 0), IdeviceLogLevel(rawValue: 0), nil)
        #if DEBUG
        // just comment/uncomment to override above set logging level during local debugging
//        idevice_init_logger(IdeviceLogLevel(rawValue: 4), IdeviceLogLevel(rawValue: 0), nil)
        #endif
    }

    func start(pairingFileContent: String) throws {
        debugLog("[IdeviceGateway] start() called, pairingFileContent length: \(pairingFileContent.count)")
        cleanup()
        
        #if DEBUG
        setLogging(true)
        #endif

        guard let data = pairingFileContent.data(using: .utf8) else {
            debugLog("[IdeviceGateway] start() failed to decode pairingFileContent data as UTF-8")
            throw IdeviceGatewayError.invalidPairingFile(reason: "UTF-8 encoding failed")
        }

        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        do {
            let pairingType = try Self.validatePairingFile(from: plist)
            self.pairingFileData = data
            self.pairingFileType = pairingType
            isRPPairing = (pairingType == .rppairing)
        } catch {
            debugLog("[IdeviceGateway] start() failed: \(error.localizedDescription)")
            throw error
        }

        if isRPPairing {
            try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    verboseLog("[IdeviceGateway] start() calling rp_pairing_file_from_bytes")
                    let err = rp_pairing_file_from_bytes(baseAddress, UInt(data.count), &pairingFile)
                    if err != nil {
                        debugLog("[IdeviceGateway] start() rp_pairing_file_from_bytes failed")
                        throw IdeviceGatewayError.invalidPairingFile(reason: "rp_pairing_file_from_bytes failed")
                    }
                }
            }
        } else {
            // Traditional usbmuxd / lockdown connection path
            // For pre-iOS 17 devices, a default connection can be established without RPPairing tunnel
            verboseLog("[IdeviceGateway] start() setting isRPPairing = false (mode = .lockdown)")
            isRPPairing = false

            // Parse pairing file content XML plist to self.pairingFile IdevicePairingFile*
            try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    verboseLog("[IdeviceGateway] start() loading lockdown pairing file bytes")
                    let err = idevice_pairing_file_from_bytes(baseAddress, UInt(data.count), &pairingFile)
                    if err != nil {
                        debugLog("[IdeviceGateway] start() idevice_pairing_file_from_bytes failed")
                        throw IdeviceGatewayError.invalidPairingFile(reason: "idevice_pairing_file_from_bytes failed")
                    }
                    verboseLog("[IdeviceGateway] start() loaded lockdown pairingFile successfully")
                }
            }
        }
        isInitialized = true
    }

    private func ensureRPConnection() throws {
        debugLog("[IdeviceGateway] ensureRPConnection() started, adapter: \(String(describing: adapter)), handshake: \(String(describing: handshake))")
        if adapter != nil && handshake != nil {
            verboseLog("[IdeviceGateway] ensureRPConnection() using existing connection")
            return
        }

        guard let pairingFile = pairingFile else {
            debugLog("[IdeviceGateway] ensureRPConnection() failed because pairingFile is nil")
            throw IdeviceGatewayError.invalidPairingFile(reason: "pairingFile is nil")
        }

        guard let deviceEndpointIp = deviceEndpointIp else {
            debugLog("[IdeviceGateway] ensureRPConnection() failed because deviceEndpointIp is nil")
            throw IdeviceGatewayError.deviceEndpointIpNotAvailable
        }

        // Standard RPPairing socket address
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = MinimuxerConstants.rsdPort.bigEndian
        addr.sin_addr.s_addr = inet_addr(deviceEndpointIp)

        let hostname = MinimuxerConstants.appName
        var err: UnsafeMutablePointer<IdeviceFfiError>? = nil

        verboseLog("[IdeviceGateway] ensureRPConnection() calling tunnel_create_rppairing with deviceEndpointIp: \(deviceEndpointIp)")
        try hostname.withCString { hostPtr in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    err = tunnel_create_rppairing(
                        sockaddrPtr,
                        socklen_t(MemoryLayout<sockaddr_in>.size),
                        hostPtr,
                        pairingFile,
                        nil,
                        nil,
                        &adapter,
                        &handshake
                    )
                }
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
                let error = IdeviceGatewayError.invalidPairingFile(reason: reason)
                lastError = error
                throw error
            } else {
                let error = IdeviceGatewayError.connectionFailed(msg.isEmpty ? "Tunnel creation failed" : msg)
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
                let errObj = IdeviceGatewayError.serviceError(reason)
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
                    let reason = "Service connection failed: \(retryMsg.isEmpty ? "Unknown FFI error" : retryMsg)"
                    let error = IdeviceGatewayError.invalidPairingFile(reason: reason)
                    lastError = error
                    throw error
                } else {
                    let error = IdeviceGatewayError.serviceError("Failed to connect to \(serviceName): \(retryMsg.isEmpty ? "Unknown FFI error" : retryMsg)")
                    lastError = error
                    throw error
                }
            }
        }
        guard let client = client else {
            debugLog("[IdeviceGateway] performWithService(\(serviceName)) client is nil")
            throw IdeviceGatewayError.serviceError("Connected client for \(serviceName) was nil")
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
            throw IdeviceGatewayError.connectionFailed("Failed to get usbmuxd addr: \(msg)")
        }
        guard let addr = addr else {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) usbmuxd addr is nil")
            throw IdeviceGatewayError.connectionFailed("Usbmuxd addr was nil")
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
            throw IdeviceGatewayError.connectionFailed("Failed to connect to usbmuxd: \(msg)")
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
                throw IdeviceGatewayError.connectionFailed("Failed to list usbmuxd devices: \(msg)")
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
                throw IdeviceGatewayError.connectionFailed("No devices found on usbmuxd")
            }
        } else {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) usbmuxd connection was nil")
            idevice_usbmuxd_addr_free(addr)
            throw IdeviceGatewayError.connectionFailed("Usbmuxd connection was nil")
        }
        
        if let provErr = provErr {
            let msg = self.getErrorMessage(from: provErr)
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) provider creation failed: code=\(provErr.pointee.code), message=\(msg)")
            defer { idevice_error_free(provErr) }
            throw IdeviceGatewayError.connectionFailed("Failed to create usbmuxd provider: \(msg)")
        }
        guard let provider = provider else {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) provider is nil")
            throw IdeviceGatewayError.connectionFailed("Usbmuxd provider was nil")
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
            throw IdeviceGatewayError.serviceError("Failed to connect to \(serviceName): \(msg)")
        }
        guard let client = client else {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) client is nil")
            throw IdeviceGatewayError.serviceError("Connected client for \(serviceName) was nil")
        }
        defer {
            verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) performing cleanup")
            cleanup(client)
        }
        verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) executing action")
        return try action(client)
    }

    private func connectWithTcpService(
        connect: @escaping (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        serviceName: String
    ) throws -> OpaquePointer {
        verboseLog("[IdeviceGateway] performWithTcpService(\(serviceName)) started")
        
        guard let deviceEndpointIp = deviceEndpointIp else {
            debugLog("[IdeviceGateway] performWithTcpService(\(serviceName)) failed because deviceEndpointIp is nil")
            throw IdeviceGatewayError.deviceEndpointIpNotAvailable
        }
        
        var sockAddr = sockaddr_in()
        sockAddr.sin_family = sa_family_t(AF_INET)
        sockAddr.sin_port = MinimuxerConstants.lockdowndPort.bigEndian
        sockAddr.sin_addr.s_addr = inet_addr(deviceEndpointIp)
        #if os(macOS) || os(iOS)
        sockAddr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        #endif

        guard let pairingFileData = self.pairingFileData else {
            debugLog("[IdeviceGateway] error: pairingFileData is nil")
            throw IdeviceGatewayError.connectionFailed("pairingFileData is nil")
        }

        var tempPairingFile: OpaquePointer? = nil
        let parseErr = pairingFileData.withUnsafeBytes { buf in
            return idevice_pairing_file_from_bytes(buf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt(pairingFileData.count), &tempPairingFile)
        }
        if let parseErr = parseErr {
            let msg = self.getErrorMessage(from: parseErr)
            debugLog("[IdeviceGateway] error: Failed to parse temporary pairing file: \(msg)")
            defer { safeFreeError(parseErr) }
            throw IdeviceGatewayError.connectionFailed("Failed to parse temporary pairing file: \(msg)")
        }
        guard let tempPairingFile = tempPairingFile else {
            throw IdeviceGatewayError.connectionFailed("Temporary pairing file was nil")
        }

        var provider: OpaquePointer? = nil
        let provErr = withUnsafePointer(to: &sockAddr) { ptr in
            ptr.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { reboundPtr in
                return idevice_tcp_provider_new(reboundPtr, tempPairingFile, MinimuxerConstants.appName, &provider)
            }
        }
        if let provErr = provErr {
            let msg = self.getErrorMessage(from: provErr)
            debugLog("[IdeviceGateway] error: Failed to create TCP provider: \(msg)")
            defer { safeFreeError(provErr) }
            throw IdeviceGatewayError.connectionFailed("Failed to create TCP provider: \(msg)")
        }
        guard let provider = provider else {
            debugLog("[IdeviceGateway] error: TCP Provider was nil")
            throw IdeviceGatewayError.connectionFailed("TCP Provider was nil")
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
            throw IdeviceGatewayError.serviceError("Failed to connect to \(serviceName): \(msg)")
        }
        guard let client = client else {
            throw IdeviceGatewayError.noConnection
        }
        return client
    }

    private func performWithTcpService<T>(
        connect: @escaping (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: @escaping (OpaquePointer?) -> Void,
        serviceName: String,
        action: (OpaquePointer) throws -> T
    ) throws -> T {
        let client = try connectWithTcpService(
            connect: connect,
            serviceName: serviceName
        )
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
        debugLog("[IdeviceGateway] performWithEitherService(\(serviceName)) started, isRPPairing: \(isRPPairing) (mode = .\(pairingFileType))")
        if isRPPairing {
            return try performWithService(connect: connectRP, cleanup: cleanup, serviceName: serviceName, action: action)
        } else {
            return try performWithTcpService(connect: connectLockdown, cleanup: cleanup, serviceName: serviceName, action: action)
        }
    }

    func fetchUDID() throws -> String? {
        debugLog("[IdeviceGateway] fetchUDID() started, isRPPairing: \(isRPPairing) (mode = .\(pairingFileType))")
        try verifyInitialized()
        if isRPPairing {
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

    func getLockdownValue(key: String) throws -> String? {
        debugLog("[IdeviceGateway] getLockdownValue(key: \(key)) started, isRPPairing: \(isRPPairing) (mode = .\(pairingFileType))")
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
                debugLog("[IdeviceGateway] getLockdownValue lockdownd_get_value failed for \(key)")
                defer { safeFreeError(valErr) }
                throw IdeviceGatewayError.serviceError("Failed to get lockdown value for key \(key)")
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

    func installProvisioningProfile(profile: Data) throws {
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
                        throw IdeviceGatewayError.serviceError("Failed to install profile: \(msg)")
                    }
                    debugLog("[IdeviceGateway] installProvisioningProfile() misagent_install succeeded")
                }
            }
        }
    }

    func removeProvisioningProfile(id: String) throws {
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
                    throw IdeviceGatewayError.serviceError("Failed to remove profile: \(msg)")
                }
                debugLog("[IdeviceGateway] removeProvisioningProfile() misagent_remove succeeded")
            }
        }
    }

    func removeApp(bundleId: String) throws {
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
                    debugLog("[IdeviceGateway] removeApp() installation_proxy_uninstall failed")
                    defer { idevice_error_free(uninstallErr) }
                    throw IdeviceGatewayError.serviceError("Failed to uninstall app")
                }
                debugLog("[IdeviceGateway] removeApp() installation_proxy_uninstall succeeded")
            }
        }
    }

    func yeetAppAfc(bundleId: String, ipaBytes: Data) throws {
        debugLog("[IdeviceGateway] yeetAppAfc() called, bundleId: \(bundleId), ipaBytes size: \(ipaBytes.count)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: afc_client_connect_rsd,
            connectLockdown: afc_client_connect,
            cleanup: afc_client_free,
            serviceName: "AFC client"
        ) { client in
            // Ensure directory
            let stagingDir = MinimuxerConstants.pkgPath
            verboseLog("[IdeviceGateway] yeetAppAfc() creating directory: \(stagingDir)")
            _ = stagingDir.withCString { dirPtr in
                afc_make_directory(client, dirPtr)
            }
            let bundleDir = "\(stagingDir)/\(bundleId)"
            verboseLog("[IdeviceGateway] yeetAppAfc() creating directory: \(bundleDir)")
            _ = bundleDir.withCString { dirPtr in
                afc_make_directory(client, dirPtr)
            }
 
            let path = "\(bundleDir)/app.ipa"
            var fileHandle: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] yeetAppAfc() opening remote file: \(path)")
            let openErr = path.withCString { pathPtr in
                afc_file_open(client, pathPtr, AfcFopenMode(rawValue: 4), &fileHandle) // WrOnly/Wr mode
            }
            if let openErr = openErr {
                debugLog("[IdeviceGateway] yeetAppAfc() afc_file_open failed")
                defer { idevice_error_free(openErr) }
                throw IdeviceGatewayError.serviceError("Failed to open remote AFC file")
            }
            defer {
                verboseLog("[IdeviceGateway] yeetAppAfc() closing remote file handle")
                afc_file_close(fileHandle)
            }
 
            try ipaBytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    verboseLog("[IdeviceGateway] yeetAppAfc() writing data to AFC file")
                    let writeErr = afc_file_write(fileHandle, baseAddress, ipaBytes.count)
                    if let writeErr = writeErr {
                        debugLog("[IdeviceGateway] yeetAppAfc() afc_file_write failed")
                        defer { idevice_error_free(writeErr) }
                        throw IdeviceGatewayError.serviceError("Failed to write to AFC file")
                    }
                    debugLog("[IdeviceGateway] yeetAppAfc() afc_file_write succeeded")
                }
            }
        }
    }

    func installIpa(bundleId: String) throws {
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
                    debugLog("[IdeviceGateway] installIpa() installation_proxy_install failed")
                    defer { idevice_error_free(installErr) }
                    throw IdeviceGatewayError.serviceError("Failed to install IPA")
                }
                debugLog("[IdeviceGateway] installIpa() installation_proxy_install succeeded")
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
                    debugLog("[IdeviceGateway] getAppPaths() installation_proxy_get_apps failed")
                    defer { idevice_error_free(err) }
                    throw IdeviceGatewayError.serviceError("Failed to lookup app paths")
                }
            }
            
            verboseLog("[IdeviceGateway] getAppPaths() installation_proxy_get_apps returned outLen: \(outLen)")
            guard let resultPtr = outResult, outLen > 0 else {
                verboseLog("[IdeviceGateway] getAppPaths() app not found")
                throw IdeviceGatewayError.serviceError("App not found: \(appId)")
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
                throw IdeviceGatewayError.serviceError("Failed to resolve app paths")
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
                    debugLog("[IdeviceGateway] sendDebugProxyCommand() failed for command \(name)")
                    defer { idevice_error_free(sendErr) }
                    throw IdeviceGatewayError.serviceError("Failed to send command to debug proxy: \(name)")
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
                throw IdeviceGatewayError.serviceError("Failed to construct debug proxy command: \(name)")
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
                debugLog("[IdeviceGateway] launchAppPre17() failed to start debugserver")
                defer { idevice_error_free(err) }
                throw IdeviceGatewayError.serviceError("Failed to start debugserver service")
            }
            debugLog("[IdeviceGateway] launchAppPre17() debugserver started on port: \(port)")
            
            var addr: OpaquePointer? = nil
            var addrErr = idevice_usbmuxd_default_addr_new(&addr)
            if let addrErr = addrErr {
                debugLog("[IdeviceGateway] launchAppPre17() default_addr_new failed")
                defer { idevice_error_free(addrErr) }
                throw IdeviceGatewayError.connectionFailed("Failed to get usbmuxd default addr")
            }
            guard let addr = addr else {
                debugLog("[IdeviceGateway] launchAppPre17() usbmuxd default addr is nil")
                throw IdeviceGatewayError.connectionFailed("Usbmuxd default addr was nil")
            }
            defer { idevice_usbmuxd_addr_free(addr) }
            
            var conn: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] launchAppPre17() creating default usbmuxd connection")
            let connErr = idevice_usbmuxd_new_default_connection(0, &conn)
            if let connErr = connErr {
                debugLog("[IdeviceGateway] launchAppPre17() new_default_connection failed")
                defer { idevice_error_free(connErr) }
                throw IdeviceGatewayError.connectionFailed("Failed to create usbmuxd connection")
            }
            guard let conn = conn else {
                debugLog("[IdeviceGateway] launchAppPre17() usbmuxd connection is nil")
                throw IdeviceGatewayError.connectionFailed("Usbmuxd connection was nil")
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
                throw IdeviceGatewayError.connectionFailed("Failed to list usbmuxd devices")
            }
            
            guard count > 0, let devicesPtr = devices, let firstDev = devicesPtr.pointee else {
                verboseLog("[IdeviceGateway] launchAppPre17() no devices found on usbmuxd")
                throw IdeviceGatewayError.connectionFailed("No devices found on usbmuxd")
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
                throw IdeviceGatewayError.connectionFailed("Failed to connect to debugserver port \(port)")
            }
            connNeedsFree = false
            
            guard let debugDevice = debugDevice else {
                debugLog("[IdeviceGateway] launchAppPre17() debug device handle is nil")
                throw IdeviceGatewayError.connectionFailed("Debug device handle was nil")
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
               throw IdeviceGatewayError.serviceError("Failed to convert device connection to stream")
           }
            debugDeviceNeedsFree = false
            
            guard let stream = stream else {
                debugLog("[IdeviceGateway] launchAppPre17() stream is nil")
                throw IdeviceGatewayError.serviceError("Stream was nil")
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
                debugLog("[IdeviceGateway] launchAppPre17() debug_proxy_new failed")
                defer { idevice_error_free(proxyErr) }
                throw IdeviceGatewayError.serviceError("Failed to create debug proxy client")
            }
            streamNeedsFree = false
            
            guard let debugProxyClient = debugProxyClient else {
                debugLog("[IdeviceGateway] launchAppPre17() debugProxyClient is nil")
                throw IdeviceGatewayError.serviceError("Debug proxy client was nil")
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
                    debugLog("[IdeviceGateway] launchAppPre17() debug_proxy_set_argv failed")
                    defer { idevice_error_free(argvErr) }
                    throw IdeviceGatewayError.serviceError("Failed to set debug proxy argv")
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

    func debugApp(appId: String) throws {
        debugLog("[IdeviceGateway] debugApp() called, appId: \(appId)")
        try verifyInitialized()
        guard let versionStr = try getLockdownValue(key: "ProductVersion"),
              let majorStr = versionStr.split(separator: ".").first,
              let major = Int(majorStr) else {
            debugLog("[IdeviceGateway] debugApp() failed to get ProductVersion")
            throw IdeviceGatewayError.serviceError("Failed to get product version for JIT")
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

    func debugProcess(pid: UInt32) throws {
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

    func dumpProfiles(docsPath: String) throws -> String {
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
                debugLog("[IdeviceGateway] dumpProfiles() misagent_copy_all failed")
                defer { idevice_error_free(copyErr) }
                throw IdeviceGatewayError.serviceError("Failed to copy profiles from misagent")
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

    func connectLockdownHeartbeat() throws -> OpaquePointer {
        try verifyInitialized()
        guard !isRPPairing else {
            throw IdeviceGatewayError.serviceError(
                "Lockdown heartbeat is unavailable for Remote Pairing"
            )
        }
        return try connectWithTcpService(
            connect: heartbeat_connect,
            serviceName: "heartbeat"
        )
    }

    func exchangeHeartbeat(client: OpaquePointer, interval: UInt64) throws -> UInt64 {
        var newInterval: UInt64 = 0
        let getError = heartbeat_get_marco(client, interval, &newInterval)
        if let getError {
            let message = getErrorMessage(from: getError)
            debugLog(
                "[IdeviceGateway] exchangeHeartbeat() " +
                "heartbeat_get_marco failed: \(message)"
            )
            safeFreeError(getError)
            throw IdeviceGatewayError.serviceError(
                "Heartbeat receive failed: \(message)"
            )
        }

        let sendError = heartbeat_send_polo(client)
        if let sendError {
            let message = getErrorMessage(from: sendError)
            debugLog(
                "[IdeviceGateway] exchangeHeartbeat() " +
                "heartbeat_send_polo failed: \(message)"
            )
            safeFreeError(sendError)
            throw IdeviceGatewayError.serviceError(
                "Heartbeat send failed: \(message)"
            )
        }
        return newInterval
    }

    func disconnectHeartbeat(_ client: OpaquePointer) {
        heartbeat_client_free(client)
    }

    func mountPersonalizedDdi(image: Data, trustcache: Data, manifest: Data) throws {
        debugLog("[IdeviceGateway] mountPersonalizedDdi() called, image size: \(image.count), trustcache size: \(trustcache.count), manifest size: \(manifest.count)")
        try verifyInitialized()

        if isRPPairing {
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
                throw IdeviceGatewayError.serviceError("Failed to get UniqueChipID")
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
                            throw IdeviceGatewayError.serviceError("Failed to mount personalized DDI: \(msg)")
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
            throw IdeviceGatewayError.deviceEndpointIpNotAvailable
        }

        var sockAddr = sockaddr_in()
        sockAddr.sin_family = sa_family_t(AF_INET)
        sockAddr.sin_port = MinimuxerConstants.lockdowndPort.bigEndian
        sockAddr.sin_addr.s_addr = inet_addr(deviceEndpointIp)

        guard let pairingFileData = self.pairingFileData else {
            debugLog("[IdeviceGateway] error: pairingFileData is nil")
            throw IdeviceGatewayError.connectionFailed("pairingFileData is nil")
        }

        var tempPairingFile: OpaquePointer? = nil
        let parseErr = pairingFileData.withUnsafeBytes { buf in
            return idevice_pairing_file_from_bytes(buf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt(pairingFileData.count), &tempPairingFile)
        }
        if let parseErr = parseErr {
            let msg = self.getErrorMessage(from: parseErr)
            debugLog("[IdeviceGateway] error: Failed to parse temporary pairing file: \(msg)")
            defer { safeFreeError(parseErr) }
            throw IdeviceGatewayError.connectionFailed("Failed to parse temporary pairing file: \(msg)")
        }
        guard let tempPairingFile = tempPairingFile else {
            throw IdeviceGatewayError.connectionFailed("Temporary pairing file was nil")
        }

        verboseLog("[IdeviceGateway] creating TCP provider to \(deviceEndpointIp):\(MinimuxerConstants.lockdowndPort)...")
        var provider: OpaquePointer? = nil
        let provErr = withUnsafePointer(to: &sockAddr) { ptr in
            ptr.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { reboundPtr in
                return idevice_tcp_provider_new(reboundPtr, tempPairingFile, MinimuxerConstants.appName, &provider)
            }
        }
        if let provErr = provErr {
            debugLog("[IdeviceGateway] error: Failed to create TCP provider")
            defer { safeFreeError(provErr) }
            throw IdeviceGatewayError.connectionFailed("Failed to create TCP provider")
        }
        guard let provider = provider else {
            debugLog("[IdeviceGateway] error: TCP Provider was nil")
            throw IdeviceGatewayError.connectionFailed("TCP Provider was nil")
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
                throw IdeviceGatewayError.noConnection
            }
            guard let lockdownClient = lockdownClient else {
                debugLog("[IdeviceGateway] error: lockdownClient was nil after connect")
                throw IdeviceGatewayError.noConnection
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
                    throw IdeviceGatewayError.connectionFailed("Failed to get pairing file for session retry")
                }
                guard let pf = pf else {
                    throw IdeviceGatewayError.connectionFailed("Pairing file nil for session retry")
                }
                defer { idevice_pairing_file_free(pf) }
                let sessionErr = lockdownd_start_session(lockdownClient, pf)
                if let sessionErr = sessionErr {
                    debugLog("[IdeviceGateway] error: lockdownd_start_session failed")
                    defer { idevice_error_free(sessionErr) }
                    throw IdeviceGatewayError.noConnection
                }
                verboseLog("[IdeviceGateway] session started. Querying UniqueChipID again...")
                let valErr2 = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &plistVal)
                if let valErr2 = valErr2 {
                    debugLog("[IdeviceGateway] error: lockdownd_get_value failed with session too")
                    defer { idevice_error_free(valErr2) }
                    throw IdeviceGatewayError.serviceError("Failed to get UniqueChipID")
                }
            }
            if let plistVal = plistVal {
                defer { plist_free(plistVal) }
                if plist_dict_get_item(plistVal, "Error") != nil {
                    debugLog("[IdeviceGateway] error: UniqueChipID returned error plist")
                    throw IdeviceGatewayError.serviceError("Failed to get UniqueChipID: Prohibited")
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
            throw IdeviceGatewayError.serviceError("Failed to connect to image mounter")
        }
        guard let mounterClient = mounterClient else {
            debugLog("[IdeviceGateway] error: mounterClient was nil")
            throw IdeviceGatewayError.serviceError("Mounter client was nil")
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
                        throw IdeviceGatewayError.serviceError("Failed to mount personalized DDI: \(msg)")
                    }
                    verboseLog("[IdeviceGateway] mountPersonalizedDdiIdevice() mount succeeded")
                }
            }
        }
    }

    func isDDIMounted() throws -> Bool {
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

    func mountDeveloperImage(image: Data, signature: Data) throws {
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
                        debugLog("[IdeviceGateway] mountDeveloperImage() upload failed")
                        defer { idevice_error_free(uploadErr) }
                        throw IdeviceGatewayError.serviceError("Failed to upload developer image")
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
                    throw IdeviceGatewayError.serviceError("Failed to mount developer image: \(msg)")
                }
                debugLog("[IdeviceGateway] mountDeveloperImage() mount succeeded")
            }
        }
    }

    struct PairedDevice {
        let name: String
        let model: String
        let udid: String
        let pairingFilePath: String
        let hostAltIrkHex: String
    }

    func startWirelessPair(
        hostName: String,
        hostModel: String,
        outPath: String,
        onReady: @escaping (String, UInt16, [String: String]) -> Void,
        onPin: @escaping (String) -> Void
    ) throws -> PairedDevice {
        debugLog("[IdeviceGateway] startWirelessPair() called, hostName: \(hostName), hostModel: \(hostModel), outPath: \(outPath)")
        // 1. Generate pairing file to get the service ID
        var rpf: OpaquePointer? = nil
        verboseLog("[IdeviceGateway] startWirelessPair() generating pairing file")
        let genErr = rp_pairing_file_generate(hostName, &rpf)
        if let genErr = genErr {
            debugLog("[IdeviceGateway] startWirelessPair() rp_pairing_file_generate failed")
            defer { idevice_error_free(genErr) }
            throw IdeviceGatewayError.serviceError("Failed to generate pairing file")
        }
        defer { rp_pairing_file_free(rpf) }

        // 2. Serialize pairing file to bytes so we can parse it in Swift and extract the identifier
        var dataPtr: UnsafeMutablePointer<UInt8>? = nil
        var dataLen: UInt = 0
        verboseLog("[IdeviceGateway] startWirelessPair() serializing pairing file to bytes")
        let toBytesErr = rp_pairing_file_to_bytes(rpf, &dataPtr, &dataLen)
        if let toBytesErr = toBytesErr {
            debugLog("[IdeviceGateway] startWirelessPair() rp_pairing_file_to_bytes failed")
            defer { idevice_error_free(toBytesErr) }
            throw IdeviceGatewayError.serviceError("Failed to serialize pairing file to bytes")
        }

        var identifier = ""
        if let dataPtr = dataPtr {
            let plistData = Data(bytes: dataPtr, count: Int(dataLen))
            idevice_data_free(dataPtr, dataLen)
            if let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
                identifier = plist["identifier"] as? String ?? ""
                verboseLog("[IdeviceGateway] startWirelessPair() parsed identifier: \(identifier)")
            }
        }

        if identifier.isEmpty {
            debugLog("[IdeviceGateway] startWirelessPair() failed: parsed identifier is empty")
            throw IdeviceGatewayError.serviceError("Failed to parse identifier from pairing file")
        }

        // 3. Find a free port
        var actualPort: UInt16 = 0
        verboseLog("[IdeviceGateway] startWirelessPair() finding free port")
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
                    verboseLog("[IdeviceGateway] startWirelessPair() bound to port: \(actualPort)")
                }
            }
            close(socketFd)
        }

        if actualPort == 0 {
            actualPort = 5555 // fallback
            verboseLog("[IdeviceGateway] startWirelessPair() fallback to port: \(actualPort)")
        }

        // 4. Invoke onReady callback
        let txtRecords = [
            "txtvers": "1",
            "id": identifier,
            "model": hostModel,
            "name": hostName
        ]
        verboseLog("[IdeviceGateway] startWirelessPair() invoking onReady")
        onReady(identifier, actualPort, txtRecords)

        // 5. Accept device pairing connection (blocking)
        var pairedRpf: OpaquePointer? = nil
        var hostAltIrk = [UInt8](repeating: 0, count: 16)

        // Wrap pin closure in convention(c) safe context block
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
            throw IdeviceGatewayError.serviceError("Pairing failed or cancelled")
        }

        guard let pairedRpf = pairedRpf else {
            debugLog("[IdeviceGateway] startWirelessPair() pairedRpf is nil")
            throw IdeviceGatewayError.serviceError("No pairing file returned")
        }
        defer { rp_pairing_file_free(pairedRpf) }

        verboseLog("[IdeviceGateway] startWirelessPair() writing pairing file to: \(outPath)")
        let writeErr = rp_pairing_file_write(pairedRpf, outPath)
        if let writeErr = writeErr {
            debugLog("[IdeviceGateway] startWirelessPair() rp_pairing_file_write failed")
            defer { idevice_error_free(writeErr) }
            throw IdeviceGatewayError.serviceError("Failed to write pairing file to path")
        }

        // Get alt_irk and identifier from paired file
        var pairedDataPtr: UnsafeMutablePointer<UInt8>? = nil
        var pairedDataLen: UInt = 0
        verboseLog("[IdeviceGateway] startWirelessPair() serializing paired file to bytes")
        let serializeErr = rp_pairing_file_to_bytes(pairedRpf, &pairedDataPtr, &pairedDataLen)
        if let serializeErr = serializeErr {
            debugLog("[IdeviceGateway] startWirelessPair() rp_pairing_file_to_bytes failed")
            defer { idevice_error_free(serializeErr) }
            throw IdeviceGatewayError.serviceError("Failed to serialize paired file")
        }

        var altIrkHex = ""
        var pairedUdid = ""
        if let pairedDataPtr = pairedDataPtr {
            let plistData = Data(bytes: pairedDataPtr, count: Int(pairedDataLen))
            idevice_data_free(pairedDataPtr, pairedDataLen)
            if let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
                pairedUdid = plist["identifier"] as? String ?? ""
                if let altIrkData = plist["alt_irk"] as? Data {
                    altIrkHex = altIrkData.map { String(format: "%02x", $0) }.joined()
                }
                verboseLog("[IdeviceGateway] startWirelessPair() parsed pairedUdid: \(pairedUdid), altIrkHex length: \(altIrkHex.count)")
            }
        }

        debugLog("[IdeviceGateway] startWirelessPair() pairing complete")
        return PairedDevice(
            name: hostName,
            model: hostModel,
            udid: pairedUdid.isEmpty ? identifier : pairedUdid,
            pairingFilePath: outPath,
            hostAltIrkHex: altIrkHex
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
                throw IdeviceGatewayError.serviceError("Failed to vend container for \(bundleId): \(msg)")
            }
            debugLog("[IdeviceGateway] startHouseArrestAfc() house_arrest_vend_container succeeded")
        }
        
        guard let resultHandle = afcHandle else {
            debugLog("[IdeviceGateway] startHouseArrestAfc() resulting AFC handle is nil")
            throw IdeviceGatewayError.serviceError("AFC handle is nil after vend_container")
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
            debugLog("[IdeviceGateway] afcListDirectory() afc_list_directory failed for: \(path)")
            defer { safeFreeError(err) }
            throw IdeviceGatewayError.serviceError("Failed to list directory: \(path)")
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
            debugLog("[IdeviceGateway] afcReadFile() afc_file_open failed for: \(path)")
            defer { safeFreeError(openErr) }
            throw IdeviceGatewayError.serviceError("Failed to open file: \(path)")
        }
        defer {
            verboseLog("[IdeviceGateway] afcReadFile() closing file handle")
            _ = afc_file_close(fileHandle)
        }
        
        var dataPtr: UnsafeMutablePointer<UInt8>? = nil
        var length: Int = 0
        let readErr = afc_file_read_entire(fileHandle, &dataPtr, &length)
        if let readErr = readErr {
            debugLog("[IdeviceGateway] afcReadFile() afc_file_read_entire failed")
            defer { safeFreeError(readErr) }
            throw IdeviceGatewayError.serviceError("Failed to read file: \(path)")
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
            throw IdeviceGatewayError.serviceError("Failed to get info for path: \(path)")
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

    func afcListDirectory(bundleId: String, path: String) throws -> [String] {
        let client = try startHouseArrestAfc(bundleId: bundleId)
        defer { afcClientFree(client: client) }
        return try afcListDirectory(client: client, path: path)
    }

    func afcReadFile(bundleId: String, path: String) throws -> Data {
        let client = try startHouseArrestAfc(bundleId: bundleId)
        defer { afcClientFree(client: client) }
        return try afcReadFile(client: client, path: path)
    }

    func afcGetFileInfo(bundleId: String, path: String) throws -> (isDirectory: Bool, fileSize: Int64) {
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

    func wipeContainer(identifier: String) throws {
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
