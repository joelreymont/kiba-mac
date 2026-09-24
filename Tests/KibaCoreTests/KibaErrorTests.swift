import Foundation
import Testing
@testable import KibaCore

@Suite struct KibaErrorTests {
    @Test func reasonsNameTheProviderAndAccount() {
        #expect(KibaError.noLive(.claude).reason == "Claude Code has no live login to save")
        #expect(KibaError.noAccount(.codex, "a@x").reason == "Codex has no saved account named a@x")
        #expect(KibaError.interrupted(.claude).reason.contains("Claude Code switch was interrupted"))
    }

    @Test func toolReasonOmitsEmptyStderr() {
        #expect(KibaError.tool("security", 44, "  \n").reason == "security failed (exit 44)")
        #expect(KibaError.tool("security", 1, "bad\n").reason == "security failed (exit 1): bad")
    }

    @Test func providerFacts() {
        #expect(Provider.claude.loginFile == "credentials.json")
        #expect(Provider.claude.identityFile == "oauth-account.json")
        #expect(Provider.codex.loginFile == Provider.codex.identityFile)
        #expect(Provider.allCases.map(\.homeVar) == ["CLAUDE_CONFIG_DIR", "CODEX_HOME"])
    }
}
