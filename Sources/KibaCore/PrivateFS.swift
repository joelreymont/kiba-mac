import Foundation

/// Private files and directories: files are 0600 and replaced by temp + rename,
/// directories are created 0700. Every failure throws with the path involved.
public enum PrivateFS {
    /// Mode of every file written here.
    static let fileMode: mode_t = 0o600
    /// Mode of every directory created here.
    static let dirMode: mode_t = 0o700
    /// Longest symlink chain followed to a write target.
    static let maxHops = 8
    /// Suffix of the temp file written beside its target, and the base its random part is spelled in.
    static let tmpSuffix = ".tmp"
    static let tmpRadix = 16
    /// The temp file is created fresh, never through a link, never inherited by a child.
    static let tmpFlags = O_WRONLY | O_CREAT | O_TRUNC | O_EXCL | O_NOFOLLOW | O_CLOEXEC
    /// Files are read through links, never inherited by a child, in chunks of this many bytes.
    static let readFlags = O_RDONLY | O_CLOEXEC
    static let readChunk = 1 << 16
    /// Directories are walked without following links.
    static let dirFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    /// The entries every directory lists for itself and its parent.
    static let dotName = Array(".".utf8)
    static let dotDotName = Array("..".utf8)

    /// Replaces the file behind `url` (after its symlink chain) with `data`, mode 0600.
    /// The temp beside the target has a random name, so concurrent writers never
    /// share one.
    public static func writePrivate(_ data: Data, to url: URL) throws {
        let target = try writeTarget(url).path
        let tmp = "\(target).\(String(UInt64.random(in: .min ... .max), radix: tmpRadix))\(tmpSuffix)"
        let fd = open(tmp, tmpFlags, fileMode)
        guard fd >= 0 else { throw KibaError.io(failure("open", tmp)) }
        var errs: [String] = []
        if let err = fill(fd, data, tmp) { errs.append(err) }
        if close(fd) != 0 { errs.append(failure("close", tmp)) }
        if errs.isEmpty, rename(tmp, target) != 0 { errs.append(failure("rename", tmp)) }
        guard errs.isEmpty else {
            if unlink(tmp) != 0 { errs.append(failure("unlink", tmp)) }
            throw KibaError.io(errs.joined(separator: "; "))
        }
    }

    /// Creates `url` and any missing ancestors with mode 0700; existing directories,
    /// including links to directories, are left as they are. Works like `mkdir -p`:
    /// finds the deepest path prefix that is a directory, then creates each one below.
    public static func ensurePrivateDir(_ url: URL) throws {
        let path = url.path
        let lead = path.hasPrefix("/") ? "/" : ""
        let parts = path.split(separator: "/")
        func prefix(_ n: Int) -> String { lead + parts[..<n].joined(separator: "/") }
        var have = parts.count
        while have > 0, try !makeDir(prefix(have)) { have -= 1 }
        while have < parts.count {
            have += 1
            guard try makeDir(prefix(have)) else { throw KibaError.io(failure("mkdir", prefix(have), ENOENT)) }
        }
    }

    /// Removes `url` and everything under it without following any link; a link is
    /// removed itself. Nothing to do when `url` does not exist. A path ending in `.`
    /// or `..` names no entry of its own and is refused.
    public static func removeTree(_ url: URL) throws {
        let path = url.path
        let leaf = path.split(separator: "/", omittingEmptySubsequences: false).last ?? ""
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { throw KibaError.io(failure("remove", path, EINVAL)) }
        try remove(AT_FDCWD, path, path)
    }

    /// The file a write to `url` replaces: `url` with its symlink chain followed for at
    /// most 8 hops. Relative link targets resolve against the link's directory.
    public static func writeTarget(_ url: URL) throws -> URL {
        var path = url.path
        var hops = 0
        while try kind(AT_FDCWD, path, path) == S_IFLNK {
            guard hops < maxHops else { throw KibaError.unsafePath(url) }
            path = try follow(path)
            hops += 1
        }
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    /// The whole file at `url`, following links; nil when it does not exist.
    static func read(_ url: URL) throws -> Data? {
        let path = url.path
        let fd = open(path, readFlags)
        guard fd >= 0 else {
            guard errno == ENOENT else { throw KibaError.io(failure("open", path)) }
            return nil
        }
        // A read-only descriptor holds no data, so closing it cannot fail in a way that matters.
        defer { close(fd) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: readChunk)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n > 0 {
                out.append(contentsOf: buf[..<n])
            } else if n == 0 {
                return out
            } else if errno != EINTR {
                throw KibaError.io(failure("read", path))
            }
        }
    }

    /// Whether `url` is a regular file, following links.
    public static func exists(_ url: URL) -> Bool { mode(url.path) == S_IFREG }

    /// Whether `url` is a directory, following links.
    public static func isDir(_ url: URL) -> Bool { mode(url.path) == S_IFDIR }

    /// `op path: reason` for the system call that just failed with `code`.
    static func failure(_ op: String, _ path: String, _ code: Int32 = errno) -> String {
        "\(op) \(path): \(String(cString: strerror(code)))"
    }

