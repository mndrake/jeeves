import AppKit
import JeevesCore
import KnowledgeIndex
import SwiftUI

struct SettingsView: View {
    let assistant: AssistantModel
    let knowledge: KnowledgeModel
    let listening: ListeningModel

    @State private var keyDraft = ""
    @State private var keyMessage: String?
    @State private var sourceDraft = ""
    @State private var sourceMessage: String?
    @State private var searchDraft = ""

    var body: some View {
        Form {
            Section("Claude") {
                LabeledContent("API key") {
                    HStack {
                        Text(assistant.maskedKey).font(.callout.monospaced()).foregroundStyle(.secondary)
                        if assistant.hasAPIKey {
                            Button("Remove") { assistant.removeAPIKey() }
                        }
                    }
                }
                HStack {
                    SecureField("sk-ant-...", text: $keyDraft)
                    Button("Save key") {
                        keyMessage = assistant.saveAPIKey(keyDraft) ? "Saved to the Keychain." : "Could not save the key."
                        keyDraft = ""
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let keyMessage { Text(keyMessage).font(.caption).foregroundStyle(.secondary) }
                Text("Create a key at platform.claude.com. It is stored in your login Keychain and sent only to api.anthropic.com.")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Answer model", selection: Binding(get: { assistant.mode }, set: { assistant.mode = $0 })) {
                    ForEach(AssistantModel.modes, id: \.self) { Text(AssistantModel.label(for: $0)).tag($0) }
                }
                Toggle("Answer questions heard on the call automatically",
                       isOn: Binding(get: { assistant.autoAnswer }, set: { assistant.autoAnswer = $0 }))
            }

            QuestionDetectionSection(listening: listening)

            Section("Knowledge sources") {
                Text(knowledge.summary).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(knowledge.searchStatus).font(.caption)
                        .foregroundStyle(knowledge.isHybrid ? Color.secondary : Color.orange)
                    if !knowledge.isHybrid && knowledge.searchStatus.hasPrefix("Keyword search only") {
                        Button("Retry") { Task { await knowledge.enableHybridSearch() } }.controlSize(.small)
                    }
                }
                if knowledge.sources.isEmpty {
                    Text("Nothing indexed yet. Start with the Anthropic docs, add a folder of Markdown notes, or paste a URL.")
                        .font(.callout)
                }
                ForEach(knowledge.sources) { source in
                    SourceRow(source: source, progress: knowledge.progress[source.id],
                              reindex: { knowledge.reindex(source.id) },
                              remove: { knowledge.remove(source.id) })
                }
                HStack {
                    if !knowledge.hasSource(.claudePlatformDocs) {
                        Button("Add Claude API docs") { knowledge.add(.claudePlatformDocs) }
                    }
                    if !knowledge.hasSource(.claudeCodeDocs) {
                        Button("Add Claude Code docs") { knowledge.add(.claudeCodeDocs) }
                    }
                    Button("Add folder...") { chooseFolder() }
                    Spacer()
                    if !knowledge.sources.isEmpty {
                        Button("Re-index all") { knowledge.reindexAll() }.disabled(knowledge.isIndexing)
                    }
                }
                HStack {
                    TextField("llms.txt or page URL, or a folder path", text: $sourceDraft)
                        .onSubmit(addTyped)
                    Button("Add", action: addTyped)
                        .disabled(sourceDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let sourceMessage { Text(sourceMessage).font(.caption).foregroundStyle(.red) }
            }

            Section("Test search") {
                TextField("Type a question to see which passages Jeeves would use", text: $searchDraft)
                    .onSubmit { knowledge.search(searchDraft) }
                if let result = knowledge.searchResult {
                    Text(String(format: "%ld passages in %.1f ms (%@) for: %@", result.passages.count, result.milliseconds,
                                result.mode.rawValue, result.query))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(result.passages) { passage in
                        PassageRow(passage: passage)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 560)
    }

    private func addTyped() {
        sourceMessage = knowledge.addFromInput(sourceDraft) ? nil : "Enter a URL or a folder path."
        if sourceMessage == nil { sourceDraft = "" }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Index folder"
        panel.message = "Choose a folder of Markdown notes (an Obsidian vault works)."
        if panel.runModal() == .OK, let url = panel.url {
            knowledge.add(KnowledgeSource(kind: .folder, location: url.path, name: url.lastPathComponent))
        }
    }
}

struct SourceRow: View {
    let source: KnowledgeSource
    let progress: String?
    let reindex: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.callout.weight(.medium))
                Text(source.location).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(status).font(.caption).foregroundStyle(progress == nil ? Color.secondary : Color.accentColor)
                if let error = source.lastError, progress == nil {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer()
            if progress == nil {
                Button("Re-index", action: reindex).controlSize(.small)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Remove this source and its passages")
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var icon: String {
        switch source.kind {
        case .folder: "folder"
        case .llmsTxt: "books.vertical"
        case .webPage: "globe"
        }
    }

    private var status: String {
        if let progress { return progress }
        guard let date = source.lastIndexed else { return "Not indexed" }
        let when = date.formatted(date: .abbreviated, time: .shortened)
        return "\(source.documentCount) documents, \(source.chunkCount) passages, indexed \(when)"
    }
}


/// Question assembly settings. Defaults come from replaying recorded calls against
/// hand-checked questions; record your own with "Save call traces" and tune them with
/// spike-qa (docs/QUESTIONS.md).
struct QuestionDetectionSection: View {
    let listening: ListeningModel

    var body: some View {
        Section("Question detection") {
            Stepper(value: Binding(get: { listening.silenceMs }, set: { listening.silenceMs = $0 }), in: 200...1500, step: 100) {
                LabeledContent("Pause that ends a phrase", value: "\(Int(listening.silenceMs)) ms")
            }
            Text("Shorter answers sooner; longer waits for speakers who pause mid-question. Applies when listening next starts.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper(value: setting(\.leadInGap), in: 0...5, step: 0.5) {
                LabeledContent("Join phrases across pauses up to", value: String(format: "%.1f s", listening.assembly.leadInGap))
            }
            Stepper(value: setting(\.leadInSeconds), in: 0...60, step: 5) {
                LabeledContent("Lead-in reaches back up to", value: String(format: "%.0f s", listening.assembly.leadInSeconds))
            }
            Text("The lead-in is what the speaker said before the question (\"We run a bot on Sonnet. The prompt is long. How do we make that cheaper?\"). It is searched with the question and sent to Claude. 0 s turns it off.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper(value: setting(\.followUpWindow), in: 0...5, step: 0.5) {
                LabeledContent("Answer again after a follow-up within",
                               value: listening.assembly.followUpWindow == 0 ? "off" : String(format: "%.1f s", listening.assembly.followUpWindow))
            }
            Text("When the speaker keeps going after a question (\"...I mean for the batch API\"), the question is updated and answered again. A reply that starts like one (\"Yeah, great question...\") ends the question.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Restore defaults") {
                    listening.assembly = QuestionAssembler.Settings()
                    listening.silenceMs = 400
                }
                Spacer()
            }
            Toggle("Save call traces for calibration", isOn: Binding(get: { listening.saveTraces }, set: { listening.saveTraces = $0 }))
            HStack {
                Text("Records audio levels and the transcript (no audio) to Application Support/Jeeves/traces, for replaying with spike-qa.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show traces") {
                    try? FileManager.default.createDirectory(at: AppPaths.traces, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AppPaths.traces)
                }
                .controlSize(.small)
            }
        }
    }

    private func setting(_ keyPath: WritableKeyPath<QuestionAssembler.Settings, Double>) -> Binding<Double> {
        Binding(get: { listening.assembly[keyPath: keyPath] }, set: { listening.assembly[keyPath: keyPath] = $0 })
    }
}
