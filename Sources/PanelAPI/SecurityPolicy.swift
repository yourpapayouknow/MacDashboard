import Hummingbird
import NIOCore
import SystemMetrics
import PanelConfig

/// Request context carrying the peer address needed by the audit trail.
public struct PanelRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    public let remoteAddress: String?

    /// Captures the peer IP without retaining the channel.
    public init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
        switch source.channel.remoteAddress {
        case .v4(let address): self.remoteAddress = String(describing: address.host)
        case .v6(let address): self.remoteAddress = String(describing: address.host)
        default: self.remoteAddress = nil
        }
    }
}

/// Enforces loopback Host and same-origin mutation rules for the no-login panel.
public struct RequestPolicy: Sendable {
    private let allowedHosts: Set<String>
    private let trustedPeers: Bool

    /// Creates the current loopback-only policy.
    public init(allowedHosts: Set<String> = ["127.0.0.1", "localhost", "::1"], trustedPeers: Bool = false) {
        self.allowedHosts = Set(allowedHosts.compactMap { Self.normhost($0.lowercased()) })
        self.trustedPeers = trustedPeers
    }

    // 只信任实际连接的私有地址，不读取代理转发头。
    public func peererr(_ address: String?) -> String? {
        guard trustedPeers else { return nil }
        return address.map(prvtaddr) == true ? nil : "Peer address is not trusted"
    }

    /// Returns a rejection reason when Host is missing or outside the allowlist.
    public func hosterr(_ host: String?) -> String? {
        guard let normalized = host.flatMap(Self.hostpart), allowedHosts.contains(normalized) else {
            return "Host is not allowed"
        }
        return nil
    }

    /// Returns a rejection reason for unsafe mutation content or cross-origin requests.
    public func writeerr(host: String?, origin: String?, contentType: String?) -> String? {
        if let error = hosterr(host) { return error }
        guard contentType?.lowercased().hasPrefix("application/json") == true else {
            return "Mutations require application/json"
        }
        guard let origin, !origin.isEmpty else { return nil }
        guard let originURL = URL(string: origin),
              originURL.scheme?.lowercased() == "http",
              originURL.user == nil,
              originURL.password == nil,
              originURL.query == nil,
              originURL.fragment == nil,
              originURL.path.isEmpty,
              let rawOriginHost = originURL.host?.lowercased(),
              let originHost = Self.normhost(rawOriginHost),
              let authority = host.flatMap(Self.authority),
              let requestHost = Self.normhost(authority.host),
              originHost == requestHost,
              originURL.port == authority.port,
              allowedHosts.contains(originHost) else {
            return "Origin does not match Host"
        }
        return nil
    }

    /// Extracts a lowercase host while discarding a valid optional port.
    private static func hostpart(_ value: String) -> String? {
        authority(value).flatMap { normhost($0.host) }
    }

    /// Parses one HTTP authority into its host and optional port.
    private static func authority(_ value: String) -> (host: String, port: Int?)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: "http://\(trimmed)"),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty,
              let host = components.host?.lowercased() else { return nil }
        return (host, components.port)
    }

    /// Normalizes bracketed IPv6 host text.
    private static func normhost(_ host: String) -> String? {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return normalized.isEmpty ? nil : nrmaddr(normalized) ?? normalized
    }
}

/// Rejects disallowed Host headers before any route performs work.
struct HostGuard: RouterMiddleware {
    typealias Context = PanelRequestContext
    let policy: RequestPolicy
    let audit: AuditStore?

    /// Validates Host and audits rejected requests.
    func handle(
        _ request: Request,
        context: PanelRequestContext,
        next: (Request, PanelRequestContext) async throws -> Response
    ) async throws -> Response {
        let host = request.head.authority
        if let reason = policy.peererr(context.remoteAddress) ?? policy.hosterr(host) {
            try? await audit?.record(AuditEntry(
                sourceAddress: context.remoteAddress,
                host: host,
                origin: request.headers[.origin],
                operation: "request.reject",
                target: request.uri.path,
                succeeded: false,
                message: reason
            ))
            throw HTTPError(.forbidden, message: reason)
        }
        return try await next(request, context)
    }
}
