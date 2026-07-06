import SwiftUI
import VoiceVaultCore

/// The gate between processing and the vault: every note is shown in full
/// before it's written anywhere.
struct ReviewView: View {
    @Environment(AppState.self) private var state
    @State private var selectedID: String? = nil

    private var selected: ProcessedNote? {
        state.reviewQueue.first { $0.id == selectedID } ?? state.reviewQueue.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review before saving")
                    .font(.headline)
                Spacer()
                Text("\(state.reviewQueue.count) waiting")
                    .foregroundStyle(.secondary)
                Button("Save all to vault") { state.saveAllReviewed() }
                    .disabled(state.reviewQueue.isEmpty)
                Button("Close") { state.showReview = false }
            }
            .padding(12)

            Divider()

            HSplitView {
                List(state.reviewQueue, selection: $selectedID) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.memo.title)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if note.transcriptIsEmpty {
                                Label("No speech found", systemImage: "waveform.slash")
                                    .foregroundStyle(.orange)
                            } else if note.summaryFailed {
                                Label("Transcript only", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                    .help(note.summaryError ?? "")
                            }
                            if !note.corrections.isEmpty {
                                Label(correctionSummary(note), systemImage: "person.text.rectangle")
                                    .foregroundStyle(Identity.violet)
                            }
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 2)
                    .tag(note.id)
                }
                .frame(minWidth: 220, maxWidth: 320)

                if let note = selected {
                    NoteDetail(note: note)
                } else {
                    Text("Nothing to review")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 780, minHeight: 520)
    }

    private func correctionSummary(_ note: ProcessedNote) -> String {
        note.corrections.map(\.label).joined(separator: ", ")
    }
}

private struct NoteDetail: View {
    @Environment(AppState.self) private var state
    let note: ProcessedNote

    var body: some View {
        VStack(spacing: 0) {
            if !note.corrections.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "person.text.rectangle")
                        .foregroundStyle(Identity.violet)
                    Text("Names fixed: " + note.corrections.map {
                        "\($0.from) → \($0.to)\($0.count > 1 ? " (×\($0.count))" : "")"
                    }.joined(separator: ", "))
                        .font(.callout)
                    Spacer()
                }
                .padding(10)
                .background(Identity.violet.opacity(0.08))
            }

            ScrollView {
                Text(note.markdown)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()
            HStack {
                Text(note.filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                Spacer()
                Button("Discard", role: .destructive) { state.discard(note) }
                    .help("Skip this one — the recording is untouched and can be processed again")
                Button("Save to vault") { state.save(note) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }
}
