import SwiftUI
import VoiceVaultCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AISettings()
                .tabItem { Label("Summarizer", systemImage: "brain") }
            PeopleSettings()
                .tabItem { Label("People", systemImage: "person.2") }
        }
        .frame(width: 620, height: 480)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Recordings come from") {
                LabeledContent("Source") {
                    Text(state.settings.inputMode == .voiceMemos ? "Voice Memos library" : "A folder")
                }
                LabeledContent("Folder") {
                    Text(state.settings.inputFolderPath ?? "Not set")
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
                HStack {
                    Button("Use Voice Memos library…") {
                        _ = state.promptForFolder(voiceMemos: true)
                    }
                    Button("Use another folder…") {
                        _ = state.promptForFolder(voiceMemos: false)
                    }
                }
            }

            Section("Notes go to") {
                LabeledContent("Vault folder") {
                    Text(state.settings.vaultFolderPath ?? "Not set")
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
                Button("Change…") { _ = state.promptForVault() }
                Toggle("Copy each recording's audio into the vault", isOn: $state.settings.copyAudioIntoVault)
            }

            Section("Each note includes") {
                Toggle("Suggested tags", isOn: $state.settings.includeTags)
                Toggle("People links ([[Name]])", isOn: $state.settings.includePeople)
                Toggle("Key-point bullets", isOn: $state.settings.includeKeyPoints)
            }

            Section {
                Toggle("Save notes without reviewing first", isOn: $state.settings.autoSaveAfterProcessing)
                Text("When on, processed notes go straight into your vault. Leave off to check every note before it's written.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Summarizer (model + prompt)

private struct AISettings: View {
    @Environment(AppState.self) private var state
    @State private var pullName = ""
    @State private var pulling = false
    @State private var pullProgress: Double = 0
    @State private var pullStatus = ""
    @State private var pullError: String? = nil

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Model") {
                if state.engineReady {
                    Picker("Model", selection: $state.settings.model) {
                        ForEach(state.installedModels) { model in
                            Text("\(model.name)  (\(model.sizeLabel))").tag(model.name)
                        }
                        if !state.installedModels.contains(where: { $0.name == state.settings.model }) {
                            Text(state.settings.model).tag(state.settings.model)
                        }
                    }
                    HStack {
                        TextField("Download another model, e.g. llama3.2:3b", text: $pullName)
                        Button("Download") { pull() }
                            .disabled(pullName.trimmingCharacters(in: .whitespaces).isEmpty || pulling)
                    }
                    if pulling {
                        ProgressView(value: pullProgress) { Text(pullStatus).font(.caption) }
                    }
                    if let pullError {
                        Text(pullError).foregroundStyle(.red).font(.caption)
                    }
                    Text("Recommended: " + AppSettings.recommendedModels
                        .map { "\($0.name) — \($0.blurb)" }
                        .joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("The local AI engine isn't running", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Start it") {
                        Task { await state.refreshEngine() }
                    }
                }
            }

            Section("Summarization prompt") {
                TextEditor(text: $state.settings.systemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 150)
                HStack {
                    Text("This is the instruction the model gets with every transcript. Bend it to your workflow — different bullets, a different voice, other frontmatter fields.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore default") {
                        state.settings.systemPrompt = AppSettings.defaultSystemPrompt
                    }
                    .disabled(state.settings.systemPrompt == AppSettings.defaultSystemPrompt)
                }
            }
        }
        .formStyle(.grouped)
        .task { await state.refreshEngine() }
    }

    private func pull() {
        let name = pullName.trimmingCharacters(in: .whitespaces)
        pulling = true
        pullError = nil
        Task {
            do {
                try await state.ollamaManager.client.pull(model: name) { p, status in
                    Task { @MainActor in pullProgress = p; pullStatus = status }
                }
                await state.refreshEngine()
                await MainActor.run {
                    pulling = false
                    state.settings.model = name
                    pullName = ""
                }
            } catch {
                await MainActor.run {
                    pulling = false
                    pullError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - People

private struct PeopleSettings: View {
    @Environment(AppState.self) private var state
    @State private var newName = ""
    @State private var newAliases: [UUID: String] = [:]

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                Text("People whose names come up in your memos. VoiceVault fixes mishearings of these names in transcripts (conservatively — everyday words are never touched) and uses the right spelling for [[links]]. Add a known mishearing if the transcriber keeps inventing one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Names") {
                ForEach($state.settings.people) { $person in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Name", text: $person.name)
                                .fontWeight(.medium)
                            Button {
                                state.settings.people.removeAll { $0.id == person.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(person.name)")
                        }
                        HStack {
                            if !person.aliases.isEmpty {
                                Text("Also heard as: " + person.aliases.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            TextField("Add a mishearing, e.g. Soren",
                                      text: aliasBinding(for: person.id))
                                .font(.caption)
                                .textFieldStyle(.plain)
                                .onSubmit { commitAlias(for: person.id) }
                        }
                    }
                    .padding(.vertical, 2)
                }

                HStack {
                    TextField("Add a person…", text: $newName)
                        .onSubmit(addPerson)
                    Button("Add", action: addPerson)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func aliasBinding(for id: UUID) -> Binding<String> {
        Binding(get: { newAliases[id] ?? "" }, set: { newAliases[id] = $0 })
    }

    private func commitAlias(for id: UUID) {
        let alias = (newAliases[id] ?? "").trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty,
              let index = state.settings.people.firstIndex(where: { $0.id == id }) else { return }
        state.settings.people[index].aliases.append(alias)
        newAliases[id] = ""
    }

    private func addPerson() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        state.settings.people.append(PersonName(name: name))
        newName = ""
    }
}
