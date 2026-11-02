import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A static embedding model published on Hugging Face, pinned to one revision so
/// every install builds identical vectors.
public struct StaticModelSpec: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public let name: String
        public let bytes: Int
        public let sha256: String
    }

    public let name: String
    public let repository: String
    public let revision: String
    public let files: [File]
    public let license: String

    /// Stored in the index; changing the model or revision rebuilds the vectors.
    public var identifier: String { "\(repository)@\(revision.prefix(12))" }
    public var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }

    /// Default model, chosen by the M3 shoot-out (docs/DECISIONS.md): 256 dimensions,
    /// 30 MB, MIT licensed, distilled from bge-base-en-v1.5.
    public static let potionBase8M = StaticModelSpec(
        name: "potion-base-8M", repository: "minishlab/potion-base-8M",
        revision: "bf8b056651a2c21b8d2565580b8569da283cab23",
        files: [
            File(name: "tokenizer.json", bytes: 683_666, sha256: "e67e803f624fb4d67dea1c730d06e1067e1b14d830e2c2202569e3ef0f70bb50"),
            File(name: "model.safetensors", bytes: 30_236_760, sha256: "f65d0f325faadc1e121c319e2faa41170d3fa07d8c89abd48ca5358d9a223de2"),
        ],
        license: "MIT")

    func url(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.name)")!
    }
}

/// Downloads (once) and loads embedding models into a local folder, such as
/// `~/Library/Application Support/Jeeves/models`.
public enum EmbeddingModelStore {
    public static func directory(for spec: StaticModelSpec, under root: URL) -> URL {
        root.appendingPathComponent(spec.name, isDirectory: true)
    }

    /// True when every file is present with the expected size.
    public static func isInstalled(_ spec: StaticModelSpec, under root: URL) -> Bool {
        let folder = directory(for: spec, under: root)
        return spec.files.allSatisfy { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file.name).path)
            return (attributes?[.size] as? NSNumber)?.intValue == file.bytes
        }
    }

    /// Loads the model, downloading missing files first. Each download is checked
    /// against the pinned size and, where CryptoKit exists (macOS), its SHA-256.
    public static func load(_ spec: StaticModelSpec, under root: URL,
                            progress: (@Sendable (IndexProgress) -> Void)? = nil) async throws -> StaticEmbedder {
        let folder = directory(for: spec, under: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !isInstalled(spec, under: root) {
            let session = URLSession(configuration: .ephemeral)
            var downloaded = 0
            for file in spec.files {
                let target = folder.appendingPathComponent(file.name)
                if let size = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? NSNumber,
                   size.intValue == file.bytes {
                    downloaded += file.bytes
                    continue
                }
                progress?(IndexProgress(completed: downloaded / 1_000_000, total: spec.totalBytes / 1_000_000,
                                        phase: "Downloading search model (MB)"))
                let (data, response) = try await session.data(from: spec.url(for: file))
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw EmbeddingError.invalidModel("download of \(file.name) failed: HTTP \(http.statusCode)")
                }
                try verify(data, against: file)
                try data.write(to: target, options: .atomic)
                downloaded += file.bytes
            }
            progress?(IndexProgress(completed: spec.totalBytes / 1_000_000, total: spec.totalBytes / 1_000_000,
                                    phase: "Downloading search model (MB)"))
        }
        return try StaticEmbedder(directory: folder, identifier: spec.identifier)
    }

    static func verify(_ data: Data, against file: StaticModelSpec.File) throws {
        guard data.count == file.bytes else {
            throw EmbeddingError.invalidModel("\(file.name) is \(data.count) bytes, expected \(file.bytes)")
        }
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else {
            throw EmbeddingError.invalidModel("\(file.name) checksum mismatch")
        }
        #endif
    }
}
