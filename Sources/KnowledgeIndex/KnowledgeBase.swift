import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JeevesCore

/// A folder or site the user chose to index (docs/prd/04: source adapters).
public struct KnowledgeSource: Codable, Sendable, Identifiable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A local folder of Markdown or text files (an Obsidian vault works).
        case folder
        /// A site's `llms.txt` index; every linked page is fetched.
        case llmsTxt
        /// One web page (Markdown or HTML).
        case webPage
    }

    public var id: String
    public var kind: Kind
    /// Folder path or URL.
    public var location: String
    public var name: String
    /// For `llmsTxt`: pages whose URL path contains any of these are skipped.
    public var excludes: [String]
    public var lastIndexed: Date?
    public var documentCount: Int
    public var chunkCount: Int
    public var lastError: String?

    public init(id: String = UUID().uuidString, kind: Kind, location: String, name: String, excludes: [String] = []) {
        self.id = id
        self.kind = kind
        self.location = location
        self.name = name
        self.excludes = excludes
        self.lastIndexed = nil
        self.documentCount = 0
        self.chunkCount = 0
        self.lastError = nil
    }

    /// Picks the kind from what the user typed: a URL ending in `llms.txt`, another
    /// URL, or a folder path.
    public static func guess(from input: String) -> KnowledgeSource? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            let isIndex = url.lastPathComponent.lowercased() == "llms.txt"
            return KnowledgeSource(kind: isIndex ? .llmsTxt : .webPage, location: trimmed, name: url.host.map { isIndex ? $0 : $0 + url.path } ?? trimmed)
        }
        let path = (trimmed as NSString).expandingTildeInPath
        return KnowledgeSource(kind: .folder, location: path, name: (path as NSString).lastPathComponent)
    }

    /// The Claude Developer Platform guides. The 550 API-reference endpoint pages are
    /// excluded: they are long schemas that rarely answer a spoken question, and they
    /// would double the index.
    public static let claudePlatformDocs = KnowledgeSource(
        id: "preset-platform-claude-com", kind: .llmsTxt, location: "https://platform.claude.com/llms.txt",
        name: "Claude API docs (platform.claude.com)", excludes: ["/docs/en/api/"])

    public static let claudeCodeDocs = KnowledgeSource(
        id: "preset-code-claude-com", kind: .llmsTxt, location: "https://code.claude.com/docs/llms.txt",
        name: "Claude Code docs (code.claude.com)")
}

public struct IndexProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int
    public var phase: String
}

public struct IndexReport: Sendable, Equatable {
    public var documents: Int
    public var chunks: Int
    /// Pages or files that could not be read, with the reason.
    public var failures: [String]
    public var seconds: Double
}

/// A retrieved passage, numbered as it is shown and cited.
public struct Passage: Sendable, Equatable, Identifiable {
    public var number: Int
    public var chunkID: Int64
    public var breadcrumb: String
    public var source: String
    public var text: String
    public var id: Int64 { chunkID }

    public init(number: Int, chunkID: Int64, breadcrumb: String, source: String, text: String) {
        self.number = number
        self.chunkID = chunkID
        self.breadcrumb = breadcrumb
        self.source = source
        self.text = text
    }
}

public struct SearchResult: Sendable, Equatable {
    /// The query after alias normalization ("cloud code" -> "Claude Code").
    public var query: String
    public var passages: [Passage]
    public var milliseconds: Double
}

public enum KnowledgeBaseError: Error, CustomStringConvertible, Sendable {
    case notFound(String)
    case fetch(String)
    case empty(String)

    public var description: String {
        switch self {
        case .notFound(let message), .fetch(let message), .empty(let message): message
        }
    }
}

