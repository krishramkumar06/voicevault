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

    /// Summarizes a transcript with structured JSON output.
    /// `peopleHint` biases the model toward canonical name spellings.
    public func summarize(
        transcript: String,
        systemPrompt: String,
        model: String,
        peopleHint: [String] = [],
        contextWindow: Int = 16384
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
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": transcript],
            ],
            "format": schema,
            "stream": false,
            // The default 4096 context silently truncates long memos —
            // hard-won lesson from the CLI proof of concept.
            "options": ["num_ctx": contextWindow, "temperature": 0.2],
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 900

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.serverUnreachable }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("not found") { throw ClientError.modelMissing(model) }
            throw ClientError.badResponse(body)
        }
        return try Self.parseChatResponse(data)
    }

    /// Parses an /api/chat response body into a summary. Split out for tests.
    public static func parseChatResponse(_ data: Data) throws -> MemoSummary {
        struct Chat: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let chat = try JSONDecoder().decode(Chat.self, from: data)
        guard let content = chat.message.content.data(using: .utf8) else {
            throw ClientError.badResponse("empty message")
        }
        do {
            return try JSONDecoder().decode(MemoSummary.self, from: content)
        } catch {
            throw ClientError.badResponse("model returned malformed JSON")
        }
    }
}
