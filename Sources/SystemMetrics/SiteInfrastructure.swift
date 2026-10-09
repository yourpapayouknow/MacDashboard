/// One AdGuardHome DNS rewrite without credentials or other private configuration.
public struct DNSRewrite: Codable, Equatable, Sendable {
    public let domain: String
    public let answer: String
    public let isEnabled: Bool
}

/// Safe operational fields selected from the local AdGuardHome configuration.
public struct AdGuardInfo: Codable, Equatable, Sendable {
    public let isAvailable: Bool
    public let managementURL: String?
    public let bindHosts: [String]
    public let dnsPort: UInt16?
    public let upstreams: [String]
    public let bootstrapServers: [String]
    public let isTLSEnabled: Bool?
    public let isDHCPEnabled: Bool?
    public let dhcpInterface: String?
    public let rewrites: [DNSRewrite]
}

/// One safe Zoraxy upstream entry.
public struct ProxyOrigin: Codable, Equatable, Sendable {
    public let address: String
    public let requiresTLS: Bool
    public let weight: Int
}

/// One Zoraxy reverse-proxy route read from its JSON configuration.
public struct ProxyRoute: Codable, Equatable, Sendable {
    public let domain: String
    public let aliases: [String]
    public let activeOrigins: [ProxyOrigin]
    public let inactiveOrigins: [ProxyOrigin]
    public let isDisabled: Bool
    public let listeningPorts: [UInt16]
}

/// Public certificate metadata; private-key files are never opened.
public struct PublicCertificate: Codable, Equatable, Sendable {
    public let fileName: String
    public let subject: String?
    public let expiresAt: Date?
}

/// Safe operational fields selected from the local Zoraxy configuration.
public struct ZoraxyInfo: Codable, Equatable, Sendable {
    public let isAvailable: Bool
    public let managementURL: String?
    public let routes: [ProxyRoute]
    public let certificates: [PublicCertificate]
}

/// Read-only DNS and reverse-proxy configuration used by the websites module.
public struct SiteInfrastructure: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let adGuard: AdGuardInfo
    public let zoraxy: ZoraxyInfo
}

/// Reads selected non-secret fields from locally installed website infrastructure.
public struct SiteInfrastructureReader: Sendable {
    private let adGuardPath: String
    private let zoraxyRoot: String

