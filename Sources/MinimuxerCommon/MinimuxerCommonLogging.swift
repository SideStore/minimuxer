//
//  MinimuxerCommonLogging.swift
//  MinimuxerCommon
//
//  Created by Magesh K on 03/09/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

public enum MinimuxerCommonLogging {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _isLoggingEnabled: Bool = true

    public static var isLoggingEnabled: Bool {
        lock.withLock { _isLoggingEnabled }
    }

    public static func setLogging(_ enabled: Bool) {
        lock.withLock { _isLoggingEnabled = enabled }
    }
}

private func getFastTimestamp() -> String {
    let now = Date()
    let cal = Calendar.current
    let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: now)
    let ms = (comps.nanosecond ?? 0) / 1_000_000
    return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d",
                  comps.year ?? 0, comps.month ?? 0, comps.day ?? 0,
                  comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0,
                  ms)
}

private func getTag(level: String) -> String {
    let timestamp = getFastTimestamp()
    return "\(timestamp) \(level): "
}

func debugLog(_ text: @autoclosure () -> String) {
    let message = text()
    if !message.isEmpty && message.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
        print(message, terminator: "")
    } else {
        print("\(getTag(level: "[D]"))\(message)")
    }
}

func verboseLog(_ text: @autoclosure () -> String) {
    if MinimuxerCommonLogging.isLoggingEnabled {
        let message = text()
        if !message.isEmpty && message.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
            print(message, terminator: "")
        } else {
            print("\(getTag(level: "[V]"))\(message)")
        }
    }
}
