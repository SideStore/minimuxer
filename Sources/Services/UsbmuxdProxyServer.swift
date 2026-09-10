//
//  UsbmuxdProxyServer.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import Network
internal import DeviceGatewayAPI
internal import MinimuxerCommon

final internal class UsbmuxdProxyServer {
    let gateway: any DeviceGatewayAPI

    private var maxBufferLen: Int { MinimuxerConstants.usbmuxMaxPacketBufferLength }
    private var headerLen: Int { MinimuxerConstants.usbmuxHeaderLen }

    private(set) var started = false
    private(set) var isListening = false

    private var deviceUDID: String?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "minimuxer.UsbmuxdProxyServer", qos: .userInitiated)

    // Stable device state
    private var currentDeviceIp: String?
    private var currentEvent: String?

    init(gateway: any DeviceGatewayAPI) {
        self.gateway = gateway
    }

    func notifyDeviceAttached(tunnelPeerIp: String) {
        currentDeviceIp = tunnelPeerIp
        currentEvent = MinimuxerConstants.deviceAttach
    }
    func notifyDeviceDetached() {
        currentDeviceIp = nil
        currentEvent = MinimuxerConstants.deviceDetach
    }

    // Binds a TCP server on 127.0.0.1:27015 and accepts incoming connections
    // from libusbmuxd. This is our fake usbmuxd — it speaks
    // just enough of the usbmuxd protocol for the library to discover the
    // device, read the pairing record, and open services (AFC, lockdown, etc.).
    @discardableResult
    func start(udid: String) async throws -> Bool {
        guard !started else {
            verboseLog("[minimuxer] Already started UsbmuxdProxyServer, skipping")
            return false
        }
        deviceUDID = udid
        isListening = false

        guard let port = NWEndpoint.Port(rawValue: MinimuxerConstants.usbmuxdPort) else {
            throw MinimuxerError.connect("Invalid usbmuxd port: \(MinimuxerConstants.usbmuxdPort)")
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let newListener = try NWListener(using: params, on: port)

        return try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) var hasResponded = false

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                    case .ready:
                        verboseLog("[minimuxer] UsbmuxdProxyServer (NWListener) bound successfully to \(MinimuxerConstants.usbmuxdHost):\(MinimuxerConstants.usbmuxdPort)")
                        self.isListening = true
                        self.started = true
                        if !hasResponded {
                            hasResponded = true
                            continuation.resume(returning: true)
                        }
                    case .failed(let error):
                        debugLog("[minimuxer] UsbmuxdProxyServer listener failed with error: \(error)")
                        self.isListening = false
                        self.started = false
                        if !hasResponded {
                            hasResponded = true
                            continuation.resume(throwing: MinimuxerError.connect("UsbmuxdProxyServer failed to bind: \(error.localizedDescription)"))
                        }
                    case .cancelled:
                        self.isListening = false
                        self.started = false
                    default:
                        break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener = newListener
            newListener.start(queue: queue)
        }
    }

    func stop() async {
        guard started else { return }
        let currentListener = listener
        started = false
        isListening = false
        deviceUDID = nil
        listener = nil

        guard let currentListener = currentListener else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            nonisolated(unsafe) var hasResponded = false
            currentListener.stateUpdateHandler = { state in
                if case .cancelled = state {
                    if !hasResponded {
                        hasResponded = true
                        continuation.resume()
                    }
                }
            }
            currentListener.cancel()
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        readNextPacket(on: connection)
    }

    private func readNextPacket(on connection: NWConnection) {
        // 1. Read the 4-byte size header
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] sizeData, _, _, error in
            guard let self = self else { return }
            if let error = error {
                debugLog("[minimuxer] UsbmuxdProxyServer receive size error: \(error)")
                connection.cancel()
                return
            }
            guard let sizeData = sizeData, sizeData.count == 4 else {
                connection.cancel()
                return
            }

            let size = sizeData.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            guard size >= UInt32(self.headerLen) && size <= UInt32(self.maxBufferLen) else {
                debugLog("[minimuxer] UsbmuxdProxyServer invalid packet size: \(size)")
                connection.cancel()
                return
            }

            // 2. Read the remaining size - 4 bytes
            let bodyLen = Int(size - 4)
            connection.receive(minimumIncompleteLength: bodyLen, maximumLength: bodyLen) { [weak self] bodyData, _, _, bodyError in
                guard let self = self else { return }
                if let bodyError = bodyError {
                    debugLog("[minimuxer] UsbmuxdProxyServer receive body error: \(bodyError)")
                    connection.cancel()
                    return
                }
                guard let bodyData = bodyData, bodyData.count == bodyLen else {
                    connection.cancel()
                    return
                }

                var fullPacketData = sizeData
                fullPacketData.append(bodyData)

                self.processPacketData(fullPacketData, on: connection)
            }
        }
    }

    private func processPacketData(_ data: Data, on connection: NWConnection) {
        defer {
            readNextPacket(on: connection)
        }

        guard let packet = RawPacket(data: data) else { return }

        do {
            let response = try handlePacket(packet)
            let responsePacket = RawPacket(plist: response, version: 1, message: 8, tag: packet.tag)
            let responseData = responsePacket.data

            connection.send(content: responseData, completion: .contentProcessed({ error in
                if let error = error {
                    debugLog("[minimuxer] UsbmuxdProxyServer send error: \(error)")
                }
            }))
        } catch {}
    }

    // Packet Handling
    // Responds to the only usbmuxd protocol message("ListDevices") that
    // idevice requires to establish lockdown session when using lockdown based pairing file
    // (lockdown requires UDID to start session, so our server responds with data read from pair file)
    private func handlePacket(_ packet: RawPacket) throws -> [String: Any] {
        guard let messageType = packet.plist["MessageType"] as? String else {
            throw MinimuxerError.connect("Malformed usbmuxd packet: missing MessageType field")
        }

        verboseLog("[minimuxer] usbmux message: \(messageType)")

        switch messageType {
            case "ListDevices":
                guard let tunnelIfaceIp = currentDeviceIp else {
                    return ["DeviceList": []]
                }
                guard let udid = deviceUDID else {
                    throw MinimuxerError.invalidPairing(protocol: .lockdown, reason: "No device UDID available for ListDevices response")
                }
                let payload: [String: Any] = [
                    "DeviceID": 1,                                                      // non-zero ID
                    "Properties": [
                        "ConnectionType": "Network",                                    // using 'network' protocol of usbmuxd
                        "DeviceID": 1,                                                  // fake non-zero device id
                        "EscapedFullServiceName": "\(udid)._apple-mobdev2._tcp.local",  // advert for mds discovery
                        "InterfaceIndex": 0,                                            // don't care
                        "NetworkAddress": convertIp(tunnelIfaceIp),                     // remote IP where device's lockdownd is accepting requests on
                        "SerialNumber": udid                                            // device UDID
                    ]
                ]
                return ["DeviceList": [payload]]
            case "Listen":
                return ["MessageType": "Result", "Number": 0]
            case "ReadBUID":
                let buid = (self.gateway.pairingDataDict?["SystemBUID"] as? String) ?? "00000000-0000-0000-0000-000000000000"
                return ["BUID": buid]
            case "ReadPairRecord":
                guard let pairingData = self.gateway.pairingFileData else {
                    throw MinimuxerError.invalidPairing(protocol: .lockdown, reason: "No pairing file data available for ReadPairRecord")
                }
                return ["PairRecordData": pairingData]
            default:
                debugLog("[minimuxer] WARN: unknown message type: \(messageType)")
                throw MinimuxerError.connect("Unsupported usbmuxd message type: \(messageType)")
        }
    }

    // Encodes an IPv4 or IPv6 address into the 152-byte sockaddr_storage layout that
    // libusbmuxd expects in the NetworkAddress field of the device properties.
    private func convertIp(_ ip: String) -> Data {
        var data = Data(count: 152)
        if ip.contains(":") {
            var sa6 = sockaddr_in6()
            #if os(macOS) || os(iOS)
            sa6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            sa6.sin6_family = sa_family_t(AF_INET6)

            var cleanIp = ip
            if let scopeRange = cleanIp.range(of: "%") {
                let ifaceName = String(cleanIp[scopeRange.upperBound...])
                cleanIp = String(cleanIp[..<scopeRange.lowerBound])
                sa6.sin6_scope_id = if_nametoindex(ifaceName)
            } else if cleanIp.lowercased().hasPrefix("fe80:") {
                let en0Idx = if_nametoindex("en0")
                if en0Idx != 0 {
                    sa6.sin6_scope_id = en0Idx
                } else {
                    let awdl0Idx = if_nametoindex("awdl0")
                    sa6.sin6_scope_id = awdl0Idx != 0 ? awdl0Idx : if_nametoindex("lo0")
                }
            }

            if inet_pton(AF_INET6, cleanIp, &sa6.sin6_addr) == 1 {
                withUnsafeBytes(of: sa6) { src in
                    data.withUnsafeMutableBytes { dst in
                        dst.copyMemory(from: src)
                    }
                }
            }
        } else {
            var sa = sockaddr_in()
            #if os(macOS) || os(iOS)
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            sa.sin_family = sa_family_t(AF_INET)

            if inet_pton(AF_INET, ip, &sa.sin_addr) == 1 {
                withUnsafeBytes(of: sa) { src in
                    data.withUnsafeMutableBytes { dst in
                        dst.copyMemory(from: src)
                    }
                }
            }
        }
        return data
    }
}
