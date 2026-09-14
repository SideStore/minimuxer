//
//  BaseDeviceGateway.swift
//  Minimuxer
//
//  Created by Magesh K on 05/09/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import MinimuxerCommon

enum AbstractClassError: Error, Sendable {
    case abstractInitializerInvoked
    case abstractMethodInvoked
}

open class BaseDeviceGateway: @unchecked Sendable {
    public package(set) var pairingFileType: PairingProtocol = .unknown
    public package(set) var pairingDataDict: [String: any Sendable]? = nil

    public package(set) var pairingFileData: Data? = nil {
        didSet {
            guard let pairingFileData else {
                self.pairingDataDict = nil
                return
            }
            self.pairingDataDict = try? PropertyListSerialization.propertyList(
                from: pairingFileData,
                options: [],
                format: nil
            ) as? [String: any Sendable]
        }
    }

    public package(set) var deviceEndpointIp: String? = nil
    public package(set) var isInitialized: Bool = false
    private var protocolPorts: [PairingProtocol: UInt16] = [:]

    package init() throws {
        if Self.self === BaseDeviceGateway.self {
            throw AbstractClassError.abstractInitializerInvoked
        }
    }

    public func setPairingFileData(_ data: Data?) {
        self.pairingFileData = data
    }

    public func setPairingFileType(_ type: PairingProtocol) {
        self.pairingFileType = type
    }

    public func setInitialized(_ initialized: Bool) {
        self.isInitialized = initialized
    }

    public func getPairingFileType() -> PairingProtocol {
        pairingFileType
    }

    public func getPort(for protocol: PairingProtocol) -> UInt16 {
        protocolPorts[`protocol`] ?? `protocol`.defaultPort
    }

    private var logTag: String {
        String(describing: type(of: self))
    }

    public func setPort(_ port: UInt16, for protocol: PairingProtocol) {
        guard protocolPorts[`protocol`] != port else { return }
        debugLog("[\(logTag)] setPort(\(port), for: .\(`protocol`)) called")
        protocolPorts[`protocol`] = port
        invalidateConnection()
    }

    public func setDeviceEndpointIp(_ ip: String?) {
        debugLog("[\(logTag)] setDeviceEndpointIp(\(ip ?? "nil")) called")
        guard deviceEndpointIp != ip else {
            debugLog("[\(logTag)] setDeviceEndpointIp: IP is already \(ip ?? "nil"), skipping invalidation")
            return
        }
        deviceEndpointIp = ip
        invalidateConnection()
    }

    open func setLogging(_ enabled: Bool) {
        DeviceGatewayLogging.setLogging(enabled)
        debugLog("[\(logTag)] setLogging(\(enabled)) called")
    }

    open func invalidateConnection() {
        // Subclasses override to invalidate cached handles/tunnels
    }
}
