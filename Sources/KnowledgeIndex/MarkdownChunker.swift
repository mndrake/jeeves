import Foundation

/// One source document before chunking: a Markdown file, a fetched `.md` page, or
/// an HTML page converted to Markdown-like text.
public struct SourceDocument: Sendable, Equatable {
    /// File path or URL shown with the passage.
    public var location: String
    /// Title from front matter, the first `#` heading, or the file name.
    public var title: String
    public var markdown: String

    public init(location: String, title: String, markdown: String) {
        self.location = location
        self.title = title
        self.markdown = markdown
    }

    /// Builds a document from raw Markdown: reads YAML front matter (`title`, `url`,
    /// `description`) and falls back to the first H1, then to `fallbackTitle`.
    public static func fromMarkdown(_ raw: String, location: String, fallbackTitle: String) -> SourceDocument {
        let (frontMatter, body) = MarkdownChunker.splitFrontMatter(raw)
        var title = frontMatter["title"] ?? ""
        if title.isEmpty, let h1 = MarkdownChunker.firstHeading(in: body, level: 1) { title = h1 }
        if title.isEmpty { title = fallbackTitle }
        var markdown = body
        if let description = frontMatter["description"], !description.isEmpty {
            markdown = description + "\n\n" + body
        }
        return SourceDocument(location: frontMatter["url"] ?? location, title: title, markdown: markdown)
    }
}

/// Splits Markdown into heading-scoped chunks with a `Title > H2 > H3` breadcrumb
/// (docs/prd/04: chunking). Sections longer than `maxCharacters` are split at
/// paragraph boundaries; code blocks are kept but long ones are truncated, since a
/// spoken answer never needs more than the first lines of an example.
public struct MarkdownChunker: Sendable {
    public var maxCharacters: Int
    /// Sections shorter than this are merged into the following section of the same parent.
    public var minCharacters: Int
    public var maxCodeLines: Int

    public init(maxCharacters: Int = 1_400, minCharacters: Int = 120, maxCodeLines: Int = 12) {
        self.maxCharacters = maxCharacters
        self.minCharacters = minCharacters
        self.maxCodeLines = maxCodeLines
    }

    public func chunks(for document: SourceDocument) -> [Chunk] {
        let sections = sections(of: clean(document.markdown), title: document.title)
        var chunks: [Chunk] = []
        for section in merge(sections) {
            for piece in split(section.text) {
                chunks.append(Chunk(source: document.location, breadcrumb: section.breadcrumb, text: piece))
            }
        }
        return chunks
    }

    // MARK: Sections

    struct Section: Equatable {
        var path: [String]
        var text: String
        var breadcrumb: String { path.joined(separator: " > ") }
    }

    func sections(of markdown: String, title: String) -> [Section] {
        var sections: [Section] = []
        var headings: [Int: String] = [:]  // level -> heading text, for levels 2...4
        var current: [String] = []
        var inFence = false

        func path() -> [String] {
            [title] + (2...4).compactMap { headings[$0] }
        }
        func flush() {
            let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { sections.append(Section(path: path(), text: text)) }
            current = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if Self.isFence(line) { inFence.toggle() }
            if !inFence, let (level, text) = Self.heading(line) {
                if level == 1 { continue }  // the title; already in the breadcrumb
                flush()
                if level <= 4 {
                    headings[level] = text
                    for deeper in (level + 1)...5 { headings[deeper] = nil }
                } else {
                    current.append(text)
                }
                continue
            }
            current.append(line)
        }
        flush()
        return sections
    }

    /// Merges a too-short section into the next one when the next is its child or
    /// sibling, so a heading followed by one sentence does not become its own chunk.
    func merge(_ sections: [Section]) -> [Section] {
        var result: [Section] = []
        var carry: Section?
        for section in sections {
            guard var pending = carry else {
                if section.text.count < minCharacters { carry = section } else { result.append(section) }
                continue
            }
            let parent = Array(pending.path.dropLast())
            if section.path.starts(with: parent) {
                // Keep the absorbed section's heading in the text; the breadcrumb keeps the
                // shallower of the two paths.
                let heading = section.path != pending.path ? (section.path.last.map { $0 + "\n" } ?? "") : ""
                pending.text += "\n\n" + heading + section.text
                if section.path.count < pending.path.count { pending.path = section.path }
                if pending.text.count < minCharacters { carry = pending } else { result.append(pending); carry = nil }
            } else {
                result.append(pending)
                carry = section.text.count < minCharacters ? section : nil
                if carry == nil { result.append(section) }
            }
        }
        if let carry { result.append(carry) }
        return result
    }

    /// Splits text longer than `maxCharacters` at blank lines (outside code fences),
    /// packing paragraphs greedily; a single oversized paragraph is cut at sentence ends.
    func split(_ text: String) -> [String] {
        guard text.count > maxCharacters else { return [text] }
        var paragraphs: [String] = []
        var current: [String] = []
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if Self.isFence(line) { inFence.toggle() }
            if !inFence && line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }

