import SwiftUI
import AVFoundation
import VoiceVaultCore

/// Where a memo sits in its journey from recording to vault note.
enum MemoStatus: Equatable {
    case new
    case processing(String)      // human-readable phase
    case inReview
    case saved(String)           // note filename
    case failed(String)
}

@MainActor
@Observable
final class AppState {
    var settings: AppSettings {
        didSet { SettingsStore.save(settings) }
    }

    var memos: [Memo] = []
    var statuses: [String: MemoStatus] = [:]
    var selection: Set<String> = []
    var libraryError: String? = nil

    var reviewQueue: [ProcessedNote] = []
    var showReview = false

    var isProcessing = false
    var processingProgress: (done: Int, total: Int) = (0, 0)
    private var processingTask: Task<Void, Never>? = nil
    /// Start time and streamed character count of the summary in flight.
    private var summarizeProgress: (start: Date, chars: Int)? = nil

    // Local AI engine state, shared by onboarding and settings.
    let ollamaManager: OllamaManager
    var engineReady = false
    var installedModels: [OllamaClient.ModelInfo] = []

    init() {
        let loaded = SettingsStore.load()
        settings = loaded
        ollamaManager = OllamaManager(client: OllamaClient(baseURL: loaded.ollamaURL))
    }

    func status(of memo: Memo) -> MemoStatus {
        if let s = statuses[memo.id] { return s }
        if let filename = settings.exported[memo.id] { return .saved(filename) }
        return .new
    }

    // MARK: - Audio preview

    /// Which memo is currently playing, if any.
    var previewingID: String? = nil
    private var previewPlayer: AVAudioPlayer? = nil
    private var previewWatcher: Task<Void, Never>? = nil

    /// Plays a memo so the user can jog their memory before processing;
    /// tapping again (or another memo) stops it.
    func togglePreview(_ memo: Memo) {
        let wasPlaying = previewingID == memo.id
        stopPreview()
        guard !wasPlaying else { return }
        guard let player = try? AVAudioPlayer(contentsOf: memo.url) else { return }
        previewPlayer = player
        previewingID = memo.id
        player.play()
        previewWatcher = Task { [weak self] in
            while let self, let player = self.previewPlayer, player.isPlaying {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if let self, self.previewingID == memo.id, self.previewPlayer?.isPlaying != true {
                self.stopPreview()
            }
        }
    }

    func stopPreview() {
        previewWatcher?.cancel()
        previewWatcher = nil
        previewPlayer?.stop()
        previewPlayer = nil
        previewingID = nil
    }

    // MARK: - Library

    func reloadLibrary() {
        libraryError = nil
        guard let folder = settings.inputFolder else {
            memos = []
            return
        }
        do {
            memos = try VoiceMemoLibrary.load(from: folder)
        } catch {
            memos = []
            libraryError = error.localizedDescription
        }
    }

    /// Asks the user to point at a folder. For the Voice Memos library the
    /// panel opens pre-navigated to the recordings container, so "just click
    /// Grant Access" — the click is what gives us permission to read it.
    func promptForFolder(voiceMemos: Bool) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = voiceMemos
        if voiceMemos {
            panel.directoryURL = VoiceMemoLibrary.defaultRecordingsFolder
            panel.message = "This is your Voice Memos library. Click Grant Access to let VoiceVault read your recordings. Nothing is changed or deleted."
            panel.prompt = "Grant Access"
        } else {
            panel.message = "Choose a folder of audio recordings."
            panel.prompt = "Choose"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        settings.inputMode = voiceMemos ? .voiceMemos : .folder
        settings.inputFolderPath = url.path
        reloadLibrary()
        return libraryError == nil
    }

    func promptForVault() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder in your Obsidian vault where voice memo notes should live."
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        settings.vaultFolderPath = url.path
        return true
    }

    // MARK: - Local AI engine

    func refreshEngine() async {
        engineReady = await ollamaManager.client.isRunning()
        if !engineReady {
            engineReady = await ollamaManager.startServerIfPossible()
        }
        if engineReady {
            installedModels = (try? await ollamaManager.client.installedModels()) ?? []
        }
    }

    // MARK: - Processing

    func processSelected() {
        let ids = selection
        let targets = memos.filter { ids.contains($0.id) && $0.isAvailable }
        process(targets)
    }

    func process(_ targets: [Memo]) {
        guard !targets.isEmpty, !isProcessing else { return }
        isProcessing = true
        processingProgress = (0, targets.count)
        let engine = ProcessingEngine(settings: settings)
        let autoSave = settings.autoSaveAfterProcessing

        processingTask = Task { [weak self] in
            for (index, memo) in targets.enumerated() {
                guard let self, !Task.isCancelled else { break }
                self.statuses[memo.id] = .processing("Transcribing…")
                self.summarizeProgress = nil

                // A local model can take minutes on a long memo, and the
                // model streams nothing while it reads the transcript. The
                // ticker keeps the clock moving so slow never looks stuck.
                let ticker = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard let self, let start = self.summarizeProgress?.start else { continue }
                        let chars = self.summarizeProgress?.chars ?? 0
                        let elapsed = Int(Date().timeIntervalSince(start))
                        var label = "Summarizing… \(elapsed / 60):" + String(format: "%02d", elapsed % 60)
                        label += chars > 0 ? " · \(chars / 5) words" : " · thinking"
                        self.statuses[memo.id] = .processing(label)
                    }
                }
                defer { ticker.cancel() }

                do {
                    let note = try await engine.process(memo) { phase in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            switch phase {
                            case .transcribing:
                                self.statuses[memo.id] = .processing("Transcribing…")
                            case .summarizing(let chars):
                                let start = self.summarizeProgress?.start ?? Date()
                                self.summarizeProgress = (start, chars)
                            }
                        }
                    }
                    self.summarizeProgress = nil
                    if autoSave {
                        let filename = try engine.write(note)
                        self.settings.exported[memo.id] = filename
                        self.statuses[memo.id] = .saved(filename)
                    } else {
                        self.reviewQueue.append(note)
                        self.statuses[memo.id] = .inReview
                    }
                } catch {
                    self.statuses[memo.id] = .failed(error.localizedDescription)
                }
                self.processingProgress = (index + 1, targets.count)
            }
            guard let self else { return }
            self.isProcessing = false
            self.processingTask = nil
            if !self.reviewQueue.isEmpty { self.showReview = true }
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
        isProcessing = false
        summarizeProgress = nil
        for (id, status) in statuses {
            if case .processing = status { statuses[id] = .new }
        }
    }

    // MARK: - Review queue

    func save(_ note: ProcessedNote) {
        let engine = ProcessingEngine(settings: settings)
        do {
            let filename = try engine.write(note)
            settings.exported[note.memo.id] = filename
            statuses[note.memo.id] = .saved(filename)
            reviewQueue.removeAll { $0.id == note.id }
        } catch {
            statuses[note.memo.id] = .failed(error.localizedDescription)
        }
        if reviewQueue.isEmpty { showReview = false }
    }

    func saveAllReviewed() {
        for note in reviewQueue { save(note) }
    }

    func discard(_ note: ProcessedNote) {
        reviewQueue.removeAll { $0.id == note.id }
        statuses[note.memo.id] = .new
        if reviewQueue.isEmpty { showReview = false }
    }
}
