import Foundation

// Handles communication with a local LM Studio server (OpenAI-compatible API)
final class LMStudioAPI {
    static let shared = LMStudioAPI()

    enum APIError: Error, LocalizedError {
        case invalidURL
        case notReachable(String)
        case noModelConfigured
        case requestFailed(String)
        case invalidResponse
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid LM Studio URL. Check Settings."
            case .notReachable(let url): return "LM Studio not reachable at \(url). Is the server running?"
            case .noModelConfigured: return "No local model selected. Pick one in Settings."
            case .requestFailed(let msg): return "LM Studio request failed: \(msg)"
            case .invalidResponse: return "Invalid response from LM Studio"
            case .emptyResponse: return "Empty response from LM Studio"
            }
        }
    }

    // Rewrite text via LM Studio chat completions
    func rewrite(
        _ text: String,
        systemPrompt: String,
        model overrideModel: String? = nil,
        images: [PromptImageAttachment] = []
    ) async throws -> String {
        let baseURL = UserSettings.shared.lmStudioBaseURL
        let model = overrideModel ?? UserSettings.shared.lmStudioModel

        guard !model.isEmpty else { throw APIError.noModelConfigured }
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw APIError.invalidURL
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent(text: text, images: images)]
            ],
            "temperature": 0.3,
            "max_tokens": 4096
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.notReachable(baseURL)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.requestFailed("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let resultText = message["content"] as? String else {
            throw APIError.invalidResponse
        }

        let trimmed = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.emptyResponse
        }

        return trimmed
    }

    private func userContent(text: String, images: [PromptImageAttachment]) -> Any {
        guard !images.isEmpty else { return text }

        var content: [[String: Any]] = [
            ["type": "text", "text": text]
        ]

        for image in images {
            let encoded = image.data.base64EncodedString()
            let dataURL = "data:\(image.mimeType);base64,\(encoded)"
            content.append([
                "type": "image_url",
                "image_url": ["url": dataURL]
            ])
        }

        return content
    }

    // List available models at the configured base URL
    func listModels() async throws -> [String] {
        let baseURL = UserSettings.shared.lmStudioBaseURL
        guard let url = URL(string: "\(baseURL)/v1/models") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.notReachable(baseURL)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.invalidResponse
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else {
            throw APIError.invalidResponse
        }

        // Filter out embedding models — they can't do chat completions
        return models.compactMap { $0["id"] as? String }
            .filter { !$0.contains("embed") }
    }

    // Quick reachability check for fallback decisions
    func isReachable() async -> Bool {
        let baseURL = UserSettings.shared.lmStudioBaseURL
        guard let url = URL(string: "\(baseURL)/v1/models") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2

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
