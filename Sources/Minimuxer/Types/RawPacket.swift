//
//  RawPacket.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
internal import MinimuxerCommon

internal struct RawPacket {
    let version: UInt32
    let message: UInt32
    let tag: UInt32
    let plist: [String: Any]

    init?(data: Data) {
        guard data.count >= MinimuxerConstants.packetHeaderLen else { return nil }
        let size = data.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        self.version = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }
        self.message = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self).littleEndian }
        self.tag = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self).littleEndian }

        guard data.count >= Int(size) else { return nil }
        let plistData = data.subdata(in: MinimuxerConstants.packetHeaderLen..<Int(size))
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        self.plist = plist
    }

    init(plist: [String: Any], version: UInt32, message: UInt32, tag: UInt32) {
        self.plist = plist
        self.version = version
        self.message = message
        self.tag = tag
    }

    var data: Data {
        guard let plistData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return Data()
        }

        var packetData = Data()
        var size = UInt32(MinimuxerConstants.packetHeaderLen + plistData.count).littleEndian
        var ver = version.littleEndian
        var msg = message.littleEndian
        var t = tag.littleEndian

        packetData.append(withUnsafeBytes(of: &size) { Data($0) })
        packetData.append(withUnsafeBytes(of: &ver) { Data($0) })
        packetData.append(withUnsafeBytes(of: &msg) { Data($0) })
        packetData.append(withUnsafeBytes(of: &t) { Data($0) })
        packetData.append(plistData)

        return packetData
    }
}
