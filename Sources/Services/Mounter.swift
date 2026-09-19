//
//  Mounter.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
import ZIPFoundation
internal import DeviceGatewayAPI
internal import MinimuxerCommon

final internal class Mounter {
    let gateway: any DeviceGatewayAPI
    let proxyServer: UsbmuxdProxyServer
    let endpoint: DeviceEndpoint

    init(gateway: any DeviceGatewayAPI, proxyServer: UsbmuxdProxyServer, endpoint: DeviceEndpoint) {
        self.gateway = gateway
        self.proxyServer = proxyServer
        self.endpoint = endpoint
    }

    @discardableResult
    @concurrent func mount(docsPath: String) async throws -> Bool {

        let path = docsPath.hasPrefix("file://") ? String(docsPath.dropFirst(7)) : docsPath
        let dmgDocsPath = (path.hasSuffix("/") ? String(path.dropLast()) : path) + "/DMG"
        try? FileManager.default.createDirectory(atPath: dmgDocsPath, withIntermediateDirectories: true)


        // Prerequisite: device must be reachable
        guard (try? await self.endpoint.ip()) != nil else {
            debugLog("[minimuxer] mounter: device IP not available")
            throw MinimuxerError.noDevice("Reachable device IP not found")
        }

        let isDDIMounted = try await self.gateway.isDDIMounted()
        if isDDIMounted {
            verboseLog("[minimuxer] mounter: DeveloperDiskImage is already mounted. Bypassing mount.")
            return false
        }

        // For lockdown path, fetch iOS version to dispatch pre-17 vs post-17
        var major = 17
        var versionStr: String? = nil
        if gateway.pairingFileType != .rppairing {
            let v = try await self.gateway.getLockdownValue(key: "ProductVersion")
            guard let firstComponent = v.split(separator: ".").first,
                  let parsedMajor = Int(firstComponent) else 
            {
                debugLog("[minimuxer] mounter: failed to parse major iOS version from ProductVersion '\(v)'")
                throw MinimuxerError.invalidProductVersion(v)
            }
            versionStr = v
            major = parsedMajor
        }

        try await performMount(major: major, iosVersion: versionStr, dmgDocsPath: dmgDocsPath)
        return true
    }

    private func performMount(major: Int, iosVersion: String?, dmgDocsPath: String) async throws {
        if major < 17, let iosVersion {
            // Pre-17: lockdown only — load DMG + signature, mount via imagemounter
            let (dmgData, sigData) = try loadPre17Image(iosVersion: iosVersion, dmgDocsPath: dmgDocsPath)
            verboseLog("[minimuxer] Uploading and mounting image (dmg=\(dmgData.count) bytes, sig=\(sigData.count) bytes)...")
            try await self.gateway.mountDeveloperImage(image: dmgData, signature: sigData)
            verboseLog("[minimuxer] Successfully mounted the image")
        } else {
            // Post-17: both RP and lockdown use mountPersonalizedDdi.
            // IdeviceGateway handles the RP vs lockdown distinction internally.
            let (imageData, trustcacheData, manifestData) = try loadPost17Image(dmgDocsPath: dmgDocsPath)
            debugLog(
                "[minimuxer] Mounting DDI " +
                "(image=\(imageData.count) bytes, " +
                "trustcache=\(trustcacheData.count) bytes, " +
                "manifest=\(manifestData.count) bytes)"
            )
            try await self.gateway.mountPersonalizedDdi(image: imageData, trustcache: trustcacheData, manifest: manifestData)
            verboseLog("[minimuxer] DDI mounted successfully")
        }
    }

    private func getOrDownload(url: URL, localURL: URL) throws -> Data {
        if FileManager.default.fileExists(atPath: localURL.path) {
            return try Data(contentsOf: localURL)
        }
        verboseLog("[minimuxer] Downloading \(localURL.lastPathComponent)...")
        guard let data = try? Data(contentsOf: url) else {
            debugLog("[minimuxer] ERROR: Failed to download \(localURL.lastPathComponent)")
            throw MinimuxerError.downloadImage("Failed to download file from \(url.absoluteString)")
        }
        try data.write(to: localURL)
        return data
    }

