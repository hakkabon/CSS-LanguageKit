import Grammar
import IncrementalParsing
import LanguageTooling
import Lexer
import Parser

public struct CSSProvider: LanguageToolingProvider {
    public let descriptor = LanguageProviderDescriptor(
        id: "css", displayName: "CSS", fileExtensions: ["css"],
        distribution: .bundledPermanent,
        capabilities: [
            .syntaxHighlighting, .incrementalAnalysis, .diagnostics, .recovery,
        ])

    public init() {}
    public func makeToolingSession() -> any LanguageToolingSession {
        CSSProviderSession()
    }
}

public actor CSSProviderSession: LanguageToolingSession {
    private var tokenizer: GrammarIncrementalTokenizer
    private var text: String?
    private var revision: SourceRevision?
    private var elements: [GrammarLexicalElement] = []

    public init() {
        do {
            tokenizer = RestartAndConvergeTokenizer(
                scanner: try GrammarDrivenLexer(specification: CSSLexicon.specification))
        } catch {
            preconditionFailure("Invalid CSS lexical specification: \(error)")
        }
    }

    public func analyze(_ snapshot: SourceSnapshot, change: SourceChange?) async throws
        -> LanguageProviderAnalysis {
        if let change, change.after != snapshot {
            throw LanguageProviderError.inconsistentChange
        }
        let lexed = tokenizer.tokenize(snapshot: snapshot, change: change)
        text = snapshot.text
        revision = snapshot.revision
        elements = lexed.output.elements
        let significant = lexed.output.tokens.filter { $0.kind != "$EOF" }
        var structure = CSSStructureValidator(tokens: significant)
        structure.validate(endOffset: snapshot.text.utf16.count)
        let metrics = lexed.metrics

        return LanguageProviderAnalysis(
            languageID: "css", revision: snapshot.revision,
            tokens: CSSLexicon.providerTokens(lexed.output.elements),
            diagnostics: lexed.output.diagnostics.map {
                .init(
                    severity: .error, message: $0.message,
                    range: .init($0.range.lowerBound, $0.range.upperBound))
            } + structure.diagnostics,
            recoveryEdits: structure.recoveryEdits,
            operations: [
                .init(operation: "lexing", evidence: CSSLexicon.evidence(metrics)),
                .init(operation: "parsing", evidence: .init(
                    strategy: .full,
                    measurements: [.init(
                        dimension: .init(rawValue: "cssDeclarations"),
                        reused: 0, rebuilt: structure.declarationCount,
                        strategy: "css-structural-validation")]))
            ])
    }

    public func semanticTokens() async throws -> ToolingSemanticTokensResult {
        guard let text, let revision else {
            throw LanguageToolingError.documentNotAnalyzed
        }
        let map = SourceLineMap(text)
        let tokens = CSSLexicon.providerTokens(elements).compactMap {
            token -> ToolingSemanticToken? in
            guard let type = CSSLexicon.semanticType(token.classification) else {
                return nil
            }
            return .init(range: map.toolingRange(token.range), type: type)
        }
        return SemanticTokenEncoder.encode(tokens, resultID: "css:\(revision.rawValue)")
    }
}

