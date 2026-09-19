//
//  MinimuxerErrors.swift
//  Minimuxer
//
//  Created by Magesh K on 4/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
public import MinimuxerCommon
public import DeviceGatewayAPI

public struct MinimuxerServiceError: Error, CustomStringConvertible {
    public let component: MinimuxerComponent
    public let error: Error
    
    public var description: String {
        return "[\(component.rawValue)] \(error.localizedDescription)"
    }
}

public enum MinimuxerError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case noDevice(String)
    case noConnection(String)
    case notReachable(String)
    case noVPN(String)
    case notStarted(String)
    case pairingNotLoaded(String)
    case connectionModeNotConfigured(String)
    case restartAlreadyInProgressError(String)
    case invalidVPN(String)
    case invalidPairing(protocol: PairingProtocol, reason: String)
    case muxerNotListening(String)

    case createDebug(String)
    case createInstproxy(String)
    case createLockdown(String)
    case createCoreDevice(String)
    case createSoftwareTunnel(String)
    case createRemoteServer(String)
    case createProcessControl(String)

    case getLockdownValue(String)
    case connect(String)
    case close(String)
    case xpcHandshake(String)
    case noService(String)
    case invalidProductVersion(String)
    case lookupApps(String)
    case findApp(String)
    case bundlePath(String)
    case maxPacket(String)
    case workingDirectory(String)
    case argv(String)
    case launchSuccess(String)
    case detach(String)
    case attach(String)

    case createAfc(String)
    case rwAfc(String)
    case installApp(String)
    case uninstallApp(String)

    case createMisagent(String)
    case profileInstall(String)
    case profileRemove(String)

    case createFolder(String)
    case downloadImage(String)
    case imageLookup(String)
    case imageRead(String)
    case mount(protocol: PairingProtocol, reason: String)

    public var description: String {
        switch self {
        case .noDevice(let r): return "NoDevice: \(r)"
        case .noConnection(let r): return "NoConnection: \(r)"
        case .notReachable(let r): return "NotReachable: \(r)"
        case .noVPN(let r): return "NoVPN: \(r)"
        case .notStarted(let r): return "NotStarted: \(r)"
        case .pairingNotLoaded(let r): return "PairingNotLoaded: \(r)"
        case .restartAlreadyInProgressError(let r): return "RestartAlreadyInProgressError: \(r)"
        case .invalidVPN(let r): return "InvalidVPN: \(r)"
        case .invalidPairing(let proto, let reason): return "InvalidPairing(protocol: \(proto), reason: \(reason))"
        case .muxerNotListening(let r): return "MuxerNotListening: \(r)"
        case .createDebug(let r): return "CreateDebug: \(r)"
        case .createInstproxy(let r): return "CreateInstproxy: \(r)"
        case .createLockdown(let r): return "CreateLockdown: \(r)"
        case .createCoreDevice(let r): return "CreateCoreDevice: \(r)"
        case .createSoftwareTunnel(let r): return "CreateSoftwareTunnel: \(r)"
        case .createRemoteServer(let r): return "CreateRemoteServer: \(r)"
        case .createProcessControl(let r): return "CreateProcessControl: \(r)"
        case .getLockdownValue(let r): return "GetLockdownValue: \(r)"
        case .connect(let r): return "Connect: \(r)"
        case .close(let r): return "Close: \(r)"
        case .xpcHandshake(let r): return "XpcHandshake: \(r)"
        case .noService(let r): return "NoService: \(r)"
        case .invalidProductVersion(let r): return "InvalidProductVersion: \(r)"
        case .lookupApps(let r): return "LookupApps: \(r)"
        case .findApp(let r): return "FindApp: \(r)"
        case .bundlePath(let r): return "BundlePath: \(r)"
        case .maxPacket(let r): return "MaxPacket: \(r)"
        case .workingDirectory(let r): return "WorkingDirectory: \(r)"
        case .argv(let r): return "Argv: \(r)"
        case .launchSuccess(let r): return "LaunchSuccess: \(r)"
        case .detach(let r): return "Detach: \(r)"
        case .attach(let r): return "Attach: \(r)"
        case .createAfc(let r): return "CreateAfc: \(r)"
        case .rwAfc(let r): return "RwAfc: \(r)"
        case .installApp(let msg): return "InstallApp(\(msg))"
        case .uninstallApp(let r): return "UninstallApp: \(r)"
        case .createMisagent(let r): return "CreateMisagent: \(r)"
        case .profileInstall(let r): return "ProfileInstall: \(r)"
        case .profileRemove(let r): return "ProfileRemove: \(r)"
        case .createFolder(let r): return "CreateFolder: \(r)"
        case .downloadImage(let r): return "DownloadImage: \(r)"
        case .imageLookup(let r): return "ImageLookup: \(r)"
        case .imageRead(let r): return "ImageRead: \(r)"
        case .mount(let proto, let reason): return "Mount(protocol: \(proto), reason: \(reason))"
        case .connectionModeNotConfigured(let r): return "ConnectionModeNotConfigured: \(r)"
        }
    }

    public var errorDescription: String? {
        return self.description
    }
}

extension DeviceGatewayError {
    var isVPNDrop: Bool {
        guard code == .connectionFailed || code == .serviceError else { return false }
        let lower = reason.lowercased()
        return lower.contains("broken pipe")        || lower.contains("brokenpipe")         ||
               lower.contains("connection reset")   || lower.contains("connectionreset")    ||
               lower.contains("early eof")          || lower.contains("unexpectedeof")      ||
               lower.contains("no route to host")   || lower.contains("connection refused")
    }

    var isRetryable: Bool {
        (code == .connectionFailed || code == .noConnection) && !isVPNDrop
    }

    func asMinimuxerError(protocol activeProtocol: PairingProtocol) throws -> MinimuxerError {
        if code == .invalidPairingFile {
            return .invalidPairing(protocol: activeProtocol, reason: reason)
        }
        if isVPNDrop {
            return .invalidVPN(reason)
        }
        throw self
    }
}
