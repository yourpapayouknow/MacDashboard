/// One panel-owned remark keyed by an exact native project definition.
public struct SiteNote: Codable, Equatable, Sendable {
    public let label: String
    public let source: ServiceDefinitionSource
    public let definitionPath: String
    public let note: String

    /// Creates one project remark without changing its service configuration.
    public init(label: String, source: ServiceDefinitionSource, definitionPath: String, note: String) {
        self.label = label
        self.source = source
        self.definitionPath = definitionPath
        self.note = note
    }

    /// Keeps same-named projects in different native domains separate.
    fileprivate func matches(_ other: SiteNote) -> Bool {
        label == other.label && source == other.source && definitionPath == other.definitionPath
    }
}

/// Owner-protected persistent project remarks; never opens a submitted configuration path.
public actor SiteNoteStore {
    private let url: URL
    public nonisolated let target: String?
    public nonisolated let isWritable: Bool

    /// Opens an isolated remarks file, optionally restricted to the review fixture.
    public init(path: String, target: String? = nil, isWritable: Bool = true) throws {
        url = URL(fileURLWithPath: path)
        self.target = target
        self.isWritable = isWritable
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: Data("[]".utf8), attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        guard chmod(path, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(.EPERM) }
        _ = try JSONDecoder().decode([SiteNote].self, from: Data(contentsOf: url))
    }

    /// Reads persisted remarks without replacing malformed data with an empty list.
    public func read() throws -> [SiteNote] {
        try JSONDecoder().decode([SiteNote].self, from: Data(contentsOf: url))
    }

    /// Atomically updates one bounded remark and preserves every other project.
    public func save(_ value: SiteNote) throws -> SiteNote {
        guard isWritable, target == nil || target == value.label,
              !value.label.isEmpty, value.label.count <= 255,
              !value.label.contains("\0"), !value.label.contains("\n"),
              value.definitionPath.hasPrefix("/"), value.definitionPath.utf8.count <= 4096,
              !value.definitionPath.contains("\0"), !value.definitionPath.contains("\n"),
              value.note.utf8.count <= 4096, !value.note.contains("\0") else {
            throw SiteNoteError.invalid
        }
        var rows = try read()
        if let index = rows.firstIndex(where: { $0.matches(value) }) {
            rows[index] = value
        } else {
            rows.append(value)
        }
        let data = try JSONEncoder().encode(rows)
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(.EPERM) }
        return value
    }
}

/// Rejects invalid or out-of-scope project remarks.
public enum SiteNoteError: Error { case invalid }

/// Reports panel remark availability separately from native service authorization.
public struct SiteNoteInventory: Codable, Sendable {
    public let enabled: Bool
    public let notes: [SiteNote]
    public let target: String?

    /// Creates a read-only availability and persisted-value snapshot.
    public init(enabled: Bool, notes: [SiteNote], target: String? = nil) {
        self.enabled = enabled
        self.notes = notes
        self.target = target
    }
}
