import AppKit
import AudioCapture
import SwiftUI

struct StatusView: View {
    @Bindable var model: ListeningModel

    var body: some View {
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

            Button(model.isRunning ? "Stop listening" : "Start listening") {
                model.isRunning ? model.stop() : model.start()
            }
            .keyboardShortcut(.defaultAction)

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
                .frame(height: 240)
                .onChange(of: model.finals.count) { proxy.scrollTo("bottom") }
                .onChange(of: model.partial) { proxy.scrollTo("bottom") }
            }

            if let lag = model.lagSummary {
                Text(lag).font(.caption.monospaced()).foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Text("M0 build: transcript only").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 400)
    }

    private var isFailure: Bool {
        if case .failed = model.phase { return true }
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