    /// Creates the reader for this Mac's installed AdGuardHome and Zoraxy services.
    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let root = "\(home)/cstmserviceslocal/adguard&zoraxy"
        self.adGuardPath = "\(root)/adguard-home/AdGuardHome.yaml"
        self.zoraxyRoot = "\(root)/conf"
    }

    /// Creates a deterministic reader for fixture-based tests.
    init(adGuardPath: String, zoraxyRoot: String) {
        self.adGuardPath = adGuardPath
        self.zoraxyRoot = zoraxyRoot
    }

    /// Returns one safe snapshot and never reads credential or private-key files.
    public func read() -> SiteInfrastructure {
        SiteInfrastructure(sampledAt: Date(), adGuard: rdag(), zoraxy: rdzrx())
    }

    /// Reads the bounded AdGuardHome fields needed by the websites module.
    private func rdag() -> AdGuardInfo {
        guard let text = try? String(contentsOfFile: adGuardPath, encoding: .utf8) else {
            return AdGuardInfo(
                isAvailable: false, managementURL: nil, bindHosts: [], dnsPort: nil,
                upstreams: [], bootstrapServers: [], isTLSEnabled: nil,
                isDHCPEnabled: nil, dhcpInterface: nil, rewrites: []
            )
        }
        let lines = text.components(separatedBy: .newlines)
        let address = scalar(lines, "http", "address")
        let managementURL = address.flatMap(weburl)
        let rewrites = rwrites(lines)
        return AdGuardInfo(
            isAvailable: true,
            managementURL: managementURL,
            bindHosts: list(lines, "dns", "bind_hosts"),
            dnsPort: scalar(lines, "dns", "port").flatMap(UInt16.init),
            upstreams: list(lines, "dns", "upstream_dns"),
            bootstrapServers: list(lines, "dns", "bootstrap_dns"),
            isTLSEnabled: scalar(lines, "tls", "enabled").flatMap(bool),
            isDHCPEnabled: scalar(lines, "dhcp", "enabled").flatMap(bool),
            dhcpInterface: scalar(lines, "dhcp", "interface_name"),
            rewrites: rewrites
        )
    }

    /// Reads every Zoraxy JSON route and only public PEM certificate metadata.
    private func rdzrx() -> ZoraxyInfo {
        let proxyRoot = "\(zoraxyRoot)/proxy"
        let routeNames = ((try? FileManager.default.contentsOfDirectory(atPath: proxyRoot)) ?? [])
            .filter { $0.hasSuffix(".config") }
        let routes = routeNames.compactMap { rdroute("\(proxyRoot)/\($0)") }.sorted {
            $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending
        }
        let certRoot = "\(zoraxyRoot)/certs"
        let certNames = ((try? FileManager.default.contentsOfDirectory(atPath: certRoot)) ?? [])
            .filter { $0.lowercased().hasSuffix(".pem") }
        let certificates = certNames.compactMap { rdcert("\(certRoot)/\($0)") }.sorted {
            $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending
        }
        let available = FileManager.default.fileExists(atPath: zoraxyRoot)
        return ZoraxyInfo(
            isAvailable: available,
            managementURL: available ? "http://127.0.0.1:3011/" : nil,
            routes: routes,
            certificates: certificates
        )
    }

    /// Decodes one Zoraxy route without accepting unknown private fields into the model.
    private func rdroute(_ path: String) -> ProxyRoute? {
        guard let data = FileManager.default.contents(atPath: path),
              let raw = try? JSONDecoder().decode(RawRoute.self, from: data) else { return nil }
        return ProxyRoute(
            domain: raw.domain,
            aliases: raw.aliases,
            activeOrigins: raw.activeOrigins.map(origin),
            inactiveOrigins: raw.inactiveOrigins.map(origin),
            isDisabled: raw.isDisabled,
            listeningPorts: raw.listeningPorts
        )
    }

    /// Maps one bounded JSON origin into the public response model.
    private func origin(_ raw: RawOrigin) -> ProxyOrigin {
        ProxyOrigin(address: raw.address, requiresTLS: raw.requiresTLS, weight: raw.weight)
    }

    /// Reads an X.509 certificate from a public PEM file while ignoring all key formats.
    private func rdcert(_ path: String) -> PublicCertificate? {
        guard path.lowercased().hasSuffix(".pem"),
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              let der = pemder(text),
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        let values = SecCertificateCopyValues(
            certificate,
            [kSecOIDX509V1ValidityNotAfter] as CFArray,
            nil
        ) as? [CFString: Any]
        let expiry = (values?[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any])?[kSecPropertyKeyValue] as? Date
        return PublicCertificate(
            fileName: URL(fileURLWithPath: path).lastPathComponent,
            subject: SecCertificateCopySubjectSummary(certificate) as String?,
            expiresAt: expiry
        )
    }

    /// Decodes the certificate block and rejects unrelated PEM payloads.
    private func pemder(_ text: String) -> Data? {
        let body = text
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return Data(base64Encoded: body)
    }

    /// Reads one scalar that is directly nested under a top-level YAML section.
    private func scalar(_ lines: [String], _ section: String, _ key: String) -> String? {
        guard let range = sectrange(lines, section) else { return nil }
        let prefix = "  \(key):"
        guard let line = lines[range].first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return clean(String(line.dropFirst(prefix.count)))
    }

    /// Reads one scalar-list that is directly nested under a top-level YAML section.
    private func list(_ lines: [String], _ section: String, _ key: String) -> [String] {
        guard let range = sectrange(lines, section),
              let start = lines[range].firstIndex(where: { $0.hasPrefix("  \(key):") }) else { return [] }
        var values: [String] = []
        for line in lines[lines.index(after: start)..<range.upperBound] {
            if line.hasPrefix("    - ") { values.append(clean(String(line.dropFirst(6)))) }
            else if !line.trimmingCharacters(in: .whitespaces).isEmpty { break }
        }
        return values
    }

    /// Parses only the fixed three-field rewrite records under filtering.rewrites.
    private func rwrites(_ lines: [String]) -> [DNSRewrite] {
        guard let range = sectrange(lines, "filtering"),
              let start = lines[range].firstIndex(where: { $0 == "  rewrites:" }) else { return [] }
        var result: [DNSRewrite] = []
        var domain: String?
        var answer: String?
        var enabled: Bool?
        for line in lines[lines.index(after: start)..<range.upperBound] {
            if line.hasPrefix("    - domain:") {
                if let domain, let answer, let enabled { result.append(DNSRewrite(domain: domain, answer: answer, isEnabled: enabled)) }
                domain = clean(String(line.dropFirst("    - domain:".count)))
                answer = nil
                enabled = nil
            } else if line.hasPrefix("      answer:") {
                answer = clean(String(line.dropFirst("      answer:".count)))
            } else if line.hasPrefix("      enabled:") {
                enabled = bool(clean(String(line.dropFirst("      enabled:".count))))
            } else if !line.hasPrefix("    ") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
        }
        if let domain, let answer, let enabled { result.append(DNSRewrite(domain: domain, answer: answer, isEnabled: enabled)) }
        return result
    }

    /// Locates one top-level YAML section without interpreting unrelated fields.
    private func sectrange(_ lines: [String], _ section: String) -> Range<Array<String>.Index>? {
        guard let start = lines.firstIndex(of: "\(section):") else { return nil }
        let lower = lines.index(after: start)
        let upper = lines[lower...].firstIndex {
            !$0.isEmpty && !$0.first.map({ $0 == " " || $0 == "\t" })!
        } ?? lines.endIndex
        return lower..<upper
    }

    /// Removes YAML quoting and surrounding whitespace from selected scalar values.
    private func clean(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespaces)
        guard clean.count >= 2,
              (clean.hasPrefix("'") && clean.hasSuffix("'") || clean.hasPrefix("\"") && clean.hasSuffix("\"")) else {
            return clean
        }
        return String(clean.dropFirst().dropLast())
    }

    /// Parses strict YAML boolean literals.
    private func bool(_ value: String) -> Bool? {
        if value == "true" { return true }
        if value == "false" { return false }
        return nil
    }

    /// Converts a wildcard listen address into a loopback browser handoff URL.
    private func weburl(_ address: String) -> String? {
        guard let colon = address.lastIndex(of: ":"), UInt16(address[address.index(after: colon)...]) != nil else { return nil }
        let port = address[address.index(after: colon)...]
        var host = String(address[..<colon])
        if ["", "0.0.0.0", "::", "*"].contains(host) { host = "127.0.0.1" }
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        return "http://\(host):\(port)/"
    }
}

/// Bounded Zoraxy origin JSON contract.
private struct RawOrigin: Decodable {
    let address: String
    let requiresTLS: Bool
    let weight: Int

    private enum CodingKeys: String, CodingKey {
        case address = "OriginIpOrDomain"
        case requiresTLS = "RequireTLS"
        case weight = "Weight"
    }
}

/// Bounded Zoraxy route JSON contract.
private struct RawRoute: Decodable {
    let domain: String
    let aliases: [String]
    let activeOrigins: [RawOrigin]
    let inactiveOrigins: [RawOrigin]
    let isDisabled: Bool
    let listeningPorts: [UInt16]

    private enum CodingKeys: String, CodingKey {
        case domain = "RootOrMatchingDomain"
        case aliases = "MatchingDomainAlias"
        case activeOrigins = "ActiveOrigins"
        case inactiveOrigins = "InactiveOrigins"
        case isDisabled = "Disabled"
        case listeningPorts = "ListeningPorts"
    }
}
