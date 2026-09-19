//
//  DeviceGatewayAPI.swift
//  Minimuxer
//
//  Created by Magesh K on 22/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import MinimuxerCommon

public struct PairedDeviceRecord: Sendable {
    public let name: String
    public let model: String
    public let pairingFilePath: String
    public let pairingFile: any PairingFile
    
    public init(name: String, model: String, pairingFilePath: String, pairingFile: any PairingFile) {
        self.name = name
        self.model = model
        self.pairingFilePath = pairingFilePath
        self.pairingFile = pairingFile
    }
}

public protocol DeviceGatewayAPI: AnyObject, Sendable {
    var pairingFileType: PairingProtocol { get }
    var pairingFileData: Data? { get }
    var pairingDataDict: [String: any Sendable]? { get }

    func getPort(for protocolType: PairingProtocol) -> UInt16
    func setPort(_ port: UInt16, for protocolType: PairingProtocol)

    func start(pairingFileContent: String) async throws
    func setDeviceEndpointIp(_ ip: String?)
    func setLogging(_ enabled: Bool)
    func getPairingFileType() -> PairingProtocol

    func fetchUDID() async throws -> String
    func getLockdownValue(key: String) async throws -> String

    func isDDIMounted() async throws -> Bool
    func mountDeveloperImage(image: Data, signature: Data) async throws
    func mountPersonalizedDdi(image: Data, trustcache: Data, manifest: Data) async throws

    func installProvisioningProfile(profile: Data) async throws
    func removeProvisioningProfile(id: String) async throws
    func dumpProfiles(docsPath: String) async throws -> String
    func removeApp(bundleId: String) async throws
    func sendIpaAfc(bundleId: String, ipaBytes: Data) async throws
    func sendAppBundleAfc(bundleId: String, appURL: URL) async throws
    func installIpa(bundleId: String) async throws
    func installAppBundle(bundleId: String, appName: String) async throws
    func wipeContainer(identifier: String) async throws

    func debugApp(appId: String) async throws
    func debugProcess(pid: UInt32) async throws

    func performHeartbeat(interval: UInt64) async throws -> UInt64

    func startWirelessPair(
        hostName: String,
        hostModel: String,
        outPath: String,
        resolveFileName: (@Sendable (String, String) -> String)?,
        onReady: @escaping @Sendable (String, UInt16, [String: String]) -> Void,
        onPin: @escaping @Sendable (String) -> Void
    ) async throws -> PairedDeviceRecord

    func triggerWirelessPair(
        targetIp: String,
        targetPort: UInt16,
        hostName: String,
        hostModel: String,
        outPath: String,
        resolveFileName: (@Sendable (String, String) -> String)?,
        onRequestPin: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> Void
    ) async throws -> PairedDeviceRecord

    func afcListDirectory(bundleId: String, path: String) async throws -> [String]
    func afcReadFile(bundleId: String, path: String) async throws -> Data
    func afcGetFileInfo(bundleId: String, path: String) async throws -> (isDirectory: Bool, fileSize: Int64)
}

public extension DeviceGatewayAPI {
    // Active service port for the currently loaded pairing file mode
    var servicePort: UInt16 {
        getPort(for: pairingFileType)
    }
}
