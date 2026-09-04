//
//  MinimuxerConstants.swift
//  Minimuxer
//
//  Created by Magesh K on 4/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

public enum MinimuxerConstants {
    public static let lockdowndPort: UInt16 = 62078     // lockdown daemon port
    public static let remotePairingPort: UInt16 = 49152 // RemotePairing daemon port
    
    public static let appName = "minimuxer"

    public static let usbmuxdHost = "127.0.0.1"
    public static let usbmuxdPort: UInt16 = 27015       // usbmux daemon port
    public static let usbmuxdSocket = "\(usbmuxdHost):\(usbmuxdPort)"

    public static let empServerHost = "127.0.0.1"
    public static let empServerPort: UInt16 = 51820           // default EMProxy WireGuard loopback port
    public static let empServerBindAddress = "\(empServerHost):\(empServerPort)"
    
    public static let vpnHandshakeTimeoutNs: UInt64 = 10_000_000_000
    
    public static let heartbeatTimeoutMs: UInt32 = 12000
    public static let deviceFetchTimeoutMs: UInt16 = 5000
    public static let deviceFetchSleepMs: UInt32 = 250
    public static let defaultTCPProbeTimeoutMs = 100
    
    public static let pkgPath = "PublicStaging"
    public static let usbmuxdEnvKey = "USBMUXD_SOCKET_ADDRESS"

    public static let pre17VersionsURL = "https://raw.githubusercontent.com/jkcoxson/JitStreamer/master/versions.json"
    public static let ddiImageURL = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg"
    public static let ddiTrustcacheURL = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg.trustcache"
    public static let ddiManifestURL = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/BuildManifest.plist"

    // WirelessPair Constants
    public static let defaultHostName = "SideStore"
    public static let defaultHostModel = "Mac17,7"
    public static let defaultBindIP = "0.0.0.0"
    public static let defaultBindPort: UInt16 = 0
    public static let defaultAdDomain = ""
    public static let remotePairingDaemonServiceType = "_remotepairing._tcp."
    public static let remotePairingPairableHostServiceType = "_remotepairing-pairable-host._tcp."
    public static let remotePairingManualPairingServiceType = "_remotepairing-manual-pairing._tcp."

    // UsbmuxdProxyServer Constants
    public static let deviceAttach = "Attached"
    public static let deviceDetach = "Detached"
    public static let usbmuxMaxPacketBufferLength = 4095
    public static let usbmuxHeaderLen = 16

    // Sleep / Threading timeouts
    public static let heartbeatSleepNs: UInt64 = 1_000_000_000
    public static let mounterSleepNs: UInt64 = 1_000_000_000

    // Packet Configuration
    public static let maxPacketSize = 1024
    public static let packetHeaderLen = 16
}
