import Testing
@testable import CCReaderKit

struct SessionResumeCommandTests {
    @Test
    func codexResumeCommandUsesRawSessionId() {
        let session = Session(
            sessionId: "019e0624-925e-71a2-8b7e-06cbc08830be",
            cwd: "/tmp/project",
            source: "codex"
        )

        #expect(session.resumeCommand == "codex resume 019e0624-925e-71a2-8b7e-06cbc08830be")
        #expect(session.identityKey == "codex:019e0624-925e-71a2-8b7e-06cbc08830be")
        #expect(session.matchesIdentityKey("codex-019e0624-925e-71a2-8b7e-06cbc08830be"))
    }

    @Test
    func codexResumeCommandSupportsLegacyPrefixedSessionId() {
        let session = Session(
            sessionId: "codex-019e0624-925e-71a2-8b7e-06cbc08830be",
            cwd: "/tmp/project",
            source: "codex"
        )

        #expect(session.resumeCommand == "codex resume 019e0624-925e-71a2-8b7e-06cbc08830be")
    }

    @Test
    func claudeResumeCommandUsesStoredSessionId() {
        let session = Session(
            sessionId: "019e0624-925e-71a2-8b7e-06cbc08830be",
            cwd: "/tmp/project",
            source: "claude"
        )

        #expect(session.resumeCommand == "claude --resume 019e0624-925e-71a2-8b7e-06cbc08830be")
    }
}
