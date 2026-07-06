import Foundation
import AppKit

/// Gets a local Ollama server running without the user touching a terminal.
///
/// Strategy, gentlest first:
///  1. A server is already answering → use it.
///  2. Ollama.app is installed → launch it (it starts its own server).
///  3. An ollama binary exists (Homebrew, or one we installed) → run
///     `ollama serve` as a child process we own.
///  4. Nothing installed → download the official standalone runtime into
///     Application Support and go to 3. No admin rights needed.
public final class OllamaManager: @unchecked Sendable {
    public let client: OllamaClient
    private var serveProcess: Process?
    private let queue = DispatchQueue(label: "voicevault.ollama-manager")

    /// Where a VoiceVault-managed runtime lives.
    public static var managedRuntimeDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceVault/ollama-runtime")
    }

    public static let runtimeDownloadURL =
        URL(string: "https://github.com/ollama/ollama/releases/latest/download/ollama-darwin.tgz")!

    public init(client: OllamaClient = OllamaClient()) {
        self.client = client
    }

    public enum Availability: Sendable, Equatable {
        case running
        case appInstalled(String)        // path to Ollama.app
        case binaryInstalled(String)     // path to ollama binary
        case notInstalled
    }

    public func availability() async -> Availability {
        if await client.isRunning() { return .running }
        for app in ["/Applications/Ollama.app",
                    ("~/Applications/Ollama.app" as NSString).expandingTildeInPath] {
            if FileManager.default.fileExists(atPath: app) { return .appInstalled(app) }
        }
        if let binary = installedBinary() { return .binaryInstalled(binary) }
        return .notInstalled
    }

    public func installedBinary() -> String? {
        let candidates = [
            Self.managedRuntimeDirectory.appendingPathComponent("ollama").path,
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Ensures a server is running, whatever it takes short of downloading.
    /// Returns false if there's nothing installed to start.
    public func startServerIfPossible() async -> Bool {
        switch await availability() {
        case .running:
            return true
        case .appInstalled(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return await waitUntilRunning()
        case .binaryInstalled(let binary):
            launchServe(binary: binary)
            return await waitUntilRunning()
        case .notInstalled:
            return false
        }
    }

    private func launchServe(binary: String) {
        queue.sync {
            guard serveProcess == nil || serveProcess?.isRunning != true else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["serve"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                serveProcess = process
            } catch {
                serveProcess = nil
            }
        }
    }

    private func waitUntilRunning(timeout: TimeInterval = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await client.isRunning() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return await client.isRunning()
    }

    /// Downloads and unpacks the official standalone runtime, then starts it.
    public func installManagedRuntime(progress: @Sendable @escaping (Double, String) -> Void) async throws {
        progress(0, "Downloading the local AI engine…")
        let (tempFile, _) = try await URLSession.shared.download(from: Self.runtimeDownloadURL)

        progress(0.8, "Unpacking…")
        let dir = Self.managedRuntimeDirectory
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let untar = Process()
        untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        untar.arguments = ["-xzf", tempFile.path, "-C", dir.path]
        try untar.run()
        untar.waitUntilExit()
        guard untar.terminationStatus == 0 else {
            throw OllamaClient.ClientError.badResponse("couldn't unpack the AI engine download")
        }

        let binary = dir.appendingPathComponent("ollama").path
        guard FileManager.default.fileExists(atPath: binary) else {
            throw OllamaClient.ClientError.badResponse("the AI engine download was missing its binary")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)

        progress(0.9, "Starting the engine…")
        launchServe(binary: binary)
        guard await waitUntilRunning() else {
            throw OllamaClient.ClientError.serverUnreachable
        }
        progress(1, "Ready")
    }

    /// Stops a server we started (never one the user was already running).
    public func shutdownManagedServer() {
        queue.sync {
            serveProcess?.terminate()
            serveProcess = nil
        }
    }
}
