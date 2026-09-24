//
//  EMProxyTests.swift
//  MinimuxerTests
//
//  Created by Magesh K on 12/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import XCTest
import Foundation
import CryptoKit
import Network
@testable import Minimuxer


/*
Packet flow:

1. Source ports are ephemereal at the connection initiator side.
2. Applications initiating connection are bound to same iface 
they are sending traffic-towards(outbound) the local interface (including virtual).

    App (10.7.0.2)
    |   ^
    |   | [Send: Dest 10.7.0.1:3344   (Src 10.7.0.2:3232)]
    v   | [Recv: Dest 10.7.0.2:3232   (Src 10.7.0.1:3344)]
    VPN Client (iface ip = 10.7.0.2)
    |   ^
    |   | [Send: Dest 127.0.0.1:51820 (Src 127.0.0.1:4234)]
    v   | [Recv: Dest 127.0.0.1:4234  (Src 127.0.0.1:51820)]
    EMProxy (boringtun Server)
    |   ^
    |   | [Send: Dest 127.0.0.1:62078 (Src 127.0.0.1:2232)]
    v   | [Recv: Dest 127.0.0.1:2232  (Src 127.0.0.1:62078)]
    Lockdownd (at 62078)

*/

final class EMProxyTests: XCTestCase {



    // Test-1: full end to end test passing packets thru real wireguard VPN client
    //         expects a properly functioning VPN configured to match the VPN source/tunnel routes list
    //         and a VPN destination endpoint used by EMProxy in start() which is the wireguard server 
    //         handling packets forwarded from the VPN
    func testEMProxyWireGuardDeviceHandshake() async throws {
        let HELLO_WORLD_PAYLOAD = "Hello World"

        let peerIp = "10.7.0.1"
        let testPort: UInt16 = 39483

        let payloadReceivedExpectation = expectation(description: "Payload received by dummy listener")

        print("[EMProxyTests] Spawning dummy TCP listener on port \(testPort)...")
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: testPort)!)
        listener.newConnectionHandler = { newConnection in
            newConnection.stateUpdateHandler = { state in
                if case .ready = state {
                    newConnection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, error in
                        if let data = data, let text = String(data: data, encoding: .utf8) {
                            print("[EMProxyTests] [DummyListener] Received payload: \"\(text)\"")
                            if text == HELLO_WORLD_PAYLOAD {
                                payloadReceivedExpectation.fulfill()
                            }
                        }
                    }
                }
            }
            newConnection.start(queue: .global())
        }
        listener.start(queue: .global())
        defer { listener.cancel() }

        Minimuxer.shared.emproxy.setHandshakeClient(host: peerIp, port: testPort)
        print("[EMProxyTests] Starting Minimuxer.shared.emproxy...")
        try await Minimuxer.shared.emproxy.start()

        print("[EMProxyTests] Using VPN peer IP: \(peerIp)")

        print("[EMProxyTests] Attempting to connect to \(peerIp):\(testPort) to trigger system VPN handshake...")
        let connection = NWConnection(host: NWEndpoint.Host(peerIp), port: NWEndpoint.Port(rawValue: testPort)!, using: .tcp)
        
        connection.stateUpdateHandler = { state in
            print("[EMProxyTests] Connection state changed: \(state)")
            if case .ready = state {
                print("[EMProxyTests] Connection established successfully!")
                let payload = HELLO_WORLD_PAYLOAD.data(using: .utf8)!
                print("[EMProxyTests] Sending payload over connection to \(peerIp):\(testPort) (which will route through the wireguard VPN client which then forwards to EMProxy that then sends to our dummy listener on localhost)...")
                connection.send(content: payload, completion: .contentProcessed { error in
                    if let error = error {
                        print("[EMProxyTests] Send error: \(error)")
                    } else {
                        print("[EMProxyTests] Send completed successfully!")
                    }
                })
            }
        }
        
        connection.start(queue: .global())
        
        await fulfillment(of: [payloadReceivedExpectation], timeout: 15.0)
        
        connection.cancel()
        
        print("[EMProxyTests] Stopping Minimuxer.shared.emproxy...")
        try await Minimuxer.shared.emproxy.stop()
        print("[EMProxyTests] WireGuard device handshake test completed!")
    }

    // Test-2: This serves as a mock for a real wireguard VPN client that would be talking wg protocol 
    // (doing a wg-handshake) to the wg server which here is our EMProxy using the boringTun wg server implemenation.
    // in case one swaps boringTun with wireguard-go/wireguard-rs etc, then this can confirm 
    // if our implementation is still safe.
    func testEMProxyWireGuardServerHandshake_v040() async throws {
        let handshakeState = try makeWireGuardHandshakeInitiationPacket()
        let handshakePacket = handshakeState.packet

        print("[EMProxyTests] Configuring EMProxy handshake client (disabled)...")
        Minimuxer.shared.emproxy.setHandshakeClient(host: "", port: 0, enabled: false)
        print("[EMProxyTests] Starting Minimuxer.shared.emproxy for WireGuard handshake test...")
        try await Minimuxer.shared.emproxy.start()

        let testPort: UInt16 = 51820
        print("[EMProxyTests] Sending WireGuard handshake initiation packet to 127.0.0.1:\(testPort)...")

        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: testPort)!, using: .udp)
        
        let responseReceivedExpectation = expectation(description: "Handshake response received from emproxy")
        var responsePacket: Data?
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.receiveMessage { data, _, _, error in
                    if let data = data {
                        print("[EMProxyTests] Received \(data.count) bytes response from emproxy: \(data.map { String(format: "%02x", $0) }.joined())")
                        responsePacket = data
                        responseReceivedExpectation.fulfill()
                    } else if let error = error {
                        print("[EMProxyTests] Receive error: \(error)")
                    }
                }
            default:
                break
            }
        }
        
        connection.start(queue: .global())
        connection.send(content: handshakePacket, completion: .idempotent)
        
        await fulfillment(of: [responseReceivedExpectation], timeout: 2.0)
        
        guard let resp = responsePacket, resp.count >= 60 else {
            XCTFail("No valid response packet received")
            return
        }
        
        let serverIndex = resp.subdata(in: 4..<8)
        let serverEphPubRaw = resp.subdata(in: 12..<44)
        let encryptedNothing = resp.subdata(in: 44..<60)
        
        guard let clientPrivRaw = Data(base64Encoded: "AIIeeUDvk3NeAFJ9BWCQvPJize/9WZibMnGJ/0rt5k4=") else {
            XCTFail("Failed to decode client private key")
            return
        }
        
        var hash = handshakeState.hash
        var chainingKey = handshakeState.chainingKey
        let ephemeralPriv = handshakeState.ephemeralPriv
        
        hash = BLAKE2s.hash(hash + serverEphPubRaw)
        let temp = BLAKE2s.hmac(key: chainingKey, data1: serverEphPubRaw)
        chainingKey = BLAKE2s.hmac(key: temp, data1: Data([0x01]))
        
        guard let serverEphPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverEphPubRaw),
              let ephSharedSecret = try? ephemeralPriv.sharedSecretFromKeyAgreement(with: serverEphPub) else {
            XCTFail("Failed to compute ephemeral shared secret")
            return
        }
        let ephemeralShared = ephSharedSecret.withUnsafeBytes { Data($0) }
        
        let temp1 = BLAKE2s.hmac(key: chainingKey, data1: ephemeralShared)
        chainingKey = BLAKE2s.hmac(key: temp1, data1: Data([0x01]))
        
        guard let clientPriv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: clientPrivRaw),
              let staticSharedSecret = try? clientPriv.sharedSecretFromKeyAgreement(with: serverEphPub) else {
            XCTFail("Failed to compute static shared secret")
            return
        }
        let staticShared = staticSharedSecret.withUnsafeBytes { Data($0) }
        
        let temp2 = BLAKE2s.hmac(key: chainingKey, data1: staticShared)
        chainingKey = BLAKE2s.hmac(key: temp2, data1: Data([0x01]))
        
        let tempPsk = BLAKE2s.hmac(key: chainingKey, data1: Data(repeating: 0, count: 32))
        chainingKey = BLAKE2s.hmac(key: tempPsk, data1: Data([0x01]))
        let temp3 = BLAKE2s.hmac(key: tempPsk, data1: chainingKey, data2: Data([0x02]))
        let key = BLAKE2s.hmac(key: tempPsk, data1: temp3, data2: Data([0x03]))
        
        hash = BLAKE2s.hash(hash + temp3)
        
        let nonce = try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12))
        let sealedBox = try ChaChaPoly.SealedBox(combined: nonce + Data() + encryptedNothing)
        let _ = try ChaChaPoly.open(sealedBox, using: SymmetricKey(data: key), authenticating: hash)
        
        hash = BLAKE2s.hash(hash + encryptedNothing)
        
        let tempSession = BLAKE2s.hmac(key: chainingKey, data1: Data())
        let sendingKey = BLAKE2s.hmac(key: tempSession, data1: Data([0x01]))
        
        print("[EMProxyTests] Successfully decrypted handshake response! Derived sending key.")
        
        var keepalivePacket = Data()
        keepalivePacket.append(contentsOf: [4, 0, 0, 0])
        keepalivePacket.append(serverIndex)
        keepalivePacket.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        
        let sealedPayload = try ChaChaPoly.seal(Data(), using: SymmetricKey(data: sendingKey), nonce: nonce, authenticating: Data())
        keepalivePacket.append(sealedPayload.tag)
        
        print("[EMProxyTests] Sending keepalive packet to emproxy...")
        connection.send(content: keepalivePacket, completion: .idempotent)
        
        try await Task.sleep(nanoseconds: 500_000_000)
        connection.cancel()

        print("[EMProxyTests] Stopping Minimuxer.shared.emproxy...")
        try await Minimuxer.shared.emproxy.stop()
        print("[EMProxyTests] WireGuard handshake test completed!")
    }
}

