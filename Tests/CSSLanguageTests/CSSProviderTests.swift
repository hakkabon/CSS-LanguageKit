import CSSLanguage
import Foundation
import IncrementalParsing
import Testing

@Suite("CSS language provider")
struct CSSProviderTests {
    @Test func analyzesStylesheetAndReusesLexing() async throws {
        let session = CSSProvider().makeToolingSession()
        let first = SourceSnapshot(
            text: "body { color: red; margin: 1rem; }", revision: .init(1))
        let clean = try await session.analyze(first)
        #expect(clean.diagnostics.isEmpty)
        #expect(clean.tokens.contains { $0.classification == "number" })

        let location = (first.text as NSString).range(of: "red").location
        let change = try SourceEdit(
            baseRevision: first.revision,
            range: .init(location: location, length: 3), replacement: "blue")
            .applying(to: first)
        let changed = try await session.analyze(change.after, change: change)
        #expect(changed.evidence(for: "lexing")?.strategy == .incremental)
        #expect(changed.diagnostics.isEmpty)
        #expect(!(try await session.semanticTokens()).data.isEmpty)
    }

    @Test func recoversMissingColonAndBrace() async throws {
        let result = try await CSSProvider().makeSession().analyze(.init(
            text: "body { color red;", revision: .init(1)))
        #expect(result.diagnostics.contains { $0.expected.contains(":") })
        #expect(result.diagnostics.contains { $0.expected.contains("}") })
        #expect(!result.recoveryEdits.isEmpty)
    }
}
