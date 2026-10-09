/// One durable monitoring point used by all history charts.
public struct HistorySample: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let cpuPercent: Double
    public let memoryUsedBytes: UInt64
    public let loadOne: Double
    public let loadFive: Double
    public let loadFifteen: Double
    public let networkReceivedBytesPerSecond: Double
    public let networkSentBytesPerSecond: Double
    public let diskReadBytesPerSecond: Double
    public let diskWrittenBytesPerSecond: Double

    /// Creates one normalized historical sample.
    public init(
        sampledAt: Date,
        cpuPercent: Double,
        memoryUsedBytes: UInt64,
        loadOne: Double,
        loadFive: Double,
        loadFifteen: Double,
        networkReceivedBytesPerSecond: Double,
        networkSentBytesPerSecond: Double,
        diskReadBytesPerSecond: Double,
        diskWrittenBytesPerSecond: Double
    ) {
        self.sampledAt = sampledAt
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.loadOne = loadOne
        self.loadFive = loadFive
        self.loadFifteen = loadFifteen
        self.networkReceivedBytesPerSecond = networkReceivedBytesPerSecond
        self.networkSentBytesPerSecond = networkSentBytesPerSecond
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWrittenBytesPerSecond = diskWrittenBytesPerSecond
    }

    /// Collapses one live response into the persisted chart schema.
    public init(live: LiveSnapshot) {
        let physical = live.networkRates.filter { $0.kind == .physical }
        self.init(
            sampledAt: live.sampledAt,
            cpuPercent: live.system.cpu.totalPercent,
            memoryUsedBytes: live.system.memory.usedBytes,
            loadOne: live.system.load.one,
            loadFive: live.system.load.five,
            loadFifteen: live.system.load.fifteen,
            networkReceivedBytesPerSecond: physical.reduce(0) { $0 + $1.receivedBytesPerSecond },
            networkSentBytesPerSecond: physical.reduce(0) { $0 + $1.sentBytesPerSecond },
            diskReadBytesPerSecond: live.diskRates.reduce(0) { $0 + $1.readBytesPerSecond },
            diskWrittenBytesPerSecond: live.diskRates.reduce(0) { $0 + $1.writtenBytesPerSecond }
        )
    }
}

/// One durable per-interface network sample.
public struct NetworkHistorySample: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let name: String
    public let kind: NetworkKind
    public let role: NetworkRole
    public let receivedBytesPerSecond: Double
    public let sentBytesPerSecond: Double
    public let receivedPacketsPerSecond: Double
    public let sentPacketsPerSecond: Double
    public let receivedBytes: UInt64
    public let sentBytes: UInt64
    public let receivedPackets: UInt64
    public let sentPackets: UInt64
}

/// One calendar-day physical-interface traffic total without tunnel double counting.
public struct DailyNetworkTotal: Codable, Equatable, Sendable {
    public let day: String
    public let receivedBytes: UInt64
    public let sentBytes: UInt64
}

/// One persisted process ranking row for historical top and high-CPU queries.
public struct ProcessHistorySample: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let rankKind: String
    public let rank: Int
    public let pid: Int32
    public let command: String
    public let cpuPercent: Double
    public let memoryPercent: Double
    public let residentBytes: UInt64
    public let readBytes: UInt64
    public let writtenBytes: UInt64
}

