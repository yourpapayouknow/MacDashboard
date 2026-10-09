/// One append-only operational security event.
public struct AuditEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let recordedAt: Date
    public let sourceAddress: String?
    public let host: String?
    public let origin: String?
    public let operation: String
    public let target: String?
    public let succeeded: Bool
    public let message: String

    /// Creates one immutable audit event.
    public init(
        id: UUID = UUID(),
        recordedAt: Date = Date(),
        sourceAddress: String?,
        host: String?,
        origin: String?,
        operation: String,
        target: String?,
        succeeded: Bool,
        message: String
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.sourceAddress = sourceAddress
        self.host = host
        self.origin = origin
        self.operation = operation
        self.target = target
        self.succeeded = succeeded
        self.message = message
    }
}

/// Persists newline-delimited audit events with owner-only file permissions.
public actor AuditStore {
    private let path: String

    /// Creates or opens one append-only audit file.
    public init(path: String) throws {
        self.path = path
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        guard chmod(path, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(.EPERM) }
    }

    /// Appends one complete JSON record followed by a newline.
    public func record(_ entry: AuditEntry) throws {
        var data = try JSONEncoder().encode(entry)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    /// Returns the newest bounded set while tolerating one damaged historical line.
    public func recent(limit: Int) throws -> [AuditEntry] {
        guard (1...1_000).contains(limit) else { return [] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        let lines = data.split(separator: 0x0A).suffix(limit)
        return lines.reversed().compactMap { try? JSONDecoder().decode(AuditEntry.self, from: Data($0)) }
    }
}
