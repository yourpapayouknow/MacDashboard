/// One locally installed or containerized database engine.
public struct DatabaseEntry: Codable, Equatable, Sendable {
    public let id: String
    public let engine: String
    public let source: String
    public let version: String?
    public let state: String
}

/// Public certificate identity without private-key material.
public struct CertificateEntry: Codable, Equatable, Sendable {
    public let sha256: String
    public let label: String
    public let keychain: String
}

// 区分非法指纹、未找到与系统钥匙串不可读。
public enum CertificateReadError: Error, Equatable, Sendable {
    case invalid, notFound, unavailable
}

/// One cron or launchd scheduled task.
public struct ScheduleEntry: Codable, Equatable, Sendable {
    public let id: String
    public let manager: String
    public let schedule: String
    public let definitionPath: String?
    public let source: ServiceDefinitionSource?
}

/// One fixed file-management root exposed by the panel.
public struct FileRoot: Codable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let isAvailable: Bool
    public let isWritable: Bool
}

/// macOS Application Firewall state.
public struct FirewallInfo: Codable, Equatable, Sendable {
    public let isAvailable: Bool
    public let isEnabled: Bool?
    public let stealthMode: Bool?
}

/// One non-system local account or group.
public struct DirectoryEntry: Codable, Equatable, Sendable {
    public let name: String
    public let numericID: UInt32
}

/// Complete administrative inventory excluding secrets and arbitrary file contents.
public struct AdminInventory: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let databases: [DatabaseEntry]
    public let certificates: [CertificateEntry]
    public let schedules: [ScheduleEntry]
    public let fileRoots: [FileRoot]
    public let firewall: FirewallInfo
    public let users: [DirectoryEntry]
    public let groups: [DirectoryEntry]
}

/// Reads fixed native administrative sources without elevation or shell dispatch.
public struct AdminReader: Sendable {
    /// Creates the stateless administrative reader.
    public init() {}