    private func loadPre17Image(iosVersion: String, dmgDocsPath: String) throws -> (Data, Data) {
        let dmgURL = URL(fileURLWithPath: "\(dmgDocsPath)/\(iosVersion).dmg")
        let sigURL = URL(fileURLWithPath: "\(dmgDocsPath)/\(iosVersion).dmg.signature")
        verboseLog("[minimuxer] Pre17 DMG: \(dmgURL.path)")
        verboseLog("[minimuxer] Pre17 Signature: \(sigURL.path)")

        if !FileManager.default.fileExists(atPath: dmgURL.path) || !FileManager.default.fileExists(atPath: sigURL.path) {
            verboseLog("[minimuxer] Downloading iOS \(iosVersion) DMG...")
            guard let url = URL(string: MinimuxerConstants.pre17VersionsURL),
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let dmgUrlStr = json[iosVersion],
                  let dmgUrl = URL(string: dmgUrlStr) else 
            {
                debugLog("[minimuxer] ERROR: Unable to download DMG dictionary or find version")
                throw MinimuxerError.downloadImage("Failed to retrieve pre-17 versions plist or find iOS \(iosVersion) DMG URL")
            }

            let zipURL = URL(fileURLWithPath: "\(dmgDocsPath)/dmg.zip")
            let tmpURL = URL(fileURLWithPath: "\(dmgDocsPath)/tmp")
            defer {
                try? FileManager.default.removeItem(at: zipURL)
                try? FileManager.default.removeItem(at: tmpURL)
            }

            try Data(contentsOf: dmgUrl).write(to: zipURL)
            try? FileManager.default.removeItem(at: tmpURL)
            try FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: zipURL, to: tmpURL)

            for item in try FileManager.default.contentsOfDirectory(atPath: tmpURL.path) {
                let itemURL = tmpURL.appendingPathComponent(item)
                let isDirectory = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDirectory, !item.contains("__MACOSX") else { continue }
                let dmgFile = itemURL.appendingPathComponent("DeveloperDiskImage.dmg")
                let sigFile = itemURL.appendingPathComponent("DeveloperDiskImage.dmg.signature")
                if FileManager.default.fileExists(atPath: dmgFile.path) 
                {
                    try? FileManager.default.removeItem(at: dmgURL)
                    try? FileManager.default.removeItem(at: sigURL)
                    try FileManager.default.moveItem(at: dmgFile, to: dmgURL)
                    try FileManager.default.moveItem(at: sigFile, to: sigURL)
                }
            }
        }

        verboseLog("[minimuxer] Reading pre-17 image files into memory")
        guard let dmgData = try? Data(contentsOf: dmgURL),
              let sigData = try? Data(contentsOf: sigURL) else 
        {
            debugLog("[minimuxer] ERROR: Unable to read developer disk image or signature files")
            throw MinimuxerError.mount(protocol: .lockdown, reason: "Unable to read pre-17 image files at: \(dmgURL.path)")
        }
        return (dmgData, sigData)
    }

    private func loadPost17Image(dmgDocsPath: String) throws -> (Data, Data, Data) {
        let dir = URL(fileURLWithPath: dmgDocsPath)
        guard let imgURL = URL(string: MinimuxerConstants.ddiImageURL),
              let tcURL = URL(string: MinimuxerConstants.ddiTrustcacheURL),
              let mftURL = URL(string: MinimuxerConstants.ddiManifestURL) else 
        {
            debugLog("[minimuxer] ERROR: Invalid post-17 DDI URLs configured")
            throw MinimuxerError.downloadImage("Invalid post-17 DDI URLs configured")
        }

        let imageData = try getOrDownload(url: imgURL, localURL: dir.appendingPathComponent("Image.dmg"))
        let trustcacheData = try getOrDownload(url: tcURL, localURL: dir.appendingPathComponent("Image.dmg.trustcache"))
        let manifestData = try getOrDownload(url: mftURL, localURL: dir.appendingPathComponent("BuildManifest.plist"))

        return (imageData, trustcacheData, manifestData)
    }
}
