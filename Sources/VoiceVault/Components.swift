import SwiftUI
import VoiceVaultCore

/// VoiceVault's identity colors: Voice Memos' coral melting into
/// Obsidian's violet. Used for the signature mark and nowhere loudly else.
enum Identity {
    static let coral = Color(red: 1.0, green: 0.32, blue: 0.27)
    static let violet = Color(red: 0.48, green: 0.32, blue: 0.93)
    static let gradient = LinearGradient(
        colors: [coral, violet], startPoint: .leading, endPoint: .trailing)
}

/// The signature: a waveform that becomes lines of text, left to right.
/// Says the whole app in one glyph — speech in, notes out.
struct WaveToNoteMark: View {
    var height: CGFloat = 44

    // Bar heights: waveform amplitudes on the left, flattening into
    // text-line heights on the right.
    private let bars: [(h: CGFloat, isText: Bool)] = [
        (0.45, false), (0.85, false), (0.6, false), (1.0, false), (0.5, false),
        (0.75, false), (0.35, false),
        (0.16, true), (0.16, true), (0.16, true),
    ]

    var body: some View {
        HStack(alignment: .center, spacing: height * 0.10) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                RoundedRectangle(cornerRadius: height * 0.05)
                    .frame(
                        width: bar.isText ? height * 0.30 : height * 0.10,
                        height: height * bar.h)
            }
        }
        .foregroundStyle(Identity.gradient)
        .frame(height: height)
        .accessibilityLabel("VoiceVault: voice memos become notes")
    }
}

/// The trust anchor, pinned to the bottom of every main screen.
struct OnDevicePill: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
            Text("Everything happens on this Mac — recordings and transcripts never leave it")
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }
}

/// Status chip for a memo row.
struct StatusChip: View {
    let status: MemoStatus

    var body: some View {
        switch status {
        case .new:
            EmptyView()
        case .processing(let phase):
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text(phase)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .inReview:
            chip("Ready to review", color: .orange, symbol: "eye")
        case .saved:
            chip("In your vault", color: .green, symbol: "checkmark")
        case .failed(let message):
            chip("Failed", color: .red, symbol: "exclamationmark.triangle")
                .help(message)
        }
    }

    private func chip(_ label: String, color: Color, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(label).font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

extension Memo {
    var durationLabel: String {
        guard let duration else { return "" }
        let s = Int(duration.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    var createdLabel: String {
        created.formatted(date: .abbreviated, time: .shortened)
    }
}
