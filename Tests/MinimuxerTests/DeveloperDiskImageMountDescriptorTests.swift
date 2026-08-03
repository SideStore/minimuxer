import XCTest
@testable import MinimuxerDomain

final class DeveloperDiskImageMountDescriptorTests: XCTestCase {
    func testRecognizesLegacyDeveloperDiskImage() {
        let descriptor = DeveloperDiskImageMountDescriptor(
            mountPath: "/Developer",
            personalizedImageType: nil,
            diskImageType: "Developer",
            isMounted: true
        )

        XCTAssertTrue(descriptor.representsMountedDeveloperImage)
    }

    func testRecognizesPersonalizedDeveloperDiskImage() {
        let descriptor = DeveloperDiskImageMountDescriptor(
            mountPath: "/System/Developer",
            personalizedImageType: "DeveloperDiskImage",
            diskImageType: "Personalized",
            isMounted: true
        )

        XCTAssertTrue(descriptor.representsMountedDeveloperImage)
    }

    func testRejectsExplicitlyUnmountedDeveloperDiskImage() {
        let descriptor = DeveloperDiskImageMountDescriptor(
            mountPath: "/Developer",
            personalizedImageType: nil,
            diskImageType: "Developer",
            isMounted: false
        )

        XCTAssertFalse(descriptor.representsMountedDeveloperImage)
    }

    func testRejectsUnrelatedDiskImage() {
        let descriptor = DeveloperDiskImageMountDescriptor(
            mountPath: "/Developer",
            personalizedImageType: nil,
            diskImageType: "Cryptex",
            isMounted: true
        )

        XCTAssertFalse(descriptor.representsMountedDeveloperImage)
    }
}
