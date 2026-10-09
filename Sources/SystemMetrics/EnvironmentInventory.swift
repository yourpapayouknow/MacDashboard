/// One installed Homebrew formula with bounded operational metadata.
public struct BrewFormula: Codable, Equatable, Sendable {
    public let id: String
    public let tap: String
    public let description: String?
    public let homepage: String?
    public let license: String?
    public let versions: [String]
    public let installedOnRequest: Bool
    public let outdated: Bool
    public let pinned: Bool
    public let deprecated: Bool
    public let disabled: Bool
}

/// One installed Homebrew cask with bounded operational metadata.
public struct BrewCask: Codable, Equatable, Sendable {
    public let id: String
    public let names: [String]
    public let tap: String
    public let description: String?
    public let homepage: String?
    public let currentVersion: String?
    public let installedVersion: String?
    public let pinned: Bool?
    public let outdated: Bool
    public let autoUpdates: Bool?
    public let deprecated: Bool
    public let disabled: Bool
}

/// 仅保留已安装运行时的公开字段。
public struct RuntimeVersion: Codable, Equatable, Sendable {
    public let tool: String
    public let version: String
    public let installPath: String
    public let active: Bool
    public let source: String
}

/// Complete package and runtime manager discovery snapshot.
public struct EnvironmentInventory: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let homebrewAvailable: Bool
    public let homebrewPath: String?
    public let formulae: [BrewFormula]
    public let casks: [BrewCask]
    public let homebrewInventoryAvailable: Bool
    public let installedTaps: [String]
    public let tapInventoryAvailable: Bool
    public let miseAvailable: Bool
    public let misePath: String?
    public let runtimes: [RuntimeVersion]
    public let runtimeInventoryAvailable: Bool
    public let runtimeWarnings: [String]
}

/// Reads documented package-manager state through fixed executables without a shell.
public struct EnvironmentReader: Sendable {
    public let brewPath: String?
    private let misePath: String?
    private let nativeEnabled: Bool

