import SwiftUI

/// M0 shell: a menu bar item whose window starts the browser tap and live
/// transcription. Retrieval, answers and the overlay panel arrive in M3 and M4.
@main
struct JeevesApp: App {
    @State private var model = ListeningModel()

    var body: some Scene {
        MenuBarExtra {
            StatusView(model: model)
        } label: {
            Image(systemName: model.isRunning ? "ear.fill" : "ear")
        }
        .menuBarExtraStyle(.window)
    }
}
