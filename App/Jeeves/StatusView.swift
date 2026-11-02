import AppKit
import AudioCapture
import JeevesCore
import SwiftUI

struct StatusView: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = app.listening
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Jeeves").font(.headline)
                Spacer()
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .lineLimit(2)
            }

            Picker("Browser", selection: $model.browser) {
                ForEach(Browser.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .disabled(model.isRunning)

            Picker("Capture", selection: $model.strategy) {
                ForEach(TapStrategy.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .disabled(model.isRunning)

            LevelMeter(decibels: model.levelDecibels)
            if !model.captureStatus.isEmpty {
                Text(model.captureStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Button(model.isRunning ? "Stop listening" : "Start listening") {
                    if model.isRunning {
                        model.stop()
                    } else {
                        model.start()
                        app.panel.show()
                    }
                }
                .keyboardShortcut(.defaultAction)
                Button("Answers panel") { app.panel.toggle() }
                Spacer()
                Button("Settings...") { showSettings() }
            }

            Toggle("Answer detected questions automatically",
                   isOn: Binding(get: { app.assistant.autoAnswer }, set: { app.assistant.autoAnswer = $0 }))
                .font(.callout)
            Text(knowledgeLine)
                .font(.caption)
                .foregroundStyle(app.knowledge.isEmpty || !app.assistant.hasAPIKey ? Color.orange : Color.secondary)
                .lineLimit(2)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.finals.suffix(30).enumerated()), id: \.offset) { _, line in
                            Text(line).textSelection(.enabled)
                        }
                        if !model.partial.isEmpty {
                            Text(model.partial).foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                .onChange(of: model.finals.count) { proxy.scrollTo("bottom") }
                .onChange(of: model.partial) { proxy.scrollTo("bottom") }
            }

            if let detection = model.lastDetection {
                Text(detection).font(.caption).foregroundStyle(.blue).lineLimit(2)
            }

            if let lag = model.lagSummary {
                Text(lag).font(.caption.monospaced()).foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Text("Jeeves \(Self.version): Q&A from your notes").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 400)
        .onAppear {
            app.openSettingsWindow = { [openWindow] in
                openWindow(id: "settings")
                NSApp.activate()
            }
        }
    }

    private func showSettings() {
        openWindow(id: "settings")
        NSApp.activate()
    }

    private var knowledgeLine: String {
        if app.knowledge.isIndexing { return "Indexing... " + app.knowledge.summary }
        if app.knowledge.isEmpty { return "No knowledge sources yet: open Settings to add the Anthropic docs or your notes." }
        if !app.assistant.hasAPIKey { return "No API key: passages only. Add a key in Settings for answers." }
        return app.knowledge.summary + " · " + AssistantModel.label(for: app.assistant.mode)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private var isFailure: Bool {
        if case .failed = app.listening.phase { return true }
        return false
    }
}

struct LevelMeter: View {
    let decibels: Float

    var body: some View {
        // Map -60...0 dBFS onto the bar.
        let fraction = CGFloat(max(0, min(1, (decibels + 60) / 60)))
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(fraction > 0.85 ? Color.orange : Color.green)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(decibels)) decibels")
    }
}