    /// Creates a reader for standard Apple Silicon and Intel installation paths.
    public init() {
        self.nativeEnabled = true
        self.brewPath = Self.find(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
        self.misePath = Self.find([
            "/opt/homebrew/bin/mise", "/usr/local/bin/mise",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/mise").path,
        ])
    }

    /// Creates a deterministic reader for fixture tests.
    init(brewPath: String?, misePath: String?) {
        self.nativeEnabled = false
        self.brewPath = brewPath
        self.misePath = misePath
    }

    /// 读取软件、已安装源与运行时，区分空清单和读取失败。
    public func read() -> EnvironmentInventory {
        let payload = brewPath.flatMap { run($0, ["info", "--json=v2", "--installed"]) }
        let parsed = payload.flatMap(Self.parse)
        let taps = brewPath.flatMap { run($0, ["tap"]) }.flatMap(Self.prstps)
        let runtimes = misePath.flatMap { run($0, ["ls", "--installed", "--json", "--offline"]) }
            .flatMap(Self.prsrntms)
        let native = nativeEnabled ? RuntimeReader().read() : (rows: [], warnings: [])
        return EnvironmentInventory(
            sampledAt: Date(),
            homebrewAvailable: brewPath != nil,
            homebrewPath: brewPath,
            formulae: parsed?.0.sorted { $0.id < $1.id } ?? [],
            casks: parsed?.1.sorted { $0.id < $1.id } ?? [],
            homebrewInventoryAvailable: parsed != nil,
            installedTaps: taps ?? [],
            tapInventoryAvailable: taps != nil,
            miseAvailable: misePath != nil,
            misePath: misePath,
            runtimes: RuntimeReader.uniq((runtimes ?? []) + native.rows),
            runtimeInventoryAvailable: runtimes != nil || nativeEnabled,
            runtimeWarnings: native.warnings + (misePath != nil && runtimes == nil ? ["mise"] : [])
        )
    }

    /// Decodes only the documented installed-package fields used by the panel.
    static func parse(_ text: String) -> ([BrewFormula], [BrewCask])? {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(BrewPayload.self, from: data) else { return nil }
        let formulae = payload.formulae.map { row in
            BrewFormula(
                id: row.fullName,
                tap: row.tap ?? "unknown",
                description: row.description,
                homepage: row.homepage,
                license: row.license,
                versions: row.installed.map(\.version),
                installedOnRequest: row.installed.contains(where: \.installedOnRequest),
                outdated: row.outdated,
                pinned: row.pinned,
                deprecated: row.deprecated,
                disabled: row.disabled
            )
        }
        let casks = payload.casks.map { row in
            BrewCask(
                id: row.fullToken ?? row.token,
                names: row.name,
                tap: row.tap ?? "unknown",
                description: row.description,
                homepage: row.homepage,
                currentVersion: row.version,
                installedVersion: row.installed,
                pinned: row.pinned,
                outdated: row.outdated,
                autoUpdates: row.autoUpdates,
                deprecated: row.deprecated,
                disabled: row.disabled
            )
        }
        return (formulae, casks)
    }

    // 解析无参数brew tap返回的已安装源。
    static func prstps(_ text: String) -> [String]? {
        let rows = text.split(whereSeparator: \.isNewline).map(String.init)
        guard rows.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#,
            options: .regularExpression) != nil }) else { return nil }
        return Array(Set(rows)).sorted()
    }

    // 解析mise已安装版本，忽略配置来源与其他字段。
    static func prsrntms(_ text: String) -> [RuntimeVersion]? {
        guard let data = text.data(using: .utf8),
              let tools = try? JSONDecoder().decode([String: [MiseVersionRow]].self, from: data) else { return nil }
        return tools.flatMap { tool, rows in
            rows.filter(\.installed).map { RuntimeVersion(tool: tool, version: $0.version,
                installPath: $0.installPath, active: $0.active, source: "mise") }
        }.sorted {
            if $0.tool != $1.tool { return $0.tool < $1.tool }
            if $0.version != $1.version { return $0.version < $1.version }
            return $0.installPath < $1.installPath
        }
    }

    /// 仅运行三种固定只读命令，不接收外部参数。
    private func run(_ path: String, _ arguments: [String]) -> String? {
        let isBrew = path == brewPath && [["info", "--json=v2", "--installed"], ["tap"]].contains(arguments)
        let isMise = path == misePath && arguments == ["ls", "--installed", "--json", "--offline"]
        guard isBrew || isMise else { return nil }
        let result = runcmd(path, arguments)
        return result.code == 0 ? result.output : nil
    }

    /// Finds the first executable from fixed supported locations.
    private static func find(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// mise版本JSON的最小字段集合。
private struct MiseVersionRow: Decodable {
    let version: String
    let installPath: String
    let installed: Bool
    let active: Bool

    enum CodingKeys: String, CodingKey {
        case version, installPath = "install_path", installed, active
    }
}

/// Minimal decoding model for Homebrew's installed inventory payload.
private struct BrewPayload: Decodable {
    let formulae: [BrewFormulaRow]
    let casks: [BrewCaskRow]
}

/// Minimal decoding model for one installed formula.
private struct BrewFormulaRow: Decodable {
    let fullName: String
    let tap: String?
    let description: String?
    let homepage: String?
    let license: String?
    let installed: [BrewInstallRow]
    let outdated: Bool
    let pinned: Bool
    let deprecated: Bool
    let disabled: Bool

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name", tap, description = "desc", homepage, license, installed
        case outdated, pinned, deprecated, disabled
    }
}

/// Minimal decoding model for one installed formula version.
private struct BrewInstallRow: Decodable {
    let version: String
    let installedOnRequest: Bool

    enum CodingKeys: String, CodingKey {
        case version
        case installedOnRequest = "installed_on_request"
    }
}

/// Minimal decoding model for one installed cask.
private struct BrewCaskRow: Decodable {
    let token: String
    let fullToken: String?
    let pinned: Bool?
    let name: [String]
    let tap: String?
    let description: String?
    let homepage: String?
    let version: String?
    let installed: String?
    let outdated: Bool
    let autoUpdates: Bool?
    let deprecated: Bool
    let disabled: Bool

    enum CodingKeys: String, CodingKey {
        case token, name, tap, pinned, fullToken = "full_token", description = "desc", homepage, version, installed, outdated
        case autoUpdates = "auto_updates"
        case deprecated, disabled
    }
}
