/// High-level role of one process that owns local listening sockets.
public enum ServiceKind: String, Codable, Equatable, Sendable {
    case dns
    case reverseProxy
    case web
    case system
    case other
}

/// Evidence used to offer a browser handoff without claiming third-party API control.
public enum ServiceLinkSource: String, Codable, Equatable, Sendable {
    case knownProcess
    case conventionalPort
}

/// launchd domain that owns one configured service definition.
public enum ServiceDefinitionSource: String, Codable, Equatable, Sendable {
    case userAgent
    case systemAgent
    case systemDaemon
}

/// One likely network service found in a launchd property list, running or stopped.
public struct ServiceDefinition: Codable, Equatable, Sendable {
    public let label: String
    public let source: ServiceDefinitionSource
    public let program: String
    public let arguments: [String]
    public let definitionPath: String
    public let isDisabled: Bool
    public let runAtLoad: Bool
    public let expectedPorts: [UInt16]
    public let isActive: Bool
    public let schedule: String?
}

/// One bound TCP or UDP endpoint exposed by a local process.
public struct ServiceListener: Codable, Equatable, Hashable, Sendable {
    public let protocolName: String
    public let address: String
    public let port: UInt16
}

/// One process-level service entry for the BaoTa-style websites module.
public struct LocalService: Codable, Equatable, Sendable {
    public let pid: Int32
    public let process: String
    public let kind: ServiceKind
    public let listeners: [ServiceListener]
    public let managementURL: String?
    public let managementURLSource: ServiceLinkSource?
}

/// Complete inventory derived from the privileged connection snapshot.
public struct SiteInventory: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let hasFullVisibility: Bool
    public let services: [LocalService]
    public let configuredServices: [ServiceDefinition]
}

/// Groups every listening socket and identifies known DNS, proxy, and web services.
public struct SiteDiscovery: Sendable {
    /// Creates the stateless service classifier.
    public init() {}

    /// Converts a connection snapshot into process-level local services.
    public func discover(
        _ snapshot: ConnectionSnapshot,
        definitions: [ServiceDefinition] = []
    ) -> SiteInventory {
        let listeners = snapshot.connections.compactMap(listener)
        let groups = Dictionary(grouping: listeners, by: { $0.connection.pid })
        let services = groups.values.compactMap(service).sorted {
            if rank($0.kind) != rank($1.kind) { return rank($0.kind) < rank($1.kind) }
            return $0.process.localizedCaseInsensitiveCompare($1.process) == .orderedAscending
        }
        return SiteInventory(
            sampledAt: snapshot.sampledAt,
            hasFullVisibility: snapshot.hasFullVisibility,
            services: services,
            configuredServices: definitions.filter { $0.schedule == nil }.map { active($0, services) }.sorted {
                if $0.isActive != $1.isActive { return $0.isActive && !$1.isActive }
                return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
        )
    }

    /// Marks configured services active when their label, program, or known identity matches a listener owner.
    private func active(_ definition: ServiceDefinition, _ services: [LocalService]) -> ServiceDefinition {
        let identity = "\(definition.label) \(definition.program)".lowercased()
        let basename = URL(fileURLWithPath: definition.program).lastPathComponent.lowercased()
        let isActive = services.contains { service in
            let process = service.process.lowercased()
            return identity.contains(process) || (!basename.isEmpty && process.contains(basename))
                || (identity.contains("adguard") && process.contains("adguard"))
                || (identity.contains("zoraxy") && process.contains("zoraxy"))
        }
        return ServiceDefinition(
            label: definition.label,
            source: definition.source,
            program: definition.program,
            arguments: definition.arguments,
            definitionPath: definition.definitionPath,
            isDisabled: definition.isDisabled,
            runAtLoad: definition.runAtLoad,
            expectedPorts: definition.expectedPorts,
            isActive: isActive,
            schedule: definition.schedule
        )
    }

    /// Retains TCP listeners and bound UDP sockets with a parseable port.
    private func listener(_ connection: NetworkConnection) -> (connection: NetworkConnection, listener: ServiceListener)? {
        let isTCP = connection.protocolName == "tcp" && connection.state == "LISTEN"
        let isUDP = connection.protocolName == "udp" && connection.remoteEndpoint == nil
        guard isTCP || isUDP, let endpoint = endpoint(connection.localEndpoint) else { return nil }
        return (connection, ServiceListener(
            protocolName: connection.protocolName,
            address: endpoint.address,
            port: endpoint.port
        ))
    }

    /// Builds one de-duplicated process-level service entry.
    private func service(_ rows: [(connection: NetworkConnection, listener: ServiceListener)]) -> LocalService? {
        guard let first = rows.first else { return nil }
        let mapped: [ServiceListener] = rows.map { $0.listener }
        let unique = Array(Set(mapped))
        let listeners = unique.sorted {
            $0.port == $1.port ? $0.protocolName < $1.protocolName : $0.port < $1.port
        }
        let kind = kind(first.connection.process, listeners)
        let url = mgmturl(first.connection.process, kind, listeners)
        return LocalService(
            pid: first.connection.pid,
            process: first.connection.process,
            kind: kind,
            listeners: listeners,
            managementURL: url,
            managementURLSource: url == nil ? nil : (known(first.connection.process) ? .knownProcess : .conventionalPort)
        )
    }

    /// Splits wildcard, IPv4, and bracketed IPv6 endpoint strings.
    private func endpoint(_ text: String) -> (address: String, port: UInt16)? {
        guard let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]) else { return nil }
        var address = String(text[..<colon])
        if address.hasPrefix("[") && address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
        return (address, port)
    }

    /// Classifies known infrastructure first and uses port evidence for generic web services.
    private func kind(_ process: String, _ listeners: [ServiceListener]) -> ServiceKind {
        let name = process.lowercased()
        if name.contains("adguard") || name == "named" || name.contains("dnsmasq") { return .dns }
        if ["zoraxy", "nginx", "caddy", "traefik", "haproxy", "httpd"].contains(where: name.contains) { return .reverseProxy }
        if listeners.contains(where: { Self.webPorts.contains($0.port) }) { return .web }
        if ["launchd", "mdnsresponder", "remotepairingd"].contains(name) { return .system }
        return .other
    }

    /// Chooses only known or strongly conventional browser management endpoints.
    private func mgmturl(_ process: String, _ kind: ServiceKind, _ listeners: [ServiceListener]) -> String? {
        let name = process.lowercased()
        let tcp = listeners.filter { $0.protocolName == "tcp" }
        let candidate: ServiceListener?
        if name.contains("adguard") {
            candidate = tcp.filter { $0.port != 53 }.min { $0.port < $1.port }
        } else if name.contains("zoraxy") {
            candidate = tcp.filter { ![80, 443].contains($0.port) }.min { $0.port < $1.port }
        } else if kind == .web || kind == .reverseProxy {
            candidate = tcp.filter { Self.webPorts.contains($0.port) }.min { $0.port < $1.port }
        } else {
            candidate = nil
        }
        guard let candidate else { return nil }
        let scheme = [443, 8443].contains(candidate.port) ? "https" : "http"
        let host = ["*", "0.0.0.0", "::"].contains(candidate.address) ? "127.0.0.1" : candidate.address
        let encodedHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(encodedHost):\(candidate.port)/"
    }

    /// Marks management links whose process-specific convention is known.
    private func known(_ process: String) -> Bool {
        let name = process.lowercased()
        return name.contains("adguard") || name.contains("zoraxy")
    }

    /// Orders user-facing infrastructure before generic and system services.
    private func rank(_ kind: ServiceKind) -> Int {
        switch kind {
        case .dns: 0
        case .reverseProxy: 1
        case .web: 2
        case .other: 3
        case .system: 4
        }
    }

    private static let webPorts: Set<UInt16> = [80, 443, 3000, 3010, 3011, 5000, 5173, 8000, 8080, 8443, 8787]
}