private enum CSSLexicon {
    static let specification = LexicalSpecification(rules: [
        .init(name: "WHITESPACE", matcher: .regularExpression(#"\s+"#), channel: .trivia),
        .init(name: "COMMENT", matcher: .blockComment(open: "/*", close: "*/"), channel: .trivia),
        .init(name: "STRING", matcher: .regularExpression(#"\"(?:\\.|[^\"\\\r\n])*\"|'(?:\\.|[^'\\\r\n])*'"#)),
        .init(name: "AT_KEYWORD", matcher: .regularExpression(#"@[A-Za-z_-][A-Za-z0-9_-]*"#)),
        .init(name: "HASH", matcher: .regularExpression(#"#[A-Za-z0-9_-]+"#)),
        .init(name: "PERCENTAGE", matcher: .regularExpression(#"[+-]?(?:[0-9]*\.)?[0-9]+%"#)),
        .init(name: "DIMENSION", matcher: .regularExpression(#"[+-]?(?:[0-9]*\.)?[0-9]+[A-Za-z_-][A-Za-z0-9_-]*"#)),
        .init(name: "NUMBER", matcher: .regularExpression(#"[+-]?(?:[0-9]*\.)?[0-9]+"#)),
        .init(name: "CUSTOM_PROPERTY", matcher: .regularExpression(#"--[A-Za-z_][A-Za-z0-9_-]*"#)),
        .init(name: "IDENT", matcher: .regularExpression(#"-?[A-Za-z_][A-Za-z0-9_-]*"#)),
        .init(name: "LBRACE", matcher: .literal("{")),
        .init(name: "RBRACE", matcher: .literal("}")),
        .init(name: "LPAREN", matcher: .literal("(")),
        .init(name: "RPAREN", matcher: .literal(")")),
        .init(name: "LBRACKET", matcher: .literal("[")),
        .init(name: "RBRACKET", matcher: .literal("]")),
        .init(name: "COLON", matcher: .literal(":")),
        .init(name: "SEMICOLON", matcher: .literal(";")),
        .init(name: "COMMA", matcher: .literal(",")),
        .init(name: "DOT", matcher: .literal(".")),
        .init(name: "GREATER", matcher: .literal(">")),
        .init(name: "PLUS", matcher: .literal("+")),
        .init(name: "TILDE", matcher: .literal("~")),
        .init(name: "STAR", matcher: .literal("*")),
        .init(name: "EQUAL", matcher: .literal("=")),
        .init(name: "SLASH", matcher: .literal("/")),
        .init(name: "BANG", matcher: .literal("!")),
    ])

    static func evidence(_ metrics: RestartAndConvergeMetrics)
        -> IncrementalExecutionEvidence {
        .init(
            strategy: metrics.incremental ? .incremental : .full,
            measurements: [.init(
                dimension: .tokens,
                reused: metrics.reusedPrefixTokenCount + metrics.reusedSuffixTokenCount,
                rebuilt: metrics.generatedTokenCount,
                strategy: metrics.incremental
                    ? "restart-and-converge" : "full-tokenization")])
    }

    static func providerTokens(_ elements: [GrammarLexicalElement])
        -> [LanguageProviderToken] {
        elements.compactMap { element in
            let classification: String
            switch element.kind {
            case .invalid: classification = "invalid"
            case .trivia: classification = "comment"
            case .token(let kind):
                switch kind {
                case "AT_KEYWORD": classification = "keyword"
                case "STRING": classification = "string"
                case "NUMBER", "DIMENSION", "PERCENTAGE": classification = "number"
                case "HASH": classification = "constant"
                case "IDENT", "CUSTOM_PROPERTY": classification = "identifier"
                default: classification = "operator"
                }
            }
            return .init(
                range: .init(element.range.lowerBound, element.range.upperBound),
                classification: classification)
        }
    }

    static func semanticType(_ classification: String)
        -> ToolingSemanticTokenType? {
        switch classification {
        case "comment": .comment
        case "keyword": .keyword
        case "string": .string
        case "number": .number
        case "constant": .constant
        case "identifier": .field
        case "operator": .operatorToken
        default: nil
        }
    }

    static func spelling(_ kind: String) -> String {
        switch kind {
        case "LBRACE": "{"
        case "RBRACE": "}"
        case "LPAREN": "("
        case "RPAREN": ")"
        case "LBRACKET": "["
        case "RBRACKET": "]"
        default: kind.lowercased()
        }
    }
}

private struct CSSStructureValidator {
    let tokens: [GrammarLexicalToken]
    var diagnostics: [LanguageProviderDiagnostic] = []
    var recoveryEdits: [LanguageProviderRecoveryEdit] = []
    var declarationCount = 0

    mutating func validate(endOffset: Int) {
        let delimiterTokens = tokens.map {
            DelimiterToken(
                id: $0.id, kind: $0.kind,
                range: SourceRange($0.range.lowerBound, $0.range.upperBound))
        }
        let balanced = BalancedDelimiterRecovery<String, String>(pairs: [
            .init(open: "LBRACE", close: "RBRACE"),
            .init(open: "LPAREN", close: "RPAREN"),
            .init(open: "LBRACKET", close: "RBRACKET"),
        ]).validate(delimiterTokens, endOffset: endOffset)
        diagnostics += balanced.diagnostics.map {
            .init(
                severity: $0.severity, message: $0.message, range: $0.range,
                expected: $0.expected.map(CSSLexicon.spelling))
        }
        recoveryEdits += balanced.repairs.compactMap(providerEdit)

        var blockDepth = 0
        var segmentStart = 0
        var hasColon = false
        for (index, token) in tokens.enumerated() {
            switch token.kind {
            case "LBRACE":
                blockDepth += 1
                segmentStart = index + 1
                hasColon = false
            case "COLON" where blockDepth > 0:
                hasColon = true
            case "SEMICOLON" where blockDepth > 0:
                validateDeclaration(
                    from: segmentStart, to: index,
                    hasColon: hasColon, insertionIndex: index)
                segmentStart = index + 1
                hasColon = false
            case "RBRACE":
                if blockDepth > 0 {
                    validateDeclaration(
                        from: segmentStart, to: index,
                        hasColon: hasColon, insertionIndex: index)
                    blockDepth -= 1
                }
                segmentStart = index + 1
                hasColon = false
            default: break
            }
        }
    }

    private mutating func validateDeclaration(
        from start: Int, to end: Int, hasColon: Bool, insertionIndex: Int
    ) {
        guard start < end else { return }
        let segment = tokens[start..<end]
        guard !segment.contains(where: { $0.kind == "LBRACE" }),
              segment.first?.kind != "AT_KEYWORD" else { return }
        declarationCount += 1
        guard !hasColon else { return }
        let offset = tokens[insertionIndex].range.lowerBound
        let diagnostic = LanguageProviderDiagnostic(
            severity: .error, message: "Expected ':' in CSS declaration",
            range: .init(location: offset, length: 0), expected: [":"])
        diagnostics.append(diagnostic)
        recoveryEdits.append(.init(
            action: .insert(terminal: ":", atUTF16Offset: offset),
            expected: [":"], diagnosticID: diagnostic.id))
    }

    private func providerEdit(
        _ repair: RecoveryAction<String, String>
    ) -> LanguageProviderRecoveryEdit? {
        switch repair {
        case .insert(let kind, let offset):
            return .init(action: .insert(
                terminal: CSSLexicon.spelling(kind), atUTF16Offset: offset))
        case .delete(let id, let range):
            guard let index = tokens.firstIndex(where: { $0.id == id }) else { return nil }
            return .init(action: .delete(
                terminal: CSSLexicon.spelling(tokens[index].kind), range: range))
        case .replace(let id, let range, let kind):
            guard let index = tokens.firstIndex(where: { $0.id == id }) else { return nil }
            return .init(action: .replace(
                terminal: CSSLexicon.spelling(tokens[index].kind), range: range,
                with: CSSLexicon.spelling(kind)))
        case .skip(let ids, let range):
            return .init(action: .skip(
                terminals: ids.compactMap { id in
                    tokens.first(where: { $0.id == id }).map {
                        CSSLexicon.spelling($0.kind)
                    }
                }, range: range), cost: max(1, ids.count))
        }
    }
}
