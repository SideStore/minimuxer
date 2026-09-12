import XCTest
@testable import Minimuxer

final class DeviceConnectionManagerTests: XCTestCase {
    func testIPv4UtunIsEligible() throws {
        let tunnel = try makeTunnel(name: "utun1", ipv4: ["100.64.0.1"])

        XCTAssertTrue(DeviceConnectionManager.isEligibleLocalVPNTunnel(tunnel))
    }

    func testDualStackUtunIsEligible() throws {
        let tunnel = try makeTunnel(
            name: "utun2",
            ipv4: ["100.64.0.2"],
            ipv6: ["fd7a:115c:a1e0::2"]
        )

        XCTAssertTrue(DeviceConnectionManager.isEligibleLocalVPNTunnel(tunnel))
    }

    func testIPv6OnlyUtunIsEligible() throws {
        let tunnel = try makeTunnel(name: "utun3", ipv6: ["fd7a:115c:a1e0::3"])

        XCTAssertTrue(DeviceConnectionManager.isEligibleLocalVPNTunnel(tunnel))
        XCTAssertEqual(DeviceConnectionManager.preferredInterfaceAddress(for: tunnel).ip, "fd7a:115c:a1e0::3")
        XCTAssertNil(DeviceConnectionManager.preferredInterfaceAddress(for: tunnel).mask)
    }

    func testDualStackCandidateOrderingPrefersIPv4() throws {
        let tunnel = try makeTunnel(
            name: "utun4",
            ipv4: ["100.64.0.4"],
            ipv6: ["fd7a:115c:a1e0::4"],
            destinationIPv4: "10.7.0.1",
            destinationIPv6: "fd7a:115c:a1e0::5"
        )

        let candidates = DeviceConnectionManager.resolveCandidatePeers(for: tunnel)

        XCTAssertEqual(candidates.map(\.ip), ["10.7.0.1", "fd7a:115c:a1e0::5"])
    }

    func testIPv6SelfAddressIsNotACandidate() throws {
        let tunnel = try makeTunnel(
            name: "utun5",
            ipv6: ["fd7a:115c:a1e0::5"],
            destinationIPv6: "fd7a:115c:a1e0::5"
        )

        XCTAssertTrue(DeviceConnectionManager.resolveCandidatePeers(for: tunnel).isEmpty)
    }

    func testIPSecTunnelIsNotEligible() throws {
        let tunnel = try makeTunnel(name: "ipsec0", ipv4: ["10.7.0.2"])

        XCTAssertFalse(DeviceConnectionManager.isEligibleLocalVPNTunnel(tunnel))
    }

    private func makeTunnel(
        name: String,
        ipv4: [String] = [],
        ipv6: [String] = [],
        destinationIPv4: String? = nil,
        destinationIPv6: String? = nil
    ) throws -> TunnelNetInfo {
        let addresses = IPAddresses(
            v4: ipv4.map {
                IPv4Info(
                    host: $0,
                    mask: "255.255.255.255",
                    hostRaw: 0,
                    maskRaw: UInt32.max
                )
            },
            v6: ipv6
        )

        let destination = IP(v4: destinationIPv4.map { makeIPv4Info(host: $0) }, v6: destinationIPv6)
        return try TunnelNetInfo(
            name: name,
            interfaceIndex: 0,
            interfaceAddresses: addresses,
            linkLayerDestinationIP: destination,
            routes: RouteSnapshot.captureRoutes()
        )
    }

    private func makeIPv4Info(host: String) -> IPv4Info {
        IPv4Info(host: host, mask: "255.255.255.255", hostRaw: 0, maskRaw: UInt32.max)
    }
}
