import Foundation

/// Small, truthful control model for networking capabilities in the menu-bar
/// Services view. Inputs are Core-observed ownership and persisted user
/// intent; UI code does not infer authority from system files.
public enum ServiceControlAction: String, Equatable, Sendable {
    case enable
    case retry
    case stop
    case disable
}

public struct ServiceControlPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String?
    public let action: ServiceControlAction?
    public let canDisable: Bool

    public init(title: String, detail: String? = nil, action: ServiceControlAction? = nil, canDisable: Bool = false) {
        self.title = title
        self.detail = detail
        self.action = action
        self.canDisable = canDisable
    }

    public static func dns(status: DNSStatus, savedOn: Bool?, blockedReason: String? = nil) -> Self {
        guard let savedOn else {
            return .init(title: "State unavailable", detail: "Vaelen could not read the saved DNS choice.")
        }
        let owned = status.ownership == .vaelen
        let running = owned && status.responderState == .ownedRunning && status.health == "healthy"

        if !savedOn {
            if status.state == .unavailable && status.health == "privilege-unavailable" {
                return .init(
                    title: "Needs attention",
                    detail: "Enable DNS to register Vaelen’s helper. macOS may require approval in System Settings.",
                    action: .enable
                )
            }
            if status.ownership == .external {
                if status.state == .notInstalled {
                    return .init(title: "Off · External DNS", detail: "External /etc/resolver/test; Vaelen preserves and restores it exactly.", action: .enable)
                }
                return .init(title: "Off · External DNS", detail: status.conflict ?? "External /etc/resolver/test; Vaelen leaves it unchanged.")
            }
            if status.ownership == .unknown {
                return .init(title: "Off", detail: status.conflict ?? "DNS ownership is uncertain; resolver state was left unchanged.")
            }
            if running {
                return .init(title: "Running · saved off", detail: "Vaelen owns the active responder; Stop releases it.", action: .stop, canDisable: true)
            }
            if owned {
                return .init(title: "Needs attention", detail: status.conflict ?? status.health, action: .disable, canDisable: true)
            }
            if status.state == .unavailable {
                return .init(title: "Off", detail: status.conflict ?? "Resolver state could not be inspected.")
            }
            return .init(title: "Off", action: status.state == .notInstalled ? .enable : nil)
        }

        if running {
            return .init(title: "On", action: .stop, canDisable: true)
        }
        let reason = blockedReason ?? status.conflict ?? status.health
        return .init(title: "Needs attention", detail: reason, action: .retry, canDisable: owned)
    }

    /// Reconcile a failed Start reply only against a fresh authoritative Core
    /// snapshot. Genuine failures remain visible; an achieved owned/healthy
    /// desired state wins over a stale operation error.
    public static func dnsStartFailure(_ message: String, authoritativeStatus: DNSStatus?) -> String? {
        guard let status = authoritativeStatus,
              status.state == .installed,
              status.ownership == .vaelen,
              status.responderState == .ownedRunning,
              status.health == "healthy" else { return message }
        return nil
    }

    public static func standardPorts(status: StandardPortsStatus, savedOn: Bool?, blockedReason: String? = nil) -> Self {
        guard let savedOn else {
            return .init(title: "State unavailable", detail: "Vaelen could not read the saved Standard Ports choice.")
        }
        let owned = status.ownership == .vaelen

        if !savedOn {
            if status.ownership == .external {
                if status.state == .installed || status.state == .unhealthy {
                    return .init(title: "Off · Existing PF configuration", detail: "Exact compatible PF configuration pre-exists; Enable uses it without claiming or removing those files.", action: .enable)
                }
                return .init(title: "Off · External PF", detail: "Legacy PF rules have no Vaelen ownership record; left unchanged.")
            }
            if status.ownership == .unknown {
                return .init(title: "Off", detail: status.detail ?? "PF ownership is uncertain; existing rules were left unchanged.")
            }
            if owned {
                let isActive = status.state == .healthy || status.state == .installed || status.state == .unhealthy
                return .init(title: isActive ? "Enabled · saved off" : "Needs attention", detail: status.detail ?? status.conflict, action: isActive ? .disable : nil, canDisable: isActive)
            }
            if status.state == .absent { return .init(title: "Off", action: .enable) }
            return .init(title: "Off", detail: status.conflict ?? status.detail)
        }

        guard owned else {
            let unownedReason = status.ownership == .external
                ? "Existing PF integration has no active Vaelen ownership record; existing rules were left unchanged."
                : (status.detail ?? "No active Vaelen ownership record; existing PF state was left unchanged.")
            let reason = blockedReason ?? status.conflict ?? unownedReason
            return .init(title: "Needs attention", detail: reason, action: .retry)
        }
        switch status.state {
        case .healthy: return .init(title: "Enabled", action: .disable, canDisable: true)
        case .installed: return .init(title: "Installed", detail: status.detail, action: .disable, canDisable: true)
        default: return .init(title: "Needs attention", detail: blockedReason ?? status.detail ?? status.conflict, action: .retry, canDisable: true)
        }
    }
}
