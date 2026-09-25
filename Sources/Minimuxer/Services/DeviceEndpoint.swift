//
//  DeviceEndpoint.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import DeviceGateway

actor DeviceEndpoint {

    let deviceProvider: DeviceProvider
    var gateway: any DeviceGateway {
        deviceProvider.gateway
    }

    private var ipAddr: String? = nil

    init(deviceProvider: DeviceProvider) {
        self.deviceProvider = deviceProvider
    }

    func ip() throws -> String {
        guard let ip = ipAddr else { throw MinimuxerInternalError.deviceEndpointNotInitialized }
        return ip
    }

    func update(_ newIP: String) {
        ipAddr = newIP
        self.gateway.setDeviceEndpointIp(newIP)
        DeviceGatewayLogging.logger.trace("[minimuxer] device endpoint updated -> \(newIP)")
    }

    func clear() {
        ipAddr = nil
        self.gateway.setDeviceEndpointIp(nil)
        DeviceGatewayLogging.logger.trace("[minimuxer] device endpoint cleared -> nil")
    }

    var isInitialized: Bool {
        ipAddr != nil
    }
}