    // 仅从固定系统钥匙串导出指纹匹配的公开证书。
    public func rdcrt(_ hash: String) throws -> Data {
        guard Self.crtref(hash) else { throw CertificateReadError.invalid }
        var keychain: SecKeychain?
        guard SecKeychainOpen("/Library/Keychains/System.keychain", &keychain) == errSecSuccess,
              let keychain else { throw CertificateReadError.unavailable }
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate, kSecMatchSearchList: [keychain],
            kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw CertificateReadError.notFound }
        guard status == errSecSuccess, let certificates = result as? [SecCertificate], certificates.count <= 1024 else {
            throw CertificateReadError.unavailable
        }
        return try Self.crtdata(hash, certificates.map { SecCertificateCopyData($0) as Data })
    }

    // 指纹只接受64位十六进制，不接受路径或其他钥匙串参数。
    static func crtref(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    // 核对有界DER证书及其真实SHA256，拒绝其他数据格式。
    static func crtdata(_ hash: String, _ certificates: [Data]) throws -> Data {
        guard crtref(hash) else { throw CertificateReadError.invalid }
        guard certificates.count <= 1024 else { throw CertificateReadError.unavailable }
        for data in certificates where !data.isEmpty && data.count <= 65_536 {
            guard SecCertificateCreateWithData(nil, data as CFData) != nil else { continue }
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
            if fingerprint == hash.uppercased() { return data }
        }
        throw CertificateReadError.notFound
    }

    /// Returns all supported administrative domains in one snapshot.
    public func read() -> AdminInventory {
        let containers = ContainerReader().read().containers
        let environment = EnvironmentReader().read()
        return AdminInventory(
            sampledAt: Date(),
            databases: rddb(environment.formulae, containers),
            certificates: run("/usr/bin/security", ["find-certificate", "-a", "-Z", "/Library/Keychains/System.keychain"])
                .map(Self.prtcert) ?? [],
            schedules: rdsched(),
            fileRoots: rdfiles(),
            firewall: rdfw(),
            users: run("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"]).map(Self.prtdir) ?? [],
            groups: run("/usr/bin/dscl", [".", "-list", "/Groups", "PrimaryGroupID"]).map(Self.prtdir) ?? []
        )
    }

    /// Detects supported database engines from package and container identities.
    private func rddb(_ formulae: [BrewFormula], _ containers: [DockerContainer]) -> [DatabaseEntry] {
        let engines = ["postgres", "mysql", "mariadb", "redis", "mongodb", "clickhouse", "influxdb", "couchdb", "sqlite"]
        var entries = formulae.compactMap { formula -> DatabaseEntry? in
            guard let engine = engines.first(where: { formula.id.lowercased().contains($0) }) else { return nil }
            return DatabaseEntry(
                id: "homebrew:\(formula.id)", engine: engine, source: "homebrew",
                version: formula.versions.last, state: "installed"
            )
        }
        entries += containers.compactMap { container -> DatabaseEntry? in
            let identity = "\(container.name) \(container.image)".lowercased()
            guard let engine = engines.first(where: { identity.contains($0) }) else { return nil }
            return DatabaseEntry(
                id: "docker:\(container.id)", engine: engine, source: "docker",
                version: container.image.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init),
                state: container.state
            )
        }
        return entries.sorted { $0.id < $1.id }
    }

    /// Reads cron plus launchd definitions containing native scheduling keys.
    private func rdsched() -> [ScheduleEntry] {
        var entries: [ScheduleEntry] = []
        if let cron = run("/usr/bin/crontab", ["-l"]) { entries += Self.prtcron(cron) }
        entries += LaunchServiceReader().rdall().compactMap { definition in
            guard let schedule = definition.schedule else { return nil }
            return ScheduleEntry(id: definition.label, manager: "launchd", schedule: schedule,
                definitionPath: definition.definitionPath, source: definition.source)
        }
        return entries.sorted { $0.id < $1.id }
    }

    /// Returns the fixed roots eligible for later bounded file operations.
    public func rdfiles() -> [FileRoot] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [home, "\(home)/cstmserviceslocal", "\(home)/Documents", "/opt/homebrew"]
        return paths.enumerated().map { index, path in
            FileRoot(
                id: "root-\(index)", path: path,
                isAvailable: FileManager.default.fileExists(atPath: path),
                isWritable: FileManager.default.isWritableFile(atPath: path)
            )
        }
    }

    /// Reads native Application Firewall global and stealth state.
    private func rdfw() -> FirewallInfo {
        let path = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return FirewallInfo(isAvailable: false, isEnabled: nil, stealthMode: nil)
        }
        let global = run(path, ["--getglobalstate"]).flatMap(Self.prtbool)
        let stealth = run(path, ["--getstealthmode"]).flatMap(Self.prtbool)
        return FirewallInfo(isAvailable: true, isEnabled: global, stealthMode: stealth)
    }

    /// Parses certificate hashes, labels, and keychain paths from Security output.
    static func prtcert(_ text: String) -> [CertificateEntry] {
        var hash: String?
        var keychain = ""
        var label = ""
        var entries: [CertificateEntry] = []
        func emit() {
            if let hash, !label.isEmpty { entries.append(CertificateEntry(sha256: hash, label: label, keychain: keychain)) }
        }
        for raw in text.split(separator: "\n").map(String.init) {
            if raw.hasPrefix("SHA-256 hash: ") { emit(); hash = String(raw.dropFirst(14)); label = ""; keychain = "" }
            else if raw.hasPrefix("keychain: \"") { keychain = raw.replacingOccurrences(of: "keychain: \"", with: "").dropLast().description }
            else if raw.contains("\"labl\"<blob>=\"") {
                label = raw.components(separatedBy: "\"labl\"<blob>=\"").last?.dropLast().description ?? ""
            }
        }
        emit()
        return entries
    }

    /// Parses only interactive local accounts and groups with IDs 500 or greater.
    static func prtdir(_ text: String) -> [DirectoryEntry] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let id = UInt32(fields[1]), id >= 500 else { return nil }
            return DirectoryEntry(name: String(fields[0]), numericID: id)
        }
    }

    /// Reads cron triggers without publishing commands or environment assignments.
    static func prtcron(_ text: String) -> [ScheduleEntry] {
        let macros = ["@reboot", "@yearly", "@annually", "@monthly", "@weekly", "@daily", "@midnight", "@hourly"]
        let allowed = CharacterSet(charactersIn: "0123456789*/,-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let fields = line.split(maxSplits: 5, whereSeparator: \.isWhitespace)
            let schedule: String
            if let first = fields.first, macros.contains(String(first)), fields.count >= 2 {
                schedule = String(first)
            } else {
                guard fields.count == 6,
                      fields.prefix(5).allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
                schedule = fields.prefix(5).joined(separator: " ")
            }
            return ScheduleEntry(
                id: "cron-\(index + 1)", manager: "cron", schedule: schedule, definitionPath: nil, source: nil
            )
        }
    }

    /// Includes every independent launchd trigger without command arguments or watched paths.
    static func plsched(_ plist: [String: Any]) -> String {
        var triggers: [String] = []
        if let seconds = plist["StartInterval"] as? NSNumber,
           CFGetTypeID(seconds) != CFBooleanGetTypeID(), seconds.int64Value > 0,
           seconds.int64Value <= Int32.max, seconds.doubleValue == Double(seconds.int64Value) {
            triggers.append("every \(seconds.int64Value) seconds")
        }
        let calendars = (plist["StartCalendarInterval"] as? [[String: Any]])
            ?? (plist["StartCalendarInterval"] as? [String: Any]).map { [$0] } ?? []
        triggers += calendars.compactMap(clndrsch)
        if let paths = plist["WatchPaths"] as? [String], !paths.isEmpty { triggers.append("watch paths") }
        if let paths = plist["QueueDirectories"] as? [String], !paths.isEmpty { triggers.append("queue directories") }
        if plist["StartOnMount"] as? Bool == true { triggers.append("mount") }
        return triggers.joined(separator: "; ")
    }

    /// Formats calendar integers in minute, hour, day, month, weekday order.
    private static func clndrsch(_ calendar: [String: Any]) -> String? {
        let fields: [(String, ClosedRange<Int>)] = [
            ("Minute", 0...59), ("Hour", 0...23), ("Day", 1...31), ("Month", 1...12), ("Weekday", 0...7),
        ]
        var values: [String] = []
        for (key, range) in fields {
            guard let raw = calendar[key] else { values.append("*"); continue }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(number.intValue), range.contains(number.intValue) else { return nil }
            values.append(String(number.intValue))
        }
        return "calendar \(values.joined(separator: " "))"
    }

    /// Parses socketfilterfw's numeric state marker.
    private static func prtbool(_ text: String) -> Bool? {
        let value = text.lowercased()
        if value.contains("state = 1") || value.contains("is on") { return true }
        if value.contains("state = 0") || value.contains("is off") { return false }
        return nil
    }

    /// Runs one exact read-only native command from the administrative allowlist.
    private func run(_ path: String, _ arguments: [String]) -> String? {
        let allowed =
            (path == "/usr/bin/security" && arguments == ["find-certificate", "-a", "-Z", "/Library/Keychains/System.keychain"])
            || (path == "/usr/bin/dscl" && (arguments == [".", "-list", "/Users", "UniqueID"] || arguments == [".", "-list", "/Groups", "PrimaryGroupID"]))
            || (path == "/usr/bin/crontab" && arguments == ["-l"])
            || (path == "/usr/libexec/ApplicationFirewall/socketfilterfw"
                && [["--getglobalstate"], ["--getstealthmode"]].contains(arguments))
        guard allowed else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