/// Owns the SQLite connection used for bounded monitoring history.
public actor HistoryStore {
    private let handle: DatabaseHandle

    /// Opens or creates the history database and its indexed sample table.
    public init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw HistoryError.open
        }
        guard sqlite3_exec(handle, Self.schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw HistoryError.schema
        }
        for migration in Self.migrations { sqlite3_exec(handle, migration, nil, nil, nil) }
        self.handle = DatabaseHandle(raw: handle)
    }

    /// Inserts or replaces one sample at its timestamp.
    public func add(_ sample: HistorySample) throws {
        let sql = """
        INSERT OR REPLACE INTO samples
        (sampled_at,cpu_percent,memory_used,load_one,load_five,load_fifteen,net_rx,net_tx,disk_read,disk_write)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle.raw, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryError.prepare
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, sample.sampledAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, sample.cpuPercent)
        sqlite3_bind_int64(statement, 3, Int64(clamping: sample.memoryUsedBytes))
        sqlite3_bind_double(statement, 4, sample.loadOne)
        sqlite3_bind_double(statement, 5, sample.loadFive)
        sqlite3_bind_double(statement, 6, sample.loadFifteen)
        sqlite3_bind_double(statement, 7, sample.networkReceivedBytesPerSecond)
        sqlite3_bind_double(statement, 8, sample.networkSentBytesPerSecond)
        sqlite3_bind_double(statement, 9, sample.diskReadBytesPerSecond)
        sqlite3_bind_double(statement, 10, sample.diskWrittenBytesPerSecond)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw HistoryError.write }
    }

    /// Persists every interface independently for tunnel-safe history.
    public func addnet(_ live: LiveSnapshot) throws {
        let sql = """
        INSERT OR REPLACE INTO network_samples
        (sampled_at,name,kind,role,rx_rate,tx_rate,rx_packets_rate,tx_packets_rate,rx_total,tx_total,rx_packets_total,tx_packets_total)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        """
        let counters = Dictionary(uniqueKeysWithValues: live.system.networks.map { ($0.name, $0) })
        for rate in live.networkRates {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle.raw, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw HistoryError.prepare
            }
            defer { sqlite3_finalize(statement) }
            let name = rate.name as NSString
            let kind = rate.kind.rawValue as NSString
            let role = rate.role.rawValue as NSString
            sqlite3_bind_double(statement, 1, live.sampledAt.timeIntervalSince1970)
            sqlite3_bind_text(statement, 2, name.utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, kind.utf8String, -1, nil)
            sqlite3_bind_text(statement, 4, role.utf8String, -1, nil)
            sqlite3_bind_double(statement, 5, rate.receivedBytesPerSecond)
            sqlite3_bind_double(statement, 6, rate.sentBytesPerSecond)
            sqlite3_bind_double(statement, 7, rate.receivedPacketsPerSecond)
            sqlite3_bind_double(statement, 8, rate.sentPacketsPerSecond)
            sqlite3_bind_int64(statement, 9, Int64(clamping: counters[rate.name]?.receivedBytes ?? 0))
            sqlite3_bind_int64(statement, 10, Int64(clamping: counters[rate.name]?.sentBytes ?? 0))
            sqlite3_bind_int64(statement, 11, Int64(clamping: counters[rate.name]?.receivedPackets ?? 0))
            sqlite3_bind_int64(statement, 12, Int64(clamping: counters[rate.name]?.sentPackets ?? 0))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw HistoryError.write }
        }
    }

    /// Returns bounded history for one exact interface name.
    public func qrynet(from: Date, to: Date, name: String, maxPoints: Int = 1_500) throws -> [NetworkHistorySample] {
        guard from <= to, maxPoints > 0, !name.isEmpty else { throw HistoryError.range }
        let sql = """
        SELECT sampled_at,name,kind,role,rx_rate,tx_rate,rx_packets_rate,tx_packets_rate,rx_total,tx_total,rx_packets_total,tx_packets_total
        FROM network_samples WHERE sampled_at >= ? AND sampled_at <= ? AND name = ? ORDER BY sampled_at ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle.raw, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryError.prepare
        }
        defer { sqlite3_finalize(statement) }
        let queryName = name as NSString
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, to.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, queryName.utf8String, -1, nil)
        var samples: [NetworkHistorySample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let kind = String(cString: sqlite3_column_text(statement, 2))
            let role = String(cString: sqlite3_column_text(statement, 3))
            samples.append(NetworkHistorySample(
                sampledAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                name: String(cString: sqlite3_column_text(statement, 1)),
                kind: NetworkKind(rawValue: kind) ?? .other,
                role: NetworkRole(rawValue: role) ?? .ordinary,
                receivedBytesPerSecond: sqlite3_column_double(statement, 4),
                sentBytesPerSecond: sqlite3_column_double(statement, 5),
                receivedPacketsPerSecond: sqlite3_column_double(statement, 6),
                sentPacketsPerSecond: sqlite3_column_double(statement, 7),
                receivedBytes: UInt64(max(0, sqlite3_column_int64(statement, 8))),
                sentBytes: UInt64(max(0, sqlite3_column_int64(statement, 9))),
                receivedPackets: UInt64(max(0, sqlite3_column_int64(statement, 10))),
                sentPackets: UInt64(max(0, sqlite3_column_int64(statement, 11)))
            ))
        }
        return Self.reduce(samples, maxPoints)
    }

    /// Aggregates physical-interface counter deltas into local calendar days.
    public func qrydays(from: Date, to: Date) throws -> [DailyNetworkTotal] {
        guard from <= to else { throw HistoryError.range }
        let sql = """
        SELECT strftime('%Y-%m-%d', sampled_at, 'unixepoch', 'localtime'), name, rx_total, tx_total
        FROM network_samples
        WHERE sampled_at >= ? AND sampled_at <= ? AND kind = 'physical'
        ORDER BY sampled_at ASC, name ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle.raw, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryError.prepare
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, to.timeIntervalSince1970)
        var totals: [String: (received: UInt64, sent: UInt64)] = [:]
        var prior: [String: (received: UInt64, sent: UInt64)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let day = String(cString: sqlite3_column_text(statement, 0))
            let name = String(cString: sqlite3_column_text(statement, 1))
            let received = UInt64(max(0, sqlite3_column_int64(statement, 2)))
            let sent = UInt64(max(0, sqlite3_column_int64(statement, 3)))
            let key = "\(day)\u{0}\(name)"
            if totals[day] == nil { totals[day] = (0, 0) }
            guard let previous = prior[key] else {
                prior[key] = (received, sent)
                continue
            }
            let total = totals[day] ?? (0, 0)
            totals[day] = (
                total.received + (received >= previous.received ? received - previous.received : received),
                total.sent + (sent >= previous.sent ? sent - previous.sent : sent)
            )
            prior[key] = (received, sent)
        }
        return totals.keys.sorted().map { day in
            DailyNetworkTotal(day: day, receivedBytes: totals[day]?.received ?? 0, sentBytes: totals[day]?.sent ?? 0)
        }
    }

    /// Persists CPU and memory process rankings from one snapshot.
    public func addproc(_ snapshot: ProcessSnapshot) throws {
        let sql = """
        INSERT OR REPLACE INTO process_samples
        (sampled_at,rank_kind,rank,pid,command,cpu_percent,memory_percent,resident_bytes,read_bytes,written_bytes)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """
        for (kind, rows) in [("cpu", snapshot.topCPU), ("memory", snapshot.topMemory)] {
            for (index, row) in rows.enumerated() {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(handle.raw, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                    throw HistoryError.prepare
                }
                defer { sqlite3_finalize(statement) }
                let rankKind = kind as NSString
                let command = row.command as NSString
                sqlite3_bind_double(statement, 1, snapshot.sampledAt.timeIntervalSince1970)
                sqlite3_bind_text(statement, 2, rankKind.utf8String, -1, nil)
                sqlite3_bind_int(statement, 3, Int32(index + 1))
                sqlite3_bind_int(statement, 4, row.pid)
                sqlite3_bind_text(statement, 5, command.utf8String, -1, nil)
                sqlite3_bind_double(statement, 6, row.cpuPercent)
                sqlite3_bind_double(statement, 7, row.memoryPercent)
                sqlite3_bind_int64(statement, 8, Int64(clamping: row.residentBytes))
                sqlite3_bind_int64(statement, 9, Int64(clamping: row.readBytes))
                sqlite3_bind_int64(statement, 10, Int64(clamping: row.writtenBytes))
                guard sqlite3_step(statement) == SQLITE_DONE else { throw HistoryError.write }
            }
        }
    }

    /// Returns process rankings or high-CPU rows over one bounded interval.
    public func qryproc(from: Date, to: Date, kind: String, minimumCPU: Double = 0) throws -> [ProcessHistorySample] {
        guard from <= to, ["cpu", "memory"].contains(kind), minimumCPU >= 0 else { throw HistoryError.range }
        let sql = """
        SELECT sampled_at,rank_kind,rank,pid,command,cpu_percent,memory_percent,resident_bytes,read_bytes,written_bytes
        FROM process_samples
        WHERE sampled_at >= ? AND sampled_at <= ? AND rank_kind = ? AND cpu_percent >= ?
        ORDER BY sampled_at ASC, rank ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle.raw, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryError.prepare
        }
        defer { sqlite3_finalize(statement) }
        let queryKind = kind as NSString
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, to.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, queryKind.utf8String, -1, nil)
        sqlite3_bind_double(statement, 4, minimumCPU)
        var rows: [ProcessHistorySample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(ProcessHistorySample(
                sampledAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                rankKind: String(cString: sqlite3_column_text(statement, 1)),
                rank: Int(sqlite3_column_int(statement, 2)),
                pid: sqlite3_column_int(statement, 3),
                command: String(cString: sqlite3_column_text(statement, 4)),
                cpuPercent: sqlite3_column_double(statement, 5),
                memoryPercent: sqlite3_column_double(statement, 6),
                residentBytes: UInt64(max(0, sqlite3_column_int64(statement, 7))),
                readBytes: UInt64(max(0, sqlite3_column_int64(statement, 8))),
                writtenBytes: UInt64(max(0, sqlite3_column_int64(statement, 9)))
            ))
        }
        return rows
    }

    /// Returns an ordered time range reduced to at most the requested point count.
    public func qry(from: Date, to: Date, maxPoints: Int = 1_500) throws -> [HistorySample] {
        guard from <= to, maxPoints > 0 else { throw HistoryError.range }
        let sql = """
        SELECT sampled_at,cpu_percent,memory_used,load_one,load_five,load_fifteen,net_rx,net_tx,disk_read,disk_write
        FROM samples WHERE sampled_at >= ? AND sampled_at <= ? ORDER BY sampled_at ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle.raw, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryError.prepare
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, to.timeIntervalSince1970)
        var samples: [HistorySample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            samples.append(HistorySample(
                sampledAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                cpuPercent: sqlite3_column_double(statement, 1),
                memoryUsedBytes: UInt64(max(0, sqlite3_column_int64(statement, 2))),
                loadOne: sqlite3_column_double(statement, 3),
                loadFive: sqlite3_column_double(statement, 4),
                loadFifteen: sqlite3_column_double(statement, 5),
                networkReceivedBytesPerSecond: sqlite3_column_double(statement, 6),
                networkSentBytesPerSecond: sqlite3_column_double(statement, 7),
                diskReadBytesPerSecond: sqlite3_column_double(statement, 8),
                diskWrittenBytesPerSecond: sqlite3_column_double(statement, 9)
            ))
        }
        guard samples.count > maxPoints else { return samples }
        guard maxPoints > 1 else { return [samples[samples.count - 1]] }
        return (0..<maxPoints).map { point in
            let index = (point * (samples.count - 1)) / (maxPoints - 1)
            return samples[index]
        }
    }

    /// Deletes samples older than the supplied retention boundary.
    public func prune(before: Date) throws -> Int {
        try del("samples", before) + del("network_samples", before) + del("process_samples", before)
    }

    /// Deletes expired rows from one fixed internal table.
    private func del(_ table: String, _ before: Date) throws -> Int {
        guard ["samples", "network_samples", "process_samples"].contains(table) else { throw HistoryError.range }
        let sql = "DELETE FROM \(table) WHERE sampled_at < ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle.raw, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryError.prepare
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, before.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw HistoryError.write }
        return Int(sqlite3_changes(handle.raw))
    }

    private static let schema = """
    PRAGMA journal_mode=WAL;
    PRAGMA synchronous=NORMAL;
    CREATE TABLE IF NOT EXISTS samples (
      sampled_at REAL PRIMARY KEY,
      cpu_percent REAL NOT NULL,
      memory_used INTEGER NOT NULL,
      load_one REAL NOT NULL,
      load_five REAL NOT NULL,
      load_fifteen REAL NOT NULL,
      net_rx REAL NOT NULL,
      net_tx REAL NOT NULL,
      disk_read REAL NOT NULL,
      disk_write REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS samples_time ON samples(sampled_at);
    CREATE TABLE IF NOT EXISTS network_samples (
      sampled_at REAL NOT NULL,
      name TEXT NOT NULL,
      kind TEXT NOT NULL,
      role TEXT NOT NULL,
      rx_rate REAL NOT NULL,
      tx_rate REAL NOT NULL,
      rx_packets_rate REAL NOT NULL,
      tx_packets_rate REAL NOT NULL,
      rx_total INTEGER NOT NULL,
      tx_total INTEGER NOT NULL,
      PRIMARY KEY (sampled_at, name)
    );
    CREATE INDEX IF NOT EXISTS network_samples_time ON network_samples(sampled_at, name);
    CREATE TABLE IF NOT EXISTS process_samples (
      sampled_at REAL NOT NULL,
      rank_kind TEXT NOT NULL,
      rank INTEGER NOT NULL,
      pid INTEGER NOT NULL,
      command TEXT NOT NULL,
      cpu_percent REAL NOT NULL,
      memory_percent REAL NOT NULL,
      resident_bytes INTEGER NOT NULL,
      read_bytes INTEGER NOT NULL,
      written_bytes INTEGER NOT NULL,
      PRIMARY KEY (sampled_at, rank_kind, rank)
    );
    CREATE INDEX IF NOT EXISTS process_samples_time ON process_samples(sampled_at, rank_kind);
    """

    private static let migrations = [
        "ALTER TABLE network_samples ADD COLUMN rx_packets_total INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE network_samples ADD COLUMN tx_packets_total INTEGER NOT NULL DEFAULT 0",
    ]

    /// Reduces an ordered array to an exact maximum while preserving endpoints.
    private static func reduce<T>(_ samples: [T], _ maxPoints: Int) -> [T] {
        guard samples.count > maxPoints else { return samples }
        guard maxPoints > 1 else { return [samples[samples.count - 1]] }
        return (0..<maxPoints).map { point in
            samples[(point * (samples.count - 1)) / (maxPoints - 1)]
        }
    }
}

/// Closes one SQLite handle after its owning actor is released.
private final class DatabaseHandle: @unchecked Sendable {
    let raw: OpaquePointer

    /// Stores the already-open SQLite handle.
    init(raw: OpaquePointer) {
        self.raw = raw
    }

    /// Releases the SQLite handle without crossing actor isolation.
    deinit {
        sqlite3_close(raw)
    }
}

/// Stable failures exposed by the monitoring history boundary.
public enum HistoryError: Error, Equatable, Sendable {
    case open
    case schema
    case prepare
    case write
    case range
}

/// Coordinates serialized live sampling with durable history writes.
public actor TelemetryMonitor {
    private let sampler: MetricsSampler
    private let store: HistoryStore
    private let processReader = ProcessReader()

    /// Creates a monitor around one sampler and one persistent store.
    public init(sampler: MetricsSampler = MetricsSampler(), store: HistoryStore) {
        self.sampler = sampler
        self.store = store
    }

    /// Captures and persists one complete live sample.
    @discardableResult
    public func tick() async throws -> LiveSnapshot {
        let live = await sampler.rdlive()
        try await store.add(HistorySample(live: live))
        try await store.addnet(live)
        try await store.addproc(processReader.rdprocs(limit: 10))
        return live
    }

    /// Reads a bounded historical time range.
    public func hist(from: Date, to: Date, maxPoints: Int) async throws -> [HistorySample] {
        try await store.qry(from: from, to: to, maxPoints: maxPoints)
    }

    /// Reads bounded history for one interface without merging tunnel layers.
    public func nethist(from: Date, to: Date, name: String, maxPoints: Int) async throws -> [NetworkHistorySample] {
        try await store.qrynet(from: from, to: to, name: name, maxPoints: maxPoints)
    }

    /// Reads physical-interface traffic totals grouped by local calendar day.
    public func netdays(from: Date, to: Date) async throws -> [DailyNetworkTotal] {
        try await store.qrydays(from: from, to: to)
    }

    /// Reads persisted process rankings with an optional high-CPU threshold.
    public func prochist(from: Date, to: Date, kind: String, minimumCPU: Double) async throws -> [ProcessHistorySample] {
        try await store.qryproc(from: from, to: to, kind: kind, minimumCPU: minimumCPU)
    }

    /// Applies the supplied history retention boundary.
    public func prune(before: Date) async throws -> Int {
        try await store.prune(before: before)
    }
}
