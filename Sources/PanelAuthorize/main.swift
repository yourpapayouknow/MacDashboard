import Foundation
import Security
import SystemMetrics

/// Requests one interactive administrator grant and externalizes it for immediate XPC use.
func reqauth(_ id: String, _ label: String) -> AuthorizationRef? {
    var authorization: AuthorizationRef?
    guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
          let authorization else { return nil }
    let status = OperationAuthorization.right.withCString { rightName in
        var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
        return withUnsafePointer(to: &item) { pointer in
            var rights = AuthorizationRights(count: 1, items: UnsafeMutablePointer(mutating: pointer))
            let prompt = "Mac Dashboard 请求\(label)项目 [\(id)]。"
            return prompt.withCString { promptValue in
              kAuthorizationEnvironmentPrompt.withCString { environmentName in
                var promptItem = AuthorizationItem(name: environmentName,
                    valueLength: prompt.utf8.count, value: UnsafeMutableRawPointer(mutating: promptValue), flags: 0)
                return withUnsafeMutablePointer(to: &promptItem) { environmentPointer in
                    var environment = AuthorizationEnvironment(count: 1, items: environmentPointer)
                    return AuthorizationCopyRights(
                        authorization,
                        &rights,
                        &environment,
                        [.interactionAllowed, .extendRights, .preAuthorize],
                        nil
                    )
                }
              }
            }
        }
    }
    guard status == errAuthorizationSuccess else {
        AuthorizationFree(authorization, [])
        return nil
    }
    return authorization
}

// Executes only the explicitly selected service action after the native password sheet succeeds.
guard CommandLine.arguments.count == 4 else { exit(64) }
let mode = CommandLine.arguments[1]
let id = CommandLine.arguments[2]
let rawAction = CommandLine.arguments[3]
let action = ServiceAction(rawValue: rawAction)
let package = mode == "package-grant" && PackageController.validid(id) && PackageController.actions.contains { $0.rawValue == rawAction }
let service = ["service-action", "service-grant"].contains(mode) && ServiceController.validid(id) && action != nil
let container = mode == "container-grant" && ContainerController.validid(id) && ContainerController.actions.contains { $0.rawValue == rawAction }
let file = mode == "file-grant" && FileController.validref(id) && FileController.actions.contains { $0.rawValue == rawAction }
let database = mode == "database-grant" && FileController.validref(id) && ["backup", "restore"].contains(rawAction)
let label = database ? (rawAction == "backup" ? "备份数据库" : "恢复数据库内容")
    : file ? (rawAction == "trash" ? "移至废纸篓" : rawAction == "move" ? "移动文件" : rawAction == "write" ? "保存文本" : rawAction == "restore" ? "恢复文件" : rawAction == "createFile" ? "新建文本" : "创建目录")
    : package ? (rawAction == "install" ? "安装软件" : rawAction == "remove" ? "移除版本" : rawAction == "pin" ? "固定软件版本" : rawAction == "upgrade" ? "升级软件" : rawAction == "restore" ? "恢复软件固定状态" : "解除版本固定")
    : (rawAction == "start" ? "启动" : rawAction == "stop" ? "停止" : rawAction == "remove" ? "移除" : "重启") + (container ? "容器" : "")
guard package || service || container || file || database, let authorization = reqauth(id, label) else {
    FileHandle.standardError.write(Data("Native authorization was not completed\n".utf8))
    exit(64)
}
defer { AuthorizationFree(authorization, []) }
var form = AuthorizationExternalForm()
guard AuthorizationMakeExternalForm(authorization, &form) == errAuthorizationSuccess else { exit(1) }
let grant = withUnsafeBytes(of: form) { Data($0) }
// 仅向本机父进程管道交付一次性授权，不经过HTTP。
if ["service-grant", "package-grant", "container-grant", "file-grant", "database-grant"].contains(mode) {
    FileHandle.standardOutput.write(grant)
    // 保留授权引用直到父进程完成XPC请求并关闭管道。
    _ = try? FileHandle.standardInput.read(upToCount: 1)
    exit(0)
}
guard let action else { exit(64) }
let request = ServiceActionRequest(id: id, action: action, confirmation: id, authorization: grant)
let result = await PrivilegedXPCClient().actservice(request)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write((try encoder.encode(result)))
FileHandle.standardOutput.write(Data("\n".utf8))
exit(result.succeeded ? 0 : 1)
