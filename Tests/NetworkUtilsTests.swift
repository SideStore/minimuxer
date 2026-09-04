import Network
import XCTest
import MinimuxerCommon

@testable import Minimuxer

final class NetworkUtilsTests: XCTestCase {
    func testDeviceConnectionAcceptsExplicitTimeout() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "TCP listener is ready")

        listener.newConnectionHandler = { $0.cancel() }
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.fulfill()
            }
        }
        listener.start(queue: DispatchQueue(label: "NetworkUtilsTests.listener"))
        defer { listener.cancel() }

        await fulfillment(of: [ready], timeout: 2)
        let port = try XCTUnwrap(listener.port?.rawValue)

        XCTAssertTrue(
            NetworkUtils.testDeviceConnection(
                ifaddr: "127.0.0.1",
                port: port,
                timeoutMs: 1_000
            )
        )
    }

    func testConnectionBindingKeepsDefaultProbeTimeout() {
        let binding = ConnectionConfigBinding(
            setTunnelIfaceIp: { _ in },
            setTunnelPeerIp: { _ in },
            setTunnelPeerSubnetMask: { _ in },
            setTunnelPeerReachable: { _ in },
            setTunnelIfaceSubnetMask: { _ in },
            getRemoteServerIp: { "" },
            setRemoteReachable: { _ in },
            getOverrideTunnelPeerIp: { "" },
            setOverrideTunnelPeerReachable: { _ in },
            getConnectionMode: { .notConfigured }
        )

        XCTAssertEqual(binding.getTCPProbeTimeoutMs(), MinimuxerConstants.defaultTCPProbeTimeoutMs)
    }

    func testConnectionBindingAcceptsCustomProbeTimeout() {
        let binding = ConnectionConfigBinding(
            setTunnelIfaceIp: { _ in },
            setTunnelPeerIp: { _ in },
            setTunnelPeerSubnetMask: { _ in },
            setTunnelPeerReachable: { _ in },
            setTunnelIfaceSubnetMask: { _ in },
            getRemoteServerIp: { "" },
            setRemoteReachable: { _ in },
            getOverrideTunnelPeerIp: { "" },
            setOverrideTunnelPeerReachable: { _ in },
            getConnectionMode: { .notConfigured },
            getTCPProbeTimeoutMs: { 1_000 }
        )

        XCTAssertEqual(binding.getTCPProbeTimeoutMs(), 1_000)
    }
}
