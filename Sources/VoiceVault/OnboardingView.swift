import SwiftUI
import VoiceVaultCore

struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var step = 0

    private let stepCount = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: WelcomeStep(next: advance)
                case 1: MemosAccessStep(next: advance)
                case 2: VaultStep(next: advance)
                case 3: EngineStep(next: advance)
                default: PeopleStep(finish: finish)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                ForEach(0..<stepCount, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 20)
            .accessibilityLabel("Step \(step + 1) of \(stepCount)")
        }
        .background(.background)
    }

    private func advance() { withAnimation(.easeInOut(duration: 0.25)) { step += 1 } }

    private func finish() {
        state.settings.onboardingComplete = true
        state.reloadLibrary()
    }
}

// MARK: - Step 1: the promise

private struct WelcomeStep: View {
    let next: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            WaveToNoteMark(height: 56)
                .padding(.top, 40)

            Text("Your voice memos, remembered")
                .font(.system(size: 30, weight: .bold, design: .rounded))

            Text("VoiceVault turns each Apple Voice Memo into a searchable note in your Obsidian vault: the full transcript, a short summary, and links to the people and topics you mention.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            VStack(alignment: .leading, spacing: 10) {
                promiseRow(symbol: "lock.fill",
                           "Recordings and transcripts never leave this Mac. There is no account, no cloud, no analytics.")
                promiseRow(symbol: "arrow.down.circle",
                           "The only things ever downloaded are the two AI models that do the work — Apple's transcriber and a local summarizer. Both run entirely on this Mac.")
                promiseRow(symbol: "eye",
                           "You see every note before it's written. Voice Memos itself is never touched.")
            }
            .frame(maxWidth: 520)
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))

            Button("Get started", action: next)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private func promiseRow(symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(Identity.violet)
            Text(text).font(.callout)
        }
    }
}

// MARK: - Step 2: reading the memos