    /// File type of `path`, following links; nil when it cannot be read.
    static func mode(_ path: String) -> mode_t? {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_mode & S_IFMT : nil
    }

    /// File type of `name` under the directory `at`, not following a final link;
    /// nil when it does not exist. A symlink loop on the way is `unsafePath`. `shown`
    /// names it in errors.
    static func kind(_ at: Int32, _ name: UnsafePointer<CChar>, _ shown: String) throws -> mode_t? {
        var st = stat()
        guard fstatat(at, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            switch errno {
            case ENOENT: return nil
            case ELOOP: throw KibaError.unsafePath(URL(fileURLWithPath: shown, isDirectory: false))
            default: throw KibaError.io(failure("lstat", shown))
            }
        }
        return st.st_mode & S_IFMT
    }

    /// Writes all of `data` to the fresh temp `fd`, forces mode 0600 whatever the umask,
    /// and flushes it to disk. Returns the failure, or nil.
    static func fill(_ fd: Int32, _ data: Data, _ tmp: String) -> String? {
        guard fchmod(fd, fileMode) == 0 else { return failure("chmod", tmp) }
        let err: String? = data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n >= 0 {
                    off += n
                } else if errno != EINTR {
                    return failure("write", tmp)
                }
            }
            return nil
        }
        if let err { return err }
        return fsync(fd) == 0 ? nil : failure("fsync", tmp)
    }

    /// The path the link at `path` points to; a relative target is joined to the link's
    /// directory as is, so the kernel resolves `..` through the real directory. A
    /// target that is not UTF-8 cannot be named and is refused.
    static func follow(_ path: String) throws -> String {
        let cap = Int(PATH_MAX)
        let dest = try withUnsafeTemporaryAllocation(of: CChar.self, capacity: cap) { buf in
            let n = readlink(path, buf.baseAddress!, cap)
            guard n >= 0 else { throw KibaError.io(failure("readlink", path)) }
            guard n < cap else { throw KibaError.io(failure("readlink", path, ENAMETOOLONG)) }
            let raw = UnsafeRawBufferPointer(start: buf.baseAddress!, count: n)
            let text = String(decoding: raw, as: UTF8.self)
            guard text.utf8.elementsEqual(raw) else { throw KibaError.io(failure("readlink", path, EILSEQ)) }
            return text
        }
        guard !dest.hasPrefix("/"), let cut = path.lastIndex(of: "/") else { return dest }
        return path[...cut] + dest
    }

    /// Makes one directory 0700. True when `path` now is a directory, false when its
    /// parent is missing.
    static func makeDir(_ path: String) throws -> Bool {
        if mkdir(path, dirMode) == 0 {
            guard fchmodat(AT_FDCWD, path, dirMode, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw KibaError.io(failure("chmod", path))
            }
            return true
        }
        switch errno {
        case EEXIST:
            guard mode(path) == S_IFDIR else { throw KibaError.io(failure("mkdir", path, ENOTDIR)) }
            return true
        case ENOENT:
            return false
        case let code:
            throw KibaError.io(failure("mkdir", path, code))
        }
    }

    /// Removes `name` under the directory `at`: a directory with its contents, anything
    /// else (links included) as a single entry.
    static func remove(_ at: Int32, _ name: UnsafePointer<CChar>, _ shown: String) throws {
        guard let type = try kind(at, name, shown) else { return }
        let isDir = type == S_IFDIR
        if isDir { try empty(at, name, shown) }
        guard unlinkat(at, name, isDir ? AT_REMOVEDIR : 0) == 0 else {
            throw KibaError.io(failure(isDir ? "rmdir" : "unlink", shown))
        }
    }

    /// Removes everything inside the directory `name` under `at`, never following a link.
    /// Entries are removed by their raw name bytes.
    static func empty(_ at: Int32, _ name: UnsafePointer<CChar>, _ shown: String) throws {
        let fd = openat(at, name, dirFlags)
        guard fd >= 0 else { throw KibaError.io(failure("open", shown)) }
        guard let dir = fdopendir(fd) else {
            let err = failure("opendir", shown)
            close(fd)
            throw KibaError.io(err)
        }
        // A read-only directory handle holds no data, so closing it cannot fail in a way that matters.
        defer { closedir(dir) }
        var names: [[UInt8]] = []
        while true {
            errno = 0
            guard let ent = readdir(dir) else {
                guard errno == 0 else { throw KibaError.io(failure("readdir", shown)) }
                break
            }
            let len = Int(ent.pointee.d_namlen)
            let entry = withUnsafeBytes(of: &ent.pointee.d_name) { Array($0.prefix(len)) }
            if entry != dotName && entry != dotDotName { names.append(entry + [0]) }
        }
        for entry in names {
            let shownEntry = shown + "/" + String(decoding: entry.dropLast(), as: UTF8.self)
            try entry.withUnsafeBytes { raw in
                try remove(fd, raw.baseAddress!.assumingMemoryBound(to: CChar.self), shownEntry)
            }
        }
    }
}
