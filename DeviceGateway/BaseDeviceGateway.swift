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


public struct RSPProcessInfo: Sendable, Equatable, Hashable {
    public let pid: UInt32
    public let name: String
    public let executable: String

    public init?(rawResponse: String) {
        guard !rawResponse.isEmpty, !rawResponse.hasPrefix("E") else { return nil }

        var parsedPid: UInt32?
        var parsedName = ""
        var parsedExecutable = ""

        let pairs = rawResponse.split(separator: ";")
        for pair in pairs {
            let parts = pair.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let val = String(parts[1]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "pid":
                parsedPid = UInt32(val, radix: 16) ?? UInt32(val)
            case "name":
                parsedName = BaseDeviceGateway.decodeHexASCII(val) ?? val
            case "executable":
                parsedExecutable = BaseDeviceGateway.decodeHexASCII(val) ?? val
            default:
                break
            }
        }

        guard let pid = parsedPid else { return nil }
        self.pid = pid
        self.name = parsedName
        self.executable = parsedExecutable
    }

    public func matches(term: String) -> Bool {
        name.localizedCaseInsensitiveContains(term) ||
        (!executable.isEmpty && executable.localizedCaseInsensitiveContains(term))
    }
}

extension BaseDeviceGateway { 

    public static func stringToHex(_ str: String) -> String {
        str.utf8.map { String(format: "%02x", $0) }.joined()
    }

    public static func decodeHexASCII(_ hex: String) -> String? {
        let utf8 = hex.utf8
        guard utf8.count % 2 == 0 else { return nil }
        var data = Data(capacity: utf8.count / 2)
        var byte: UInt8 = 0

        for (index, char) in utf8.enumerated() {
            let val: UInt8
            switch char {
            case 48...57:  val = char - 48       // '0'...'9'
            case 65...70:  val = char - 65 + 10  // 'A'...'F'
            case 97...102: val = char - 97 + 10  // 'a'...'f'
            default: return nil
            }

            if index.isMultiple(of: 2) {
                byte = val << 4
            } else {
                data.append(byte | val)
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
    }

    open func findProcessPID(
        appId: String,
        bundlePath: String? = nil,
        executableName: String? = nil,
        sendCommand: (String, [String]) throws -> String?
    ) throws -> UInt32? {
        debugLog("[\(logTag)] findProcessPID() searching for appId: \(appId), bundlePath: \(bundlePath ?? "nil"), executableName: \(executableName ?? "nil")")

        var targetTerms: [String] = []

        if let executableName, !executableName.isEmpty {
            targetTerms.append(executableName)
        }

        if let bundlePath, !bundlePath.isEmpty {
            let lastComponent = URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
            if !lastComponent.isEmpty && !targetTerms.contains(lastComponent) {
                targetTerms.append(lastComponent)
            }
        }

        let components = appId.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" })
        for comp in components {
            let str = String(comp)
            if ["com", "org", "net", "io", "app", "ios"].contains(str.lowercased()) { continue }
            if str.count == 10 && str.allSatisfy({ $0.isLetter || $0.isNumber }) && str.uppercased() == str {
                continue
            }
            if !targetTerms.contains(str) {
                targetTerms.append(str)
            }
            let stripped = str.trimmingCharacters(in: .decimalDigits)
            if !stripped.isEmpty && stripped != str && !targetTerms.contains(stripped) {
                targetTerms.append(stripped)
            }
        }

        let dotComponents = appId.split(separator: ".")
        if dotComponents.count > 1 {
            let withoutSuffix = dotComponents.dropLast().joined(separator: ".")
            if !withoutSuffix.isEmpty && !targetTerms.contains(withoutSuffix) {
                targetTerms.append(withoutSuffix)
            }
        }

        if !targetTerms.contains(appId) {
            targetTerms.append(appId)
        }

        verboseLog("[\(logTag)] findProcessPID() target search terms: \(targetTerms)")

        // 1. Query process list via qfProcessInfo / qsProcessInfo
        var queryCommands = [
            "qfProcessInfo:all_users:1;",
            "qfProcessInfo:all_users:1"
        ]
        for term in targetTerms {
            let hex = Self.stringToHex(term)
            queryCommands.append("qfProcessInfo:name:\(hex);")
            queryCommands.append("qfProcessInfo:name_match:contains;name:\(hex);")
            queryCommands.append("qfProcessInfo:name_match:starts_with;name:\(hex);")
            queryCommands.append("qfProcessInfo:name_match:equals;name:\(hex);")
            queryCommands.append("qfProcessInfo:name:\(hex)")
        }

        for queryCmd in queryCommands {
            debugLog("[\(logTag)] findProcessPID() trying query: '\(queryCmd)'")
            var currentResponse = try? sendCommand(queryCmd, [])

            while let resp = currentResponse, let proc = RSPProcessInfo(rawResponse: resp) {
                verboseLog("[\(logTag)] findProcessPID() found process: pid=\(proc.pid), name='\(proc.name)', exec='\(proc.executable)'")
                for term in targetTerms {
                    if proc.matches(term: term) {
                        debugLog("[\(logTag)] findProcessPID() matched PID \(proc.pid) for '\(term)'")
                        return proc.pid
                    }
                }
                currentResponse = try? sendCommand("qsProcessInfo", [])
            }
        }

        // 2. Direct attach fallback by name
        for term in targetTerms {
            let hex = Self.stringToHex(term)
            let attachCommands = [
                "vAttachName;\(hex)",
                "vAttachWait;\(hex)"
            ]
            for attachCmd in attachCommands {
                debugLog("[\(logTag)] findProcessPID() trying direct attach: '\(attachCmd)'")
                if let attachResp = try? sendCommand(attachCmd, []),
                   !attachResp.isEmpty,
                   !attachResp.hasPrefix("E") 
                {
                    debugLog("[\(logTag)] findProcessPID() direct attach succeeded: '\(attachResp)'")
                    _ = try? sendCommand("D", [])
                    return 0
                }
            }
        }

        debugLog("[\(logTag)] findProcessPID() no running process found for \(appId)")
        return nil
    }
}
