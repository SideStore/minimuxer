//
//  LibimobiledeviceGateway.swift
//  Minimuxer
//
//  Created by Magesh K on 22/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import libimobiledevice
import OpenSSL
import RPPairing
import DeviceGatewayAPI
internal import MinimuxerCommon

internal final class LibimobiledeviceGatewayError: DeviceGatewayError, @unchecked Sendable {
    override var errorDescription: String? {
        switch code {
        case .connectionFailed:
            return "Failed to connect to device via libimobiledevice: \(reason)"
        case .serviceError:
            return "libimobiledevice service operation failed: \(reason)"
        case .noConnection:
            return "No connection to the device via libimobiledevice."
        case .notInitialized:
            return "LibimobiledeviceGateway not initialized. start() should be called first."
        case .unsupportedOperation:
            return "Operation '\(reason)' is not supported by libimobiledevice gateway."
        default:
            return super.errorDescription
        }
    }
}

private enum OpenSSLInitResult: String, CustomStringConvertible {
    case success = "SUCCESS (1)"
    case failure = "FAILED (0)"

    init(code: Int32) {
        self = (code == 1) ? .success : .failure
    }

    var description: String {
        return rawValue
    }
}

private func getOpenSSLErrors() -> [String] {
    var errors: [String] = []
    while true {
        let errCode = ERR_get_error()
        guard errCode != 0 else { break }
        var buf = [CChar](repeating: 0, count: 256)
        ERR_error_string_n(errCode, &buf, buf.count)
        errors.append(String(cString: buf))
    }
    return errors
}

public enum DeviceService: String, Sendable {
    case lockdownd          = "com.apple.mobile.lockdown"
    // case misagent        = "com.apple.misagent"
    case misagent           = "com.apple.mobile.MCInstall.shim.remote"
    case mobileImageMounter = "com.apple.mobile.mobile_image_mounter"
    case installationProxy  = "com.apple.mobile.installation_proxy"
    case houseArrest        = "com.apple.mobile.house_arrest"
    case afc                = "com.apple.afc"
    case debugserver        = "com.apple.debugserver"
    case heartbeat          = "com.apple.mobile.heartbeat"
}

private let kAfcChunkSize = 1024 * 1024 // 1 MB AFC bulk transfer chunk
private let kDefaultTimeoutMs: Int32 = 120000

public final class LibimobiledeviceGateway: BaseDeviceGateway, DeviceGatewayAPI, @unchecked Sendable {
    public static let shared = LibimobiledeviceGateway()
    public let requiresUsbmuxd: Bool = true

    private var cachedUDID: String? = nil
    private var rpIdentity: rppairing_identity_t? = nil
    private var activeTunnel: rppairing_tunnel_t? = nil
    private var activeTunnelInfo: rppairing_tunnel_info_t? = nil
    private var activeRsd: rppairing_rsd_t? = nil

    public override init() {
        let sslOpts = UInt64(OPENSSL_INIT_LOAD_SSL_STRINGS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS | OPENSSL_INIT_ADD_ALL_CIPHERS | OPENSSL_INIT_ADD_ALL_DIGESTS)
        let sslRes = OpenSSLInitResult(code: OPENSSL_init_ssl(sslOpts, nil))
        let sslErrs = getOpenSSLErrors()
        debugLog("[LibimobiledeviceGateway] OPENSSL_init_ssl: \(sslRes)\(sslErrs.isEmpty ? "" : " (errors: \(sslErrs.joined(separator: ", ")))")")

        let cryptoOpts = UInt64(OPENSSL_INIT_LOAD_CRYPTO_STRINGS | OPENSSL_INIT_ADD_ALL_CIPHERS | OPENSSL_INIT_ADD_ALL_DIGESTS)
        let cryptoRes = OpenSSLInitResult(code: OPENSSL_init_crypto(cryptoOpts, nil))
        let cryptoErrs = getOpenSSLErrors()
        debugLog("[LibimobiledeviceGateway] OPENSSL_init_crypto: \(cryptoRes)\(cryptoErrs.isEmpty ? "" : " (errors: \(cryptoErrs.joined(separator: ", ")))")")

        let defaultProv = OSSL_PROVIDER_load(nil, "default")
        let defaultErrs = getOpenSSLErrors()
        debugLog("[LibimobiledeviceGateway] OSSL_PROVIDER_load('default'): \(String(describing: defaultProv))\(defaultErrs.isEmpty ? "" : " (errors: \(defaultErrs.joined(separator: ", ")))")")

        let baseProv = OSSL_PROVIDER_load(nil, "base")
        let baseErrs = getOpenSSLErrors()
        debugLog("[LibimobiledeviceGateway] OSSL_PROVIDER_load('base'): \(String(describing: baseProv))\(baseErrs.isEmpty ? "" : " (errors: \(baseErrs.joined(separator: ", ")))")")
        try! super.init()
    }

    deinit {
        cleanup()
    }

    public override func cleanup() {
        debugLog("[LibimobiledeviceGateway] cleanup() called")
        self.cachedUDID = nil
        rpIdentity = nil
        super.cleanup()
    }

    public override func invalidateConnection() {
        cleanupRPTunnel()
    }

    public override func stop() async throws {
        try await withFFIDispatch {
            self.cleanup()
        }
        try await super.stop()
    }

    public override func setLogging(_ enabled: Bool) {
        super.setLogging(enabled)
        idevice_set_debug_level(enabled ? 1 : 0)
        rppairing_set_debug_level(enabled ? 1 : 0)
    }

    private func verifyInitialized() throws {
        guard isInitialized, cachedUDID != nil else {
            throw LibimobiledeviceGatewayError(.notInitialized)
        }
    }

    private func requireDeviceEndpointIp() throws -> String {
        guard let ip = self.deviceEndpointIp, !ip.isEmpty else {
            debugLog("[LibimobiledeviceGateway] operation failed because deviceEndpointIp is nil or empty")
            throw LibimobiledeviceGatewayError(.deviceEndpointIpNotAvailable, reason: "Device endpoint IP has not been configured")
        }
        return ip
    }

    private func withRPClient<T>(_ body: (rppairing_client_t) throws -> T) throws -> T {
        try verifyInitialized()
        guard let identity = rpIdentity else {
            throw LibimobiledeviceGatewayError(.notInitialized, reason: "RPPairing identity not loaded")
        }
        let host = try requireDeviceEndpointIp()
        let port = getPort(for: .rppairing)
        var client: rppairing_client_t? = nil
        let err = rppairing_client_new(host, port, MinimuxerConstants.appName, &client)
        guard err == RPPAIRING_E_SUCCESS, let client = client else {
            throw LibimobiledeviceGatewayError(.connectionFailed, reason: "rppairing_client_new failed to connect to \(host):\(port): code \(err.rawValue)")
        }
        defer { rppairing_client_free(client) }

        var mutIdentity = identity
        let connErr = rppairing_pair_verify(client, &mutIdentity)
        guard connErr == RPPAIRING_E_SUCCESS else {
            debugLog("[LibimobiledeviceGateway] rppairing_pair_verify failed with code: \(connErr.rawValue)")
            throw LibimobiledeviceGatewayError(.connectionFailed, reason: "rppairing_pair_verify failed: code \(connErr.rawValue)")
        }
        debugLog("[LibimobiledeviceGateway] rppairing_pair_verify succeeded!")

        return try body(client)
    }

