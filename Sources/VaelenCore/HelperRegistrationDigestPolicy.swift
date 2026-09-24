/// Decision for the app's existing SMAppService helper refresh path.
/// This is a pure comparison of the packaged manifest to the app's recorded
/// digests; it stores no registration state and performs no ServiceManagement
/// operations itself.
public enum HelperRegistrationDigestResolution: Equatable, Sendable {
    case useCurrentRegistration
    case approvalRequired
    case reconcile
}

public enum HelperRegistrationDigestPolicy {
    public static func resolve(
        serviceEnabled: Bool,
        serviceRequiresApproval: Bool,
        packagedDigest: String,
        registeredDigest: String?,
        pendingDigest: String?
    ) -> HelperRegistrationDigestResolution {
        let digestMatches = registeredDigest == packagedDigest || pendingDigest == packagedDigest
        if serviceEnabled && digestMatches { return .useCurrentRegistration }
        if serviceRequiresApproval && digestMatches { return .approvalRequired }
        return .reconcile
    }
}
