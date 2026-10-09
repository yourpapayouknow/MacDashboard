// 描述允许目录内的一个文件条目。
public struct FileEntry: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let kind: String
    public let byteCount: UInt64
    public let modifiedAt: Date?
    public let permissions: UInt16
}

// 返回有界目录列表与采样范围。
public struct FileInventory: Codable, Equatable, Sendable {
    public let rootID: String
    public let path: String
    public let entries: [FileEntry]
    public let isComplete: Bool
    public let isWritable: Bool
}

// 返回有界文本预览，不读取设备或管道。
public struct FilePreview: Codable, Equatable, Sendable {
    public let rootID: String
    public let path: String
    public let byteCount: UInt64
    public let text: String?
    public let isComplete: Bool
    public let digest: String?
}

// 限制文件读取为既有目录并阻止路径与符号链接越界。
public struct FileReader: Sendable {
    private let roots: [FileRoot]
    private let trashdir: @Sendable (URL) throws -> URL
    private let trashfile: @Sendable (URL) throws -> URL

    /// Reuses the administrative inventory's fixed file roots.
    public init(roots: [FileRoot] = AdminReader().rdfiles()) {
        self.roots = roots
        trashdir = Self.trshdir
        trashfile = Self.trshfile
    }

    // 测试回收原语仅作用于独立临时目录。
    init(roots: [FileRoot], trashdir: @escaping @Sendable (URL) throws -> URL,
        trashfile: @escaping @Sendable (URL) throws -> URL) {
        self.roots = roots; self.trashdir = trashdir; self.trashfile = trashfile
    }

