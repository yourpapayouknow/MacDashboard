/// A stable, read-only snapshot returned by the first system API.
public struct SystemSummary: Codable, Equatable, Sendable {
    public let hostname: String
    public let osVersion: String
    public let architecture: String
    public let logicalCores: Int
    public let memoryBytes: UInt64
    public let uptimeSeconds: TimeInterval
    public let modelName: String?

    /// Creates a system summary value.
    public init(
        hostname: String,
        osVersion: String,
        architecture: String,
        logicalCores: Int,
        memoryBytes: UInt64,
        uptimeSeconds: TimeInterval,
        modelName: String? = nil
    ) {
        self.hostname = hostname
        self.osVersion = osVersion
        self.architecture = architecture
        self.logicalCores = logicalCores
        self.memoryBytes = memoryBytes
        self.uptimeSeconds = uptimeSeconds
        self.modelName = modelName
    }
}

/// Reads a snapshot from native Foundation process information.
public struct SummaryReader: Sendable {
    /// Creates the stateless reader.
    public init() {}

    /// Reads the current machine summary.
    public func rdsmry() -> SystemSummary {
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif

        return SystemSummary(
            hostname: info.hostName,
            osVersion: osVersion,
            architecture: architecture,
            logicalCores: info.processorCount,
            memoryBytes: info.physicalMemory,
            uptimeSeconds: info.systemUptime,
            modelName: rdmdl()
        )
    }

    /// 读取本机产品名称，缺失时保留硬件型号标识。
    private func rdmdl() -> String? {
        let entries = [
            IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/AppleARMPE/product"),
            IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        ]
        defer { for entry in entries where entry != 0 { IOObjectRelease(entry) } }
        for entry in entries where entry != 0 {
            let value = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            if let name = mdlstr(value) { return name }
        }
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { sysctlbyname("hw.model", $0.baseAddress, &size, nil, 0) }
        return result == 0 ? mdlstr(data) : nil
    }

    /// 解码产品字符串并移除终止符与空白。
    func mdlstr(_ value: Any?) -> String? {
        let text: String?
        if let data = value as? Data {
            text = String(data: Data(data.prefix { $0 != 0 }), encoding: .utf8)
        } else {
            text = value as? String
        }
        guard let name = text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }
}

/// One, five, and fifteen minute system load averages.
public struct LoadInfo: Codable, Equatable, Sendable {
    public let one: Double
    public let five: Double
    public let fifteen: Double
    public let safeLimit: Double
    public let maximum: Double
}

/// CPU topology and sampled utilization.
public struct CPUInfo: Codable, Equatable, Sendable {
    public let logicalCores: Int
    public let physicalCores: Int
    public let totalPercent: Double
    public let userPercent: Double
    public let systemPercent: Double
    public let idlePercent: Double
    public let perCorePercent: [Double]
}

/// Native macOS memory and swap counters.
public struct MemoryInfo: Codable, Equatable, Sendable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let availableBytes: UInt64
    public let activeBytes: UInt64
    public let inactiveBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedBytes: UInt64
    public let swapTotalBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapInPages: UInt64
    public let swapOutPages: UInt64
    public let pressureLevel: Int32
}

/// Capacity and inode counters for one mounted volume.
public struct DiskInfo: Codable, Equatable, Sendable {
    public let mountPath: String
    public let fileSystem: String
    public let device: String
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let availableBytes: UInt64
    public let totalFiles: UInt64
    public let usedFiles: UInt64
    public let availableFiles: UInt64
}

/// Cumulative I/O counters for one block-storage driver.
public struct DiskCounter: Codable, Equatable, Sendable {
    public let name: String
    public let readBytes: UInt64
    public let writtenBytes: UInt64
    public let readOperations: UInt64
    public let writeOperations: UInt64
}

/// Instantaneous I/O rates derived from two block-storage samples.
public struct DiskRate: Codable, Equatable, Sendable {
    public let name: String
    public let readBytesPerSecond: Double
    public let writtenBytesPerSecond: Double
    public let readOperationsPerSecond: Double
    public let writeOperationsPerSecond: Double
}

/// Counters and addresses for one network interface.
public enum NetworkKind: String, Codable, Equatable, Sendable {
    case physical
    case tunnel
    case loopback
    case bridge
    case peer
    case virtual
    case other
}

/// Known routing role inferred from interface addresses and naming.
public enum NetworkRole: String, Codable, Equatable, Sendable {
    case flClash
    case tailscale
    case systemTunnel
    case ordinary
}

