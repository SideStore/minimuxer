//
//  DeviceGatewayError.swift
//  Minimuxer
//
//  Created by Magesh K on 22/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

open class DeviceGatewayError: LocalizedError, CustomStringConvertible, @unchecked Sendable {
    public struct Code: Equatable, Sendable, ExpressibleByStringLiteral {
        public let rawValue: String
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }

        public static let invalidPairingFile = Code("invalidPairingFile")
        public static let connectionFailed = Code("connectionFailed")
        public static let serviceError = Code("serviceError")
        public static let noConnection = Code("noConnection")
        public static let notInitialized = Code("notInitialized")
        public static let deviceEndpointIpNotAvailable = Code("deviceEndpointIpNotAvailable")
        public static let invalidTargetEndpoint = Code("invalidTargetEndpoint")
        public static let unsupportedOperation = Code("unsupportedOperation")
    }

    public let code: Code
    public let reason: String

    public init(_ code: Code, reason: String = "") {
        self.code = code
        self.reason = reason
    }

    open var errorDescription: String? {
        switch code {
        case .invalidPairingFile:
            return "The pairing file is invalid: \(reason)"
        case .connectionFailed:
            return "Failed to connect to device: \(reason)"
        case .serviceError:
            return "Service operation failed: \(reason)"
        case .noConnection:
            return reason.isEmpty ? "No connection to the device." : reason
        case .notInitialized:
            return reason.isEmpty ? "DeviceGateway not initialized. start() should be called first." : reason
        case .deviceEndpointIpNotAvailable:
            return reason.isEmpty ? "Device endpoint IP is not available." : reason
        case .invalidTargetEndpoint:
            return reason.isEmpty ? "Invalid target endpoint IP or port." : reason
        case .unsupportedOperation:
            return "Operation '\(reason)' is not supported."
        default:
            return reason
        }
    }

    public var description: String {
        errorDescription ?? reason
    }
}