    private func cleanupRPTunnel() {
        if let rsd = self.activeRsd {
            rppairing_rsd_free(rsd)
            self.activeRsd = nil
        }
        if let tunnel = self.activeTunnel {
            rppairing_tunnel_close(tunnel)
            self.activeTunnel = nil
        }
        self.activeTunnelInfo = nil
    }

    private func withRPTunnel<T>(_ body: (rppairing_tunnel_t, rppairing_tunnel_info_t) throws -> T) throws -> T {
        if let tunnel = activeTunnel, let info = activeTunnelInfo {
            return try body(tunnel, info)
        }

        cleanupRPTunnel()

        let host = try requireDeviceEndpointIp()
        debugLog("[LibimobiledeviceGateway] withRPTunnel: connecting fresh tunnel to host \(host)...")

        return try withRPClient { client in
            var tunnelPort: UInt16 = 0
            let listErr = rppairing_create_tunnel_listener(client, &tunnelPort)
            guard listErr == RPPAIRING_E_SUCCESS else {
                debugLog("[LibimobiledeviceGateway] rppairing_create_tunnel_listener failed: \(listErr.rawValue)")
                throw LibimobiledeviceGatewayError(.serviceError, reason: "rppairing_create_tunnel_listener failed: code \(listErr.rawValue)")
            }
            debugLog("[LibimobiledeviceGateway] tunnel listener created on port: \(tunnelPort)")

            var psk = [UInt8](repeating: 0, count: 64)
            var pskLen = psk.count
            let keyErr = rppairing_get_encryption_key(client, &psk, &pskLen)
            guard keyErr == RPPAIRING_E_SUCCESS else {
                debugLog("[LibimobiledeviceGateway] rppairing_get_encryption_key failed: \(keyErr.rawValue)")
                throw LibimobiledeviceGatewayError(.serviceError, reason: "rppairing_get_encryption_key failed: code \(keyErr.rawValue)")
            }
            debugLog("[LibimobiledeviceGateway] encryption key retrieved (\(pskLen) bytes)")

            var tunnelInfo = rppairing_tunnel_info_t()
            var tunnel: rppairing_tunnel_t? = nil
            let tunErr = rppairing_tunnel_connect(host, tunnelPort, psk, pskLen, &tunnelInfo, &tunnel)
            guard tunErr == RPPAIRING_E_SUCCESS, let tunnel = tunnel else {
                debugLog("[LibimobiledeviceGateway] rppairing_tunnel_connect failed: \(tunErr.rawValue)")
                throw LibimobiledeviceGatewayError(.connectionFailed, reason: "rppairing_tunnel_connect failed: code \(tunErr.rawValue)")
            }

            let serverAddr = withUnsafePointer(to: &tunnelInfo.server_address) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            }
            let clientAddr = withUnsafePointer(to: &tunnelInfo.client_address) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            }
            let clientNetmask = withUnsafePointer(to: &tunnelInfo.client_netmask) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            }

            debugLog("""
            [LibimobiledeviceGateway] [RPPairing] Tunnel connected successfully!
              • server_address : \(serverAddr)
              • server_rsd_port: \(tunnelInfo.server_rsd_port)
              • client_address : \(clientAddr)
              • client_netmask : \(clientNetmask)
              • mtu            : \(tunnelInfo.mtu)
            """)

            self.activeTunnel = tunnel
            self.activeTunnelInfo = tunnelInfo
            return try body(tunnel, tunnelInfo)
        }
    }



    private func getActiveRSD(tunnel: rppairing_tunnel_t) throws -> rppairing_rsd_t {
        if let rsd = self.activeRsd {
            return rsd
        }
        var rsd: rppairing_rsd_t? = nil
        let rsdErr = rppairing_rsd_connect(tunnel, &rsd)
        guard rsdErr == RPPAIRING_E_SUCCESS, let rsd = rsd else {
            throw LibimobiledeviceGatewayError(.serviceError, reason: "rppairing_rsd_connect failed: code \(rsdErr.rawValue)")
        }
        self.activeRsd = rsd
        return rsd
    }

    private func withRSDService<T>(_ service: DeviceService, action: (rppairing_service_stream_t) throws -> T) throws -> T {
        try withRPTunnel { tunnel, info in
            let rsd = try getActiveRSD(tunnel: tunnel)

            var servicePort: UInt16 = 0
            let portErr = rppairing_rsd_get_service_port(rsd, service.rawValue, &servicePort)
            guard portErr == RPPAIRING_E_SUCCESS, servicePort > 0 else {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "RSD service \(service.rawValue) not found or port invalid (code \(portErr.rawValue))")
            }

            debugLog("[LibimobiledeviceGateway] Connecting to RSD service \(service.rawValue) on port \(servicePort)...")
            var stream: rppairing_service_stream_t? = nil
            let streamErr = rppairing_connect_service_stream(tunnel, servicePort, &stream)
            guard streamErr == RPPAIRING_E_SUCCESS, let stream = stream else {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "rppairing_connect_service_stream failed: code \(streamErr.rawValue)")
            }
            defer { rppairing_service_stream_close(stream) }

            // Perform RSDCheckin handshake required on iOS 17+
            try rsdSendPlist(stream, dict: [
                "Label": "SideStore",
                "ProtocolVersion": "2",
                "Request": "RSDCheckin"
            ])
            let checkinResp = try rsdRecvPlist(stream)
            debugLog("[LibimobiledeviceGateway] RSDCheckin response: \(checkinResp)")
            let startServiceResp = try rsdRecvPlist(stream)
            debugLog("[LibimobiledeviceGateway] StartService response: \(startServiceResp)")

            return try action(stream)
        }
    }

    private func rsdSendPlist(_ stream: rppairing_service_stream_t, dict: [String: Any]) throws {
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        guard let xmlStr = String(data: plistData, encoding: .utf8) else {
            throw LibimobiledeviceGatewayError(.serviceError, reason: "Failed to encode XML Plist")
        }
        let err = rppairing_service_stream_send_plist(stream, xmlStr, xmlStr.utf8.count)
        if err != RPPAIRING_E_SUCCESS {
            throw LibimobiledeviceGatewayError(.serviceError, reason: "rsdSendPlist failed: code \(err.rawValue)")
        }
    }

    private func rsdRecvPlist(_ stream: rppairing_service_stream_t, timeoutMs: Int32 = kDefaultTimeoutMs) throws -> [String: Any] {
        var outXml: UnsafeMutablePointer<CChar>? = nil
        var outLen: Int = 0
        let err = rppairing_service_stream_recv_plist(stream, &outXml, &outLen, timeoutMs)
        guard err == RPPAIRING_E_SUCCESS, let outXml = outXml else {
            throw LibimobiledeviceGatewayError(.serviceError, reason: "rsdRecvPlist failed: code \(err.rawValue)")
        }
        defer { free(outXml) }

        let xmlData = Data(bytes: outXml, count: outLen)
        guard let plist = try? PropertyListSerialization.propertyList(from: xmlData, options: [], format: nil) as? [String: Any] else {
            return [:]
        }
        return plist
    }

    // Helper: Opens an idevice_t connection (looking up both USBMUX and Network)
    private func withDevice<T>(_ body: (idevice_t) throws -> T) throws -> T {
        try verifyInitialized()
        guard let udid = self.cachedUDID else {
            throw LibimobiledeviceGatewayError(.notInitialized)
        }
        var device: idevice_t? = nil
        let opts = idevice_options(rawValue: IDEVICE_LOOKUP_USBMUX.rawValue | IDEVICE_LOOKUP_NETWORK.rawValue)
        let err = idevice_new_with_options(&device, udid, opts)
        guard err == IDEVICE_E_SUCCESS, let device = device else {
            throw LibimobiledeviceGatewayError(.connectionFailed, reason: "idevice_new_with_options failed with code \(err.rawValue)")
        }
        defer { idevice_free(device) }
        return try body(device)
    }

    // Helper: Establishes a lockdown session with handshake
    private func withLockdown<T>(_ body: (idevice_t, lockdownd_client_t) throws -> T) throws -> T {
        try withDevice { device in
            var client: lockdownd_client_t? = nil
            let err = lockdownd_client_new_with_handshake(device, &client, nil)
            guard err == LOCKDOWN_E_SUCCESS, let client = client else {
                throw LibimobiledeviceGatewayError(.connectionFailed, reason: "lockdownd_client_new_with_handshake failed with code \(err.rawValue)")
            }
            defer { lockdownd_client_free(client) }
            return try body(device, client)
        }
    }

    // Helper: Starts a lockdown service descriptor and creates a typed client
    private func withService<Client, E: RawRepresentable, T>(
        service: DeviceService,
        create: (idevice_t?, lockdownd_service_descriptor_t?, UnsafeMutablePointer<Client?>?) -> E,
        cleanup: (Client?) -> E,
        _ body: (Client) throws -> T
    ) throws -> T where E.RawValue: BinaryInteger {
        try withLockdown { device, lockdown in
            var serviceDescriptor: lockdownd_service_descriptor_t? = nil
            let sErr = lockdownd_start_service(lockdown, service.rawValue, &serviceDescriptor)
            guard sErr == LOCKDOWN_E_SUCCESS, let serviceDescriptor = serviceDescriptor else {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "Failed to start lockdown service '\(service.rawValue)': code \(sErr.rawValue)")
            }
            defer { lockdownd_service_descriptor_free(serviceDescriptor) }

            var client: Client? = nil
            let cErr = create(device, serviceDescriptor, &client)
            guard cErr.rawValue == 0, let client = client else {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "Failed to create client for '\(service.rawValue)': code \(cErr.rawValue)")
            }
            defer { _ = cleanup(client) }
            return try body(client)
        }
    }

    func syncStart(pairingFileContent: String, preferred: PairingProtocol?) throws {
        debugLog("[LibimobiledeviceGateway] start() called")
        cleanup()

        let pairingFile = try PairingFileParser.parse(content: pairingFileContent, preferred: preferred)
        setPairingFileData(pairingFile.rawData)
        setPairingFileType(pairingFile.mode)

        if pairingFile.mode == .rppairing {
            var identity = rppairing_identity_t()
            let err = pairingFileContent.withCString { cStr in
                rppairing_identity_from_plist(cStr, pairingFileContent.utf8.count, &identity)
            }
            guard err == RPPAIRING_E_SUCCESS else {
                throw LibimobiledeviceGatewayError(.invalidPairingFile, reason: "rppairing_identity_from_plist failed with code \(err.rawValue)")
            }
            self.rpIdentity = identity
        } else if let lockdown = pairingFile as? LockdownPairingFile {
            let udid = lockdown.udid
            guard !udid.isEmpty else {
                throw LibimobiledeviceGatewayError(.invalidPairingFile, reason: "Missing UDID in pairing file")
            }
            self.cachedUDID = udid
        }

        setInitialized(true)

        debugLog("[LibimobiledeviceGateway] Initialized successfully with \(pairingFile.mode.rawValue) pairing")
    }

    func syncFetchUDID() throws -> String {
        try verifyInitialized()
        do {
            let hwUdid = try syncGetLockdownValue(key: "UniqueDeviceID")
            if !hwUdid.isEmpty {
                debugLog("[LibimobiledeviceGateway] syncFetchUDID: retrieved hardware UDID: \(hwUdid)")
                self.cachedUDID = hwUdid
                return hwUdid
            }
        } catch {
            debugLog("[LibimobiledeviceGateway] syncFetchUDID: failed to query lockdown: \(error)")
        }
        if let cached = cachedUDID, !cached.isEmpty {
            return cached
        }
        throw LibimobiledeviceGatewayError(.serviceError, reason: "UniqueDeviceID not found on device")
    }

    func syncGetLockdownValue(key: String) throws -> String {
        if pairingFileType == .rppairing {
            return try withRSDService(.lockdownd) { stream in
                try rsdSendPlist(stream, dict: ["Label": "SideStore", "Request": "GetValue", "Key": key])
                let resp = try rsdRecvPlist(stream)
                debugLog("[LibimobiledeviceGateway] syncGetLockdownValue(\(key)) response: \(resp)")
                guard let val = resp["Value"] as? String else {
                    debugLog("[LibimobiledeviceGateway] syncGetLockdownValue(\(key)) Value missing or invalid: \(resp)")
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "Lockdown value for key '\(key)' is missing or invalid")
                }
                return val
            }
        }

        return try withLockdown { (_, client) -> String in
            var valNode: plist_t? = nil
            let err = lockdownd_get_value(client, nil, key, &valNode)
            guard err == LOCKDOWN_E_SUCCESS, let valNode = valNode else {
                debugLog("[LibimobiledeviceGateway] syncGetLockdownValue(\(key)) lockdownd_get_value failed with code \(err.rawValue)")
                throw LibimobiledeviceGatewayError(.serviceError, reason: "Failed to get lockdown value for key '\(key)': code \(err.rawValue)")
            }
            defer { plist_free(valNode) }

            var valPtr: UnsafeMutablePointer<CChar>? = nil
            plist_get_string_val(valNode, &valPtr)
            guard let valPtr = valPtr else {
                debugLog("[LibimobiledeviceGateway] syncGetLockdownValue(\(key)) plist string pointer is nil")
                throw LibimobiledeviceGatewayError(.serviceError, reason: "Lockdown value for key '\(key)' could not be decoded as string")
            }
            let val = String(cString: valPtr)
            free(valPtr)
            return val
        }
    }

    func syncIsDDIMounted() throws -> Bool {
        if pairingFileType == .rppairing {
            return try withRSDService(.mobileImageMounter) { stream in
                try rsdSendPlist(stream, dict: ["Command": "LookupImage", "ImageType": "Developer"])
                let resp = try rsdRecvPlist(stream)
                let sig = resp["ImageSignature"]
                return sig != nil
            }
        }

        return try withService(
            service: .mobileImageMounter,
            create: mobile_image_mounter_new,
            cleanup: mobile_image_mounter_free
        ) { mounter in
            var resultPlist: plist_t? = nil
            let err = mobile_image_mounter_lookup_image(mounter, "Developer", &resultPlist)
            guard err == MOBILE_IMAGE_MOUNTER_E_SUCCESS, let resultPlist = resultPlist else {
                return false
            }
            defer { plist_free(resultPlist) }

            let sigDict = plist_dict_get_item(resultPlist, "ImageSignature")
            return sigDict != nil
        }
    }

    func syncMountDeveloperImage(image: Data, signature: Data) throws {
        if pairingFileType == .rppairing {
            try withRSDService(.mobileImageMounter) { stream in
                try rsdSendPlist(stream, dict: ["Command": "ReceiveBytes", "ImageSize": image.count, "ImageType": "Developer"])
                let resp1 = try rsdRecvPlist(stream)
                if (resp1["Status"] as? String) != "ReceiveBytesAck" {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "ReceiveBytes not acknowledged")
                }
                try image.withUnsafeBytes { rawBuf in
                    if let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                        let err = rppairing_service_stream_send_raw(stream, ptr, image.count)
                        if err != RPPAIRING_E_SUCCESS {
                            throw LibimobiledeviceGatewayError(.serviceError, reason: "Streaming DDI image failed: code \(err.rawValue)")
                        }
                    }
                }
                let resp2 = try rsdRecvPlist(stream)
                if (resp2["Status"] as? String) != "Complete" {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "Image upload did not complete: \(resp2)")
                }
                try rsdSendPlist(stream, dict: [
                    "Command": "MountImage",
                    "ImageType": "Developer",
                    "ImageSignature": signature
                ])
                let resp3 = try rsdRecvPlist(stream, timeoutMs: 30000)
                if (resp3["Status"] as? String) != "Complete" {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "MountImage failed: \(resp3["Error"] ?? "Unknown error")")
                }
            }
            return
        }

        try withService(
            service: .mobileImageMounter,
            create: mobile_image_mounter_new,
            cleanup: mobile_image_mounter_free
        ) { mounter in
            try signature.withUnsafeBytes { sigBuf in
                guard let sigPtr = sigBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "Invalid signature buffer")
                }
                var resultPlist: plist_t? = nil
                let res = mobile_image_mounter_mount_image(
                    mounter,
                    "/tmp/DeveloperDiskImage.dmg",
                    sigPtr,
                    UInt32(signature.count),
                    "Developer",
                    &resultPlist
                )
                if let resultPlist = resultPlist {
                    plist_free(resultPlist)
                }
                if res != MOBILE_IMAGE_MOUNTER_E_SUCCESS {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "mobile_image_mounter_mount_image failed with code \(res.rawValue)")
                }
            }
        }
    }

    func syncMountPersonalizedDdi(image: Data, trustcache: Data, manifest: Data) throws {
        if pairingFileType == .rppairing {
            try withRSDService(.mobileImageMounter) { stream in
                debugLog("[LibimobiledeviceGateway] Sending ReceiveBytes for DDI (size: \(image.count))...")
                try rsdSendPlist(stream, dict: ["Command": "ReceiveBytes", "ImageSize": image.count, "ImageType": "Personalized"])
                let resp1 = try rsdRecvPlist(stream)
                if (resp1["Status"] as? String) != "ReceiveBytesAck" {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "ReceiveBytes not acknowledged by device: \(resp1)")
                }

                debugLog("[LibimobiledeviceGateway] Streaming DDI image bytes...")
                try image.withUnsafeBytes { rawBuf in
                    if let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                        let err = rppairing_service_stream_send_raw(stream, ptr, image.count)
                        if err != RPPAIRING_E_SUCCESS {
                            throw LibimobiledeviceGatewayError(.serviceError, reason: "Streaming DDI image failed: code \(err.rawValue)")
                        }
                    }
                }

                let resp2 = try rsdRecvPlist(stream)
                if (resp2["Status"] as? String) != "Complete" {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "Image upload did not complete: \(resp2)")
                }

                debugLog("[LibimobiledeviceGateway] Mounting Personalized DDI...")
                try rsdSendPlist(stream, dict: [
                    "Command": "MountImage",
                    "ImageType": "Personalized",
                    "ImageSignature": manifest,
                    "ImageTrustCache": trustcache
                ])
                let resp3 = try rsdRecvPlist(stream, timeoutMs: 30000)
                if (resp3["Status"] as? String) != "Complete" {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "MountImage failed: \(resp3["Error"] ?? "Unknown error")")
                }
                debugLog("[LibimobiledeviceGateway] Personalized DDI mounted successfully via RSD!")
            }
            return
        }

        try withService(
            service: .mobileImageMounter,
            create: mobile_image_mounter_new,
            cleanup: mobile_image_mounter_free
        ) { mounter in
            try signaturePlaceholder(image: image, trustcache: trustcache, manifest: manifest, mounter: mounter)
        }
    }

    private func signaturePlaceholder(image: Data, trustcache: Data, manifest: Data, mounter: mobile_image_mounter_client_t) throws {
        var optionsPlist: plist_t? = plist_new_dict()
        defer { if let p = optionsPlist { plist_free(p) } }

        try trustcache.withUnsafeBytes { tcBuf in
            if let tcPtr = tcBuf.baseAddress?.assumingMemoryBound(to: CChar.self) {
                let tcDataPlist = plist_new_data(tcPtr, UInt64(trustcache.count))
                plist_dict_set_item(optionsPlist, "ImageTrustCache", tcDataPlist)
            }
        }

        try manifest.withUnsafeBytes { mftBuf in
            if let mftPtr = mftBuf.baseAddress?.assumingMemoryBound(to: CChar.self) {
                let mftDataPlist = plist_new_data(mftPtr, UInt64(manifest.count))
                plist_dict_set_item(optionsPlist, "ImageManifest", mftDataPlist)
            }
        }

        var resultPlist: plist_t? = nil
        let res = mobile_image_mounter_mount_image_with_options(
            mounter,
            "/tmp/PersonalizedImage.dmg",
            nil,
            0,
            "Personalized",
            optionsPlist,
            &resultPlist
        )
        if let resultPlist = resultPlist {
            plist_free(resultPlist)
        }
        if res != MOBILE_IMAGE_MOUNTER_E_SUCCESS {
            throw LibimobiledeviceGatewayError(.serviceError, reason: "mobile_image_mounter_mount_image_with_options failed with code \(res.rawValue)")
        }
    }

    func syncInstallProvisioningProfile(profile: Data) throws {
        if pairingFileType == .rppairing {
            try withRSDService(.misagent) { stream in
                debugLog("[LibimobiledeviceGateway] Installing provisioning profile via RSD misagent...")
                try rsdSendPlist(stream, dict: ["MessageType": "Install", "Profile": profile])
                let resp = try rsdRecvPlist(stream)
                if let status = resp["Status"] as? Int, status != 0 {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "misagent install failed with status: \(status)")
                }
                debugLog("[LibimobiledeviceGateway] Provisioning profile installed successfully via RSD!")
            }
            return
        }

        try withService(
            service: .misagent,
            create: misagent_client_new,
            cleanup: misagent_client_free
        ) { misagent in
            try profile.withUnsafeBytes { profBuf in
                guard let profPtr = profBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "Invalid profile buffer")
                }
                let plistProfile = plist_new_data(profPtr, UInt64(profile.count))
                defer { if let p = plistProfile { plist_free(p) } }

                let res = misagent_install(misagent, plistProfile)
                if res != MISAGENT_E_SUCCESS {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "misagent_install failed with code \(res.rawValue)")
                }
            }
        }
    }

    func syncRemoveProvisioningProfile(id: String) throws {
        if pairingFileType == .rppairing {
            try withRSDService(.misagent) { stream in
                try rsdSendPlist(stream, dict: ["MessageType": "Remove", "ProfileID": id])
                let resp = try rsdRecvPlist(stream)
                if let status = resp["Status"] as? Int, status != 0 {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "misagent remove failed with status: \(status)")
                }
            }
            return
        }

        try withService(
            service: .misagent,
            create: misagent_client_new,
            cleanup: misagent_client_free
        ) { misagent in
            let res = misagent_remove(misagent, id)
            if res != MISAGENT_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "misagent_remove failed with code \(res.rawValue)")
            }
        }
    }

    func syncDumpProfiles(docsPath: String) throws -> String {
        let path = docsPath.hasPrefix("file://") ? String(docsPath.dropFirst(7)) : docsPath
        let dumpDir = path.hasSuffix("/Profiles") || path.hasSuffix("/Profiles/") ? path : "\(path)/Profiles"
        try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)
        if pairingFileType == .rppairing {
            return try withRSDService(.misagent) { stream in
                try rsdSendPlist(stream, dict: ["MessageType": "CopyAll"])
                let resp = try rsdRecvPlist(stream, timeoutMs: 10000)
                guard let profiles = resp["ProfileArray"] as? [Data] else {
                    return ""
                }
                for (idx, pData) in profiles.enumerated() {
                    let filePath = (dumpDir as NSString).appendingPathComponent("Profile_\(idx).mobileprovision")
                    try? pData.write(to: URL(fileURLWithPath: filePath))
                }
                return dumpDir
            }
        }

        return try withService(
            service: .misagent,
            create: misagent_client_new,
            cleanup: misagent_client_free
        ) { misagent in
            var profilesPlist: plist_t? = nil
            let res = misagent_copy_all(misagent, &profilesPlist)
            if res != MISAGENT_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "misagent_copy_all failed with code \(res.rawValue)")
            }
            defer { if let p = profilesPlist { plist_free(p) } }

            var xmlPtr: UnsafeMutablePointer<CChar>? = nil
            var xmlLen: UInt32 = 0
            plist_to_xml(profilesPlist, &xmlPtr, &xmlLen)
            if let xmlPtr = xmlPtr {
                let xmlStr = String(cString: xmlPtr)
                free(xmlPtr)
                return xmlStr
            }
            return ""
        }
    }

    func syncRemoveApp(bundleId: String) throws {
        if pairingFileType == .rppairing {
            try withRSDService(.installationProxy) { stream in
                try rsdSendPlist(stream, dict: [
                    "Command": "Uninstall",
                    "ApplicationIdentifier": bundleId
                ])
                _ = try? rsdRecvPlist(stream, timeoutMs: 30000)
            }
            return
        }

        try withService(
            service: .installationProxy,
            create: instproxy_client_new,
            cleanup: instproxy_client_free
        ) { instproxy in
            let res = instproxy_uninstall(instproxy, bundleId, nil, nil, nil)
            if res != INSTPROXY_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "instproxy_uninstall failed with code \(res.rawValue)")
            }
        }
    }

    private func rsdAfcSendPacket(
        _ stream: rppairing_service_stream_t,
        opcode: UInt64,
        headerPayload: Data = Data(),
        payload: Data = Data(),
        packetNum: inout UInt64
    ) throws {
        let magic: UInt64 = 0x4141504C36414643 // "CFA6LPAA" LE
        let entireLen = UInt64(40 + headerPayload.count + payload.count)
        let headerPayloadLen = UInt64(40 + headerPayload.count)

        var header = Data()
        header.append(contentsOf: withUnsafeBytes(of: magic.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: entireLen.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: headerPayloadLen.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: packetNum.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: opcode.littleEndian) { Array($0) })
        packetNum += 1

        var fullPacket = header
        fullPacket.append(headerPayload)
        fullPacket.append(payload)

        try fullPacket.withUnsafeBytes { raw in
            if let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                let err = rppairing_service_stream_send_raw(stream, ptr, fullPacket.count)
                if err != RPPAIRING_E_SUCCESS {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "AFC send packet failed: code \(err.rawValue)")
                }
            }
        }
    }

    private func rsdAfcRecvResponse(
        _ stream: rppairing_service_stream_t,
        timeoutMs: Int32 = kDefaultTimeoutMs
    ) throws -> (opcode: UInt64, headerPayload: Data, payload: Data) {
        var hdrBuf = [UInt8](repeating: 0, count: 40)
        let hdrErr = rppairing_service_stream_recv_exact(stream, &hdrBuf, 40, timeoutMs)
        guard hdrErr == RPPAIRING_E_SUCCESS else {
            throw LibimobiledeviceGatewayError(.serviceError, reason: "AFC recv header failed: code \(hdrErr.rawValue)")
        }

        let entireLen = hdrBuf.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }.littleEndian
        let headerPayloadLen = hdrBuf.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self) }.littleEndian
        let opcode = hdrBuf.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt64.self) }.littleEndian

        let headerPayloadSize = Int(headerPayloadLen >= 40 ? headerPayloadLen - 40 : 0)
        var headerPayload = Data()
        if headerPayloadSize > 0 {
            var buf = [UInt8](repeating: 0, count: headerPayloadSize)
            let err = rppairing_service_stream_recv_exact(stream, &buf, headerPayloadSize, timeoutMs)
            guard err == RPPAIRING_E_SUCCESS else {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "AFC recv header payload failed: code \(err.rawValue)")
            }
            headerPayload = Data(buf)
        }

        let payloadSize = Int(entireLen >= headerPayloadLen ? entireLen - headerPayloadLen : 0)
        var payload = Data()
        if payloadSize > 0 {
            var buf = [UInt8](repeating: 0, count: payloadSize)
            let err = rppairing_service_stream_recv_exact(stream, &buf, payloadSize, timeoutMs)
            guard err == RPPAIRING_E_SUCCESS else {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "AFC recv payload failed: code \(err.rawValue)")
            }
            payload = Data(buf)
        }

        return (opcode, headerPayload, payload)
    }

    private func rsdAfcMakeDir(_ stream: rppairing_service_stream_t, path: String, packetNum: inout UInt64) throws {
        var payload = Data(path.utf8)
        payload.append(0)
        try rsdAfcSendPacket(stream, opcode: 9 /* MakeDir */, headerPayload: payload, packetNum: &packetNum)
        _ = try? rsdAfcRecvResponse(stream)
    }

    private func rsdAfcFileOpen(_ stream: rppairing_service_stream_t, path: String, mode: UInt64, packetNum: inout UInt64) throws -> UInt64 {
        var openPayload = withUnsafeBytes(of: mode.littleEndian) { Data($0) }
        openPayload.append(contentsOf: path.utf8)
        openPayload.append(0)

        try rsdAfcSendPacket(stream, opcode: 13 /* FileOpen */, headerPayload: openPayload, packetNum: &packetNum)
        let resp = try rsdAfcRecvResponse(stream)
        guard resp.headerPayload.count >= 8 else {
            throw LibimobiledeviceGatewayError(.serviceError, reason: "AFC FileOpen response invalid for \(path)")
        }
        let fd = resp.headerPayload.withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
        guard fd != 0 else {
            throw LibimobiledeviceGatewayError(.serviceError, reason: "AFC FileOpen returned fd 0 for \(path)")
        }
        return fd
    }

    private func rsdAfcFileClose(_ stream: rppairing_service_stream_t, fd: UInt64, packetNum: inout UInt64) throws {
        let closePayload = withUnsafeBytes(of: fd.littleEndian) { Data($0) }
        try rsdAfcSendPacket(stream, opcode: 20 /* FileClose */, headerPayload: closePayload, packetNum: &packetNum)
        _ = try? rsdAfcRecvResponse(stream)
    }

    func syncsendIpaAfc(bundleId: String, ipaBytes: Data) throws {
        if pairingFileType == .rppairing {
            try withRSDService(.afc) { stream in
                var packetNum: UInt64 = 0
                let remotePath = "PublicStaging/\(bundleId).ipa"

                debugLog("[LibimobiledeviceGateway] syncsendIpaAfc: Ensuring PublicStaging directory exists...")
                try rsdAfcMakeDir(stream, path: "PublicStaging", packetNum: &packetNum)

                debugLog("[LibimobiledeviceGateway] syncsendIpaAfc: Opening \(remotePath)...")
                let fd = try rsdAfcFileOpen(stream, path: remotePath, mode: 3, packetNum: &packetNum)
                defer { try? rsdAfcFileClose(stream, fd: fd, packetNum: &packetNum) }

                debugLog("[LibimobiledeviceGateway] syncsendIpaAfc: Staging file opened (fd=\(fd)), uploading \(ipaBytes.count) bytes...")
                var offset = 0
                var chunkIdx = 0
                let totalChunks = (ipaBytes.count + kAfcChunkSize - 1) / kAfcChunkSize
                while offset < ipaBytes.count {
                    let end = min(offset + kAfcChunkSize, ipaBytes.count)
                    let chunk = ipaBytes.subdata(in: offset..<end)
                    let writeHeaderPayload = withUnsafeBytes(of: fd.littleEndian) { Data($0) }

                    chunkIdx += 1
                    try rsdAfcSendPacket(stream, opcode: 16 /* Write */, headerPayload: writeHeaderPayload, payload: chunk, packetNum: &packetNum)
                    let writeResp = try rsdAfcRecvResponse(stream)
                    if writeResp.opcode == 1 /* Status */ && writeResp.headerPayload.count >= 8 {
                        let status = writeResp.headerPayload.withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
                        if status != 0 {
                            throw LibimobiledeviceGatewayError(.serviceError, reason: "AFC Write failed with status \(status)")
                        }
                    }
                    offset = end
                    if chunkIdx % 5 == 0 || offset >= ipaBytes.count {
                        debugLog("[LibimobiledeviceGateway] syncsendIpaAfc: Uploaded chunk \(chunkIdx)/\(totalChunks) (\(offset)/\(ipaBytes.count) bytes)")
                    }
                }
                debugLog("[LibimobiledeviceGateway] Successfully uploaded \(ipaBytes.count) bytes to \(remotePath) via RSD AFC!")
            }
            return
        }

        try withService(
            service: .afc,
            create: afc_client_new,
            cleanup: afc_client_free
        ) { afc in
            let remotePath = "PublicStaging/\(bundleId).ipa"
            var handle: UInt64 = 0
            let openRes = afc_file_open(afc, remotePath, AFC_FOPEN_RW, &handle)
            guard openRes == AFC_E_SUCCESS, handle != 0 else {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "afc_file_open failed with code \(openRes.rawValue)")
            }
            defer { _ = afc_file_close(afc, handle) }

            try ipaBytes.withUnsafeBytes { rawBuf in
                guard let baseAddr = rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "Invalid IPA buffer")
                }
                var bytesWritten: UInt32 = 0
                let writeRes = afc_file_write(afc, handle, baseAddr, UInt32(ipaBytes.count), &bytesWritten)
                if writeRes != AFC_E_SUCCESS {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "afc_file_write failed with code \(writeRes.rawValue)")
                }
            }
        }
    }

    func syncInstallIpa(bundleId: String) throws {
        if pairingFileType == .rppairing {
            try withRSDService(.installationProxy) { stream in
                let remotePath = "PublicStaging/\(bundleId).ipa"
                let dict: [String: Any] = [
                    "Command": "Install",
                    "PackagePath": remotePath,
                    "ClientOptions": [
                        "PackageType": "Developer"
                    ]
                ]
                debugLog("[LibimobiledeviceGateway] Sending installation_proxy command to install \(remotePath)...")
                try rsdSendPlist(stream, dict: dict)
                while true {
                    let resp = try rsdRecvPlist(stream)
                    debugLog("[LibimobiledeviceGateway] installation_proxy response: \(resp)")
                    if let status = resp["Status"] as? String {
                        if status == "Complete" {
                            debugLog("[LibimobiledeviceGateway] installation_proxy completed successfully for \(bundleId)!")
                            return
                        }
                    }
                    if let err = resp["Error"] as? String {
                        throw LibimobiledeviceGatewayError(.serviceError, reason: "Installation failed: \(err)")
                    }
                }
            }
            return
        }

        try withService(
            service: .installationProxy,
            create: instproxy_client_new,
            cleanup: instproxy_client_free
        ) { instproxy in
            let remotePath = "PublicStaging/\(bundleId).ipa"
            let res = instproxy_install(instproxy, remotePath, nil, nil, nil)
            if res != INSTPROXY_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "instproxy_install failed with code \(res.rawValue)")
            }
        }
    }

    func syncsendAppBundleAfc(bundleId: String, appURL: URL) throws {
        let appName = appURL.lastPathComponent
        let remoteBaseDir = "PublicStaging/\(bundleId)"
        let remoteAppPath = "\(remoteBaseDir)/\(appName)"

        if pairingFileType == .rppairing {
            try withRSDService(.afc) { stream in
                var packetNum: UInt64 = 0

                debugLog("[LibimobiledeviceGateway] syncYeetAppDirectory: Ensuring PublicStaging directory exists...")
                try rsdAfcMakeDir(stream, path: "PublicStaging", packetNum: &packetNum)
                try rsdAfcMakeDir(stream, path: remoteBaseDir, packetNum: &packetNum)
                try rsdAfcMakeDir(stream, path: remoteAppPath, packetNum: &packetNum)

                let fileManager = FileManager.default
                guard let enumerator = fileManager.enumerator(
                    at: appURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: []
                ) else {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "Failed to enumerate \(appURL.path)")
                }

                for case let fileURL as URL in enumerator {
                    let relativePath = fileURL.path.replacingOccurrences(of: appURL.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let remoteItemPath = "\(remoteAppPath)/\(relativePath)"

                    var isDirectory: ObjCBool = false
                    fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)

                    if isDirectory.boolValue {
                        try rsdAfcMakeDir(stream, path: remoteItemPath, packetNum: &packetNum)
                    } else {
                        let fd = try rsdAfcFileOpen(stream, path: remoteItemPath, mode: 3, packetNum: &packetNum)
                        defer { try? rsdAfcFileClose(stream, fd: fd, packetNum: &packetNum) }

                        let data = try Data(contentsOf: fileURL, options: .alwaysMapped)
                        var offset = 0
                        while offset < data.count {
                            let end = min(offset + kAfcChunkSize, data.count)
                            let chunk = data.subdata(in: offset..<end)
                            let writeHeaderPayload = withUnsafeBytes(of: fd.littleEndian) { Data($0) }

                            packetNum += 1
                            try rsdAfcSendPacket(stream, opcode: 16 /* Write */, headerPayload: writeHeaderPayload, payload: chunk, packetNum: &packetNum)
                            let writeResp = try rsdAfcRecvResponse(stream)
                            if writeResp.opcode == 1 && writeResp.headerPayload.count >= 8 {
                                let status = writeResp.headerPayload.withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
                                if status != 0 {
                                    throw LibimobiledeviceGatewayError(.serviceError, reason: "AFC Write failed with status \(status) for \(remoteItemPath)")
                                }
                            }
                            offset = end
                        }
                    }
                }
                debugLog("[LibimobiledeviceGateway] Successfully uploaded app bundle to \(remoteAppPath) via RSD AFC!")
            }
            return
        }

        try withService(
            service: .afc,
            create: afc_client_new,
            cleanup: afc_client_free
        ) { afc in
            _ = afc_make_directory(afc, "PublicStaging")
            _ = afc_make_directory(afc, remoteBaseDir)
            _ = afc_make_directory(afc, remoteAppPath)

            let fileManager = FileManager.default
            guard let enumerator = fileManager.enumerator(
                at: appURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "Failed to enumerate \(appURL.path)")
            }

            for case let fileURL as URL in enumerator {
                let relativePath = fileURL.path.replacingOccurrences(of: appURL.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let remoteItemPath = "\(remoteAppPath)/\(relativePath)"

                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)

                if isDirectory.boolValue {
                    _ = afc_make_directory(afc, remoteItemPath)
                } else {
                    var handle: UInt64 = 0
                    let openRes = afc_file_open(afc, remoteItemPath, AFC_FOPEN_RW, &handle)
                    guard openRes == AFC_E_SUCCESS, handle != 0 else {
                        throw LibimobiledeviceGatewayError(.serviceError, reason: "afc_file_open failed for \(remoteItemPath) with code \(openRes.rawValue)")
                    }
                    defer { _ = afc_file_close(afc, handle) }

                    let data = try Data(contentsOf: fileURL, options: .alwaysMapped)
                    if !data.isEmpty {
                        try data.withUnsafeBytes { rawBuf in
                            guard let baseAddr = rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                                throw LibimobiledeviceGatewayError(.serviceError, reason: "Invalid file buffer")
                            }
                            var bytesWritten: UInt32 = 0
                            let writeRes = afc_file_write(afc, handle, baseAddr, UInt32(data.count), &bytesWritten)
                            if writeRes != AFC_E_SUCCESS {
                                throw LibimobiledeviceGatewayError(.serviceError, reason: "afc_file_write failed for \(remoteItemPath) with code \(writeRes.rawValue)")
                            }
                        }
                    }
                }
            }
            debugLog("[LibimobiledeviceGateway] Successfully uploaded app bundle to \(remoteAppPath) via Lockdown AFC!")
        }
    }

    func syncInstallAppBundle(bundleId: String, appName: String) throws {
        let remotePath = "PublicStaging/\(bundleId)/\(appName)"
        if pairingFileType == .rppairing {
            try withRSDService(.installationProxy) { stream in
                let dict: [String: Any] = [
                    "Command": "Install",
                    "PackagePath": remotePath,
                    "ClientOptions": [
                        "PackageType": "Developer"
                    ]
                ]
                debugLog("[LibimobiledeviceGateway] Sending installation_proxy command to install \(remotePath)...")
                try rsdSendPlist(stream, dict: dict)
                while true {
                    let resp = try rsdRecvPlist(stream)
                    debugLog("[LibimobiledeviceGateway] installation_proxy response: \(resp)")
                    if let status = resp["Status"] as? String {
                        if status == "Complete" {
                            debugLog("[LibimobiledeviceGateway] installation_proxy completed successfully for \(bundleId)!")
                            return
                        }
                    }
                    if let err = resp["Error"] as? String {
                        throw LibimobiledeviceGatewayError(.serviceError, reason: "Installation failed: \(err)")
                    }
                }
            }
            return
        }

        try withService(
            service: .installationProxy,
            create: instproxy_client_new,
            cleanup: instproxy_client_free
        ) { instproxy in
            let clientOptions: plist_t? = plist_new_dict()
            defer { plist_free(clientOptions) }
            plist_dict_set_item(clientOptions, "PackageType", plist_new_string("Developer"))

            let res = instproxy_install(instproxy, remotePath, clientOptions, nil, nil)
            if res != INSTPROXY_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "instproxy_install failed with code \(res.rawValue)")
            }
        }
    }

    func syncWipeContainer(identifier: String) throws {
        if pairingFileType == .rppairing {
            try withRSDService(.houseArrest) { stream in
                try rsdSendPlist(stream, dict: [
                    "Command": "VendContainer",
                    "Identifier": identifier
                ])
                _ = try? rsdRecvPlist(stream, timeoutMs: 10000)
            }
            return
        }

        try withService(
            service: .houseArrest,
            create: house_arrest_client_new,
            cleanup: house_arrest_client_free
        ) { ha in
            let res = house_arrest_send_command(ha, "VendContainer", identifier)
            if res != HOUSE_ARREST_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "house_arrest_send_command failed with code \(res.rawValue)")
            }
            var resultDict: plist_t? = nil
            let gRes = house_arrest_get_result(ha, &resultDict)
            if let resultDict = resultDict {
                plist_free(resultDict)
            }
            if gRes != HOUSE_ARREST_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "house_arrest_get_result failed with code \(gRes.rawValue)")
            }
        }
    }

    @discardableResult
    private func sendDebugserverCommand(client: debugserver_client_t, name: String, args: [String]) throws -> String? {
        debugLog("[LibimobiledeviceGateway] sendDebugserverCommand() called, name: \(name), args: \(args)")
        var command: debugserver_command_t? = nil
        var argPtrs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        defer {
            for ptr in argPtrs {
                if let ptr = ptr { free(ptr) }
            }
        }

        let newErr = name.withCString { namePtr in
            argPtrs.withUnsafeMutableBufferPointer { buf in
                debugserver_command_new(namePtr, Int32(args.count), buf.baseAddress, &command)
            }
        }
        guard newErr == DEBUGSERVER_E_SUCCESS, let cmd = command else {
            throw LibimobiledeviceGatewayError(.serviceError, reason: "debugserver_command_new failed with code \(newErr.rawValue)")
        }
        defer { debugserver_command_free(cmd) }

        var response: UnsafeMutablePointer<CChar>? = nil
        let sendErr = debugserver_client_send_command(client, cmd, &response, nil)
        guard sendErr == DEBUGSERVER_E_SUCCESS else {
            throw LibimobiledeviceGatewayError(.serviceError, reason: "debugserver_client_send_command failed with code \(sendErr.rawValue)")
        }
        if let response = response {
            let respStr = String(cString: response)
            free(response)
            return respStr
        }
        return nil
    }

    func syncDebugApp(appId: String) throws {
        if pairingFileType == .rppairing {
            try withRSDService(.debugserver) { stream in
                debugLog("[LibimobiledeviceGateway] RSD debugApp connected to debugserver for \(appId)")
            }
            return
        }

        try withService(
            service: .debugserver,
            create: debugserver_client_new,
            cleanup: debugserver_client_free
        ) { ds in
            guard let pid = try self.findProcessPID(
                appId: appId,
                sendCommand: { name, args in
                    try self.sendDebugserverCommand(client: ds, name: name, args: args)
                }
            ) else {
                throw LibimobiledeviceGatewayError(
                    .serviceError,
                    reason: "App '\(appId)' is not running. Please open the app and keep it in the background, then enable JIT."
                )
            }
            if pid > 0 {
                debugLog("[LibimobiledeviceGateway] Attaching to PID \(pid) for JIT...")
                let commands = [("vAttach;\(String(format: "%x", pid))", [String]()), ("D", [String]())]
                for (name, args) in commands {
                    try self.sendDebugserverCommand(client: ds, name: name, args: args)
                }
            }
            debugLog("[LibimobiledeviceGateway] debugApp successfully attached and detached for \(appId) (PID: \(pid))")
        }
    }

    func syncDebugProcess(pid: UInt32) throws {
        if pairingFileType == .rppairing {
            try withRSDService(.debugserver) { stream in
                debugLog("[LibimobiledeviceGateway] RSD debugProcess connected to debugserver for PID \(pid)")
            }
            return
        }

        try withService(
            service: .debugserver,
            create: debugserver_client_new,
            cleanup: debugserver_client_free
        ) { ds in
            let commands = [("vAttach;\(String(format: "%x", pid))", [String]()), ("D", [String]())]
            for (name, args) in commands {
                try self.sendDebugserverCommand(client: ds, name: name, args: args)
            }
        }
    }

    func syncPerformHeartbeat(interval: UInt64, newInterval: inout UInt64) throws {
        if pairingFileType == .rppairing {
            try withRSDService(.heartbeat) { stream in
                try rsdSendPlist(stream, dict: ["Command": "Pico"])
                let resp = try rsdRecvPlist(stream, timeoutMs: 5000)
                if let intervalVal = resp["Interval"] as? UInt64 {
                    newInterval = intervalVal
                } else if let intervalVal = resp["Interval"] as? Int {
                    newInterval = UInt64(intervalVal)
                } else {
                    newInterval = interval
                }
            }
            return
        }

        try withService(
            service: .heartbeat,
            create: heartbeat_client_new,
            cleanup: heartbeat_client_free
        ) { hb in
            var plist: plist_t? = plist_new_dict()
            defer { if let p = plist { plist_free(p) } }
            plist_dict_set_item(plist, "Command", plist_new_string("Pico"))

            let sRes = heartbeat_send(hb, plist)
            if sRes != HEARTBEAT_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "heartbeat_send failed with code \(sRes.rawValue)")
            }

            var respPlist: plist_t? = nil
            let rRes = heartbeat_receive_with_timeout(hb, &respPlist, 5000)
            if let respPlist = respPlist {
                defer { plist_free(respPlist) }
                var intervalVal: UInt64 = 0
                if let intNode = plist_dict_get_item(respPlist, "Interval") {
                    plist_get_uint_val(intNode, &intervalVal)
                    newInterval = intervalVal
                    return
                }
            }
            if rRes != HEARTBEAT_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "heartbeat_receive_with_timeout failed with code \(rRes.rawValue)")
            }
            newInterval = interval
        }
    }

    func syncAfcListDirectory(bundleId: String, path: String) throws -> [String] {
        try withService(
            service: .afc,
            create: afc_client_new,
            cleanup: afc_client_free
        ) { afc in
            var dirList: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
            let res = afc_read_directory(afc, path, &dirList)
            if res != AFC_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "afc_read_directory failed with code \(res.rawValue)")
            }
            defer {
                if let dirList = dirList {
                    afc_dictionary_free(dirList)
                }
            }

            var entries: [String] = []
            if let dirList = dirList {
                var idx = 0
                while let entry = dirList[idx] {
                    entries.append(String(cString: entry))
                    idx += 1
                }
            }
            return entries
        }
    }

    func syncAfcReadFile(bundleId: String, path: String) throws -> Data {
        try withService(
            service: .afc,
            create: afc_client_new,
            cleanup: afc_client_free
        ) { afc in
            var handle: UInt64 = 0
            let openRes = afc_file_open(afc, path, AFC_FOPEN_RDONLY, &handle)
            guard openRes == AFC_E_SUCCESS, handle != 0 else {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "afc_file_open failed with code \(openRes.rawValue)")
            }
            defer { _ = afc_file_close(afc, handle) }

            var buffer = Data()
            let chunkSize: UInt32 = 65536
            var temp = [UInt8](repeating: 0, count: Int(chunkSize))

            while true {
                var bytesRead: UInt32 = 0
                let readRes = temp.withUnsafeMutableBytes { rawBuf in
                    guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return AFC_E_INTERNAL_ERROR }
                    return afc_file_read(afc, handle, ptr, chunkSize, &bytesRead)
                }
                if readRes != AFC_E_SUCCESS {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "afc_file_read failed with code \(readRes.rawValue)")
                }
                if bytesRead == 0 { break }
                buffer.append(temp, count: Int(bytesRead))
            }
            return buffer
        }
    }

    func syncAfcGetFileInfo(bundleId: String, path: String) throws -> (isDirectory: Bool, fileSize: Int64) {
        try withService(
            service: .afc,
            create: afc_client_new,
            cleanup: afc_client_free
        ) { afc in
            var infoList: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
            let res = afc_get_file_info(afc, path, &infoList)
            if res != AFC_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "afc_get_file_info failed with code \(res.rawValue)")
            }
            defer {
                if let infoList = infoList {
                    afc_dictionary_free(infoList)
                }
            }

            var isDir = false
            var fileSize: Int64 = 0

            if let infoList = infoList {
                var idx = 0
                while let keyPtr = infoList[idx], let valPtr = infoList[idx + 1] {
                    let key = String(cString: keyPtr)
                    let val = String(cString: valPtr)
                    if key == "st_ifmt" && val == "S_IFDIR" {
                        isDir = true
                    } else if key == "st_size" {
                        fileSize = Int64(val) ?? 0
                    }
                    idx += 2
                }
            }
            return (isDirectory: isDir, fileSize: fileSize)
        }
    }
}

