public struct DeveloperDiskImageMountDescriptor: Equatable, Sendable {
    public let mountPath: String?
    public let personalizedImageType: String?
    public let diskImageType: String?
    public let isMounted: Bool?

    public init(
        mountPath: String?,
        personalizedImageType: String?,
        diskImageType: String?,
        isMounted: Bool?
    ) {
        self.mountPath = mountPath
        self.personalizedImageType = personalizedImageType
        self.diskImageType = diskImageType
        self.isMounted = isMounted
    }

    public var representsMountedDeveloperImage: Bool {
        guard isMounted != false else { return false }

        let isLegacyDeveloperImage =
            mountPath == "/Developer" &&
            diskImageType == "Developer"

        let isPersonalizedDeveloperImage =
            mountPath == "/System/Developer" &&
            (personalizedImageType == "DeveloperDiskImage" || personalizedImageType == "Developer") &&
            (diskImageType == nil || diskImageType == "Personalized")

        return isLegacyDeveloperImage || isPersonalizedDeveloperImage
    }
}