/// Counters and addresses for one network interface.
public struct NetworkInfo: Codable, Equatable, Sendable {
    public let name: String
    public let kind: NetworkKind
    public let role: NetworkRole
    public let isUp: Bool
    public let isLoopback: Bool
    public let addresses: [String]
    public let receivedBytes: UInt64
    public let sentBytes: UInt64
    public let receivedPackets: UInt64
    public let sentPackets: UInt64
    public let inputErrors: UInt64
    public let outputErrors: UInt64
}

/// A complete low-cost live snapshot used by the monitoring API.
public struct SystemSnapshot: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let summary: SystemSummary
    public let load: LoadInfo
    public let cpu: CPUInfo
    public let memory: MemoryInfo
    public let disks: [DiskInfo]
    public let diskCounters: [DiskCounter]
    public let networks: [NetworkInfo]
}

/// Instantaneous throughput derived from two interface counter samples.
public struct NetworkRate: Codable, Equatable, Sendable {
    public let name: String
    public let kind: NetworkKind
    public let role: NetworkRole
    public let receivedBytesPerSecond: Double
    public let sentBytesPerSecond: Double
    public let receivedPacketsPerSecond: Double
    public let sentPacketsPerSecond: Double
}

/// Stateful live monitoring response with counter-derived rates.
public struct LiveSnapshot: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let intervalSeconds: TimeInterval
    public let system: SystemSnapshot
    public let diskRates: [DiskRate]
    public let networkRates: [NetworkRate]
}

/// One read-only operating-system process record.
public struct ProcessSample: Codable, Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let user: String
    public let state: String
    public let cpuPercent: Double
    public let memoryPercent: Double
    public let residentBytes: UInt64
    public let threadCount: Int
    public let readBytes: UInt64
    public let writtenBytes: UInt64
    public let elapsed: String
    public let command: String
}

/// Process inventory and pre-ranked views captured at one instant.
public struct ProcessSnapshot: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let processes: [ProcessSample]
    public let topCPU: [ProcessSample]
    public let topMemory: [ProcessSample]
}

/// Reads the process table through Apple's fixed ps executable contract.
public struct ProcessReader: Sendable {
    /// Creates the stateless process reader.
    public init() {}

    /// Reads all visible processes and produces CPU and memory rankings.
    public func rdprocs(limit: Int = 10) -> ProcessSnapshot {
        let processes = runps()
        return ProcessSnapshot(
            sampledAt: Date(),
            processes: processes,
            topCPU: Array(processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(max(0, limit))),
            topMemory: Array(processes.sorted { $0.residentBytes > $1.residentBytes }.prefix(max(0, limit)))
        )
    }

    /// Executes one fixed, non-shell process-table query and parses its columns.
    private func runps() -> [ProcessSample] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,user=,state=,pcpu=,pmem=,rss=,etime=,comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 8, whereSeparator: \.isWhitespace)
            guard fields.count == 9,
                  let pid = Int32(fields[0]),
                  let parentPID = Int32(fields[1]),
                  let cpu = Double(fields[4]),
                  let memory = Double(fields[5]),
                  let residentKB = UInt64(fields[6]) else { return nil }
            let io = rdio(pid)
            return ProcessSample(
                pid: pid,
                parentPID: parentPID,
                user: String(fields[2]),
                state: String(fields[3]),
                cpuPercent: cpu,
                memoryPercent: memory,
                residentBytes: residentKB * 1_024,
                threadCount: rdthrd(pid),
                readBytes: io.read,
                writtenBytes: io.write,
                elapsed: String(fields[7]),
                command: String(fields[8])
            )
        }
    }

    /// Reads the current thread count through libproc task information.
    private func rdthrd(_ pid: Int32) -> Int {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        return result == size ? Int(info.pti_threadnum) : 0
    }

    /// Reads cumulative process disk bytes through libproc resource usage.
    private func rdio(_ pid: Int32) -> (read: UInt64, write: UInt64) {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result != -1 else { return (0, 0) }
        return (usage.ri_diskio_bytesread, usage.ri_diskio_byteswritten)
    }
}

