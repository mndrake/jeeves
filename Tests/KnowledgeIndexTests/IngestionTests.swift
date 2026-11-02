import Foundation
import Testing
@testable import KnowledgeIndex

@Suite struct MarkdownChunkerTests {
    let page = """
    ---
    title: Prompt caching
    url: https://platform.claude.com/docs/en/build-with-claude/prompt-caching
    description: Cache prompt prefixes with `cache_control`.
    featureMetadata:
      zdr:
        eligibility: eligible
    ---

    Prompt caching lets you resume from a prefix. It reduces cost and latency for repeated context.

    ## Cache lifetime {#lifetime}

    <Note>
    The cache has a **five minute** lifetime by default, refreshed each time it is read. A one-hour TTL costs more to write.
    </Note>

    ### Pricing for `max\\_tokens`

    See the [pricing page](https://example.com/pricing) for details. ![diagram](img.png) More text to pass the minimum size for a section.

    ```bash cURL
    curl https://api.anthropic.com/v1/messages
    # A comment that is not a heading
    ```

    ## Supported models

    Every current model supports caching, including Claude Sonnet 5.5 and Claude Haiku 5.5, at the listed prices.
    """

    @Test func readsFrontMatterAndBuildsBreadcrumbs() {
        let document = SourceDocument.fromMarkdown(page, location: "fallback", fallbackTitle: "x")
        #expect(document.title == "Prompt caching")
        #expect(document.location == "https://platform.claude.com/docs/en/build-with-claude/prompt-caching")
        #expect(document.markdown.hasPrefix("Cache prompt prefixes"))
        #expect(!document.markdown.contains("eligibility"))

        let chunks = MarkdownChunker().chunks(for: document)
        let crumbs = chunks.map(\.breadcrumb)
        #expect(crumbs.first == "Prompt caching")
        #expect(crumbs.contains("Prompt caching > Cache lifetime"))
        #expect(crumbs.contains("Prompt caching > Supported models"))
        // A `#` line inside a code fence is not a heading.
        #expect(!crumbs.contains { $0.contains("comment") })
    }

    @Test func cleansMDXLinksImagesAndEscapes() {
        let chunker = MarkdownChunker()
        let cleaned = chunker.clean("""
        <Note>
        See the [pricing page](https://example.com) ![alt](a.png) for `max\\_tokens` and [[Obsidian Note]] or [[target|shown]].
        </Note>
        <Tabs><Tab title="Python">
        ```python extra words
        print(1)
        ```
        """)
        #expect(!cleaned.contains("<Note>"))
        #expect(!cleaned.contains("<Tab"))
        #expect(cleaned.contains("See the pricing page"))
        #expect(!cleaned.contains("a.png"))
        #expect(cleaned.contains("max_tokens"))
        #expect(cleaned.contains("Obsidian Note or shown"))
        #expect(cleaned.contains("```python\nprint(1)"))
    }

    @Test func truncatesLongCodeBlocks() {
        let code = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let cleaned = MarkdownChunker(maxCodeLines: 5).clean("```\n\(code)\n```")
        #expect(cleaned.contains("line 5"))
        #expect(!cleaned.contains("line 6"))
        #expect(cleaned.contains("..."))
    }

    @Test func splitsLongSectionsAtParagraphs() {
        let paragraph = String(repeating: "Words in a sentence. ", count: 20)  // 420 characters
        let markdown = "## Long\n\n" + Array(repeating: paragraph, count: 8).joined(separator: "\n\n")
        let chunks = MarkdownChunker(maxCharacters: 1_000).chunks(for: SourceDocument(location: "a.md", title: "T", markdown: markdown))
        #expect(chunks.count >= 4)
        #expect(chunks.allSatisfy { $0.text.count <= 1_000 })
        #expect(chunks.allSatisfy { $0.breadcrumb == "T > Long" })
    }

    @Test func mergesTinySectionIntoItsChild() {
        let markdown = """
        ## Pricing

        Short intro.

        ### Cache writes

        Cache writes cost 1.25 times the base input price for the five-minute TTL, and twice the base price for one hour.
        """
        let chunks = MarkdownChunker(minCharacters: 60).chunks(for: SourceDocument(location: "a.md", title: "T", markdown: markdown))
        #expect(chunks.count == 1)
        #expect(chunks[0].breadcrumb == "T > Pricing")
        #expect(chunks[0].text.contains("Short intro."))
        #expect(chunks[0].text.contains("Cache writes\nCache writes cost"))
    }

    @Test func titleFallsBackToH1ThenFileName() {
        #expect(SourceDocument.fromMarkdown("# My note\n\nBody", location: "n.md", fallbackTitle: "n").title == "My note")
        #expect(SourceDocument.fromMarkdown("Body only", location: "n.md", fallbackTitle: "n").title == "n")
    }
}

