import Foundation
import KnowledgeIndex
import Observation

/// The user's knowledge sources and the local index built from them.
@MainActor
@Observable
final class KnowledgeModel {
    private(set) var sources: [KnowledgeSource]
    /// Source ID -> progress line, while that source is being indexed.
    private(set) var progress: [String: String] = [:]
    private(set) var totalChunks = 0
    private(set) var openError: String?
    /// "Hybrid search (potion-base-8M)", "Downloading search model 12/30 MB", ...
    private(set) var searchStatus = "Keyword search"
    private(set) var isHybrid = false
    var searchResult: SearchResult?

    let base: KnowledgeBase?

    init() {
        sources = SourceCatalog.load(from: AppPaths.sources)
        do {
            base = try KnowledgeBase(path: AppPaths.index.path)
        } catch {
            base = nil
            openError = "Could not open the index at \(AppPaths.index.path): \(error)"
        }
        Task {
            await refreshCounts()
            await enableHybridSearch()
        }
    }

    static var modelsDirectory: URL { AppPaths.directory.appendingPathComponent("models", isDirectory: true) }

    /// Downloads the embedding model on first launch (30 MB, pinned and checksummed),
    /// then embeds any passages indexed without vectors. Search stays keyword-only
    /// until this finishes, and keeps working while it runs.
    func enableHybridSearch() async {
        guard let base, !isHybrid else { return }
        let spec = StaticModelSpec.potionBase8M
        do {
            let embedder = try await EmbeddingModelStore.load(spec, under: Self.modelsDirectory) { [weak self] update in
                let line = "\(update.phase) \(update.completed)/\(update.total)"
                Task { @MainActor in self?.searchStatus = line }
            }
            try await base.useEmbedder(embedder) { [weak self] update in
                let line = "Preparing hybrid search: \(update.completed)/\(update.total) passages"
                Task { @MainActor in self?.searchStatus = line }
            }
            isHybrid = true
            searchStatus = "Hybrid search (keywords + \(spec.name))"
        } catch {
            searchStatus = "Keyword search only: \(error)"
        }
    }

    var isIndexing: Bool { !progress.isEmpty }
    var isEmpty: Bool { totalChunks == 0 }

    var summary: String {
        if let openError { return openError }
        let documents = sources.reduce(0) { $0 + $1.documentCount }
        return "\(sources.count) source\(sources.count == 1 ? "" : "s"), \(documents) documents, \(totalChunks) passages"
    }

    func hasSource(_ preset: KnowledgeSource) -> Bool { sources.contains { $0.id == preset.id } }

    /// Adds a source and indexes it straight away.
    func add(_ source: KnowledgeSource) {
        guard !sources.contains(where: { $0.id == source.id || ($0.location == source.location && $0.kind == source.kind) }) else {
            if let existing = sources.first(where: { $0.location == source.location }) { reindex(existing.id) }
            return
        }
        sources.append(source)
        save()
        reindex(source.id)
    }

    func addFromInput(_ input: String) -> Bool {
        guard let source = KnowledgeSource.guess(from: input) else { return false }
        add(source)
        return true
    }

    func remove(_ id: String) {
        sources.removeAll { $0.id == id }
        save()
        Task {
            try? await base?.remove(sourceID: id)
            await refreshCounts()
        }
    }

    func reindexAll() {
        for source in sources { reindex(source.id) }
    }

    func reindex(_ id: String) {
        guard let base, let source = sources.first(where: { $0.id == id }), progress[id] == nil else { return }
        progress[id] = "Starting..."
        Task {
            do {
                let report = try await base.index(source) { [weak self] update in
                    let line = update.total > 0 ? "\(update.phase) \(update.completed)/\(update.total)" : update.phase
                    Task { @MainActor in
                        if self?.progress[id] != nil { self?.progress[id] = line }
                    }
                }
                update(id) {
                    $0.lastIndexed = Date()
                    $0.documentCount = report.documents
                    $0.chunkCount = report.chunks
                    $0.lastError = report.failures.isEmpty ? nil
                        : "\(report.failures.count) page(s) failed, first: \(report.failures[0])"
                }
            } catch {
                update(id) { $0.lastError = "\(error)" }
            }
            progress[id] = nil
            await refreshCounts()
        }
    }

    func search(_ text: String) {
        guard let base, !text.trimmingCharacters(in: .whitespaces).isEmpty else { searchResult = nil; return }
        Task { searchResult = try? await base.search(text) }
    }

    private func update(_ id: String, _ change: (inout KnowledgeSource) -> Void) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        change(&sources[index])
        save()
    }

    private func save() {
        try? SourceCatalog.save(sources, to: AppPaths.sources)
    }

    private func refreshCounts() async {
        totalChunks = (try? await base?.chunkCount()) ?? 0
    }
}
