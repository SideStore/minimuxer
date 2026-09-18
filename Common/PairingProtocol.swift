//
//  PairingProtocol.swift
//  MinimuxerCommon
//
//  Created by Magesh K on 7/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

public enum PairingError: LocalizedError, CustomStringConvertible, Sendable {
    case unreadable(String)
    case invalidPlist(String)
    case incomplete(protocolType: PairingProtocol, missingKeys: [String])

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason):
            return "The pairing file could not be read: \(reason)"
        case .invalidPlist(let reason):
            return "The pairing file could not be parsed as a property list (plist): \(reason)"
        case .incomplete(let protocolType, let missingKeys):
            return "The pairing file is incomplete for .\(protocolType). Missing keys: \(missingKeys.joined(separator: ", "))."
        }
    }

    public var description: String {
        errorDescription ?? "Pairing error"
    }
}

public enum PairingProtocol: String, Codable, CustomStringConvertible, Sendable {
    case rppairing = "rppairing"
    case lockdown = "lockdown"
    case unknown = "unknown"
    
    public var description: String {
        return self.rawValue
    }

    public var defaultPort: UInt16 {
        switch self {
        case .rppairing:
            return MinimuxerConstants.remotePairingPort
        case .lockdown, .unknown:
            return MinimuxerConstants.lockdowndPort
        }
    }
}
