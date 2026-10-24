import Foundation
import Darwin

/// One budget covers a complete scan, including unrelated directory entries.
/// Limits are injectable so tests exercise the boundary with tiny synthetic data.
public final class BoundedInput {
    public struct Limits {
        public var fileBytes = 64 * 1024 * 1024
        public var jsonBytes = 8 * 1024 * 1024
        public var lineBytes = 1024 * 1024
        public var totalBytes = 256 * 1024 * 1024
        public var entries = 20_000
        public var files = 5_000
        public var seconds: TimeInterval = 15
        public var databaseBytes = 256 * 1024 * 1024
        public var sqliteSteps = 1_000_000
        public init() {}
    }

    public enum Failure: LocalizedError {
        case limit, file, encoding, database
        public var errorDescription: String? {
            switch self {
            case .limit: return "読込量または処理時間の上限に達しました。対象ログを小さくして再試行してください"
            case .file: return "通常ファイルを読み込めませんでした"
            case .encoding: return "ログの文字コードを読み込めませんでした"
            case .database: return "Windsurf DBの形式が不正か、読込予算を超えています"
            }
        }
    }

    public let limits: Limits
    private let deadline: TimeInterval
    private let cancelled: () -> Bool
    private var byteCount = 0
    private var entryCount = 0
    private var fileCount = 0

    public init(limits: Limits = Limits(), cancelled: @escaping () -> Bool = { Task.isCancelled }) {
        self.limits = limits
        self.cancelled = cancelled
        self.deadline = ProcessInfo.processInfo.systemUptime + limits.seconds
    }

    public func check() throws {
        if cancelled() { throw CancellationError() }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.limit }
    }

    public func files(
        at root: URL,
        includeHidden: Bool = false,
        allowedHiddenNames: Set<String> = []
    ) throws -> [URL] {
        try check()
        var info = stat()
        if Darwin.lstat(root.path, &info) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return [] }
            throw Failure.file
        }
        let mode = info.st_mode & S_IFMT
        if mode == S_IFREG { return [root] }
        guard mode == S_IFDIR else { throw Failure.file }
        var failure: Error?
        guard let iterator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey],
            options: [],
            errorHandler: { _, _ in failure = Failure.file; return false }
        ) else { throw Failure.file }
        var result: [URL] = []
        while let url = iterator.nextObject() as? URL {
            try check()
            guard entryCount < limits.entries else { throw Failure.limit }
            entryCount += 1
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey])
            if properties.isSymbolicLink == true {
                iterator.skipDescendants()
                continue
            }
            if properties.isHidden == true && !includeHidden && !allowedHiddenNames.contains(url.lastPathComponent) {
                iterator.skipDescendants()
                continue
            }
            if properties.isRegularFile == true { result.append(url) }
        }
        try check()
        if let failure { throw failure }
        return result
    }

    // O_NONBLOCK prevents FIFOs/devices from hanging before fstat can reject them.
    // fstat validates the opened object, not a racy path metadata check.
    public func openRegular(_ url: URL, maximum: Int) throws -> FileHandle {
        try check()
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.file }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw Failure.file
        }
        guard info.st_size >= 0, info.st_size <= maximum, fileCount < limits.files else {
            Darwin.close(descriptor)
            throw Failure.limit
        }
        fileCount += 1
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func read(_ handle: FileHandle, consumed: inout Int, maximum: Int) throws -> Data {
        try check()
        let chunk = try handle.read(upToCount: 32 * 1024) ?? Data()
        guard chunk.count <= maximum - consumed, chunk.count <= limits.totalBytes - byteCount else {
            throw Failure.limit
        }
        consumed += chunk.count
        byteCount += chunk.count
        return chunk
    }

    public func data(at url: URL) throws -> Data {
        let maximum = min(limits.fileBytes, limits.jsonBytes)
        let handle = try openRegular(url, maximum: maximum)
        defer { try? handle.close() }
        var consumed = 0
        var result = Data()
        while true {
            let chunk = try read(handle, consumed: &consumed, maximum: maximum)
            if chunk.isEmpty { break }
            result.append(chunk)
        }
        return result
    }

    public func dataIfPresent(at url: URL) throws -> Data? {
        try check()
        var info = stat()
        if Darwin.lstat(url.path, &info) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw Failure.file
        }
        return try data(at: url)
    }

    public static func writeRegularFileAtomically(_ data: Data, to destination: URL) throws {
        var destInfo = stat()
        if Darwin.lstat(destination.path, &destInfo) == 0 {
            guard (destInfo.st_mode & S_IFMT) == S_IFREG else {
                throw Failure.file
            }
        } else if errno != ENOENT {
            throw Failure.file
        }

        let directory = destination.deletingLastPathComponent()
        var dirInfo = stat()
        guard Darwin.lstat(directory.path, &dirInfo) == 0,
              (dirInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw Failure.file
        }

        let tempURL = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.file }
        var closed = false
        defer {
            if !closed { Darwin.close(descriptor) }
            Darwin.unlink(tempURL.path)
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else { throw Failure.file }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: written), rawBuffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Failure.file
                }
                guard count > 0 else { throw Failure.file }
                written += count
            }
        }

        guard Darwin.fsync(descriptor) == 0 else { throw Failure.file }
        closed = true
        guard Darwin.close(descriptor) == 0 else { throw Failure.file }
        guard Darwin.rename(tempURL.path, destination.path) == 0 else { throw Failure.file }
    }

    /// Copy from the checked descriptor into a private file, never reopen the
    /// untrusted pathname after validation. Used for SQLite's path-based API.
    public func copyRegularFile(at source: URL, to destination: URL, maximum: Int) throws {
        let sourceHandle = try openRegular(source, maximum: maximum)
        defer { try? sourceHandle.close() }
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.file }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        var consumed = 0
        while true {
            let chunk = try read(sourceHandle, consumed: &consumed, maximum: maximum)
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
        }
        try check()
    }

    public func lines(at url: URL, body: (String) throws -> Void) throws {
        let handle = try openRegular(url, maximum: limits.fileBytes)
        defer { try? handle.close() }
        var consumed = 0
        var pending = Data()
        func deliver(_ bytes: Data) throws {
            try check()
            guard bytes.count <= limits.lineBytes else { throw Failure.limit }
            guard let line = String(data: bytes, encoding: .utf8) else { throw Failure.encoding }
            try body(line)
        }
        while true {
            let chunk = try read(handle, consumed: &consumed, maximum: limits.fileBytes)
            if chunk.isEmpty { break }
            pending.append(chunk)
            var start = pending.startIndex
            while let end = pending[start...].firstIndex(of: 10) {
                try deliver(pending.subdata(in: start..<end))
                start = end + 1
            }
            if start > pending.startIndex { pending = Data(pending[start...]) }
            guard pending.count <= limits.lineBytes else { throw Failure.limit }
        }
        if !pending.isEmpty { try deliver(pending) }
    }
}
