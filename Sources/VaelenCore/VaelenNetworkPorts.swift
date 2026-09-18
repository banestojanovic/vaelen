import Foundation

/// Centralized Vaelen network port assignments.
///
/// 8787/8743 are Vaelen's private loopback backend ports: Caddy binds them
/// on 127.0.0.1 only. Standard ports 80/443 are exposed exclusively through
/// the Standard Ports capability (PF rdr), never by binding Caddy directly.
public enum VaelenNetworkPorts {
    /// Private loopback HTTP backend bound by Caddy.
    public static let httpBackend = 8787
    /// Private loopback HTTPS backend bound by Caddy.
    public static let httpsBackend = 8743
    /// Standard HTTP port, served via PF forwarding only.
    public static let standardHTTP = 80
    /// Standard HTTPS port, served via PF forwarding only.
    public static let standardHTTPS = 443
}