/// Reads likely network-service definitions from the standard launchd domains.
public struct LaunchServiceReader: Sendable {
    private let roots: [(String, ServiceDefinitionSource)]

    /// Creates the stateless launchd definition reader.
    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.roots = [
            ("\(home)/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .systemAgent),
            ("/Library/LaunchDaemons", .systemDaemon),
        ]
    }

    /// Creates a reader over deterministic launchd roots for testing.
    init(roots: [(String, ServiceDefinitionSource)]) {
        self.roots = roots
    }

    /// Returns configured network services even when they currently own no listener.
    public func rdservices() -> [ServiceDefinition] {
        rdall().filter { definition in
            let evidence = ([definition.label, definition.program] + definition.arguments)
                .joined(separator: " ").lowercased()
            return candidate(evidence)
        }
    }

    /// Returns every third-party launchd definition from user and system domains.
    public func rdall() -> [ServiceDefinition] {
        roots.flatMap { root, source in
            let paths = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            return paths.filter { $0.hasSuffix(".plist") }.compactMap {
                readplist("\(root)/\($0)", source)
            }
        }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Parses one launchd plist and keeps only likely network-facing services.
    private func readplist(_ path: String, _ source: ServiceDefinitionSource) -> ServiceDefinition? {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String else { return nil }
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let program = plist["Program"] as? String ?? arguments.first ?? ""
        let evidence = ([label, program] + arguments).joined(separator: " ").lowercased()
        let schedule = AdminReader.plsched(plist)
        return ServiceDefinition(
            label: label,
            source: source,
            program: program,
            arguments: arguments,
            definitionPath: path,
            isDisabled: plist["Disabled"] as? Bool ?? false,
            runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
            expectedPorts: ports(evidence),
            isActive: false,
            schedule: schedule.isEmpty ? nil : schedule
        )
    }

    /// Uses bounded service-oriented terms to avoid treating every background helper as a website.
    private func candidate(_ evidence: String) -> Bool {
        Self.serviceTerms.contains(where: evidence.contains) || !ports(evidence).isEmpty
    }

    /// Extracts explicit 2-5 digit ports from port, listen, and address arguments.
    private func ports(_ evidence: String) -> [UInt16] {
        guard let regex = try? NSRegularExpression(
            pattern: "(?::([0-9]{2,5})(?![0-9.]))|(?:(?:^|\\s)--?(?:port|listen)[^0-9:.]{0,8}([0-9]{2,5})(?![0-9.]))",
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(evidence.startIndex..<evidence.endIndex, in: evidence)
        return Array(Set(regex.matches(in: evidence, range: range).compactMap { match in
            let group = match.range(at: 1).location == NSNotFound ? 2 : 1
            guard let valueRange = Range(match.range(at: group), in: evidence) else { return nil }
            return UInt16(evidence[valueRange])
        })).sorted()
    }

    private static let serviceTerms = [
        "adguard", "zoraxy", "nginx", "caddy", "proxy", "server", "gateway", "netdata",
        "openlist", "chatgpt2api", "freellmapi", "http", "dns", "web", "api",
    ]
}