        var pieces: [String] = []
        var buffer = ""
        for paragraph in paragraphs.flatMap(cutLong) {
            if !buffer.isEmpty && buffer.count + 2 + paragraph.count > maxCharacters {
                pieces.append(buffer)
                buffer = ""
            }
            buffer += buffer.isEmpty ? paragraph : "\n\n" + paragraph
        }
        if !buffer.isEmpty { pieces.append(buffer) }
        return pieces
    }

    private func cutLong(_ paragraph: String) -> [String] {
        guard paragraph.count > maxCharacters else { return [paragraph] }
        var pieces: [String] = []
        var buffer = ""
        // Sentence ends: ". ", "? ", "! " or newlines.
        var sentence = ""
        for character in paragraph {
            sentence.append(character)
            let ends = character == "\n" || ((character == " ") && [".", "?", "!"].contains(sentence.dropLast().last))
            if ends || sentence.count >= maxCharacters {
                if buffer.count + sentence.count > maxCharacters, !buffer.isEmpty { pieces.append(buffer); buffer = "" }
                buffer += sentence
                sentence = ""
            }
        }
        if buffer.count + sentence.count > maxCharacters, !buffer.isEmpty { pieces.append(buffer); buffer = "" }
        buffer += sentence
        if !buffer.isEmpty { pieces.append(buffer) }
        return pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: Cleaning

    /// Removes what helps a web page but not a spoken answer: MDX/HTML component tags,
    /// images, link targets, Obsidian wiki-link syntax, and code beyond `maxCodeLines`.
    public func clean(_ markdown: String) -> String {
        var output: [String] = []
        var inFence = false
        var codeLines = 0
        var truncated = false
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if Self.isFence(rawLine) {
                inFence.toggle()
                if inFence {
                    codeLines = 0
                    truncated = false
                    // Keep only the language word: "```bash cURL" -> "```bash".
                    let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                    output.append(String(trimmed.split(separator: " ").first ?? "```"))
                } else {
                    output.append("```")
                }
                continue
            }
            if inFence {
                codeLines += 1
                if codeLines <= maxCodeLines {
                    output.append(rawLine)
                } else if !truncated {
                    output.append("...")
                    truncated = true
                }
                continue
            }
            var line = rawLine
            line = Self.replace(Self.imagePattern, in: line, with: "")
            line = Self.replace(Self.wikiEmbedPattern, in: line, with: "")
            line = Self.replace(Self.wikiAliasPattern, in: line, with: "$1")
            line = Self.replace(Self.wikiLinkPattern, in: line, with: "$1")
            line = Self.replace(Self.linkPattern, in: line, with: "$1")
            line = Self.replace(Self.tagPattern, in: line, with: "")
            line = Self.unescape(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A line that held only component tags becomes empty; drop runs of blanks.
            if trimmed.isEmpty {
                if let last = output.last, last.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                output.append("")
                continue
            }
            // Tags are often indented inside components; indentation is not meaningful
            // outside code, and four leading spaces would read as a code block.
            output.append(rawLine.hasPrefix("    ") || rawLine.hasPrefix("\t") ? trimmed : line)
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    static func isFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    /// `## Heading {#anchor}` -> (2, "Heading").
    static func heading(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        if let anchor = text.range(of: " {#", options: .backwards), text.hasSuffix("}") {
            text = String(text[..<anchor.lowerBound])
        }
        text = replace(linkPattern, in: text, with: "$1")
        text = unescape(text.replacingOccurrences(of: "`", with: ""))
        return text.isEmpty ? nil : (hashes, text)
    }

    /// Markdown backslash escapes (`max\\_tokens`) read as literal characters.
    static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                if !"\\`*_{}[]()#+-.!<>|~".contains(character) { result.append("\\") }
                result.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        if escaping { result.append("\\") }
        return result
    }

    static func firstHeading(in markdown: String, level: Int) -> String? {
        var inFence = false
        for line in markdown.split(separator: "\n").map(String.init) {
            if isFence(line) { inFence.toggle() }
            if !inFence, let (found, text) = heading(line), found == level { return text }
        }
        return nil
    }

    /// Returns simple `key: value` pairs from a leading `---` YAML block (nested keys
    /// and lists are skipped) and the body after it.
    static func splitFrontMatter(_ raw: String) -> ([String: String], String) {
        let text = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return ([:], text) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], text)
        }
        var values: [String: String] = [:]
        for line in lines[1..<end] where !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.hasPrefix("-") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty && !value.isEmpty { values[key] = value }
        }
        return (values, lines[(end + 1)...].joined(separator: "\n"))
    }

    nonisolated(unsafe) static let imagePattern = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\([^)]*\)"#)
    nonisolated(unsafe) static let linkPattern = try! NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#)
    nonisolated(unsafe) static let wikiEmbedPattern = try! NSRegularExpression(pattern: #"!\[\[[^\]]*\]\]"#)
    nonisolated(unsafe) static let wikiAliasPattern = try! NSRegularExpression(pattern: #"\[\[[^\]|]*\|([^\]]*)\]\]"#)
    nonisolated(unsafe) static let wikiLinkPattern = try! NSRegularExpression(pattern: #"\[\[([^\]]*)\]\]"#)
    /// JSX components (capitalized) and common HTML tags. Inline code is left alone
    /// only in the sense that tags inside backticks are rare in prose.
    nonisolated(unsafe) static let tagPattern = try! NSRegularExpression(
        pattern: #"</?(?:[A-Z][A-Za-z0-9.]*|div|span|p|br|img|a|details|summary|sup|sub|table|thead|tbody|tr|td|th|iframe|video|source|figure|figcaption|picture)(?:\s[^<>]*)?/?>"#)

    static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        guard text.contains("[") || text.contains("<") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
