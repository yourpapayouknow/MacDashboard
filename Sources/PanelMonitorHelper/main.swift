import Foundation
import SystemMetrics

// 提供只读采集和经系统授权的固定服务动作。
final class MonitorHelper: NSObject, NSXPCListenerDelegate, MonitorHelperIPC, @unchecked Sendable {
    private let networkReader = ProcessNetworkReader()
    private let powerReader = PowerThermalReader()
    private let connectionReader = ConnectionReader()
    private let serviceController: ServiceController
    private let allowedUID: uid_t
    let clientRequirement: String

    /// Loads the one allowed caller identity from launchd-owned environment values.
    override init() {
        let environment = ProcessInfo.processInfo.environment
        self.allowedUID = uid_t(environment["PANEL_ALLOWED_UID"].flatMap(UInt32.init) ?? UInt32.max)
        self.serviceController = ServiceController(uid: self.allowedUID)
        self.clientRequirement = NativeIdentity.cdreq("com.iwmei.macdashboard.panel-service")
        super.init()
    }

    /// Accepts only the configured user and matching signed PanelService client.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard geteuid() == 0, connection.effectiveUserIdentifier == allowedUID else { return false }
        connection.exportedInterface = NSXPCInterface(with: MonitorHelperIPC.self)
        connection.exportedObject = self
        connection.activate()
        return true
    }

    /// Encodes one root-visible per-process network snapshot.
    func procnet(_ reply: @escaping @Sendable (Data) -> Void) {
        Task {
            let snapshot = await networkReader.rdprocnet()
            reply((try? JSONEncoder().encode(snapshot)) ?? Data())
        }
    }

    /// Encodes one root-visible power and thermal snapshot.
    func power(_ reply: @escaping @Sendable (Data) -> Void) {
        reply((try? JSONEncoder().encode(powerReader.rdpower())) ?? Data())
    }

    /// Encodes the root-visible TCP and UDP connection inventory.
    func conns(_ reply: @escaping @Sendable (Data) -> Void) {
        reply((try? JSONEncoder().encode(connectionReader.rdconns())) ?? Data())
    }

    /// Decodes and performs one validated launchd lifecycle operation.
    func service(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let action = try? JSONDecoder().decode(ServiceActionRequest.self, from: request) else {
            reply(Data())
            return
        }
        guard OperationAuthorization.verify(action.authorization) else {
            let result = ServiceActionResult(
                id: action.id,
                action: action.action,
                succeeded: false,
                message: "Native administrator authorization is required",
                exitCode: nil
            )
            reply((try? JSONEncoder().encode(result)) ?? Data())
            return
        }
        reply((try? JSONEncoder().encode(serviceController.perform(action))) ?? Data())
    }
}

/// Starts the launchd-owned Mach service and enters its run loop.
func runhelper() {
    let helper = MonitorHelper()
    let listener = NSXPCListener(machServiceName: PrivilegedXPCClient.service)
    listener.setConnectionCodeSigningRequirement(helper.clientRequirement)
    listener.delegate = helper
    listener.activate()
    RunLoop.current.run()
}

runhelper()
