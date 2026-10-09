/// Narrow XPC contract exported by the root monitoring helper.
@objc public protocol MonitorHelperIPC {
    /// Returns one encoded per-process network snapshot.
    func procnet(_ reply: @escaping @Sendable (Data) -> Void)

    /// Returns one encoded power and thermal snapshot.
    func power(_ reply: @escaping @Sendable (Data) -> Void)

    /// Returns one encoded complete TCP and UDP connection inventory.
    func conns(_ reply: @escaping @Sendable (Data) -> Void)

    /// Performs one encoded, validated service lifecycle request.
    func service(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

/// Abstracts privileged monitoring so HTTP routing remains independently testable.
public protocol PrivilegedSource: Sendable {
    /// Reads privileged per-process network activity.
    func rdprocnet() async -> ProcessNetworkSnapshot

    /// Reads privileged power and thermal state.
    func rdpower() async -> PowerThermalSnapshot

    /// Reads the root-visible network connection inventory.
    func rdconns() async -> ConnectionSnapshot

    /// Performs one narrow privileged service lifecycle operation.
    func actservice(_ request: ServiceActionRequest) async -> ServiceActionResult
}

/// Connects an ordinary process to the signature-constrained root helper.
public final class PrivilegedXPCClient: @unchecked Sendable, PrivilegedSource {
    public static let service = "com.iwmei.macdashboard.monitor-helper.native"
    public static let helperRequirement = NativeIdentity.cdreq("com.iwmei.macdashboard.monitor-helper.native")

    /// Creates an on-demand privileged XPC client.
    public init() {}

    /// Requests one process-network sample or returns an explicit unavailable result.
    public func rdprocnet() async -> ProcessNetworkSnapshot {
        await request(
            invoke: { $0.procnet($1) },
            fallback: ProcessNetworkSnapshot(
                sampledAt: Date(),
                intervalSeconds: 0,
                requiresPrivilege: true,
                samples: []
            )
        )
    }

    /// Requests one power sample or returns an explicit unavailable result.
    public func rdpower() async -> PowerThermalSnapshot {
        await request(
            invoke: { $0.power($1) },
            fallback: PowerThermalSnapshot(
                sampledAt: Date(),
                requiresPrivilege: true,
                cpuMilliwatts: nil,
                gpuMilliwatts: nil,
                aneMilliwatts: nil,
                combinedMilliwatts: nil,
                thermalPressure: nil,
                cpuTemperatureCelsius: nil,
                temperatureUnavailableReason: "privileged monitoring helper is unavailable"
            )
        )
    }

    /// Requests complete connection ownership or falls back to the caller-visible inventory.
    public func rdconns() async -> ConnectionSnapshot {
        await request(
            invoke: { $0.conns($1) },
            fallback: ConnectionReader().rdconns()
        )
    }

    /// Requests one validated service action or returns an explicit helper failure.
    public func actservice(_ serviceRequest: ServiceActionRequest) async -> ServiceActionResult {
        let data = (try? JSONEncoder().encode(serviceRequest)) ?? Data()
        return await request(
            invoke: { $0.service(data, reply: $1) },
            fallback: ServiceActionResult(
                id: serviceRequest.id,
                action: serviceRequest.action,
                succeeded: false,
                message: "Privileged helper is unavailable",
                exitCode: nil
            ),
            timeout: 30
        )
    }

    /// Performs one bounded XPC request and decodes its typed response.
    private func request<Value: Codable & Sendable>(
        invoke: @escaping @Sendable (MonitorHelperIPC, @escaping @Sendable (Data) -> Void) -> Void,
        fallback: Value,
        timeout: TimeInterval = 10
    ) async -> Value {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: Self.service, options: .privileged)
            let state = ReplyState<Value>(continuation: continuation, fallback: fallback, connection: connection)
            connection.remoteObjectInterface = NSXPCInterface(with: MonitorHelperIPC.self)
            connection.setCodeSigningRequirement(Self.helperRequirement)
            connection.invalidationHandler = { state.finish(nil) }
            connection.interruptionHandler = { state.finish(nil) }
            connection.activate()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { state.finish(nil) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in state.finish(nil) }) as? MonitorHelperIPC else {
                state.finish(nil)
                return
            }
            invoke(proxy) { data in
                state.finish(try? JSONDecoder().decode(Value.self, from: data))
            }
        }
    }
}

/// Ensures XPC completion, failure, and invalidation resume a request exactly once.
private final class ReplyState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private let fallback: Value
    private let connection: NSXPCConnection

    /// Stores one pending continuation and its failure value.
    init(continuation: CheckedContinuation<Value, Never>, fallback: Value, connection: NSXPCConnection) {
        self.continuation = continuation
        self.fallback = fallback
        self.connection = connection
    }

    /// Completes the request once and ignores later terminal callbacks.
    func finish(_ value: Value?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value ?? fallback)
        if pending != nil { connection.invalidate() }
    }
}
