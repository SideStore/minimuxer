//
//  HeartbeatTiming.swift
//  MinimuxerDomain
//
//  Copyright © 2026 SideStore. All rights reserved.
//

public enum HeartbeatTiming {
    public static let initialReceiveTimeoutSeconds: UInt64 = 15
    public static let receiveTimeoutMarginSeconds: UInt64 = 5
    public static let maximumReceiveTimeoutSeconds: UInt64 = 60

    public static func receiveTimeoutSeconds(
        forRequestedInterval requestedInterval: UInt64
    ) -> UInt64 {
        let (timeout, overflow) = requestedInterval.addingReportingOverflow(
            receiveTimeoutMarginSeconds
        )
        return overflow
            ? maximumReceiveTimeoutSeconds
            : min(timeout, maximumReceiveTimeoutSeconds)
    }
}