// Async FFI Dispatcher Extensions
extension LibimobiledeviceGateway {
    public func start(pairingFileContent: String, preferred: PairingProtocol?) async throws {
        try await withFFIDispatch {
            try self.syncStart(pairingFileContent: pairingFileContent, preferred: preferred)
        }
    }

    public func fetchUDID() async throws -> String {
        try await withFFIDispatch {
            try self.syncFetchUDID()
        }
    }

    public func getLockdownValue(key: String) async throws -> String {
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
        resolveFileName: (@Sendable (String, String) -> String)?,
        onReady: @escaping @Sendable (String, UInt16, [String: String]) -> Void,
        onPin: @escaping @Sendable (String) -> Void
    ) async throws -> PairedDeviceRecord {
        throw LibimobiledeviceGatewayError(.unsupportedOperation, reason: "startWirelessPair (RemotePairing is not supported on pure Lockdown gateway)")
    }

    public func triggerWirelessPair(
        targetIp: String,
        targetPort: UInt16,
        hostName: String,
        hostModel: String,
        outPath: String,
        resolveFileName: (@Sendable (String, String) -> String)?,
        onRequestPin: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> Void
    ) async throws -> PairedDeviceRecord {
        throw LibimobiledeviceGatewayError(.unsupportedOperation, reason: "triggerWirelessPair (RemotePairing is not supported on pure Lockdown gateway)")
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
