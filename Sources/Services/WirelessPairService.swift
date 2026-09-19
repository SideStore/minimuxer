//
//  WirelessPairService.swift
//  Minimuxer
//
//  Created by Magesh K on 04/07/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
internal import MinimuxerCommon
internal import DeviceGatewayAPI

// MARK: - Wireless Pair API

final internal class WirelessPairService: WirelessPairAPI {
    let deviceProvider: DeviceProvider
    var gateway: any DeviceGatewayAPI {
        deviceProvider.gateway
    }
    
    private var netService: NetService?
    
    private var activeStartTask: Task<Void, Never>?
    private let startLock = NSLock()
    
    private var activeTriggerTasks: [String: Task<Void, Never>] = [:]
    private let triggerLock = NSLock()
    
    var onPinReceived: ((String) -> Void)?
    var onReadyToPair: ((String, Int) -> Void)?
    var onRequestPin: ((@escaping (String) -> Void) -> Void)?
    
    init(deviceProvider: DeviceProvider) {
        self.deviceProvider = deviceProvider
    }
    
    func start(
        hostName: String = MinimuxerConstants.defaultHostName,
        hostModel: String = MinimuxerConstants.defaultHostModel,
        outPath: String,
        resolveFileName: (@Sendable (String, String) -> String)? = nil,
        completion: @escaping (Result<PairedDeviceRecord, Swift.Error>) -> Void
    ) {
        debugLog("[WirelessPairService] start() invoked (hostName='\(hostName)', hostModel='\(hostModel)', outPath='\(outPath)')")
        startLock.withLock {
            if activeStartTask != nil {
                debugLog("[WirelessPairService] start() cancelling existing activeStartTask")
                activeStartTask?.cancel()
                activeStartTask = nil
            }
        }
        
        let task = Task.detached { [weak self] in
            guard let self = self else { return }
            
            let outcome: Result<PairedDeviceRecord, Swift.Error>
            do {
                debugLog("[WirelessPairService] Calling gateway.startWirelessPair...")
                let pairedDevice = try await self.gateway.startWirelessPair(
                    hostName: hostName,
                    hostModel: hostModel,
                    outPath: outPath,
                    resolveFileName: resolveFileName,
                    onReady: { [weak self] serviceID, port, txtRecords in
                        guard let self = self else { return }
                        debugLog("[WirelessPairService] gateway onReady callback (serviceID='\(serviceID)', port=\(port), txtCount=\(txtRecords.count))")
                        var txt: [String: Data] = [:]
                        for (k, v) in txtRecords {
                            txt[k] = Data(v.utf8)
                        }
                        Task { @MainActor in
                            self.startAdvertising(serviceID: serviceID, port: Int(port), txt: txt)
                        }
                    },
                    onPin: { [weak self] pinString in
                        guard let self = self else { return }
                        debugLog("[WirelessPairService] gateway onPin callback (pin='\(pinString)')")
                        Task { @MainActor in
                            self.onPinReceived?(pinString)
                        }
                    }
                )
                debugLog("[WirelessPairService] gateway.startWirelessPair SUCCEEDED with device: \(pairedDevice.name) (\(pairedDevice.pairingFilePath))")
                outcome = .success(pairedDevice)
            } catch {
                debugLog("[WirelessPairService] gateway.startWirelessPair FAILED with error: \(error)")
                outcome = .failure(error)
            }
            
            await MainActor.run {
                self.startLock.withLock {
                    self.activeStartTask = nil
                }
                self.stopAdvertising()
                completion(outcome)
            }
        }
        
        startLock.withLock {
            activeStartTask = task
        }
    }

    func trigger(
        targetIp: String,
        targetPort: UInt16,
        hostName: String = MinimuxerConstants.defaultHostName,
        hostModel: String = MinimuxerConstants.defaultHostModel,
        outPath: String,
        resolveFileName: (@Sendable (String, String) -> String)? = nil,
        completion: @escaping (Result<PairedDeviceRecord, Swift.Error>) -> Void
    ) {
        let socketKey = "\(targetIp):\(targetPort)"
        debugLog("[WirelessPairService] trigger() invoked for \(socketKey) (outPath='\(outPath)')")
        
        triggerLock.withLock {
            if let existing = activeTriggerTasks[socketKey] {
                debugLog("[WirelessPairService] trigger() cancelling existing activeTriggerTask for \(socketKey)")
                existing.cancel()
                activeTriggerTasks.removeValue(forKey: socketKey)
            }
        }
        
        let task = Task.detached { [weak self] in
            guard let self = self else { return }
            
            let outcome: Result<PairedDeviceRecord, Swift.Error>
            do {
                debugLog("[WirelessPairService] Calling gateway.triggerWirelessPair for \(socketKey)...")
                let pairedDevice = try await self.gateway.triggerWirelessPair(
                    targetIp: targetIp,
                    targetPort: targetPort,
                    hostName: hostName,
                    hostModel: hostModel,
                    outPath: outPath,
                    resolveFileName: resolveFileName,
                    onRequestPin: { [weak self] submitPin in
                        guard let self = self else { return }
                        debugLog("[WirelessPairService] gateway trigger onRequestPin callback invoked")
                        Task { @MainActor in
                            if let onRequestPin = self.onRequestPin {
                                onRequestPin(submitPin)
                            } else {
                                submitPin("000000")
                            }
                        }
                    }
                )
                debugLog("[WirelessPairService] gateway.triggerWirelessPair SUCCEEDED with device: \(pairedDevice.name) (\(pairedDevice.pairingFilePath))")
                outcome = .success(pairedDevice)
            } catch {
                debugLog("[WirelessPairService] gateway.triggerWirelessPair FAILED with error: \(error)")
                outcome = .failure(error)
            }
            
            await MainActor.run {
                self.triggerLock.withLock {
                    _ = self.activeTriggerTasks.removeValue(forKey: socketKey)
                }
                completion(outcome)
            }
        }
        
        triggerLock.withLock {
            activeTriggerTasks[socketKey] = task
        }
    }
    
    func stop() {
        debugLog("[WirelessPairService] stop() invoked")
        startLock.withLock {
            activeStartTask?.cancel()
            activeStartTask = nil
        }
        
        triggerLock.withLock {
            for (key, task) in activeTriggerTasks {
                debugLog("[WirelessPairService] stop() cancelling active trigger task for \(key)")
                task.cancel()
            }
            activeTriggerTasks.removeAll()
        }
        
        stopAdvertising()
    }
    
    fileprivate func startAdvertising(serviceID: String, port: Int, txt: [String: Data]) {
        debugLog("[WirelessPairService] startAdvertising() serviceID='\(serviceID)', port=\(port), domain='\(MinimuxerConstants.defaultAdDomain)', type='\(MinimuxerConstants.remotePairingPairableHostServiceType)'")
        stopAdvertising()
        let service = NetService(
            domain: MinimuxerConstants.defaultAdDomain,
            type: MinimuxerConstants.remotePairingPairableHostServiceType,
            name: serviceID,
            port: Int32(port)
        )
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
        onReadyToPair?(serviceID, port)
    }
    
    private func stopAdvertising() {
        if let ns = netService {
            debugLog("[WirelessPairService] stopAdvertising() stopping NetService '\(ns.name)'")
            ns.stop()
            netService = nil
        }
    }
}
