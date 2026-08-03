import XCTest
import MinimuxerDomain

final class HeartbeatTimingTests: XCTestCase {
    func testReceiveTimeoutKeepsMarginBeyondDeviceInterval() {
        XCTAssertEqual(
            HeartbeatTiming.receiveTimeoutSeconds(
                forRequestedInterval: 10
            ),
            15
        )
    }

    func testZeroIntervalUsesOnlyTheReceiveMargin() {
        XCTAssertEqual(
            HeartbeatTiming.receiveTimeoutSeconds(
                forRequestedInterval: 0
            ),
            5
        )
    }

    func testReceiveTimeoutIsBoundedOnOverflow() {
        XCTAssertEqual(
            HeartbeatTiming.receiveTimeoutSeconds(
                forRequestedInterval: UInt64.max
            ),
            HeartbeatTiming.maximumReceiveTimeoutSeconds
        )
    }
}
