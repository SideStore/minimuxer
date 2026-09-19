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

    // NOTE: mounter doesn't cache the mount status nor the minimuxer.
    //       reason is that the actual device state responded by idevice should be truthiness
    @discardableResult
    @concurrent func mount(docsPath: String, maxRetries: Int = 3) async throws -> Bool {

        let path = docsPath.hasPrefix("file://") ? String(docsPath.dropFirst(7)) : docsPath
        let dmgDocsPath = (path.hasSuffix("/") ? String(path.dropLast()) : path) + "/DMG"
        try? FileManager.default.createDirectory(atPath: dmgDocsPath, withIntermediateDirectories: true)

        let activeProtocol = self.gateway.pairingFileType
        // Prerequisite: usbmuxd must be up (RP pairing connects via RSD, skips muxer)
        if activeProtocol != .rppairing {
            guard self.proxyServer.isListening else {
                debugLog("[minimuxer] mounter: usbmuxd not ready!")
                throw MinimuxerError.noConnection("Usbmuxd fake server is not listening")
            }
        }

        // Prerequisite: device must be reachable
        guard (try? await self.endpoint.ip()) != nil else {
            debugLog("[minimuxer] mounter: device IP not available")
            throw MinimuxerError.noDevice("Reachable device IP not found")
        }

        let isDDIMounted = try await runIdevice("isDDIMounted") {
            try await self.gateway.isDDIMounted()
        }
        if isDDIMounted {
            verboseLog("[minimuxer] mounter: DeveloperDiskImage is already mounted. Bypassing mount.")
            return false
        }

        // For lockdown path, fetch iOS version to dispatch pre-17 vs post-17
        var major = 17
        var versionStr: String? = nil
        if activeProtocol != .rppairing {
            guard let v = try await runIdevice("getLockdownValue(ProductVersion)", body: {
                try await self.gateway.getLockdownValue(key: "ProductVersion")
            }) else {
                debugLog("[minimuxer] mounter: could not get device version")
                throw MinimuxerError.noDevice("ProductVersion not found in lockdown")
            }
            versionStr = v
            major = Int(v.split(separator: ".").first ?? "0") ?? 0
        }

        var lastError: Error = MinimuxerError.mount(protocol: activeProtocol, reason: "Initial mount state")
        for attempt in 1...max(1, maxRetries) {
            do {
                try await performMount(major: major, iosVersion: versionStr, dmgDocsPath: dmgDocsPath)
                return true
            } catch let error as DeviceGatewayError {
                if error.isRetryable {
                    lastError = error
                    verboseLog("[minimuxer] mounter: attempt \(attempt)/\(maxRetries) — connection failed, retrying...")
                    continue
                }
                throw try error.asMinimuxerError(protocol: activeProtocol)
            }

            if attempt < maxRetries {
                try? await Task.sleep(nanoseconds: MinimuxerConstants.mounterSleepNs)
            }
        }

        debugLog("[minimuxer] mounter: all \(maxRetries) attempt(s) exhausted")
        throw lastError
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

    private func loadPre17Image(iosVersion: String, dmgDocsPath: String) throws -> (Data, Data) {
        let dmgPath = "\(dmgDocsPath)/\(iosVersion).dmg"
        let sigPath = "\(dmgPath).signature"
        verboseLog("[minimuxer] Pre17 DMG: \(dmgPath)")
        verboseLog("[minimuxer] Pre17 Signature: \(sigPath)")

        if !FileManager.default.fileExists(atPath: dmgPath) {
            verboseLog("[minimuxer] Downloading iOS \(iosVersion) DMG...")
            guard let url = URL(string: MinimuxerConstants.pre17VersionsURL),
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let dmgUrlStr = json[iosVersion],
                  let dmgUrl = URL(string: dmgUrlStr) else {
                debugLog("[minimuxer] ERROR: Unable to download DMG dictionary or find version")
                throw MinimuxerError.downloadImage("Failed to retrieve pre-17 versions plist or find iOS \(iosVersion) DMG URL")
            }

            let zipData = try Data(contentsOf: dmgUrl)
            let zipPath = "\(dmgDocsPath)/dmg.zip"
            try zipData.write(to: URL(fileURLWithPath: zipPath))

            let tmpPath = "\(dmgDocsPath)/tmp"
            try? FileManager.default.removeItem(atPath: tmpPath)
            try FileManager.default.createDirectory(atPath: tmpPath, withIntermediateDirectories: true)

            let tmpPathURL = URL(fileURLWithPath: tmpPath)
            try FileManager.default.unzipItem(at: URL(fileURLWithPath: zipPath), to: tmpPathURL)
            try? FileManager.default.removeItem(atPath: zipPath)

            for item in try FileManager.default.contentsOfDirectory(atPath: tmpPath) {
                let itemPath = "\(tmpPath)/\(item)"
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDir), isDir.boolValue,
                      !item.contains("__MACOSX") else { continue }
                let dmgFile = "\(itemPath)/DeveloperDiskImage.dmg"
                let sigFile = "\(itemPath)/DeveloperDiskImage.dmg.signature"
                if FileManager.default.fileExists(atPath: dmgFile) {
                    try FileManager.default.moveItem(atPath: dmgFile, toPath: "\(dmgDocsPath)/\(iosVersion).dmg")
                    try FileManager.default.moveItem(atPath: sigFile, toPath: "\(dmgDocsPath)/\(iosVersion).dmg.signature")
                }
            }
            try? FileManager.default.removeItem(atPath: tmpPath)
        }

        verboseLog("[minimuxer] Reading pre-17 image files into memory")
        guard let dmgData = try? Data(contentsOf: URL(fileURLWithPath: dmgPath)),
              let sigData = try? Data(contentsOf: URL(fileURLWithPath: sigPath)) else {
            debugLog("[minimuxer] ERROR: Unable to read developer disk image or signature files")
            throw MinimuxerError.mount(protocol: .lockdown, reason: "Unable to read pre-17 image files at: \(dmgPath)")
        }
        return (dmgData, sigData)
    }

    private func loadPost17Image(dmgDocsPath: String) throws -> (Data, Data, Data) {
        let dir = URL(fileURLWithPath: dmgDocsPath)
        let tasks: [(String, URL)] = [
            (MinimuxerConstants.ddiImageURL,      dir.appendingPathComponent("Image.dmg")),
            (MinimuxerConstants.ddiTrustcacheURL, dir.appendingPathComponent("Image.dmg.trustcache")),
            (MinimuxerConstants.ddiManifestURL,   dir.appendingPathComponent("BuildManifest.plist"))
        ]

        for (urlStr, path) in tasks {
            if !FileManager.default.fileExists(atPath: path.path) {
                verboseLog("[minimuxer] Downloading \(path.lastPathComponent)...")
                guard let url = URL(string: urlStr), let data = try? Data(contentsOf: url) else {
                    debugLog("[minimuxer] ERROR: Failed to download \(path.lastPathComponent)")
                    throw MinimuxerError.downloadImage("Failed to download post-17 file from \(urlStr)")
                }
                try data.write(to: path)
            }
        }
        verboseLog("[minimuxer] Files downloaded, reading to memory")

        let imageURL      = tasks[0].1
        let trustcacheURL = tasks[1].1
        let manifestURL   = tasks[2].1

        verboseLog("[minimuxer] Image:      \(imageURL.path)")
        verboseLog("[minimuxer] Trustcache: \(trustcacheURL.path)")
        verboseLog("[minimuxer] Manifest:   \(manifestURL.path)")

        let imageData      = try Data(contentsOf: imageURL)
        let trustcacheData = try Data(contentsOf: trustcacheURL)
        let manifestData   = try Data(contentsOf: manifestURL)

        return (imageData, trustcacheData, manifestData)
    }
}
