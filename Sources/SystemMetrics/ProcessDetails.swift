// 描述进程可读取的普通文件句柄。
public struct ProcessFile: Codable, Equatable, Sendable {
    public let descriptor: Int32
    public let path: String
}

// 返回进程启动时间、套接字数量与文件读取边界。
public struct ProcessDetail: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let pid: Int32
    public let startedAt: Date?
    public let socketCount: Int?
    public let files: [ProcessFile]
    public let isAvailable: Bool
    public let isComplete: Bool
}

// 通过libproc读取单个进程，限制句柄枚举数量。
extension ProcessReader {
    /// Reads native process details without opening submitted file paths.
    public func rddtl(_ pid: Int32) -> ProcessDetail {
        let now = Date()
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else {
            return ProcessDetail(sampledAt: now, pid: pid, startedAt: nil, socketCount: nil,
                files: [], isAvailable: false, isComplete: false)
        }
        let started = Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1_000_000)
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        let stride = MemoryLayout<proc_fdinfo>.stride
        let capacity = min(4096, max(32, Int(max(0, needed)) / stride + 32))
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let bytes = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard needed >= 0, bytes >= 0 else {
            return ProcessDetail(sampledAt: now, pid: pid, startedAt: started, socketCount: nil,
                files: [], isAvailable: true, isComplete: false)
        }
        var complete = bytes < capacity * stride && needed < capacity * stride
        var sockets = 0
        var files: [ProcessFile] = []
        for descriptor in descriptors.prefix(Int(bytes) / stride) {
            if descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) { sockets += 1 }
            guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
            var vnode = vnode_fdinfowithpath()
            let vnodeSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, vnodeSize) == vnodeSize else {
                complete = false
                continue
            }
            let path = withUnsafeBytes(of: &vnode.pvip.vip_path) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if !path.isEmpty { files.append(ProcessFile(descriptor: descriptor.proc_fd, path: path)) }
        }
        return ProcessDetail(sampledAt: now, pid: pid, startedAt: started, socketCount: sockets,
            files: files, isAvailable: true, isComplete: complete)
    }
}
