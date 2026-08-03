//
//  NetworkObserverService.swift
//  Minimuxer
//
//  Created by Magesh K on 02/03/26.
//

import Network
import Foundation

final internal class NetworkObserverService: NetworkObserverAPI, @unchecked Sendable {

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "net.monitor")
    private let state = State()
    
    private actor State {
        var started = false
        var observationTask: Task<Void, Never>? = nil
        
        func with<T>(_ body: (isolated State) throws -> T) rethrows -> T {
            try body(self)
        }
    }

    @discardableResult
    func start() async -> Bool {
        let alreadyStarted = await state.with { $0.started }
        guard !alreadyStarted else {
            verboseLog("[minimuxer] [net] monitor already started")
            return false
        }

        await state.with { $0.started = true }
        verboseLog("[minimuxer] [net] monitor started")

        let paths = AsyncStream<NWPath> { [weak self] continuation in
            guard let self = self else {
                continuation.finish()
                return
            }
            self.monitor.pathUpdateHandler = { path in
                continuation.yield(path)
            }
        }

        self.monitor.start(queue: self.queue)

        let task = Task.detached { [weak self] in
            for await path in paths {
                verboseLog("[minimuxer] [net] path changed, status: \(path.status)")
                guard path.status == .satisfied else { continue }
                await self?.refreshEndpoint()
            }
        }
        await state.with { $0.observationTask = task }

        return true
    }
    
    func refreshEndpoint() async {
        verboseLog("[minimuxer] [net] refreshing interfaces list and peers")
        let changed = await NetworkIfaceScanner.shared.refresh()
        guard changed else { return }

        let connectionMode = await NetworkIfaceScanner.shared.getPreferredConnectionMode()

        switch connectionMode {
            case .notConfigured:
                debugLog("[minimuxer] [net] connection mode not configured. skipping refreshEndpoint...")
                return
                
            case .localVPN:
                verboseLog("[minimuxer] [net] retrive the first uTun vpn interface info")
                if let info = await NetworkIfaceScanner.shared.vpnIface {
                    verboseLog("""
                    [minimuxer] [net] vpn interface detected
                      • name: \(info.name)
                      • ip: \(info.hostIP)
                      • mask: \(info.maskIP)
                      • linkType: \(info.linkType)
                      • reportedPeer: \(info.reportedPeer ?? "nil")
                      • derivedPeer: \(info.derivedPeer ?? "nil")
                    
                    """)

                    let scanner = await NetworkIfaceScanner.shared
                    let overrideIp = await scanner.overridePeerIp
                    let isOverridden = !(overrideIp ?? "").isEmpty

                    let effectiveIp = await isOverridden
                            ? (scanner.isOverridePeerIpReachable ? overrideIp : nil)            // when override active, we don't question user intent
                            : (scanner.isDerivedPeerIpReachable ? scanner.derivedPeerIp : nil)  // only if not overriden, we try to use auto discovered
                    let effectivePeer = isOverridden ? "overridePeer" : "derivedPeerIp"

                    if let peer = effectiveIp {
                        verboseLog("[minimuxer] [net] update device IP with effective tunnel peer: '\(effectivePeer)'")
                        await applyDeviceEndpoint(peer)
                    } else {
                        verboseLog("[minimuxer] [net] peer not available for \(info.name)")
                        await applyDeviceEndpoint(nil)
                    }

                } else {
                    verboseLog("[minimuxer] [net] no local VPN interface detected")
                    await applyDeviceEndpoint(nil)
                }
            
            case .remoteServer:
                let scanner = await NetworkIfaceScanner.shared
                let isReachable = await scanner.isRemoteServerIpReachable
                if let remoteIp = await scanner.remoteServerIp  {
                    verboseLog("""
                    [minimuxer] [net] remote server endpoint detected \(isReachable ? "and reachable" : "but unreachable")
                      • remoteServerIp: \(remoteIp)
                    
                    """)
                    if isReachable {
                        await applyDeviceEndpoint(remoteIp)
                    } else {
                        await applyDeviceEndpoint(nil)
                    }
                } else {
                    verboseLog("[minimuxer] [net] remote server endpoint unreachable")
                    await applyDeviceEndpoint(nil)
                }
            }
    }

    private func applyDeviceEndpoint(_ endpoint: String?) async {
        await LockdownSessionRuntime.shared.updateDeviceEndpoint(endpoint)
    }
    
    @discardableResult
    func stop() async -> Bool {
        let isStarted = await state.with { $0.started }
        guard isStarted else {
            verboseLog("[minimuxer] [net] monitor already stopped")
            return false
        }

        self.monitor.cancel()
        await state.with {
            $0.observationTask?.cancel()
            $0.observationTask = nil
            $0.started = false
        }
        
        verboseLog("[minimuxer] [net] monitor stopped")
        return true
    }
    
    var isWifiSatisfied: Bool {
        let path = monitor.currentPath
        return path.status == .satisfied && path.usesInterfaceType(.wifi)
    }
    
    var isWiredSatisfied: Bool {
        let path = monitor.currentPath
        return path.status == .satisfied && path.usesInterfaceType(.wiredEthernet)
    }
    
    var isUsbSatisfied: Bool {
        return NetworkIfaceScanner.scan(quiet: true).contains { info in
            let name = info.name.lowercased()
            return name.hasPrefix("en") && name != "en0" && info.hostIP.hasPrefix("169.254.")
        }
    }
    
    var isBridgeSatisfied: Bool {
        let path = monitor.currentPath
        if path.status == .satisfied && path.usesInterfaceType(.other) {
            return true
        }
        
        return NetworkIfaceScanner.scan(quiet: true).contains { info in
            info.name.lowercased().contains("bridge") ||
            info.name.lowercased().contains("ap")
        }
    }

    // True when at least one `utun*` interface is active (userspace VPN — ex: wireguard).
    var isUTunAvailable: Bool {
        return NetworkIfaceScanner.scan(quiet: true).contains { $0.name.hasPrefix("utun") }
    }

    // True when at least one `ipsec*` interface is active (IKEv2/IPSec kernel VPN).
    var isIKEv2IPSecAvailable: Bool {
        return NetworkIfaceScanner.scan(quiet: true).contains { $0.name.hasPrefix("ipsec") }
    }
}
