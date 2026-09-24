//
//  MinimuxerInternalError.swift
//  Minimuxer
//
//  Created by Magesh K on 4/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

internal enum MinimuxerInternalError: Error, LocalizedError {
    case deviceEndpointNotInitialized
    case networkIfaceNotRefreshed
    case pairingFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceEndpointNotInitialized: return "DeviceEndpointNotInitialized"
        case .networkIfaceNotRefreshed: return "NetworkIfaceNotRefreshed"
        case .pairingFailed(let msg): return "PairingFailed(\(msg))"
        }
    }
}