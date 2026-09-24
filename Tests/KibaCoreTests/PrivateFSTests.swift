import Foundation
import Testing
import KibaCore

/// End to end through the public API on a scratch directory: a live config that is a
/// symlink gets its `oauthAccount` inserted, then replaced, by byte splicing, and is
/// written privately through the link each time.
@Suite struct PrivateFSTests {
    static let config = #"""
        {
          "numStartups": 3,
          "tip": "use \"}\" and {\"oauthAccount\": 1}",
          "a\"b": [1, {"oauthAccount": null}],
          "caf\u00e9": {"oauthAccount": {"deep": true}},
          "projects": {"/p": {"history": [[{}], "]"]}}
        }
        """#
    static let key = Data(#","oauthAccount":"#.utf8)
    static let slotA = Data(#"{"emailAddress":"a@x.com","organizationUuid":"o1"}"#.utf8)
    static let slotB = Data(#"{"emailAddress":"b@y.com","organizationUuid":null}"#.utf8)

    @Test func splicesConfigThroughSymlink() throws {
        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("kiba-fs-XXXXXX").path.utf8CString)
        let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!).map { String(cString: $0) } }
        let root = URL(fileURLWithPath: try #require(made), isDirectory: true)
        let run = Result { try flow(root) }
        try PrivateFS.removeTree(root)
        #expect(!PrivateFS.isDir(root))
        try run.get()
    }

    func flow(_ root: URL) throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let store = home.appendingPathComponent("dotfiles/claude", isDirectory: true)
        let real = store.appendingPathComponent(".claude.json", isDirectory: false)
        let live = home.appendingPathComponent(".claude.json", isDirectory: false)
        try PrivateFS.ensurePrivateDir(store)
        for dir in [home, store.deletingLastPathComponent(), store] {
            #expect(PrivateFS.isDir(dir) && perms(dir) == 0o700)
        }
        let base = Data(Self.config.utf8)
        try PrivateFS.writePrivate(base, to: real)
        #expect(symlink("dotfiles/claude/.claude.json", live.path) == 0)

        // Insert: only nested members are named oauthAccount, so it goes before the root's `}`.
        var doc = try JSONDoc(Data(contentsOf: live))
        #expect(doc.valueSpan("oauthAccount") == nil)
        #expect(doc.valueSpan("café", "oauthAccount").map { doc.data[$0] } == Data(#"{"deep": true}"#.utf8))
        let (brace, hasMembers) = doc.closingBrace()
        #expect(hasMembers && doc.data[brace] == UInt8(ascii: "}"))
        doc = doc.replacing(brace ..< brace, with: Self.key + Self.slotA)
        try PrivateFS.writePrivate(doc.data, to: live)
        #expect(try Data(contentsOf: real) == base[..<brace] + Self.key + Self.slotA + base[brace...])

        // Replace: every byte outside the value stays as it was.
        doc = try JSONDoc(Data(contentsOf: live))
        let span = try #require(doc.objectSpan("oauthAccount"))
        #expect(doc.data[span] == Self.slotA)
        let before = doc.data
        doc = doc.replacing(span, with: Self.slotB)
        try PrivateFS.writePrivate(doc.data, to: live)
        #expect(try Data(contentsOf: real) == before[..<span.lowerBound] + Self.slotB + before[span.upperBound...])

        let obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: live)) as? [String: Any])
        #expect((obj["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "b@y.com")
        #expect(obj["tip"] as? String == #"use "}" and {"oauthAccount": 1}"#)

        // The link stays a link; the file behind it is 0600 with no temp left over.
        #expect(try PrivateFS.writeTarget(live).path == real.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: live.path) == "dotfiles/claude/.claude.json")
        #expect(PrivateFS.exists(live) && perms(real) == 0o600)
        #expect(!PrivateFS.exists(real.appendingPathExtension("tmp")) && !PrivateFS.exists(live.appendingPathExtension("tmp")))
    }

    func perms(_ u: URL) -> mode_t? {
        var st = stat()
        return stat(u.path, &st) == 0 ? st.st_mode & 0o777 : nil
    }
}
