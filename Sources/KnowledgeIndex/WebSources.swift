import Foundation

/// Parses an `llms.txt` index (https://llmstxt.org): a Markdown file whose list items
/// link to the site's pages, on Anthropic's doc sites as `.md` URLs.
public enum LLMSTxt {
    public struct Link: Sendable, Equatable {
        public var title: String
        public var url: URL
    }

    /// Absolute http(s) links in document order, deduplicated, without links to other
    /// `llms*.txt` files. `excluding` drops URLs whose path contains any of the strings.
    public static func links(in text: String, excluding: [String] = []) -> [Link] {
        let pattern = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#)
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var links: [Link] = []
        for match in pattern.matches(in: text, range: range) {
            guard let titleRange = Range(match.range(at: 1), in: text),
                  let urlRange = Range(match.range(at: 2), in: text),
                  let url = URL(string: String(text[urlRange])) else { continue }
            let path = url.path
            let last = url.lastPathComponent.lowercased()
            if last.hasPrefix("llms") && last.hasSuffix(".txt") { continue }
            if excluding.contains(where: { !$0.isEmpty && path.contains($0) }) { continue }
            // One page per URL, ignoring fragments.
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            let key = components?.string ?? url.absoluteString
            guard seen.insert(key).inserted, let clean = components?.url else { continue }
            links.append(Link(title: String(text[titleRange]), url: clean))
        }
        return links
    }
}

/// Converts an HTML page to Markdown-ish text for the generic URL fallback: drops
/// scripts, styles, navigation and footers, maps headings to `#` lines, and decodes
/// common entities. Not a readability engine; Markdown sources are preferred.
public enum HTMLText {
    public static func document(fromHTML html: String, location: String) -> SourceDocument {
        let title = firstMatch(#"<title[^>]*>(.*?)</title>"#, in: html).map(decodeEntities)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var body = html
        if let main = firstMatch(#"<main[^>]*>(.*?)</main>"#, in: html) ?? firstMatch(#"<article[^>]*>(.*?)</article>"#, in: html) {
            body = main
        }
        for tag in ["script", "style", "noscript", "nav", "footer", "header", "svg", "aside", "form"] {
            body = replace(#"<\#(tag)\b[^>]*>.*?</\#(tag)>"#, in: body, with: " ")
        }
        body = replace(#"<!--.*?-->"#, in: body, with: " ")
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            body = replace(#"<h\#(level)\b[^>]*>(.*?)</h\#(level)>"#, in: body, with: "\n\n\(hashes) $1\n\n")
        }
        body = replace(#"<pre\b[^>]*>(.*?)</pre>"#, in: body, with: "\n\n```\n$1\n```\n\n")
        body = replace(#"<li\b[^>]*>"#, in: body, with: "\n- ")
        body = replace(#"</?(p|div|section|br|tr|ul|ol|table|blockquote)\b[^>]*>"#, in: body, with: "\n\n")
        body = replace(#"<[^>]+>"#, in: body, with: "")
        body = decodeEntities(body)
        // Collapse whitespace within lines and runs of blank lines.
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "\t", with: " ").split(separator: " ").joined(separator: " ")
        }
        var output: [String] = []
        for line in lines {
            if line.isEmpty, output.last?.isEmpty ?? true { continue }
            output.append(line)
        }
        // Heading lines may have picked up inner spaces; fix "#  Title".
        let markdown = output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = URL(string: location)?.lastPathComponent ?? location
        let resolvedTitle = (title?.isEmpty == false ? title! : nil) ?? MarkdownChunker.firstHeading(in: markdown, level: 1) ?? fallback
        return SourceDocument(location: location, title: resolvedTitle, markdown: markdown)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}", "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}",
                     "&mdash;": "\u{2014}", "&ndash;": "\u{2013}", "&hellip;": "\u{2026}", "&copy;": "\u{00A9}"]
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        let numeric = try! NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]+);"#)
        let matches = numeric.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
        for match in matches {
            guard let whole = Range(match.range, in: result), let digits = Range(match.range(at: 2), in: result) else { continue }
            let hex = match.range(at: 1).length > 0
            if let value = UInt32(result[digits], radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
