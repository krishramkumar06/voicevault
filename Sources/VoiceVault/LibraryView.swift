import SwiftUI
import VoiceVaultCore

struct LibraryView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    @State private var confirmAll = false
    @State private var searchText = ""

    private var visibleMemos: [Memo] {
        guard !searchText.isEmpty else { return state.memos }
        return state.memos.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = state.libraryError {
                    errorBanner(error)
                }

                if state.memos.isEmpty && state.libraryError == nil {
                    emptyState
                } else {
                    memoList
                }

                bottomBar
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search titles")
        .toolbar {
            ToolbarItem {
                Button {
                    state.reloadLibrary()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Re-read the recordings list")
            }
            ToolbarItem {
                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .navigationTitle("VoiceVault")
        .onAppear { state.reloadLibrary() }
        .task { await state.refreshEngine() }
        .sheet(isPresented: Bindable(state).showReview) {
            ReviewView()
        }
        .confirmationDialog(
            "Process all \(state.selection.count) recordings?",
            isPresented: $confirmAll) {
            Button("Process \(state.selection.count) recordings") {
                state.processSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each one will be transcribed and summarized on this Mac. You'll review every note before anything is saved to your vault.")
        }
    }

    // MARK: - List

    private var memoList: some View {
        List {
            Section {
                ForEach(visibleMemos) { memo in
                    MemoRow(memo: memo)
                }
            } header: {
                HStack {
                    Toggle(isOn: allSelectedBinding) {
                        Text("\(state.memos.count) recordings")
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    if state.selection.count > 0 {
                        Text("\(state.selection.count) selected")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var allSelectedBinding: Binding<Bool> {
        Binding(
            get: { !state.memos.isEmpty && state.selection.count == state.memos.count },
            set: { on in
                state.selection = on ? Set(state.memos.map(\.id)) : []
            })
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            WaveToNoteMark(height: 36).opacity(0.5)
            Text("No recordings found")
                .font(.title3.weight(.semibold))
            Text("Record something in Voice Memos, or choose a different folder in Settings.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(message).font(.callout)
                Text("Grant access again, or give VoiceVault Full Disk Access in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Grant access…") {
                _ = state.promptForFolder(voiceMemos: state.settings.inputMode == .voiceMemos)
            }
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.1))
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                OnDevicePill()
                Spacer()

                if state.isProcessing {
                    HStack(spacing: 10) {
                        ProgressView(
                            value: Double(state.processingProgress.done),
                            total: Double(max(state.processingProgress.total, 1)))
                            .frame(width: 140)
                        Text("\(state.processingProgress.done) of \(state.processingProgress.total)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button("Stop") { state.cancelProcessing() }
                    }
                } else {
                    if !state.reviewQueue.isEmpty {
                        Button("Review \(state.reviewQueue.count) notes…") {
                            state.showReview = true
                        }
                    }
                    Button(processButtonTitle) {
                        // Processing the whole library is a deliberate act.
                        if state.selection.count == state.memos.count && state.memos.count > 3 {
                            confirmAll = true
                        } else {
                            state.processSelected()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.selection.isEmpty || !vaultReady)
                    .help(vaultReady ? "Transcribe and summarize the selected recordings"
                                     : "Choose a vault folder in Settings first")
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .background(.bar)
    }

    private var vaultReady: Bool { state.settings.vaultFolderPath != nil }

    private var processButtonTitle: String {
        switch state.selection.count {
        case 0: "Process recordings"
        case 1: "Process 1 recording"
        case state.memos.count: "Process all \(state.selection.count)"
        default: "Process \(state.selection.count) recordings"
        }
    }
}

// MARK: - Row

private struct MemoRow: View {
    @Environment(AppState.self) private var state
    let memo: Memo

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: selectionBinding) { EmptyView() }
                .toggleStyle(.checkbox)
                .disabled(!memo.isAvailable)
                .accessibilityLabel("Select \(memo.title)")

            VStack(alignment: .leading, spacing: 2) {
                Text(memo.title)
                    .fontWeight(.medium)
                    .foregroundStyle(memo.isAvailable ? .primary : .tertiary)
                HStack(spacing: 6) {
                    Text(memo.createdLabel)
                    if !memo.durationLabel.isEmpty {
                        Text("·")
                        Text(memo.durationLabel).monospacedDigit()
                    }
                    if !memo.isAvailable {
                        Text("· audio not downloaded — open it once in Voice Memos")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
            StatusChip(status: state.status(of: memo))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            guard memo.isAvailable else { return }
            selectionBinding.wrappedValue.toggle()
        }
    }

    private var selectionBinding: Binding<Bool> {
        Binding(
            get: { state.selection.contains(memo.id) },
            set: { on in
                if on { state.selection.insert(memo.id) } else { state.selection.remove(memo.id) }
            })
    }
}