// Private Helper Extensions Describing Verification Methods

private extension EMProxyTests {

    struct HandshakeState {
        let packet: Data
        let chainingKey: Data
        let hash: Data
        let ephemeralPriv: Curve25519.KeyAgreement.PrivateKey
    }

    func makeWireGuardHandshakeInitiationPacket() throws -> HandshakeState {
        let dummyState = HandshakeState(packet: Data(), chainingKey: Data(), hash: Data(), ephemeralPriv: try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0, count: 32)))
        guard let clientPrivRaw = Data(base64Encoded: "AIIeeUDvk3NeAFJ9BWCQvPJize/9WZibMnGJ/0rt5k4="),
              let serverPubRaw = Data(base64Encoded: "kHDoekeYhBvfW9a9UQ+UCmpbG423eejTjcjW+DT+JF0=") else {
            return dummyState
        }

        let initialChainKey = Data([
            96, 226, 109, 174, 243, 39, 239, 192, 46, 195, 53, 226, 160, 37, 210, 208, 22, 235, 66, 6, 248,
            114, 119, 245, 45, 56, 209, 152, 139, 120, 205, 54
        ])
        let initialChainHash = Data([
            34, 17, 179, 97, 8, 26, 197, 102, 105, 18, 67, 219, 69, 138, 213, 50, 45, 156, 108, 102, 34,
            147, 232, 183, 14, 225, 156, 101, 186, 7, 158, 243
        ])

        var chainingKey = initialChainKey
        var hash = BLAKE2s.hash(initialChainHash + serverPubRaw)

        let ephemeralPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0, count: 32))
        let ephemeralPub = ephemeralPriv.publicKey.rawRepresentation

        var packet = Data()
        packet.append(contentsOf: [1, 0, 0, 0])
        packet.append(contentsOf: [1, 0, 0, 0])
        packet.append(ephemeralPub)

        hash = BLAKE2s.hash(hash + ephemeralPub)

        let temp0 = BLAKE2s.hmac(key: chainingKey, data1: ephemeralPub)
        chainingKey = BLAKE2s.hmac(key: temp0, data1: Data([0x01]))

        guard let serverPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPubRaw),
              let sharedSecret1 = try? ephemeralPriv.sharedSecretFromKeyAgreement(with: serverPub) else {
            return dummyState
        }
        let dh1 = sharedSecret1.withUnsafeBytes { Data($0) }

        let res1 = BLAKE2s.hkdf2(ck: chainingKey, input: dh1)
        chainingKey = res1.ck
        let key1 = SymmetricKey(data: res1.key)

        guard let clientPriv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: clientPrivRaw) else {
            return dummyState
        }
        let clientPubRaw = clientPriv.publicKey.rawRepresentation
        guard let nonce = try? ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12)) else { return dummyState }
        let sealedStatic = try ChaChaPoly.seal(clientPubRaw, using: key1, nonce: nonce, authenticating: hash)
        let encryptedStatic = sealedStatic.ciphertext + sealedStatic.tag
        packet.append(encryptedStatic)
        hash = BLAKE2s.hash(hash + encryptedStatic)

        guard let sharedSecret2 = try? clientPriv.sharedSecretFromKeyAgreement(with: serverPub) else {
            return dummyState
        }
        let dh2 = sharedSecret2.withUnsafeBytes { Data($0) }

        let res2 = BLAKE2s.hkdf2(ck: chainingKey, input: dh2)
        chainingKey = res2.ck
        let key2 = SymmetricKey(data: res2.key)

        var timestamp = Data(repeating: 0, count: 12)
        let now = Date().timeIntervalSince1970
        let seconds = UInt64(now) + 4611686018427387904
        let nanos = UInt32((now - floor(now)) * 1_000_000_000)
        var secBE = seconds.bigEndian
        var nanBE = nanos.bigEndian
        withUnsafeBytes(of: &secBE) { timestamp.replaceSubrange(0..<8, with: $0) }
        withUnsafeBytes(of: &nanBE) { timestamp.replaceSubrange(8..<12, with: $0) }

        let sealedTimestamp = try ChaChaPoly.seal(timestamp, using: key2, nonce: nonce, authenticating: hash)
        let encryptedTimestamp = sealedTimestamp.ciphertext + sealedTimestamp.tag
        packet.append(encryptedTimestamp)
        hash = BLAKE2s.hash(hash + encryptedTimestamp)

        let mac1Key = BLAKE2s.hash(Data("mac1----".utf8) + serverPubRaw)
        let mac1 = BLAKE2s.hash(packet, key: mac1Key, outputLength: 16)
        packet.append(mac1)
        packet.append(contentsOf: Data(repeating: 0, count: 16))

        print("[EMProxyTests] packet size: \(packet.count)")
        print("[EMProxyTests] packet hex: \(packet.map { String(format: "%02x", $0) }.joined())")
        return HandshakeState(packet: packet, chainingKey: chainingKey, hash: hash, ephemeralPriv: ephemeralPriv)
    }
}