/// Serializes rate baselines so concurrent API requests remain consistent.
public actor MetricsSampler {
    private let reader = SnapshotReader()
    private var priorDisks: [String: DiskCounter] = [:]
    private var priorNetworks: [String: NetworkInfo] = [:]
    private var priorDate: Date?

    /// Creates an empty sampler whose first rate sample is zero.
    public init() {}

    /// Reads a system snapshot and derives per-interface rates since the prior call.
    public func rdlive() -> LiveSnapshot {
        let system = reader.rdsnp()
        let sampledAt = system.sampledAt
        let interval = max(sampledAt.timeIntervalSince(priorDate ?? sampledAt), 0)
        let rates = system.networks.map { current in
            let prior = priorNetworks[current.name]
            return NetworkRate(
                name: current.name,
                kind: current.kind,
                role: current.role,
                receivedBytesPerSecond: rdrate(current.receivedBytes, prior?.receivedBytes, interval),
                sentBytesPerSecond: rdrate(current.sentBytes, prior?.sentBytes, interval),
                receivedPacketsPerSecond: rdrate(current.receivedPackets, prior?.receivedPackets, interval),
                sentPacketsPerSecond: rdrate(current.sentPackets, prior?.sentPackets, interval)
            )
        }.sorted { $0.name < $1.name }
        let diskRates = system.diskCounters.map { current in
            let prior = priorDisks[current.name]
            return DiskRate(
                name: current.name,
                readBytesPerSecond: rdrate(current.readBytes, prior?.readBytes, interval),
                writtenBytesPerSecond: rdrate(current.writtenBytes, prior?.writtenBytes, interval),
                readOperationsPerSecond: rdrate(current.readOperations, prior?.readOperations, interval),
                writeOperationsPerSecond: rdrate(current.writeOperations, prior?.writeOperations, interval)
            )
        }.sorted { $0.name < $1.name }
        priorDisks = Dictionary(uniqueKeysWithValues: system.diskCounters.map { ($0.name, $0) })
        priorNetworks = Dictionary(uniqueKeysWithValues: system.networks.map { ($0.name, $0) })
        priorDate = sampledAt
        return LiveSnapshot(
            sampledAt: sampledAt,
            intervalSeconds: interval,
            system: system,
            diskRates: diskRates,
            networkRates: rates
        )
    }

    /// Converts a monotonic counter delta to a non-negative per-second rate.
    private func rdrate(_ current: UInt64, _ prior: UInt64?, _ interval: TimeInterval) -> Double {
        guard let prior, current >= prior, interval > 0 else { return 0 }
        return Double(current - prior) / interval
    }
}

/// Reads native macOS host counters without invoking a shell.
public struct SnapshotReader: Sendable {
    /// Creates the stateless snapshot reader.
    public init() {}

    /// Reads every low-cost monitoring category in one consistent payload.
    public func rdsnp() -> SystemSnapshot {
        SystemSnapshot(
            sampledAt: Date(),
            summary: SummaryReader().rdsmry(),
            load: rdload(),
            cpu: rdcpu(),
            memory: rdmem(),
            disks: rddisks(),
            diskCounters: rddiskio(),
            networks: rdnets()
        )
    }

    /// Reads the Darwin load average vector and BaoTa-compatible thresholds.
    public func rdload() -> LoadInfo {
        var values = [Double](repeating: 0, count: 3)
        _ = getloadavg(&values, 3)
        let maximum = Double(max(ProcessInfo.processInfo.processorCount * 2, 1))
        return LoadInfo(
            one: values[0],
            five: values[1],
            fifteen: values[2],
            safeLimit: maximum * 0.75,
            maximum: maximum
        )
    }

