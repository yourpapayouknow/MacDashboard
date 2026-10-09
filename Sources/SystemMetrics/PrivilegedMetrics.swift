/// Per-process network totals and interval rates from macOS nettop.
public struct ProcessNetworkSample: Codable, Equatable, Sendable {
    public let pid: Int32
    public let process: String
    public let receivedBytes: UInt64
    public let sentBytes: UInt64
    public let receivedBytesPerSecond: Double
    public let sentBytesPerSecond: Double
}

/// Complete or permission-limited process network response.
public struct ProcessNetworkSnapshot: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let intervalSeconds: TimeInterval
    public let requiresPrivilege: Bool
    public let samples: [ProcessNetworkSample]
}

/// Hardware power and supported thermal state from powermetrics.
public struct PowerThermalSnapshot: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let requiresPrivilege: Bool
    public let cpuMilliwatts: Double?
    public let gpuMilliwatts: Double?
    public let aneMilliwatts: Double?
    public let combinedMilliwatts: Double?
    public let thermalPressure: String?
    public let cpuTemperatureCelsius: Double?
    public let temperatureUnavailableReason: String?
}

/// Serializes privileged nettop baselines for per-process rates.
public actor ProcessNetworkReader {
    private var prior: [Int32: (received: UInt64, sent: UInt64)] = [:]
    private var priorDate: Date?

    /// Creates an empty process-network sampler.
    public init() {}

    /// Reads all process totals when executed by the privileged helper.
    public func rdprocnet() -> ProcessNetworkSnapshot {
        let now = Date()
        guard geteuid() == 0, let output = runnettop() else {
            return ProcessNetworkSnapshot(
                sampledAt: now,
                intervalSeconds: 0,
                requiresPrivilege: true,
                samples: []
            )
        }
        let interval = max(now.timeIntervalSince(priorDate ?? now), 0)
        let totals = Self.parse(output)
        let samples = totals.map { total in
            let old = prior[total.pid]
            return ProcessNetworkSample(
                pid: total.pid,
                process: total.process,
                receivedBytes: total.receivedBytes,
                sentBytes: total.sentBytes,
                receivedBytesPerSecond: rate(total.receivedBytes, old?.received, interval),
                sentBytesPerSecond: rate(total.sentBytes, old?.sent, interval)
            )
        }.sorted { max($0.receivedBytesPerSecond, $0.sentBytesPerSecond) > max($1.receivedBytesPerSecond, $1.sentBytesPerSecond) }
        prior = totals.reduce(into: [:]) { values, total in
            values[total.pid] = (total.receivedBytes, total.sentBytes)
        }
        priorDate = now
        return ProcessNetworkSnapshot(sampledAt: now, intervalSeconds: interval, requiresPrivilege: false, samples: samples)
    }

    /// Parses one machine-readable nettop sample.
    static func parse(_ text: String) -> [ProcessNetworkSample] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let split = fields[0].lastIndex(of: "."),
                  let pid = Int32(fields[0][fields[0].index(after: split)...]),
                  let received = UInt64(fields[1]),
                  let sentText = fields[2].split(separator: ",", maxSplits: 1).first,
                  let sent = UInt64(sentText) else { return nil }
            return ProcessNetworkSample(
                pid: pid,
                process: String(fields[0][..<split]),
                receivedBytes: received,
                sentBytes: sent,
                receivedBytesPerSecond: 0,
                sentBytesPerSecond: 0
            )
        }
    }

    /// Runs the single approved nettop sampling command without a shell.
    private func runnettop() -> String? {
        runfixed("/usr/bin/nettop", ["-P", "-L", "1", "-k", "state", "-J", "bytes_in,bytes_out"])
    }

    /// Converts a cumulative process counter delta to bytes per second.
    private func rate(_ current: UInt64, _ old: UInt64?, _ interval: TimeInterval) -> Double {
        guard let old, current >= old, interval > 0 else { return 0 }
        return Double(current - old) / interval
    }
}

/// Reads supported Apple Silicon power and thermal-pressure metrics.
public struct PowerThermalReader: Sendable {
    /// Creates the stateless power reader.
    public init() {}

    /// Reads one privileged powermetrics sample.
    public func rdpower() -> PowerThermalSnapshot {
        let now = Date()
        guard geteuid() == 0, let output = runfixed(
            "/usr/bin/powermetrics",
            ["-s", "thermal,cpu_power,gpu_power,ane_power", "-n", "1", "-i", "100"]
        ) else {
            return PowerThermalSnapshot(
                sampledAt: now,
                requiresPrivilege: true,
                cpuMilliwatts: nil,
                gpuMilliwatts: nil,
                aneMilliwatts: nil,
                combinedMilliwatts: nil,
                thermalPressure: nil,
                cpuTemperatureCelsius: nil,
                temperatureUnavailableReason: "powermetrics requires the privileged helper"
            )
        }
        return Self.parse(output, sampledAt: now)
    }

    /// Parses stable power and thermal-pressure lines without inventing temperature.
    static func parse(_ text: String, sampledAt: Date = Date()) -> PowerThermalSnapshot {
        var cpu: Double?
        var gpu: Double?
        var ane: Double?
        var combined: Double?
        var pressure: String?
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("CPU Power:") { cpu = number(line) }
            if line.hasPrefix("GPU Power:") { gpu = number(line) }
            if line.hasPrefix("ANE Power:") { ane = number(line) }
            if line.hasPrefix("Combined Power") { combined = number(line) }
            if line.hasPrefix("Current pressure level:") { pressure = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) }
        }
        return PowerThermalSnapshot(
            sampledAt: sampledAt,
            requiresPrivilege: false,
            cpuMilliwatts: cpu,
            gpuMilliwatts: gpu,
            aneMilliwatts: ane,
            combinedMilliwatts: combined,
            thermalPressure: pressure,
            cpuTemperatureCelsius: nil,
            temperatureUnavailableReason: "macOS powermetrics does not expose a supported Celsius sensor on this Mac"
        )
    }

    /// Extracts the first numeric value following a metric label.
    private static func number(_ line: String) -> Double? {
        line.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }.first
    }
}

/// Runs only the two exact privileged read-only commands approved by this module.
private func runfixed(_ path: String, _ arguments: [String]) -> String? {
    let nettop = path == "/usr/bin/nettop" && arguments == ["-P", "-L", "1", "-k", "state", "-J", "bytes_in,bytes_out"]
    let power = path == "/usr/bin/powermetrics" && arguments == ["-s", "thermal,cpu_power,gpu_power,ane_power", "-n", "1", "-i", "100"]
    guard nettop || power else { return nil }
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