// Custom BLAKE2s cryptographic wrappers are required because Apple's CryptoKit lacks native BLAKE2s support, which is mandatory for the WireGuard protocol.
fileprivate struct BLAKE2s {
    static func hash(_ data: Data, key: Data = Data(), outputLength: Int = 32) -> Data {
        var state = RFC7693BLAKE2s(key: key, outlen: outputLength)
        state.update(data)
        return state.finalize()
    }

    static func hmac(key: Data, data1: Data, data2: Data = Data()) -> Data {
        var k = key
        if k.count > 64 {
            k = BLAKE2s.hash(k)
        }
        if k.count < 64 {
            k.append(Data(repeating: 0, count: 64 - k.count))
        }

        var iKey = Data(repeating: 0, count: 64)
        var oKey = Data(repeating: 0, count: 64)
        for i in 0..<64 {
            iKey[i] = k[i] ^ 0x36
            oKey[i] = k[i] ^ 0x5C
        }

        let innerHash = BLAKE2s.hash(iKey + data1 + data2, key: Data(), outputLength: 32)
        return BLAKE2s.hash(oKey + innerHash, key: Data(), outputLength: 32)
    }

    static func hkdf2(ck: Data, input: Data) -> (ck: Data, key: Data) {
        let temp = BLAKE2s.hmac(key: ck, data1: input)
        let newCk = BLAKE2s.hmac(key: temp, data1: Data([0x01]))
        let newKey = BLAKE2s.hmac(key: temp, data1: newCk, data2: Data([0x02]))
        return (newCk, newKey)
    }
}

