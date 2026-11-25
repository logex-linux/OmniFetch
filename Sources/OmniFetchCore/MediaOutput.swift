import CryptoKit
import Darwin
import Foundation

/// Keep external-engine partials away from finished files. The directory lock
/// also excludes a second task/process trying to resume the very same inputs.
final class MediaOutput: Sendable {
    let staging: URL
    private let parent: URL
    private let name: String
    private let lockFD: Int32

    init(_ request: DownloadRequest) throws {
        parent = request.destinationDirectory.standardizedFileURL
        name = MediaNaming.sanitize(request.baseName)
        let source = request.info.extra["webpage"] ?? request.info.extra["noteID"]
            ?? request.info.files.first?.url.absoluteString ?? ""
        let key = [request.info.engineID, source, name, request.options.quality,
                   request.options.formatID ?? "", String(request.options.audioOnly)].joined(separator: "\u{0}")
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        staging = parent.appendingPathComponent(".omnifetch-\(hash).part", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let fd = open(staging.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw EngineError.probeFailed("相同内容正在下载")
        }
        // A competing writer may have published this directory between open and flock.
        var locked = stat()
        var current = stat()
        guard fstat(fd, &locked) == 0, lstat(staging.path, &current) == 0,
              locked.st_dev == current.st_dev, locked.st_ino == current.st_ino else {
            close(fd)
            throw EngineError.probeFailed("相同内容刚完成，请重试")
        }
        lockFD = fd
    }

    deinit { close(lockFD) }

    static func isCompleteFile(_ file: URL) -> Bool {
        let ext = file.pathExtension.lowercased()
        guard !["part", "ytdl", "omni-resume", "tmp"].contains(ext),
              !file.lastPathComponent.contains(".part-Frag"),
              let state = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        else { return false }
        return state.isRegularFile == true && state.isSymbolicLink != true && (state.fileSize ?? 0) > 0
    }

    func completedFile(at path: String) -> URL? {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.resolvingSymlinksInPath().path.hasPrefix(staging.resolvingSymlinksInPath().path + "/"),
              Self.isCompleteFile(file) else { return nil }
        return file
    }

    static func itemCount(in folder: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys:
            [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
        var count: Int64 = 0
        while let file = files?.nextObject() as? URL {
            if isCompleteFile(file) { count += 1 }
        }
        return count
    }

    func publishCollection(members: Set<URL>) throws -> URL {
        guard !members.isEmpty else { throw EngineError.emptyResult }
        let keep = Set(members.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        let fm = FileManager.default
        guard let all = fm.enumerator(at: staging, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            throw CocoaError(.fileReadNoPermission)
        }
        var found = 0
        while let path = all.nextObject() as? URL {
            let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { all.skipDescendants(); try fm.removeItem(at: path); continue }
            if values.isDirectory == false {
                if keep.contains(path.resolvingSymlinksInPath().standardizedFileURL.path) {
                    guard Self.isCompleteFile(path) else { throw EngineError.emptyResult }
                    found += 1
                } else { try fm.removeItem(at: path) }
            }
        }
        guard found == keep.count else { throw EngineError.emptyResult }
        return try moveToDestination(file: nil)
    }

    func publish(file: URL? = nil) throws -> URL {
        if let file {
            guard completedFile(at: file.path) != nil else { throw EngineError.emptyResult }
        } else {
            guard Self.itemCount(in: staging) > 0 else { throw EngineError.emptyResult }
        }
        return try moveToDestination(file: file)
    }

    private func moveToDestination(file: URL?) throws -> URL {
        let source = file ?? staging
        let ext = file.map { $0.pathExtension.isEmpty ? "" : "." + $0.pathExtension } ?? ""
        var i = 1
        while true {
            let suffix = i == 1 ? "" : " \(i)"
            let dest = parent.appendingPathComponent(name + suffix + ext, isDirectory: file == nil)
            if renamex_np(source.path, dest.path, UInt32(RENAME_EXCL)) == 0 {
                if file != nil { try? FileManager.default.removeItem(at: staging) }
                return dest
            }
            if errno == EEXIST || errno == ENOTEMPTY { i += 1; continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
