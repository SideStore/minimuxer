//
//  DeviceProvider.swift
//  Minimuxer
//
//  Created by Magesh K on 20/09/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import DeviceGatewayAPI

final class DeviceProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedGateway: any DeviceGatewayAPI

    var gateway: any DeviceGatewayAPI {
        lock.withLock { cachedGateway }
    }

    init(gateway: any DeviceGatewayAPI) {
        self.cachedGateway = gateway
    }

    func setGateway(_ newGateway: any DeviceGatewayAPI) {
        lock.withLock {
            self.cachedGateway = newGateway
        }
    }
}