// Core RFC 7693 BLAKE2s hashing state machine implementation.
fileprivate struct RFC7693BLAKE2s {
    static let iv: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
    ]
    static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]
    ]

    var h: [UInt32] = iv
    var t: [UInt32] = [0, 0]
    var f: [UInt32] = [0, 0]
    var buf = [UInt8](repeating: 0, count: 64)
    var buflen: Int = 0
    var outlen: Int = 32

    init(key: Data = Data(), outlen: Int = 32) {
        self.outlen = outlen
        h[0] ^= 0x01010000 | (UInt32(key.count) << 8) | UInt32(outlen)
        if !key.isEmpty {
            var block = [UInt8](repeating: 0, count: 64)
            for (i, b) in key.enumerated() { block[i] = b }
            update(Data(block))
        }
    }

    mutating func incrementCounter(_ inc: UInt32) {
        t[0] = t[0] &+ inc
        if t[0] < inc {
            t[1] = t[1] &+ 1
        }
    }

    mutating func compress(isLast: Bool) {
        if isLast { f[0] = 0xFFFFFFFF }
        var m = [UInt32](repeating: 0, count: 16)
        for j in 0..<16 {
            let b0 = UInt32(buf[j * 4])
            let b1 = UInt32(buf[j * 4 + 1])
            let b2 = UInt32(buf[j * 4 + 2])
            let b3 = UInt32(buf[j * 4 + 3])
            m[j] = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        }

        var v = h + RFC7693BLAKE2s.iv
        v[12] ^= t[0]
        v[13] ^= t[1]
        v[14] ^= f[0]
        v[15] ^= f[1]

        for r in 0..<10 {
            let s = RFC7693BLAKE2s.sigma[r]
            g(&v, 0, 4, 8, 12, m[s[0]], m[s[1]])
            g(&v, 1, 5, 9, 13, m[s[2]], m[s[3]])
            g(&v, 2, 6, 10, 14, m[s[4]], m[s[5]])
            g(&v, 3, 7, 11, 15, m[s[6]], m[s[7]])
            g(&v, 0, 5, 10, 15, m[s[8]], m[s[9]])
            g(&v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            g(&v, 2, 7, 8, 13, m[s[12]], m[s[13]])
            g(&v, 3, 4, 9, 14, m[s[14]], m[s[15]])
        }

        for j in 0..<8 {
            h[j] ^= v[j] ^ v[j + 8]
        }
    }

    mutating func update(_ data: Data) {
        for b in data {
            if buflen == 64 {
                incrementCounter(64)
                compress(isLast: false)
                buf = [UInt8](repeating: 0, count: 64)
                buflen = 0
            }
            buf[buflen] = b
            buflen += 1
        }
    }

    mutating func finalize() -> Data {
        incrementCounter(UInt32(buflen))
        while buflen < 64 {
            buf[buflen] = 0
            buflen += 1
        }
        compress(isLast: true)

        var result = Data()
        for word in h {
            var w = word.littleEndian
            withUnsafeBytes(of: &w) { result.append(contentsOf: $0) }
        }
        return result.prefix(outlen)
    }

    private mutating func g(_ v: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt32, _ y: UInt32) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = (v[d] ^ v[a]).rotr(16)
        v[c] = v[c] &+ v[d]
        v[b] = (v[b] ^ v[c]).rotr(12)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = (v[d] ^ v[a]).rotr(8)
        v[c] = v[c] &+ v[d]
        v[b] = (v[b] ^ v[c]).rotr(7)
    }
}

fileprivate extension UInt32 {
    func rotr(_ count: Int) -> UInt32 {
        return (self >> count) | (self << (32 - count))
    }
}