@Suite struct WebSourceTests {
    @Test func parsesLLMSTxtLinks() {
        let text = """
        # Docs
        - [Overview](https://code.claude.com/docs/en/overview.md): Claude Code is...
        - [Hooks](https://code.claude.com/docs/en/hooks.md#events)
        - [Hooks again](https://code.claude.com/docs/en/hooks.md)
        - [Full text](https://platform.claude.com/llms-full.txt)
        - [Messages API](https://platform.claude.com/docs/en/api/messages.md)
        - [Relative](/docs/en/relative.md)
        """
        let links = LLMSTxt.links(in: text, excluding: ["/docs/en/api/"])
        #expect(links.map(\.url.absoluteString) == [
            "https://code.claude.com/docs/en/overview.md",
            "https://code.claude.com/docs/en/hooks.md",
        ])
        #expect(links[0].title == "Overview")
    }

    @Test func convertsHTMLToText() {
        let html = """
        <!doctype html><html><head><title>Rate limits &amp; tiers</title><style>body{}</style></head>
        <body><nav>Home | Docs</nav><main><h1>Rate limits</h1><p>Tier 1 allows 50&nbsp;requests per minute.</p>
        <h2>Raising limits</h2><ul><li>Deposit credit</li><li>Wait 7 days</li></ul><script>var x = 1;</script></main>
        <footer>Copyright</footer></body></html>
        """
        let document = HTMLText.document(fromHTML: html, location: "https://example.com/limits")
        #expect(document.title == "Rate limits & tiers")
        #expect(document.markdown.contains("# Rate limits"))
        #expect(document.markdown.contains("## Raising limits"))
        #expect(document.markdown.contains("Tier 1 allows 50 requests per minute."))
        #expect(document.markdown.contains("- Deposit credit"))
        #expect(!document.markdown.contains("var x"))
        #expect(!document.markdown.contains("Home | Docs"))
        #expect(!document.markdown.contains("Copyright"))
    }

    @Test func guessesSourceKind() {
        #expect(KnowledgeSource.guess(from: "https://code.claude.com/docs/llms.txt")?.kind == .llmsTxt)
        #expect(KnowledgeSource.guess(from: "https://example.com/page")?.kind == .webPage)
        #expect(KnowledgeSource.guess(from: "/Users/me/Notes")?.kind == .folder)
        #expect(KnowledgeSource.guess(from: "  ") == nil)
    }
}

@Suite struct KnowledgeBaseTests {
    @Test func indexesFolderSearchesAndReplacesCollection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jeeves-kb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("clients"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# Caching\n\n## Lifetime\n\nCached prompts stay warm for five minutes by default and each read refreshes the timer."
            .write(to: folder.appendingPathComponent("caching.md"), atomically: true, encoding: .utf8)
        try "# Acme\n\nAcme runs Claude Code with auto mode enabled for every engineer on the platform team."
            .write(to: folder.appendingPathComponent("clients/acme.md"), atomically: true, encoding: .utf8)
        try "should be skipped".write(to: folder.appendingPathComponent(".obsidian/workspace.md"), atomically: true, encoding: .utf8)
        try "not markdown".write(to: folder.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)

        let knowledge = try KnowledgeBase(path: ":memory:")
        let source = KnowledgeSource(id: "notes", kind: .folder, location: folder.path, name: "Notes")
        let report = try await knowledge.index(source)
        #expect(report.documents == 2)
        #expect(report.failures.isEmpty)

        // "cloud code" is normalized to "Claude Code" before searching.
        let result = try await knowledge.search("does acme use cloud code automote")
        #expect(result.query.contains("Claude Code"))
        #expect(result.passages.first?.source.hasSuffix("clients/acme.md") == true)
        #expect(result.passages.first?.number == 1)

        let warm = try await knowledge.search("how long does a cached prompt stay warm")
        #expect(warm.passages.first?.breadcrumb == "Caching > Lifetime")

        // Re-indexing replaces rather than duplicates; removing empties the collection.
        _ = try await knowledge.index(source)
        #expect(try await knowledge.chunkCount() == report.chunks)
        try await knowledge.remove(sourceID: "notes")
        #expect(try await knowledge.chunkCount() == 0)
    }

    @Test func diversifiesResultsAcrossSections() async throws {
        let knowledge = try KnowledgeBase(path: ":memory:")
        let long = (1...6).map { "Paragraph \($0) about prompt caching and cache lifetime, repeated to fill the chunk. " +
            String(repeating: "caching detail ", count: 60) }.joined(separator: "\n\n")
        let documents = [
            SourceDocument(location: "a.md", title: "A", markdown: "## Caching\n\n" + long),
            SourceDocument(location: "b.md", title: "B", markdown: "## Caching basics\n\nPrompt caching keeps a prefix warm."),
        ]
        _ = try await knowledge.index(documents: documents, sourceID: "test")
        let result = try await knowledge.search("prompt caching lifetime", limit: 6)
        #expect(result.passages.filter { $0.source == "a.md" }.count <= 2)
        #expect(result.passages.contains { $0.source == "b.md" })
    }

    @Test func catalogRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jeeves-sources-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var source = KnowledgeSource.claudeCodeDocs
        source.lastIndexed = Date(timeIntervalSince1970: 1_800_000_000)
        source.chunkCount = 42
        try SourceCatalog.save([source, .claudePlatformDocs], to: url)
        #expect(SourceCatalog.load(from: url) == [source, .claudePlatformDocs])
    }
}
