import Foundation

/// Runs a tool with posix_spawn, feeding stdin and draining stdout and stderr
/// together so no pipe fills while another is waited on. `Foundation.Process`
/// cannot start the child in a new session, which `security` needs to take a
/// secret on stdin.
public enum Subprocess {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data
    }

    /// Bytes read per `read` call.
    static let chunk = 1 << 16
    /// Status of a child killed by a signal: this plus the signal number, as shells report it.
    static let signalBase: Int32 = 128
    /// `waitpid` status layout: the low seven bits name the killing signal (0 for
    /// a normal exit), the next byte holds the exit status.
    static let sigBits: Int32 = 0o177
    static let exitShift: Int32 = 8
    static let exitBits: Int32 = 0xFF
    static let devNull = "/dev/null"
    static let pathSep: Character = ":"

    /// Runs `tool` with `args` and waits for it. `env` nil inherits this
    /// process's environment; `setsid` starts the child in a new session with
    /// no controlling terminal. The child inherits only its three standard
    /// streams; stdin is `/dev/null` when `stdin` is nil.
    public static func run(_ tool: URL, _ args: [String], stdin: Data?, env: [String: String]?, setsid: Bool) throws -> Result {
        var fds = Pipes(tool: tool.path)
        defer { fds.closeAll() }
        let input = try stdin.map { _ in try fds.make() }
        let out = try fds.make()
        let err = try fds.make()

        var acts: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&acts), "spawn", tool.path)
        defer { posix_spawn_file_actions_destroy(&acts) }
        if let input {
            try check(posix_spawn_file_actions_adddup2(&acts, input.read, STDIN_FILENO), "spawn", tool.path)
        } else {
            try check(posix_spawn_file_actions_addopen(&acts, STDIN_FILENO, devNull, O_RDONLY, 0), "spawn", tool.path)
        }
        try check(posix_spawn_file_actions_adddup2(&acts, out.write, STDOUT_FILENO), "spawn", tool.path)
        try check(posix_spawn_file_actions_adddup2(&acts, err.write, STDERR_FILENO), "spawn", tool.path)

        var attr: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attr), "spawn", tool.path)
        defer { posix_spawnattr_destroy(&attr) }
        var flags = Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        if setsid { flags |= Int32(POSIX_SPAWN_SETSID) }
        try check(posix_spawnattr_setflags(&attr, Int16(flags)), "spawn", tool.path)

        let vars = env ?? ProcessInfo.processInfo.environment
        let argv = ([tool.path] + args).map { strdup($0) } + [nil]
        let envp = vars.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid = pid_t()
        try check(posix_spawn(&pid, tool.path, &acts, &attr, argv, envp), "spawn", tool.path)

        if let input { try fds.close(input.read) }
        try fds.close(out.write)
        try fds.close(err.write)
        let drained: (Data, Data)
        do {
            drained = try pump(&fds, feed: input.map { ($0.write, stdin ?? Data()) }, out: out.read, err: err.read)
        } catch {
            kill(pid, SIGKILL)
            _ = try reap(pid, tool.path)
            throw error
        }
        return Result(status: try reap(pid, tool.path), stdout: drained.0, stderr: drained.1)
    }

    /// The first executable file named `name` in the `:`-separated `path`;
    /// nil when there is none, which callers report as `noCLI`.
    public static func find(_ name: String, path: String) -> URL? {
        for dir in path.split(separator: pathSep) where dir.hasPrefix("/") {
            let url = URL(fileURLWithPath: String(dir), isDirectory: true).appending(component: name, directoryHint: .notDirectory)
            if PrivateFS.exists(url), access(url.path, X_OK) == 0 { return url }
        }
        return nil
    }

    /// Writes `feed` to its pipe while reading `out` and `err` to their ends. A
    /// child that stops reading stdin ends the feed; the rest is dropped.
    static func pump(_ fds: inout Pipes, feed: (fd: Int32, data: Data)?, out: Int32, err: Int32) throws -> (Data, Data) {
        var inFD: Int32 = -1
        var sent = 0
        if let feed {
            inFD = feed.fd
            guard fcntl(inFD, F_SETNOSIGPIPE, 1) == 0, fcntl(inFD, F_SETFL, O_NONBLOCK) == 0 else {
                throw KibaError.io(PrivateFS.failure("fcntl", fds.tool))
            }
            if feed.data.isEmpty {
                try fds.close(inFD)
                inFD = -1
            }
        }
        var outFD = out, errFD = err
        var outData = Data(), errData = Data()
        var buf = [UInt8](repeating: 0, count: chunk)
        while inFD >= 0 || outFD >= 0 || errFD >= 0 {
            // poll skips entries whose fd is negative.
            var polls = [
                pollfd(fd: inFD, events: Int16(POLLOUT), revents: 0),
                pollfd(fd: outFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: errFD, events: Int16(POLLIN), revents: 0),
            ]
            guard poll(&polls, nfds_t(polls.count), -1) >= 0 else {
                if errno == EINTR { continue }
                throw KibaError.io(PrivateFS.failure("poll", fds.tool))
            }
            if polls[0].revents != 0, let feed {
                let n = feed.data.withUnsafeBytes { raw in write(inFD, raw.baseAddress! + sent, raw.count - sent) }
                if n >= 0 {
                    sent += n
                } else if errno != EAGAIN && errno != EINTR && errno != EPIPE {
                    throw KibaError.io(PrivateFS.failure("write", fds.tool))
                }
                if sent == feed.data.count || (n < 0 && errno == EPIPE) {
                    try fds.close(inFD)
                    inFD = -1
                }
            }
            if polls[1].revents != 0, try !drain(outFD, &buf, into: &outData, fds.tool) {
                try fds.close(outFD)
                outFD = -1
            }
            if polls[2].revents != 0, try !drain(errFD, &buf, into: &errData, fds.tool) {
                try fds.close(errFD)
                errFD = -1
            }
        }
        return (outData, errData)
    }

    /// Reads what `fd` has into `data`; false at end of file.
    static func drain(_ fd: Int32, _ buf: inout [UInt8], into data: inout Data, _ tool: String) throws -> Bool {
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if n > 0 {
                data.append(contentsOf: buf[..<n])
                return true
            }
            if n == 0 { return false }
            guard errno == EINTR else { throw KibaError.io(PrivateFS.failure("read", tool)) }
        }
    }

    /// Waits for `pid`; its exit status, or `signalBase` plus the signal that killed it.
    static func reap(_ pid: pid_t, _ tool: String) throws -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { throw KibaError.io(PrivateFS.failure("waitpid", tool)) }
        }
        let sig = status & sigBits
        return sig == 0 ? (status >> exitShift) & exitBits : signalBase + sig
    }

    /// posix_spawn calls return their error instead of setting errno.
    static func check(_ rc: Int32, _ op: String, _ path: String) throws {
        guard rc == 0 else { throw KibaError.io(PrivateFS.failure(op, path, rc)) }
    }

    /// The pipe ends a run holds open, so every exit path closes them.
    struct Pipes {
        let tool: String
        private var open: Set<Int32> = []

        init(tool: String) {
            self.tool = tool
        }

        mutating func make() throws -> (read: Int32, write: Int32) {
            var ends: [Int32] = [0, 0]
            guard pipe(&ends) == 0 else { throw KibaError.io(PrivateFS.failure("pipe", tool)) }
            open.formUnion(ends)
            return (ends[0], ends[1])
        }

        mutating func close(_ fd: Int32) throws {
            open.remove(fd)
            guard Darwin.close(fd) == 0 else { throw KibaError.io(PrivateFS.failure("close", tool)) }
        }

        /// Closes what an early exit left open; the run already failed or finished.
        mutating func closeAll() {
            for fd in open { Darwin.close(fd) }
            open.removeAll()
        }
    }
}
