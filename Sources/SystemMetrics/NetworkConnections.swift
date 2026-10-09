/// One TCP or UDP socket attributed to its owning process.
public struct NetworkConnection: Codable, Equatable, Hashable, Sendable {
    public let pid: Int32
    public let process: String
    public let protocolName: String
    public let localEndpoint: String
    public let remoteEndpoint: String?
    public let state: String?
    public let descriptor: Int32?

    /// Creates one socket record while preserving older snapshots without descriptors.
    public init(pid: Int32, process: String, protocolName: String, localEndpoint: String,
        remoteEndpoint: String?, state: String?, descriptor: Int32? = nil) {
        self.pid = pid
        self.process = process
        self.protocolName = protocolName
        self.localEndpoint = localEndpoint
        self.remoteEndpoint = remoteEndpoint
        self.state = state
        self.descriptor = descriptor
    }
}

/// A connection table plus its permission-completeness indicator.
public struct ConnectionSnapshot: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let hasFullVisibility: Bool
    public let connections: [NetworkConnection]
}

/// Reads macOS socket ownership through a fixed machine-readable lsof query.
public struct ConnectionReader: Sendable {
    /// Creates the stateless connection reader.
    public init() {}

    /// Reads every socket visible to the current service identity.
    public func rdconns() -> ConnectionSnapshot {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-iUDP", "-FpcPnT"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            return ConnectionSnapshot(sampledAt: Date(), hasFullVisibility: geteuid() == 0, connections: [])
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return ConnectionSnapshot(
            sampledAt: Date(),
            hasFullVisibility: geteuid() == 0,
            connections: Self.parse(text)
        )
    }

    /// Parses lsof field output into typed socket records.
    static func parse(_ text: String) -> [NetworkConnection] {
        var pid: Int32 = 0
        var command = ""
        var protocolName = ""
        var endpoint = ""
        var state: String?
        var descriptor: Int32?
        var records: [NetworkConnection] = []

        // Emits the completed file record before a new file or process begins.
        func emit() {
            guard pid > 0, !protocolName.isEmpty, !endpoint.isEmpty else { return }
            let sides = endpoint.components(separatedBy: "->")
            records.append(NetworkConnection(
                pid: pid,
                process: command,
                protocolName: protocolName,
                localEndpoint: sides[0],
                remoteEndpoint: sides.count > 1 ? sides[1] : nil,
                state: state,
                descriptor: descriptor
            ))
        }

        for line in text.split(separator: "\n").map(String.init) {
            guard let key = line.first else { continue }
            let value = String(line.dropFirst())
            switch key {
            case "p": emit(); pid = Int32(value) ?? 0; protocolName = ""; endpoint = ""; state = nil; descriptor = nil
            case "c": command = value
            case "f": emit(); protocolName = ""; endpoint = ""; state = nil; descriptor = Int32(value)
            case "P": protocolName = value.lowercased()
            case "n": endpoint = value
            case "T": if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: break
            }
        }
        emit()
        var seen: Set<NetworkConnection> = []
        return records.filter { seen.insert($0).inserted }
    }
}