/// Owns the on-disk index and the ingestion pipeline. Searches are local SQLite
/// FTS5 (BM25) queries, typically a few milliseconds.
///
/// M3 scope note: embeddings and hybrid search (ChunkIndex.hybridSearch) are wired
/// in once the embedding-model shoot-out picks a model; until then retrieval is
/// lexical, which the M0 spike showed is the fast half of hybrid search.
public actor KnowledgeBase {
    public nonisolated let path: String
    private let index: ChunkIndex
    private let chunker = MarkdownChunker()
    private let aliases: AliasTable
    private let session: URLSession

    public init(path: String, aliases: AliasTable = .anthropic) throws {
        self.path = path
        // The vector table is created now so hybrid search can be added without a
        // schema change; 384 matches the small embedding models under evaluation.
        index = try ChunkIndex(path: path, dimensions: 384)
        self.aliases = aliases
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "Jeeves/0.3 (local knowledge indexer)"]
        session = URLSession(configuration: configuration)
    }

    public func chunkCount() throws -> Int { try index.count() }

    public func counts(for sourceID: String) throws -> (documents: Int, chunks: Int) {
        (try index.documentCount(collection: sourceID), try index.count(collection: sourceID))
    }

    public func remove(sourceID: String) throws {
        try index.deleteCollection(sourceID)
    }

    /// Fetches or reads every document of a source, chunks it, and replaces that
    /// source's chunks in one transaction.
    public func index(_ source: KnowledgeSource,
                      progress: (@Sendable (IndexProgress) -> Void)? = nil) async throws -> IndexReport {
        let started = MonotonicClock.now()
        let (documents, failures) = try await load(source, progress: progress)
        guard !documents.isEmpty else {
            throw KnowledgeBaseError.empty("no readable documents in \(source.location)" +
                                           (failures.first.map { " (first error: \($0))" } ?? ""))
        }
        progress?(IndexProgress(completed: documents.count, total: documents.count, phase: "Indexing"))
        let chunks = documents.flatMap { chunker.chunks(for: $0) }.map {
            Chunk(source: $0.source, breadcrumb: $0.breadcrumb, text: $0.text, collection: source.id)
        }
        try index.replaceCollection(source.id, with: chunks)
        return IndexReport(documents: documents.count, chunks: chunks.count, failures: failures,
                           seconds: MonotonicClock.milliseconds(from: started, to: MonotonicClock.now()) / 1000)
    }

    /// Indexes documents that are already in memory (tests, pasted notes).
    public func index(documents: [SourceDocument], sourceID: String) throws -> Int {
        let chunks = documents.flatMap { chunker.chunks(for: $0) }.map {
            Chunk(source: $0.source, breadcrumb: $0.breadcrumb, text: $0.text, collection: sourceID)
        }
        try index.replaceCollection(sourceID, with: chunks)
        return chunks.count
    }

    /// BM25 search over chunk text and breadcrumbs, after alias normalization.
    ///
    /// Results are diversified: at most `perSection` chunks from one section and
    /// `perDocument` from one page, so a long section split into many chunks cannot
    /// fill every slot.
    public func search(_ text: String, limit: Int = 6, perSection: Int = 2, perDocument: Int = 3) throws -> SearchResult {
        let started = MonotonicClock.now()
        let query = aliases.apply(to: text)
        let hits = try index.lexicalSearch(query, limit: max(limit * 5, 30))
        var passages: [Passage] = []
        var sectionCounts: [String: Int] = [:]
        var documentCounts: [String: Int] = [:]
        for hit in hits {
            guard passages.count < limit else { break }
            guard let chunk = try index.chunk(id: hit.chunkID) else { continue }
            let section = chunk.source + "#" + chunk.breadcrumb
            guard sectionCounts[section, default: 0] < perSection, documentCounts[chunk.source, default: 0] < perDocument else { continue }
            sectionCounts[section, default: 0] += 1
            documentCounts[chunk.source, default: 0] += 1
            passages.append(Passage(number: passages.count + 1, chunkID: hit.chunkID, breadcrumb: chunk.breadcrumb,
                                    source: chunk.source, text: chunk.text))
        }
        return SearchResult(query: query, passages: passages,
                            milliseconds: MonotonicClock.milliseconds(from: started, to: MonotonicClock.now()))
    }

    // MARK: Loading

    private func load(_ source: KnowledgeSource,
                      progress: (@Sendable (IndexProgress) -> Void)?) async throws -> ([SourceDocument], [String]) {
        switch source.kind {
        case .folder:
            return try Self.readFolder(source.location, progress: progress)
        case .webPage:
            guard let url = URL(string: source.location) else { throw KnowledgeBaseError.notFound("not a URL: \(source.location)") }
            progress?(IndexProgress(completed: 0, total: 1, phase: "Fetching"))
            return ([try await fetchDocument(url, title: nil)], [])
        case .llmsTxt:
            guard let url = URL(string: source.location) else { throw KnowledgeBaseError.notFound("not a URL: \(source.location)") }
            progress?(IndexProgress(completed: 0, total: 0, phase: "Fetching index"))
            let text = try await fetchText(url)
            let links = LLMSTxt.links(in: text, excluding: source.excludes)
            guard !links.isEmpty else { throw KnowledgeBaseError.empty("\(url.absoluteString) lists no pages") }
            return await fetchAll(links, progress: progress)
        }
    }

    /// Fetches pages eight at a time, keeping index order.
    private func fetchAll(_ links: [LLMSTxt.Link],
                          progress: (@Sendable (IndexProgress) -> Void)?) async -> ([SourceDocument], [String]) {
        var results = [SourceDocument?](repeating: nil, count: links.count)
        var failures: [String] = []
        var completed = 0
        await withTaskGroup(of: (Int, Result<SourceDocument, Error>).self) { group in
            var next = 0
            func addNext() {
                guard next < links.count else { return }
                let index = next
                let link = links[index]
                next += 1
                group.addTask { [self] in
                    do { return (index, .success(try await fetchDocument(link.url, title: link.title))) }
                    catch { return (index, .failure(error)) }
                }
            }
            for _ in 0..<8 { addNext() }
            for await (index, result) in group {
                switch result {
                case .success(let document): results[index] = document
                case .failure(let error): failures.append("\(links[index].url.absoluteString): \(error)")
                }
                completed += 1
                if completed % 10 == 0 || completed == links.count {
                    progress?(IndexProgress(completed: completed, total: links.count, phase: "Fetching pages"))
                }
                addNext()
            }
        }
        return (results.compactMap { $0 }, failures)
    }

    nonisolated func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw KnowledgeBaseError.fetch("HTTP \(http.statusCode)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated func fetchDocument(_ url: URL, title: String?) async throws -> SourceDocument {
        let (data, response) = try await session.data(from: url)
        let http = response as? HTTPURLResponse
        if let http, !(200..<300).contains(http.statusCode) { throw KnowledgeBaseError.fetch("HTTP \(http.statusCode)") }
        let text = String(decoding: data, as: UTF8.self)
        let contentType = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let looksHTML = contentType.contains("html") ||
            text.prefix(512).lowercased().contains("<!doctype html") || text.prefix(512).lowercased().contains("<html")
        let fallbackTitle = title ?? url.deletingPathExtension().lastPathComponent
        if looksHTML {
            var document = HTMLText.document(fromHTML: text, location: url.absoluteString)
            if let title, !title.isEmpty, document.title.isEmpty { document.title = title }
            return document
        }
        return SourceDocument.fromMarkdown(text, location: url.absoluteString, fallbackTitle: fallbackTitle)
    }

    static let folderExtensions: Set<String> = ["md", "markdown", "mdx", "txt"]
    static let skippedDirectories: Set<String> = ["node_modules", "build", "dist", "DerivedData"]

    /// Reads Markdown and text files under a folder, skipping hidden folders (such as
    /// `.obsidian` and `.git`), dependency folders and files over 2 MB.
    public static func readFolder(_ path: String,
                                  progress: (@Sendable (IndexProgress) -> Void)? = nil) throws -> ([SourceDocument], [String]) {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw KnowledgeBaseError.notFound("folder not found: \(path)")
        }
        let files = markdownFiles(under: root)
        var documents: [SourceDocument] = []
        var failures: [String] = []
        for (number, file) in files.enumerated() {
            do {
                let values = try file.resourceValues(forKeys: [.fileSizeKey])
                if (values.fileSize ?? 0) > 2_000_000 { failures.append("\(file.path): larger than 2 MB, skipped"); continue }
                let data = try Data(contentsOf: file)
                let text = String(decoding: data, as: UTF8.self)
                let name = file.deletingPathExtension().lastPathComponent
                documents.append(SourceDocument.fromMarkdown(text, location: file.path, fallbackTitle: name))
            } catch {
                failures.append("\(file.path): \(error.localizedDescription)")
            }
            if (number + 1) % 50 == 0 { progress?(IndexProgress(completed: number + 1, total: files.count, phase: "Reading files")) }
        }
        return (documents, failures)
    }

    static func markdownFiles(under root: URL) -> [URL] {
        var result: [URL] = []
        var stack = [root]
        let manager = FileManager.default
        while let directory = stack.popLast() {
            guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                let name = entry.lastPathComponent
                if name.hasPrefix(".") { continue }
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory {
                    if !skippedDirectories.contains(name) { stack.append(entry) }
                } else if folderExtensions.contains(entry.pathExtension.lowercased()) {
                    result.append(entry)
                }
            }
        }
        return result.sorted { $0.path < $1.path }
    }
}

/// Persists the list of sources as JSON next to the index.
public enum SourceCatalog {
    public static func load(from url: URL) -> [KnowledgeSource] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([KnowledgeSource].self, from: data)) ?? []
    }

    public static func save(_ sources: [KnowledgeSource], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(sources).write(to: url, options: .atomic)
    }
}
