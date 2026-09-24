import Foundation
import Testing
import KibaCore

/// Paths never touches the disk, so these scratch locations need not exist.
private let home = "/scratch/home"
private let root = URL(filePath: "/scratch/root", directoryHint: .notDirectory)

/// Values that are not absolute paths; `URL(filePath:)` would expand or
/// resolve each against the real process instead of the given env.
private let relative = ["~/x", "~", "~root", "~user", "rel", "./x", " /x"]
private let vars = ["HOME", "KIBA_STORE", "CLAUDE_CONFIG_DIR", "CODEX_HOME"]

/// A scratch env with `HOME` set; entries in `env` win.
private func paths(_ env: [String: String] = [:]) throws -> Paths {
    try Paths(env: ["HOME": home].merging(env) { _, given in given }, username: "tester")
}

@Suite struct PathsTests {
    @Test func storeDefaultsUnderConfig() throws {
        #expect(try paths().store.path == "/scratch/home/.config/kiba")
        #expect(try paths(["KIBA_STORE": ""]).store.path == "/scratch/home/.config/kiba")
    }

    @Test func storeFromEnv() throws {
        #expect(try paths(["KIBA_STORE": "/scratch/store"]).store.path == "/scratch/store")
    }

    @Test func homeIsRequired() {
        #expect(throws: KibaError.io("HOME is not set")) { try Paths(env: [:], username: "tester") }
        #expect(throws: KibaError.io("HOME is not set")) {
            try Paths(env: ["HOME": "", "KIBA_STORE": "/scratch/store"], username: "tester")
        }
    }

    @Test func rejectsRelativePaths() {
        for name in vars {
            for value in relative {
                #expect(throws: KibaError.io("\(name) is not an absolute path: \(value)")) {
                    try paths([name: value])
                }
            }
        }
    }

    /// A `~` after the leading `/` is an ordinary path byte.
    @Test func tildeStaysLiteral() throws {
        let env = ["HOME": "/~", "KIBA_STORE": "/~/k", "CLAUDE_CONFIG_DIR": "/c/~", "CODEX_HOME": "/x/~/y"]
        let p = try paths(env)
        #expect(p.store.path == "/~/k")
        #expect(p.claudeConfigDir(root: nil).path == "/c/~")
        #expect(p.codexAuthFile(root: nil).path == "/x/~/y/auth.json")
        #expect(p.slotDir(.claude, try #require(SlotName("~"))).path == "/~/k/claude/~")
        #expect(try paths(["HOME": "/~"]).store.path == "/~/.config/kiba")
    }

    @Test func storeLayout() throws {
        let p = try paths(["KIBA_STORE": "/s"])
        let n = try #require(SlotName("a@x #2"))
        #expect(p.lock.path == "/s/lock")
        #expect(p.probe.path == "/s/probe")
        #expect(p.providerDir(.claude).path == "/s/claude")
        #expect(p.providerDir(.codex).path == "/s/codex")
        #expect(p.slotDir(.claude, n).path == "/s/claude/a@x #2")
        #expect(p.slotFile(.codex, n, Provider.codex.loginFile).path == "/s/codex/a@x #2/auth.json")
        #expect(p.usageFile(.claude, n).path == "/s/claude/a@x #2/usage.json")
        #expect(p.installedFile(.claude).path == "/s/claude/.installed")
        #expect(p.markFile(.codex).path == "/s/codex/.installing")
    }

    @Test func loginRoots() throws {
        let p = try paths(["KIBA_STORE": "/s"])
        #expect(p.loginRoot(.claude).path == "/s/probe/login-claude")
        #expect(p.loginRoot(.codex).path == "/s/probe/login-codex")
    }

    @Test func claudeDirPrecedence() throws {
        let env = ["CLAUDE_CONFIG_DIR": "/scratch/cfg"]
        #expect(try paths(env).claudeConfigDir(root: root).path == "/scratch/root/.claude")
        #expect(try paths(env).claudeConfigDir(root: nil).path == "/scratch/cfg")
        #expect(try paths(["CLAUDE_CONFIG_DIR": ""]).claudeConfigDir(root: nil).path == "/scratch/home/.claude")
        #expect(try paths().claudeConfigDir(root: nil).path == "/scratch/home/.claude")
    }

    @Test func claudeConfigPlacement() throws {
        let env = ["CLAUDE_CONFIG_DIR": "/scratch/cfg"]
        #expect(try paths(env).claudeConfigFile(root: root).path == "/scratch/root/.claude/.claude.json")
        #expect(try paths().claudeConfigFile(root: root).path == "/scratch/root/.claude/.claude.json")
        #expect(try paths(env).claudeConfigFile(root: nil).path == "/scratch/cfg/.claude.json")
        #expect(try paths().claudeConfigFile(root: nil).path == "/scratch/home/.claude.json")
        #expect(try paths(["CLAUDE_CONFIG_DIR": ""]).claudeConfigFile(root: nil).path == "/scratch/home/.claude.json")
    }

    @Test func claudeCredsFollowDir() throws {
        let env = ["CLAUDE_CONFIG_DIR": "/scratch/cfg"]
        #expect(try paths(env).claudeCredsFile(root: root).path == "/scratch/root/.claude/.credentials.json")
        #expect(try paths(env).claudeCredsFile(root: nil).path == "/scratch/cfg/.credentials.json")
        #expect(try paths().claudeCredsFile(root: nil).path == "/scratch/home/.claude/.credentials.json")
    }

    @Test func codexHomePrecedence() throws {
        let env = ["CODEX_HOME": "/scratch/cx"]
        #expect(try paths(env).codexHome(root: root).path == "/scratch/root/.codex")
        #expect(try paths(env).codexHome(root: nil).path == "/scratch/cx")
        #expect(try paths(["CODEX_HOME": ""]).codexHome(root: nil).path == "/scratch/home/.codex")
        #expect(try paths().codexHome(root: nil).path == "/scratch/home/.codex")
    }

    @Test func codexAuthFollowsHome() throws {
        let env = ["CODEX_HOME": "/scratch/cx"]
        #expect(try paths(env).codexAuthFile(root: root).path == "/scratch/root/.codex/auth.json")
        #expect(try paths(env).codexAuthFile(root: nil).path == "/scratch/cx/auth.json")
        #expect(try paths().codexAuthFile(root: nil).path == "/scratch/home/.codex/auth.json")
    }

    @Test func providerVarsStayApart() throws {
        let p = try paths(["CLAUDE_CONFIG_DIR": "/scratch/cfg"])
        #expect(p.codexHome(root: nil).path == "/scratch/home/.codex")
        let q = try paths(["CODEX_HOME": "/scratch/cx"])
        #expect(q.claudeConfigDir(root: nil).path == "/scratch/home/.claude")
        #expect(q.claudeConfigFile(root: nil).path == "/scratch/home/.claude.json")
    }

    @Test func keychainFacts() throws {
        let p = try paths()
        #expect(p.keychainService == "Claude Code-credentials")
        #expect(p.username == "tester")
    }

    @Test func trailingSlashesAreDropped() throws {
        let p = try paths(["HOME": "/scratch/home/", "KIBA_STORE": "/s/", "CODEX_HOME": "/scratch/cx/"])
        #expect(p.store.absoluteString == "file:///s")
        #expect(p.lock.path == "/s/lock")
        #expect(p.codexAuthFile(root: nil).path == "/scratch/cx/auth.json")
        #expect(p.claudeConfigFile(root: nil).path == "/scratch/home/.claude.json")
        let dirRoot = URL(filePath: "/scratch/root/", directoryHint: .isDirectory)
        #expect(p.claudeConfigDir(root: dirRoot).absoluteString == "file:///scratch/root/.claude")
        #expect(p.codexAuthFile(root: dirRoot).absoluteString == "file:///scratch/root/.codex/auth.json")
    }

    /// The URLs must not depend on what exists on disk: an existing directory
    /// gains no trailing slash, and equal paths stay equal URLs.
    @Test func urlsIgnoreTheDisk() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(component: "kiba-paths-\(UUID().uuidString)", directoryHint: .notDirectory)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: scratch) } }
        let p = try Paths(env: ["HOME": scratch.path, "KIBA_STORE": scratch.path], username: "tester")
        let n = try #require(SlotName("a@x"))
        let before = [p.store, p.lock, p.probe, p.providerDir(.claude), p.slotDir(.claude, n), p.loginRoot(.codex),
                      p.claudeConfigDir(root: nil), p.codexHome(root: nil)]
        for url in before {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let after = [p.store, p.lock, p.probe, p.providerDir(.claude), p.slotDir(.claude, n), p.loginRoot(.codex),
                     p.claudeConfigDir(root: nil), p.codexHome(root: nil)]
        #expect(before == after)
        for url in after {
            #expect(url.isFileURL)
            #expect(!url.hasDirectoryPath)
            #expect(!url.absoluteString.hasSuffix("/"))
        }
    }
}
