import SwiftUI
import VoiceVaultCore

@main
struct VoiceVaultApp: App {
    @State private var state = AppState()
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .frame(minWidth: 760, minHeight: 520)
                .onDisappear { state.ollamaManager.shutdownManagedServer() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(state)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.settings.onboardingComplete {
            LibraryView()
        } else {
            OnboardingView()
        }
    }
}
