import AppKit
import Assistant
import KnowledgeIndex
import SwiftUI

/// A floating panel for answers (docs/prd/06): stays above the browser on every Space,
/// does not activate Jeeves when clicked, and is excluded from screen sharing and
/// screenshots (`sharingType = .none`).
final class AnswerPanel: NSPanel {
    // A non-activating panel can still take key status, so the Ask field accepts typing
    // without pulling focus away from the browser's window ordering.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AnswerPanelController {
    private var panel: AnswerPanel?
    private let assistant: AssistantModel
    private let listening: ListeningModel
    private let openSettings: @MainActor () -> Void

    init(assistant: AssistantModel, listening: ListeningModel, openSettings: @escaping @MainActor () -> Void) {
        self.assistant = assistant
        self.listening = listening
        self.openSettings = openSettings
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    func toggle() { isVisible ? hide() : show() }

    private func makePanel() -> AnswerPanel {
        let panel = AnswerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = "Jeeves"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 320, height: 300)
        panel.contentView = NSHostingView(rootView: AnswerView(assistant: assistant, listening: listening,
                                                               openSettings: openSettings))
        if !panel.setFrameUsingName("JeevesAnswerPanel"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - 460, y: visible.maxY - 580))
        }
        _ = panel.setFrameAutosaveName("JeevesAnswerPanel")
        return panel
    }
}

struct AnswerView: View {
    let assistant: AssistantModel
    let listening: ListeningModel
    let openSettings: @MainActor () -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            askField
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let current = assistant.current {
                        ExchangeView(exchange: current, expanded: true)
                    } else {
                        emptyState
                    }
                    ForEach(assistant.history) { exchange in
                        Divider()
                        ExchangeView(exchange: exchange, expanded: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 28)  // clears the transparent title bar
        .padding(.bottom, 8)
        .frame(minWidth: 320, minHeight: 300)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(listening.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(listening.isRunning ? listening.statusText : "Not listening")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Picker("Model", selection: Binding(get: { assistant.mode }, set: { assistant.mode = $0 })) {
                ForEach(AssistantModel.modes, id: \.self) { Text(AssistantModel.label(for: $0)).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }

    private var askField: some View {
        HStack(spacing: 6) {
            TextField("Ask your notes...", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Button("Ask", action: submit)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Answer last") {
                if let turn = listening.lastTurn { assistant.ask(turn.utterance, leadIn: turn.leadIn, trigger: .manual) }
            }
            .disabled(listening.lastUtterance.isEmpty)
            .help(listening.lastUtterance.isEmpty ? "Nothing heard yet" : "Answer: \(listening.lastUtterance)")
        }
        .controlSize(.small)
    }

    private func submit() {
        assistant.ask(draft, trigger: .manual)
        draft = ""
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if assistant.knowledge.isEmpty {
                Text("No knowledge sources indexed yet.").font(.headline)
                Text("Add the Anthropic docs or a notes folder in Settings, then ask a question here or start listening to a call.")
                    .foregroundStyle(.secondary)
                Button("Open Settings", action: openSettings)
            } else if !assistant.hasAPIKey {
                Text("Add your Anthropic API key").font(.headline)
                Text("Passages from your notes work without one; answers need a key from platform.claude.com.")
                    .foregroundStyle(.secondary)
                Button("Open Settings", action: openSettings)
            } else {
                Text(assistant.autoAnswer ? "Questions heard on the call are answered here." : "Auto-answer is off: type a question or use Answer last.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

struct ExchangeView: View {
    let exchange: Exchange
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(exchange.trigger.rawValue)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(exchange.trigger == .detected ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.2)))
                VStack(alignment: .leading, spacing: 2) {
                    if !exchange.leadIn.isEmpty {
                        Text(exchange.leadIn)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? 3 : 1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                    }
                    Text(exchange.question)
                        .font(expanded ? .callout.weight(.medium) : .caption)
                        .foregroundStyle(expanded ? Color.primary : Color.secondary)
                        .textSelection(.enabled)
                }
                if exchange.revision > 0 {
                    Text("updated")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("The speaker added to the question, so it was answered again")
                }
            }

            if expanded || !exchange.answer.isEmpty {
                answer
            }

            if expanded && !exchange.passages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(exchange.passages) { passage in
                        PassageRow(passage: passage)
                    }
                }
            }

            if expanded, let footer = footer {
                Text(footer).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var answer: some View {
        switch exchange.status {
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        case .searching:
            Text("Searching...").font(.callout).foregroundStyle(.secondary)
        case .answering, .done:
            if exchange.answer.isEmpty {
                if exchange.status == .answering {
                    Text(exchange.retryNote ?? "Answering...").font(.callout).foregroundStyle(.secondary)
                } else if let note = exchange.summary?.note {
                    Text(Self.sentence(note)).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text(Self.markdown(exchange.answer))
                    .font(expanded ? .body : .callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: String? {
        var parts: [String] = []
        if let ms = exchange.passagesMs { parts.append("passages \(Int(ms)) ms") }
        if let summary = exchange.summary {
            if let ttft = summary.firstTokenMs { parts.append("first token \(Int(ttft)) ms") }
            if let model = summary.model { parts.append(model.replacingOccurrences(of: "claude-", with: "")) }
            if let cost = summary.costUSD { parts.append(String(format: "$%.4f", cost)) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func sentence(_ note: String) -> String {
        guard let first = note.first else { return note }
        return String(first).uppercased() + String(note.dropFirst()) + "."
    }

    /// Inline Markdown (bold, code, links) with line breaks kept, so "- " bullets stay
    /// on their own lines.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct PassageRow: View {
    let passage: Passage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("[\(passage.number)]").font(.caption.monospacedDigit().weight(.semibold))
                Text(passage.breadcrumb).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button {
                    openSource(passage.source)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help(passage.source)
            }
            Text(snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private var snippet: String {
        passage.text.split(separator: "\n").filter { !$0.hasPrefix("```") }.joined(separator: " ")
    }

    private func openSource(_ source: String) {
        if let url = URL(string: source), url.scheme?.hasPrefix("http") == true {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: source))
        }
    }
}
