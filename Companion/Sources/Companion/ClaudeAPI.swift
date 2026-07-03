import Foundation

// Handles communication with the Claude API
final class ClaudeAPI {
    static let shared = ClaudeAPI()
    static let modelName = "claude-haiku-4-5-20251001"

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    enum APIError: Error, LocalizedError {
        case noAPIKey
        case requestFailed(String)
        case invalidResponse
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "No Claude API key configured. Add one in Settings."
            case .requestFailed(let msg): return "Claude request failed: \(msg)"
            case .invalidResponse: return "Invalid response from Claude"
            case .emptyResponse: return "Empty response from Claude"
            }
        }
    }

    // Send text to Claude for rewriting using the given system prompt
    func rewrite(
        _ text: String,
        systemPrompt: String,
        model: String = ClaudeAPI.modelName,
        images: [PromptImageAttachment] = []
    ) async throws -> String {
        let apiKey = UserSettings.shared.apiKey
        guard !apiKey.isEmpty else { throw APIError.noAPIKey }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userContent(text: text, images: images)]
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.requestFailed("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let resultText = firstBlock["text"] as? String else {
            throw APIError.invalidResponse
        }

        guard !resultText.isEmpty else {
            throw APIError.emptyResponse
        }

        return resultText
    }

    private func userContent(text: String, images: [PromptImageAttachment]) -> Any {
        guard !images.isEmpty else { return text }

        var content = images.map { image in
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mimeType,
                    "data": image.data.base64EncodedString()
                ]
            ] as [String: Any]
        }
        content.append(["type": "text", "text": text])
        return content
    }

    // Validate an API key by making a minimal request
    func validateKey(_ key: String) async -> Bool {
        let body: [String: Any] = [
            "model": Self.modelName,
            "max_tokens": 1,
            "messages": [
                ["role": "user", "content": "Hi"]
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }
}
