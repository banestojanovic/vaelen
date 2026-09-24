/// Keeps app-owned helper package reconciliation ahead of a new Core process.
/// Returning false means macOS still requires approval; the caller must not
/// start Core because startup restoration could invoke the helper.
public enum CoreStartupHelperGate {
    @MainActor
    @discardableResult
    public static func run(
        reconcileHelper: () async throws -> Bool,
        startCore: () throws -> Void
    ) async throws -> Bool {
        guard try await reconcileHelper() else { return false }
        try startCore()
        return true
    }
}