private struct MemosAccessStep: View {
    @Environment(AppState.self) private var state
    let next: () -> Void
    @State private var granted = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 20) {
            stepHeader(
                symbol: "waveform",
                title: "Let VoiceVault see your recordings",
                subtitle: "macOS protects your Voice Memos. To read them, VoiceVault opens a window pointing at your Voice Memos library — you just click Grant Access. Read-only, nothing is moved or changed.")

            if granted {
                Label("\(state.memos.count) recordings found", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                Button("Continue", action: next)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Open my Voice Memos library") {
                    granted = state.promptForFolder(voiceMemos: true)
                    failed = !granted
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if failed {
                    VStack(spacing: 8) {
                        Text(state.libraryError ?? "That folder couldn't be read.")
                            .foregroundStyle(.red)
                        Text("If macOS keeps refusing, you can give VoiceVault Full Disk Access in System Settings → Privacy & Security, then try again. Or use a folder of exported recordings instead.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                        Button("Open Privacy & Security settings") {
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                    }
                }

                Button("Use a folder of audio files instead…") {
                    granted = state.promptForFolder(voiceMemos: false)
                    failed = !granted
                }
                .buttonStyle(.link)
            }
            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Step 3: where notes go

private struct VaultStep: View {
    @Environment(AppState.self) private var state
    let next: () -> Void

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 20) {
            stepHeader(
                symbol: "folder",
                title: "Where should the notes live?",
                subtitle: "Pick a folder inside your Obsidian vault — a subfolder like “journals/voice memos” works well. Any folder is fine; notes are plain Markdown files.")

            if let path = state.settings.vaultFolderPath {
                Label(path, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .truncationMode(.middle)
                    .frame(maxWidth: 480)

                Toggle("Also copy each recording's audio file into that folder", isOn: $state.settings.copyAudioIntoVault)
                    .toggleStyle(.checkbox)
                Text("Off by default: most people keep the vault text-only and leave audio where it already lives.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("Continue", action: next)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Choose a folder…") { _ = state.promptForVault() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Step 4: the local AI engine

private struct EngineStep: View {
    @Environment(AppState.self) private var state
    let next: () -> Void

    @State private var checking = true
    @State private var installing = false
    @State private var pulling = false
    @State private var progress: Double = 0
    @State private var statusLine = ""
    @State private var errorMessage: String? = nil
    @State private var modelReady = false

    var body: some View {
        VStack(spacing: 20) {
            stepHeader(
                symbol: "brain",
                title: "Set up the summarizer",
                subtitle: "Summaries come from a small AI model that runs on this Mac through a free engine called Ollama. VoiceVault sets it up for you — this is the one-time download mentioned earlier.")

            if checking {
                ProgressView("Checking what's already installed…")
            } else if modelReady {
                Label("The summarizer is ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                Button("Continue", action: next)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else if installing || pulling {
                VStack(spacing: 10) {
                    ProgressView(value: progress)
                        .frame(maxWidth: 420)
                    Text(statusLine.isEmpty ? "Working…" : statusLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("This can take a few minutes depending on your connection. Feel free to leave it running.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else if !state.engineReady {
                Button("Download and set up the engine") { install() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Text("About 25 MB now, then the model (≈ \(modelSizeLabel)) in the next step.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button("Download the summary model (\(modelSizeLabel))") { pullModel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Text("Model: \(state.settings.model) — you can switch models any time in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 460)
                    .multilineTextAlignment(.center)
            }

            if !modelReady && !checking {
                Button("Set this up later") { next() }
                    .buttonStyle(.link)
                Text("Without it, notes still get full transcripts — just no summaries or suggested tags yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 40)
        .task { await check() }
    }

    private var modelSizeLabel: String {
        state.settings.model.hasPrefix("llama3.2") ? "2 GB" : "7 GB"
    }

    private func check() async {
        checking = true
        await state.refreshEngine()
        modelReady = state.engineReady && state.installedModels.contains {
            $0.name == state.settings.model
        }
        // Someone with models already pulled shouldn't re-download ours:
        // adopt their first model as the default.
        if state.engineReady, !modelReady, let first = state.installedModels.first {
            state.settings.model = first.name
            modelReady = true
        }
        checking = false
    }

    private func install() {
        installing = true
        errorMessage = nil
        Task {
            do {
                try await state.ollamaManager.installManagedRuntime { p, status in
                    Task { @MainActor in progress = p; statusLine = status }
                }
                await state.refreshEngine()
                installing = false
                pullModel()
            } catch {
                await MainActor.run {
                    installing = false
                    errorMessage = "The engine couldn't be set up: \(error.localizedDescription). You can also install the Ollama app from ollama.com and come back."
                }
            }
        }
    }

    private func pullModel() {
        pulling = true
        errorMessage = nil
        progress = 0
        Task {
            do {
                try await state.ollamaManager.client.pull(model: state.settings.model) { p, status in
                    Task { @MainActor in progress = p; statusLine = status }
                }
                await state.refreshEngine()
                await MainActor.run {
                    pulling = false
                    modelReady = true
                }
            } catch {
                await MainActor.run {
                    pulling = false
                    errorMessage = "The model download failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Step 5: people

private struct PeopleStep: View {
    @Environment(AppState.self) private var state
    let finish: () -> Void
    @State private var newName = ""

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 16) {
            stepHeader(
                symbol: "person.2",
                title: "Teach it your people",
                subtitle: "Transcribers mangle names — Suren becomes “Soren”, Isa becomes “Issa”. List the people you actually talk about and VoiceVault fixes their names in transcripts and links them properly in your vault. Add more any time in Settings.")

            HStack {
                TextField("A name you often mention, e.g. Suren", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit(addName)
                Button("Add", action: addName)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !state.settings.people.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.settings.people) { person in
                            HStack {
                                Text(person.name)
                                Spacer()
                                Button {
                                    state.settings.people.removeAll { $0.id == person.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(person.name)")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                        }
                    }
                    .frame(maxWidth: 360)
                }
                .frame(maxHeight: 160)
            }

            Button("Start using VoiceVault", action: finish)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

            if state.settings.people.isEmpty {
                Text("You can skip this — it just makes transcripts smarter.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private func addName() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        state.settings.people.append(PersonName(name: name))
        newName = ""
    }
}

// MARK: - Shared header

private func stepHeader(symbol: String, title: String, subtitle: String) -> some View {
    VStack(spacing: 14) {
        Image(systemName: symbol)
            .font(.system(size: 34))
            .foregroundStyle(Identity.gradient)
            .padding(.top, 44)
        Text(title)
            .font(.system(size: 24, weight: .bold, design: .rounded))
        Text(subtitle)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 540)
    }
    .padding(.bottom, 8)
}