    /// Samples Mach CPU ticks and converts their interval deltas to utilization.
    public func rdcpu() -> CPUInfo {
        guard let first = rdcputks() else {
            return CPUInfo(
                logicalCores: ProcessInfo.processInfo.processorCount,
                physicalCores: ProcessInfo.processInfo.activeProcessorCount,
                totalPercent: 0,
                userPercent: 0,
                systemPercent: 0,
                idlePercent: 0,
                perCorePercent: []
            )
        }
        usleep(100_000)
        guard let second = rdcputks(), first.count == second.count else {
            return CPUInfo(
                logicalCores: ProcessInfo.processInfo.processorCount,
                physicalCores: rdint("hw.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount,
                totalPercent: 0,
                userPercent: 0,
                systemPercent: 0,
                idlePercent: 0,
                perCorePercent: []
            )
        }
        let deltas = zip(first, second).map { old, new in
            zip(old, new).map { before, after in after >= before ? after - before : 0 }
        }
        let sums = deltas.reduce(into: [UInt64](repeating: 0, count: Int(CPU_STATE_MAX))) { total, core in
            for index in total.indices { total[index] += core[index] }
        }
        let user = Double(sums[Int(CPU_STATE_USER)])
        let system = Double(sums[Int(CPU_STATE_SYSTEM)])
        let idle = Double(sums[Int(CPU_STATE_IDLE)])
        let nice = Double(sums[Int(CPU_STATE_NICE)])
        let total = max(user + system + idle + nice, 1)
        let perCore = deltas.map { core -> Double in
            let idle = core[Int(CPU_STATE_IDLE)]
            let total = max(core.reduce(0, +), 1)
            return (Double(total - idle) / Double(total)) * 100
        }
        return CPUInfo(
            logicalCores: ProcessInfo.processInfo.processorCount,
            physicalCores: rdint("hw.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount,
            totalPercent: ((user + system + nice) / total) * 100,
            userPercent: ((user + nice) / total) * 100,
            systemPercent: (system / total) * 100,
            idlePercent: (idle / total) * 100,
            perCorePercent: perCore
        )
    }

    /// Reads Mach VM statistics, swap usage, and memory pressure.
    public func rdmem() -> MemoryInfo {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let page = UInt64(rdint("hw.pagesize") ?? 4_096)
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else {
            return MemoryInfo(
                totalBytes: total, usedBytes: 0, availableBytes: total,
                activeBytes: 0, inactiveBytes: 0, wiredBytes: 0,
                compressedBytes: 0, cachedBytes: 0, swapTotalBytes: 0,
                swapUsedBytes: 0, swapInPages: 0, swapOutPages: 0,
                pressureLevel: 0
            )
        }
        let active = UInt64(stats.active_count) * page
        let inactive = UInt64(stats.inactive_count) * page
        let speculative = UInt64(stats.speculative_count) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let purgeable = UInt64(stats.purgeable_count) * page
        let external = UInt64(stats.external_page_count) * page
        let gross = active + inactive + speculative + wired + compressed
        let reclaimable = min(gross, purgeable + external)
        let used = min(total, gross - reclaimable)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        _ = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        var pressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0)
        return MemoryInfo(
            totalBytes: total,
            usedBytes: used,
            availableBytes: total - used,
            activeBytes: active,
            inactiveBytes: inactive,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedBytes: purgeable + external,
            swapTotalBytes: UInt64(swap.xsu_total),
            swapUsedBytes: UInt64(swap.xsu_used),
            swapInPages: UInt64(stats.swapins),
            swapOutPages: UInt64(stats.swapouts),
            pressureLevel: pressure
        )
    }

    /// Reads mounted-volume capacity and inode counters through statfs.
    public func rddisks() -> [DiskInfo] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let mounts = UnsafeMutablePointer<statfs>.allocate(capacity: Int(count))
        defer { mounts.deallocate() }
        let loaded = getfsstat(mounts, Int32(Int(count) * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard loaded > 0 else { return [] }
        return (0..<Int(loaded)).compactMap { index -> DiskInfo? in
            let item = mounts[index]
            let path = withUnsafePointer(to: item.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
            }
            let fileSystem = withUnsafePointer(to: item.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            let device = withUnsafePointer(to: item.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
            }
            guard !path.hasPrefix("/System/Volumes/") || path == "/System/Volumes/Data" else { return nil }
            let block = UInt64(item.f_bsize)
            let total = UInt64(item.f_blocks) * block
            let free = UInt64(item.f_bfree) * block
            let available = UInt64(item.f_bavail) * block
            return DiskInfo(
                mountPath: path,
                fileSystem: fileSystem,
                device: device,
                totalBytes: total,
                usedBytes: total >= free ? total - free : 0,
                availableBytes: available,
                totalFiles: UInt64(item.f_files),
                usedFiles: UInt64(item.f_files >= item.f_ffree ? item.f_files - item.f_ffree : 0),
                availableFiles: UInt64(item.f_ffree)
            )
        }.sorted { $0.mountPath < $1.mountPath }
    }

    /// Reads per-driver cumulative block I/O statistics from IOKit.
    public func rddiskio() -> [DiskCounter] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var counters: [DiskCounter] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service,
                &properties,
                kCFAllocatorDefault,
                0
            ) == KERN_SUCCESS, let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary["Statistics"] as? [String: Any] else { continue }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(service, &nameBuffer) == KERN_SUCCESS,
                  let end = nameBuffer.firstIndex(of: 0) else { continue }
            let driver = String(decoding: nameBuffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }
            counters.append(DiskCounter(
                name: "\(driver)-\(entryID)",
                readBytes: rdnum(statistics["Bytes (Read)"]),
                writtenBytes: rdnum(statistics["Bytes (Write)"]),
                readOperations: rdnum(statistics["Operations (Read)"]),
                writeOperations: rdnum(statistics["Operations (Write)"])
            ))
        }
        return counters.sorted { $0.name < $1.name }
    }

