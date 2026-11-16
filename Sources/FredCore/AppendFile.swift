import Foundation

/// The write side of Fred's append-only logs (learning, clipboard).
///
/// - O_APPEND: every write lands at the current end of file.
/// - Mode 0600: the logs hold clipboard text and what you search for.
/// - A write that fails part-way (disk full) is cut back off, so a torn record never sits
///   in front of later appends — the reader stops at the first bad record, and anything
///   behind it would be lost at the next launch.
final class AppendFile {
    private let fd: Int32

    /// Opens (creating if needed) `url` and cuts it to `validLength` bytes when given:
    /// callers pass the end of the last record they could parse.
    init?(_ url: URL, validLength: Int? = nil) {
        fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        fchmod(fd, 0o600)
        if let n = validLength { ftruncate(fd, off_t(n)) }
    }

    deinit { close(fd) }

    func append(_ d: Data) {
        let end = lseek(fd, 0, SEEK_END)
        let n = d.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
        if n != d.count && end >= 0 { ftruncate(fd, end) }
    }

    func sync() { fsync(fd) }

    /// A log whose header isn't the one this build writes (another format version, or
    /// not a Fred log at all) is moved aside, never overwritten: a newer Fred's data
    /// survives an older build, and nothing is silently lost.
    /// Returns true when the file is absent, empty, or starts with `header`.
    static func claim(_ url: URL, header: [UInt8]) -> Bool {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return true }
        let head = (try? h.read(upToCount: header.count)) ?? Data()
        try? h.close()
        if head.isEmpty || Array(head) == header { return true }
        if head.count < header.count, header.starts(with: head) { return true }   // torn header
        let aside = url.appendingPathExtension("unrecognized-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: aside)
        return false
    }
}
