import Foundation

/// Talks to a local Ollama server. All traffic stays on this machine.
public struct OllamaClient: Sendable {
    public let baseURL: URL

    public init(baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.baseURL = baseURL
    }

    public enum ClientError: LocalizedError {
        case serverUnreachable
        case badResponse(String)
        case modelMissing(String)

        public var errorDescription: String? {
            switch self {
            case .serverUnreachable:
                return "The local AI engine isn't running."
            case .badResponse(let m):
                return "The local AI engine returned something unexpected: \(m)"
            case .modelMissing(let name):
                return "The model “\(name)” isn't downloaded yet."
            }
        }
    }

    public struct ModelInfo: Identifiable, Hashable, Sendable {
        public let name: String
        public let sizeBytes: Int64
        public var id: String { name }

        public var sizeLabel: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    /// True when the server answers on the configured port.
    public func isRunning() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Models already downloaded and ready to use.
    public func installedModels() async throws -> [ModelInfo] {
        let url = baseURL.appendingPathComponent("api/tags")
        let (data, _) = try await URLSession.shared.data(from: url)
        struct Tags: Decodable {
            struct Model: Decodable {
                let name: String
                let size: Int64?
            }
            let models: [Model]
        }
        let tags = try JSONDecoder().decode(Tags.self, from: data)
        return tags.models.map { ModelInfo(name: $0.name, sizeBytes: $0.size ?? 0) }
    }

    /// Downloads a model, streaming progress (0...1) and a status line.
    public func pull(model: String, progress: @Sendable @escaping (Double, String) -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": model, "stream": true])
        request.timeoutInterval = 3600

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ClientError.badResponse("pull failed to start")
        }
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = obj["error"] as? String {
                throw ClientError.badResponse(error)
            }
            let status = obj["status"] as? String ?? ""
            if let total = obj["total"] as? Double, total > 0,
               let completed = obj["completed"] as? Double {
                progress(completed / total, status)
            } else {
                progress(status == "success" ? 1.0 : 0, status)
            }
        }
    }

    /// Summarizes a transcript with structured JSON output, streaming so
    /// callers can prove liveness to the user (a long local generation is
    /// otherwise indistinguishable from a hang).
    /// `peopleHint` biases the model toward canonical name spellings;
    /// `progress` receives the total characters generated so far.
    public func summarize(
        transcript: String,
        systemPrompt: String,
        model: String,
        peopleHint: [String] = [],
        contextWindow: Int = 16384,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> MemoSummary {
        var prompt = systemPrompt
        if !peopleHint.isEmpty {
            prompt += """


            The speaker's world includes these people (canonical spellings): \(peopleHint.joined(separator: ", ")). \
            If the transcript names someone who sounds like one of them, use the canonical spelling in your output.
            """
        }

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "distillation": ["type": "string"],
                "key_points": ["type": "array", "items": ["type": "string"]],
                "tags": ["type": "array", "items": ["type": "string"]],
                "people": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["distillation", "key_points", "tags", "people"],
        ]
        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": transcript],
            ],
            "format": schema,
            "stream": true,
            // Reasoning models (qwen3.5 etc.) otherwise spend *minutes*
            // thinking out loud before the JSON; a summary doesn't need
            // chain-of-thought. Non-thinking models ignore the flag.
            "think": false,
            // The default 4096 context silently truncates long memos —
            // hard-won lesson from the CLI proof of concept.
            "options": ["num_ctx": contextWindow, "temperature": 0.2],
        ]

        do {
            return try await chat(payload: payload, progress: progress)
        } catch ClientError.badResponse(let message) where message.lowercased().contains("think") {
            // Some Ollama versions reject `think` for models without the
            // capability instead of ignoring it. Retry without.
            payload.removeValue(forKey: "think")
            return try await chat(payload: payload, progress: progress)
        }
    }

    private func chat(payload: [String: Any], progress: (@Sendable (Int) -> Void)?) async throws -> MemoSummary {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 1800

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.serverUnreachable }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            if body.contains("not found"), let model = payload["model"] as? String {
                throw ClientError.modelMissing(model)
            }
            throw ClientError.badResponse(body)
        }

        var content = ""
        var streamed = 0
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = obj["error"] as? String { throw ClientError.badResponse(error) }
            if let message = obj["message"] as? [String: Any] {
                if let chunk = message["content"] as? String, !chunk.isEmpty {
                    content += chunk
                    streamed += chunk.count
                    progress?(streamed)
                }
                // If a model thinks anyway, its thinking still proves life.
                if let thinking = message["thinking"] as? String, !thinking.isEmpty {
                    streamed += thinking.count
                    progress?(streamed)
                }
            }
            if obj["done"] as? Bool == true { break }
        }
        return try Self.parseSummaryContent(content)
    }

    /// Parses the model's accumulated JSON output. Split out for tests.
    public static func parseSummaryContent(_ content: String) throws -> MemoSummary {
        guard let data = content.data(using: .utf8), !content.isEmpty else {
            throw ClientError.badResponse("empty message")
        }
        do {
            return try JSONDecoder().decode(MemoSummary.self, from: data)
        } catch {
            throw ClientError.badResponse("model returned malformed JSON")
        }
    }

    /// Parses a non-streaming /api/chat response body. Kept for tests and
    /// third-party reuse.
    public static func parseChatResponse(_ data: Data) throws -> MemoSummary {
        struct Chat: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let chat = try JSONDecoder().decode(Chat.self, from: data)
        return try parseSummaryContent(chat.message.content)
    }
}