    // 查询当前文件所在卷的系统废纸篓，不创建目录。
    private static func trshdir(_ url: URL) throws -> URL {
        try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false)
    }

    // 保留系统处理同名冲突后返回的实际位置。
    private static func trshfile(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw FileReadError.changed }
        return result as URL
    }

    /// Lists up to 2000 entries without recursive traversal.
    public func rdlst(_ rootID: String, path: String = "") throws -> FileInventory {
        let url = try rslv(rootID, path)
        let fd = try opnfd(url, S_IFDIR)
        guard let directory = fdopendir(fd) else { close(fd); throw FileReadError.invalid }
        defer { closedir(directory) }
        var entries: [FileEntry] = []
        var complete = true
        while let item = readdir(directory) {
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard entries.count < 2000 else { complete = false; break }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { complete = false; continue }
            let type = info.st_mode & S_IFMT
            entries.append(FileEntry(name: name, path: path.isEmpty ? name : "\(path)/\(name)",
                kind: type == S_IFDIR ? "directory" : type == S_IFREG ? "file" : type == S_IFLNK ? "link" : "other",
                byteCount: UInt64(max(0, info.st_size)),
                modifiedAt: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)),
                permissions: UInt16(info.st_mode & 0o7777)))
        }
        return FileInventory(rootID: rootID, path: path, entries: entries.sorted { $0.name < $1.name }, isComplete: complete,
            isWritable: faccessat(fd, ".", W_OK | X_OK, AT_EACCESS) == 0)
    }

    /// Reads at most 256 KiB from a regular file.
    public func rdtxt(_ rootID: String, path: String) throws -> FilePreview {
        let url = try rslv(rootID, path)
        let fd = try opnfd(url, S_IFREG)
        var info = stat()
        guard fstat(fd, &info) == 0 else { close(fd); throw FileReadError.invalid }
        let size = UInt64(max(0, info.st_size))
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 262144) ?? Data()
        var text = data.contains(0) ? nil : String(data: data, encoding: .utf8)
        // 截断预览时保留完整的末尾字符。
        if text == nil, !data.isEmpty, !data.contains(0), size > UInt64(data.count) {
            for trim in 1...min(3, data.count) {
                if let prefix = String(data: data.dropLast(trim), encoding: .utf8) { text = prefix; break }
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, info.st_size == after.st_size,
              info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw FileReadError.changed }
        let complete = size <= UInt64(data.count)
        let digest = complete && text != nil && info.st_uid == geteuid() && info.st_nlink == 1
            && info.st_mode & S_IWUSR != 0 && info.st_mode & 0o7000 == 0 ? FileController.txtdgt(data) : nil
        return FilePreview(rootID: rootID, path: path, byteCount: size,
            text: text, isComplete: complete, digest: digest)
    }

    // 完整读取32MiB以内的普通文件，拒绝读取期间发生的变化。
    public func rddwn(_ rootID: String, path: String, limit: Int = 32 * 1_024 * 1_024) throws -> Data {
        guard (1...33_554_432).contains(limit) else { throw FileReadError.invalid }
        let fd = try opnfd(try rslv(rootID, path), S_IFREG)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_size >= 0 else { throw FileReadError.invalid }
        guard before.st_size <= limit else { throw FileReadError.oversized }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        while let part = try handle.read(upToCount: min(65_536, limit + 1 - data.count)), !part.isEmpty {
            data.append(part)
            guard data.count <= limit else { throw FileReadError.oversized }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              after.st_size == data.count, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw FileReadError.changed }
        return data
    }

    // 验证已存在的可写父目录并确认目标尚不存在。
    func prmkdir(_ rootID: String, path: String) throws -> DirectorySnapshot {
        let snapshot = try prparent(rootID, path: path)
        let descriptor = try opnfd(snapshot.parentPath, S_IFDIR)
        defer { close(descriptor) }
        var child = stat()
        guard fstatat(descriptor, snapshot.name, &child, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else {
            throw FileReadError.changed
        }
        return snapshot
    }

    // 复用固定根目录和有效用户权限解析父目录。
    private func prparent(_ rootID: String, path: String) throws -> DirectorySnapshot {
        guard roots.contains(where: { $0.id == rootID && $0.isAvailable && $0.isWritable }),
              FileController.validpath(path) else { throw FileReadError.forbidden }
        let parts = path.split(separator: "/")
        let name = String(parts.last!)
        let parent = try rslv(rootID, parts.dropLast().joined(separator: "/"))
        let descriptor = try opnfd(parent, S_IFDIR)
        defer { close(descriptor) }
        guard faccessat(descriptor, ".", W_OK | X_OK, AT_EACCESS) == 0 else { throw FileReadError.forbidden }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw FileReadError.invalid }
        return DirectorySnapshot(rootID: rootID, relativePath: path, parentPath: parent, name: name,
            device: info.st_dev, inode: info.st_ino)
    }

    // 核对普通源文件及同卷不存在目标。
    func prmv(_ rootID: String, path: String, destinationRoot: String, destinationPath: String) throws -> MoveSnapshot {
        let source = try prparent(rootID, path: path)
        let destination = try prmkdir(destinationRoot, path: destinationPath)
        let identity = try rdid(source)
        guard identity.device == destination.device else { throw FileReadError.forbidden }
        return MoveSnapshot(source: source, destination: destination, identity: identity)
    }

    // 回收仅限所有者的单链接普通文件，拒绝特殊权限。
    func trshid(_ snapshot: DirectorySnapshot) throws -> FileIdentity {
        let identity = try rdid(snapshot)
        let parent = try opnfd(snapshot.parentPath, S_IFDIR)
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, snapshot.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_nlink == 1, info.st_mode & 0o7000 == 0, try rdid(snapshot) == identity else { throw FileReadError.forbidden }
        return identity
    }

    // 冻结源文件与已存在的同卷系统废纸篓身份。
    func prtrsh(_ rootID: String, path: String) throws -> TrashSnapshot {
        let source = try prparent(rootID, path: path)
        let identity = try trshid(source)
        let directory = try trashdir(URL(fileURLWithPath: source.parentPath).appendingPathComponent(source.name))
        guard let actual = realpath(directory.path, nil) else { throw FileReadError.forbidden }
        defer { free(actual) }
        let trashPath = String(cString: actual)
        guard source.parentPath != trashPath, !source.parentPath.hasPrefix(trashPath + "/") else { throw FileReadError.forbidden }
        let receiptID = UUID()
        for root in roots where root.isAvailable && root.isWritable {
            guard let base = try? rslv(root.id, ""), trashPath.hasPrefix(base + "/") else { continue }
            let relative = String(trashPath.dropFirst(base.count + 1)) + "/" + receiptID.uuidString
            let trash = try prmkdir(root.id, path: relative)
            guard trash.device == identity.device else { throw FileReadError.forbidden }
            return TrashSnapshot(source: source, identity: identity, trash: trash, receiptID: receiptID)
        }
        throw FileReadError.forbidden
    }

    // 原生回收后核对实际位置与身份，回执成功落盘才报告完成。
    func trsh(_ snapshot: TrashSnapshot) throws -> MoveSnapshot {
        guard try prparent(snapshot.source.rootID, path: snapshot.source.relativePath) == snapshot.source,
              try trshid(snapshot.source) == snapshot.identity,
              try prmkdir(snapshot.trash.rootID, path: snapshot.trash.relativePath) == snapshot.trash else { throw FileReadError.changed }
        let sourceURL = URL(fileURLWithPath: snapshot.source.parentPath).appendingPathComponent(snapshot.source.name)
        let result = try trashfile(sourceURL)
        guard result.isFileURL, let parentPath = realpath(result.deletingLastPathComponent().path, nil) else { throw FileReadError.changed }
        defer { free(parentPath) }
        guard String(cString: parentPath) == snapshot.trash.parentPath else { throw FileReadError.changed }
        let relative = snapshot.trash.relativePath.split(separator: "/").dropLast().joined(separator: "/") + "/" + result.lastPathComponent
        let destination = try prparent(snapshot.trash.rootID, path: relative)
        guard destination.parentPath == snapshot.trash.parentPath, destination.device == snapshot.trash.device,
              destination.inode == snapshot.trash.inode, try trshid(destination) == snapshot.identity else { throw FileReadError.changed }
        let parent = try opnfd(snapshot.source.parentPath, S_IFDIR)
        defer { close(parent) }
        var info = stat()
        var parentInfo = stat()
        guard fstat(parent, &parentInfo) == 0, parentInfo.st_dev == snapshot.source.device, parentInfo.st_ino == snapshot.source.inode,
              fstatat(parent, snapshot.source.name, &info, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else { throw FileReadError.changed }
        return MoveSnapshot(source: snapshot.source, destination: destination, identity: snapshot.identity)
    }

    // 数据库复用固定根与文件身份，拒绝硬链接和危险旁路文件。
    func prdb(_ rootID: String, path: String) throws -> (DirectorySnapshot, FileIdentity) {
        let source = try prparent(rootID, path: path)
        let identity = try rdid(source)
        let parent = try opnfd(source.parentPath, S_IFDIR)
        defer { close(parent) }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            var info = stat()
            let status = fstatat(parent, source.name + suffix, &info, AT_SYMLINK_NOFOLLOW)
            if status == -1 && errno == ENOENT && !suffix.isEmpty { continue }
            guard status == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
                  info.st_size >= 0, info.st_size <= 33_554_432 else { throw FileReadError.forbidden }
        }
        return (source, identity)
    }

    // 使用不跟随链接的目录项核对源文件所有者和身份。
    private func rdid(_ snapshot: DirectorySnapshot) throws -> FileIdentity {
        let descriptor = try opnfd(snapshot.parentPath, S_IFDIR)
        defer { close(descriptor) }
        var parent = stat()
        var info = stat()
        guard fstat(descriptor, &parent) == 0, parent.st_dev == snapshot.device, parent.st_ino == snapshot.inode,
              fstatat(descriptor, snapshot.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_size >= 0 else { throw FileReadError.changed }
        return FileIdentity(device: info.st_dev, inode: info.st_ino, byteCount: info.st_size,
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            permissions: UInt16(info.st_mode & 0o7777))
    }

    // 完整文本和预览摘要必须与同一所有者文件匹配。
    func prtxt(_ rootID: String, path: String, digest: String, replacement: Data) throws -> TextSnapshot {
        guard FileController.validdgt(digest), FileController.validtxt(replacement) else { throw FileReadError.invalid }
        let source = try prparent(rootID, path: path)
        let identity = try rdid(source)
        guard identity.byteCount <= 262_144, identity.permissions & 0o7000 == 0 else { throw FileReadError.forbidden }
        let descriptor = try opnfd(source.parentPath, S_IFDIR)
        defer { close(descriptor) }
        var info = stat()
        guard fstatat(descriptor, source.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_nlink == 1, info.st_mode & S_IWUSR != 0 else { throw FileReadError.forbidden }
        let data = try rddwn(rootID, path: path, limit: 262_144)
        guard FileController.validtxt(data), FileController.txtdgt(data) == digest.lowercased(),
              try rdid(source) == identity else { throw FileReadError.changed }
        return TextSnapshot(source: source, identity: identity, data: data, writtenDigest: FileController.txtdgt(replacement))
    }

    // 独占描述符下核对内容后原位写入，保留inode和既有元数据。
    func wrtxt(_ snapshot: TextSnapshot, replacement: Data) throws {
        guard try prtxt(snapshot.source.rootID, path: snapshot.source.relativePath,
            digest: FileController.txtdgt(snapshot.data), replacement: replacement) == snapshot else { throw FileReadError.changed }
        let parent = try opnfd(snapshot.source.parentPath, S_IFDIR)
        defer { close(parent) }
        let descriptor = openat(parent, snapshot.source.name, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_EXLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_dev == snapshot.identity.device, info.st_ino == snapshot.identity.inode,
              info.st_size == snapshot.identity.byteCount, UInt16(info.st_mode & 0o7777) == snapshot.identity.permissions,
              try (handle.read(upToCount: 262_145) ?? Data()) == snapshot.data, try rdid(snapshot.source) == snapshot.identity else {
            throw FileReadError.changed
        }
        do {
            try flshtxt(handle, data: replacement)
        } catch {
            try? flshtxt(handle, data: snapshot.data)
            throw error
        }
        try handle.seek(toOffset: 0)
        guard try (handle.read(upToCount: 262_145) ?? Data()) == replacement, fstat(descriptor, &info) == 0,
              info.st_dev == snapshot.identity.device, info.st_ino == snapshot.identity.inode,
              info.st_size == replacement.count,
              UInt16(info.st_mode & 0o7777) == snapshot.identity.permissions,
              try rdid(snapshot.source).inode == snapshot.identity.inode else { throw FileReadError.changed }
    }

    // 保存或失败回退共用完整写入、精确长度与磁盘同步。
    private func flshtxt(_ handle: FileHandle, data: Data) throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
        guard ftruncate(handle.fileDescriptor, off_t(data.count)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try handle.synchronize()
    }

    // 排他原子移动拒绝覆盖，移动后再次验证文件身份。
    func mv(_ snapshot: MoveSnapshot) throws {
        guard try prmv(snapshot.source.rootID, path: snapshot.source.relativePath,
            destinationRoot: snapshot.destination.rootID, destinationPath: snapshot.destination.relativePath) == snapshot else {
            throw FileReadError.changed
        }
        let source = try opnfd(snapshot.source.parentPath, S_IFDIR)
        defer { close(source) }
        let destination = try opnfd(snapshot.destination.parentPath, S_IFDIR)
        defer { close(destination) }
        var left = stat()
        var right = stat()
        guard fstat(source, &left) == 0, left.st_dev == snapshot.source.device, left.st_ino == snapshot.source.inode,
              fstat(destination, &right) == 0, right.st_dev == snapshot.destination.device, right.st_ino == snapshot.destination.inode,
              try rdid(snapshot.source) == snapshot.identity else { throw FileReadError.changed }
        guard renameatx_np(source, snapshot.source.name, destination, snapshot.destination.name, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard try rdid(snapshot.destination) == snapshot.identity else { throw FileReadError.changed }
    }

    // 排他创建普通文本，完整保存和回读复用现有写入流程。
    func mkfile(_ snapshot: DirectorySnapshot, content: Data) throws {
        guard FileController.validtxt(content), try prmkdir(snapshot.rootID, path: snapshot.relativePath) == snapshot else {
            throw FileReadError.changed
        }
        let parent = try opnfd(snapshot.parentPath, S_IFDIR)
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_dev == snapshot.device, info.st_ino == snapshot.inode else {
            throw FileReadError.changed
        }
        let descriptor = openat(parent, snapshot.name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try flshtxt(handle, data: content)
        try handle.seek(toOffset: 0)
        guard try (handle.read(upToCount: 262_145) ?? Data()) == content, fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_size == content.count, info.st_mode & 0o7777 == 0o600,
              try rdid(snapshot).inode == info.st_ino else { throw FileReadError.changed }
    }

    // 重新核对根内父目录身份，mkdirat拒绝已存在目标。
    func mkdir(_ snapshot: DirectorySnapshot) throws {
        guard try prmkdir(snapshot.rootID, path: snapshot.relativePath) == snapshot else { throw FileReadError.changed }
        let descriptor = try opnfd(snapshot.parentPath, S_IFDIR)
        defer { close(descriptor) }
        var parent = stat()
        guard fstat(descriptor, &parent) == 0, parent.st_dev == snapshot.device, parent.st_ino == snapshot.inode else {
            throw FileReadError.changed
        }
        guard mkdirat(descriptor, snapshot.name, S_IRWXU) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var created = stat()
        guard fstatat(descriptor, snapshot.name, &created, AT_SYMLINK_NOFOLLOW) == 0,
              created.st_mode & S_IFMT == S_IFDIR, created.st_uid == geteuid() else { throw FileReadError.changed }
    }

    // 打开时拒绝全部符号链接并验证实际文件类型。
    private func opnfd(_ path: String, _ type: mode_t) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw FileReadError.forbidden }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == type else {
            close(fd)
            throw FileReadError.invalid
        }
        return fd
    }

    /// Resolves only relative paths contained by their selected canonical root.
    private func rslv(_ rootID: String, _ path: String) throws -> String {
        guard let root = roots.first(where: { $0.id == rootID && $0.isAvailable }),
              !path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096,
              !path.split(separator: "/").contains("..") else { throw FileReadError.forbidden }
        guard let rootPath = realpath(root.path, nil) else { throw FileReadError.forbidden }
        defer { free(rootPath) }
        let base = String(cString: rootPath)
        guard let selected = realpath(base + "/" + path, nil) else { throw FileReadError.forbidden }
        defer { free(selected) }
        let resolved = String(cString: selected)
        guard resolved == base || resolved.hasPrefix(base + "/") else { throw FileReadError.forbidden }
        return resolved
    }
}

// 区分越界请求与不支持的文件类型。
public enum FileReadError: Error, Equatable { case forbidden, invalid, oversized, changed }