    /// Reads interface addresses and link counters through getifaddrs.
    public func rdnets() -> [NetworkInfo] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var values: [String: NetworkInfo] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = head
        while let current = pointer {
            let item = current.pointee
            let name = String(cString: item.ifa_name)
            let prior = values[name]
            var addresses = prior?.addresses ?? []
            if let address = rdaddr(item.ifa_addr), !addresses.contains(address) { addresses.append(address) }
            var received = prior?.receivedBytes ?? 0
            var sent = prior?.sentBytes ?? 0
            var receivedPackets = prior?.receivedPackets ?? 0
            var sentPackets = prior?.sentPackets ?? 0
            var inputErrors = prior?.inputErrors ?? 0
            var outputErrors = prior?.outputErrors ?? 0
            if let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK), let data = item.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                received = UInt64(data.ifi_ibytes)
                sent = UInt64(data.ifi_obytes)
                receivedPackets = UInt64(data.ifi_ipackets)
                sentPackets = UInt64(data.ifi_opackets)
                inputErrors = UInt64(data.ifi_ierrors)
                outputErrors = UInt64(data.ifi_oerrors)
            }
            values[name] = NetworkInfo(
                name: name,
                kind: .other,
                role: .ordinary,
                isUp: item.ifa_flags & UInt32(IFF_UP) != 0,
                isLoopback: item.ifa_flags & UInt32(IFF_LOOPBACK) != 0,
                addresses: addresses.sorted(),
                receivedBytes: received,
                sentBytes: sent,
                receivedPackets: receivedPackets,
                sentPackets: sentPackets,
                inputErrors: inputErrors,
                outputErrors: outputErrors
            )
            pointer = item.ifa_next
        }
        return values.values.map { value in
            let identity = netid(value.name, value.addresses, value.isLoopback)
            return NetworkInfo(
                name: value.name,
                kind: identity.kind,
                role: identity.role,
                isUp: value.isUp,
                isLoopback: value.isLoopback,
                addresses: value.addresses,
                receivedBytes: value.receivedBytes,
                sentBytes: value.sentBytes,
                receivedPackets: value.receivedPackets,
                sentPackets: value.sentPackets,
                inputErrors: value.inputErrors,
                outputErrors: value.outputErrors
            )
        }.sorted { $0.name < $1.name }
    }

    /// Reads an integer sysctl value by its documented key.
    private func rdint(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    /// Converts an IOKit numeric property to a non-negative counter.
    private func rdnum(_ value: Any?) -> UInt64 {
        (value as? NSNumber)?.uint64Value ?? 0
    }

    /// Classifies physical, peer, bridge, and tunnel interfaces without excluding any.
    private func netid(_ name: String, _ addresses: [String], _ loopback: Bool) -> (kind: NetworkKind, role: NetworkRole) {
        if loopback { return (.loopback, .ordinary) }
        if name.hasPrefix("utun") || name.hasPrefix("tun") || name.hasPrefix("tap") || name.hasPrefix("gif") || name.hasPrefix("stf") {
            if addresses.contains(where: { $0.hasPrefix("198.18.") }) { return (.tunnel, .flClash) }
            if addresses.contains(where: { istsaddr($0) }) { return (.tunnel, .tailscale) }
            return (.tunnel, .systemTunnel)
        }
        if name.hasPrefix("bridge") { return (.bridge, .ordinary) }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { return (.peer, .ordinary) }
        if name.hasPrefix("en") || name.hasPrefix("anpi") || name.hasPrefix("ap") { return (.physical, .ordinary) }
        if name.hasPrefix("vmenet") || name.hasPrefix("vmnet") { return (.virtual, .ordinary) }
        return (.other, .ordinary)
    }

    /// Recognizes Tailscale's CGNAT and stable IPv6 address ranges.
    private func istsaddr(_ address: String) -> Bool {
        if address.hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = address.split(separator: ".")
        guard parts.count == 4, parts[0] == "100", let second = Int(parts[1]) else { return false }
        return (64...127).contains(second)
    }

    /// Copies per-core Mach CPU counters and releases the kernel buffer.
    private func rdcputks() -> [[UInt64]]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &count,
            &info,
            &infoCount
        ) == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }
        return (0..<Int(count)).map { core in
            (0..<Int(CPU_STATE_MAX)).map { state in
                UInt64(UInt32(bitPattern: info[(core * Int(CPU_STATE_MAX)) + state]))
            }
        }
    }

    /// Formats an IPv4 or IPv6 sockaddr without DNS lookup.
    private func rdaddr(_ address: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let address, [UInt8(AF_INET), UInt8(AF_INET6)].contains(address.pointee.sa_family) else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0, let end = host.firstIndex(of: 0) else { return nil }
        return String(decoding: host[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
