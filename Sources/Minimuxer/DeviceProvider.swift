//
//  DeviceProvider.swift
//  Minimuxer
//
//  Created by Magesh K on 20/09/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import DeviceGateway

final class DeviceProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedGateway: any DeviceGateway

    var gateway: any DeviceGateway {
        lock.withLock { cachedGateway }
    }

    init(gateway: any DeviceGateway) {
        self.cachedGateway = gateway
    }

    func setGateway(_ newGateway: any DeviceGateway) {
        lock.withLock {
            self.cachedGateway = newGateway
        }
    }
}
