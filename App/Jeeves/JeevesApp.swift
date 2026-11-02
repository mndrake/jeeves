import AppKit
import SwiftUI

/// Wires the models together: listening -> question detection -> assistant -> panel.
@MainActor
@Observable
final class AppModel {
    let knowledge: KnowledgeModel
    let assistant: AssistantModel
    let listening: ListeningModel
    @ObservationIgnored private(set) var panel: AnswerPanelController!
    /// Set by the scene so non-SwiftUI code (the panel) can open the settings window.
    @ObservationIgnored var openSettingsWindow: @MainActor () -> Void = {}

    init() {
        knowledge = KnowledgeModel()
        assistant = AssistantModel(knowledge: knowledge)
        listening = ListeningModel()
        panel = AnswerPanelController(assistant: assistant, listening: listening,
                                      openSettings: { [weak self] in self?.openSettingsWindow() })
        listening.onQuestion = { [weak self] question in
            guard let self, self.assistant.autoAnswer else { return }
            self.assistant.ask(question, trigger: .detected)
            self.panel.show()
        }
        assistant.recentTranscript = { [weak self] in self?.listening.recentTranscript() ?? "" }
    }
}

@main
struct JeevesApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        MenuBarExtra {
            StatusView(app: app)
        } label: {
            Image(systemName: app.listening.isRunning ? "ear.fill" : "ear")
        }
        .menuBarExtraStyle(.window)

        Window("Jeeves Settings", id: "settings") {
            SettingsView(assistant: app.assistant, knowledge: app.knowledge)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentMinSize)
    }
}
