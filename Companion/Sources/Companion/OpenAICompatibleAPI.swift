import Foundation

// Shared client for providers that expose an OpenAI-compatible chat completions API.
final class OpenAICompatibleAPI {
    static let shared = OpenAICompatibleAPI()

    enum APIError: Error, LocalizedError {
        case noAPIKey(String)
        case noModelConfigured(String)
        case requestFailed(String, String)
        case invalidResponse(String)
        case emptyResponse(String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey(let provider):
                return "No \(provider) API key configured. Add one in Settings."
            case .noModelConfigured(let provider):
                return "No \(provider) model configured. Add one in Settings."
            case .requestFailed(let provider, let message):
                return "\(provider) request failed: \(message)"
            case .invalidResponse(let provider):
                return "Invalid response from \(provider)"
            case .emptyResponse(let provider):
                return "Empty response from \(provider)"
            }
        }
    }

    func rewrite(
        _ text: String,
        systemPrompt: String,
        providerName: String,
        endpoint: URL,
        apiKey: String,
        authorizationHeader: String,
        model: String,
        images: [PromptImageAttachment] = [],
        instructionRole: String = "system",
        includeTemperature: Bool = true,
        maxTokensParameter: String? = "max_tokens"
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedKey.isEmpty else { throw APIError.noAPIKey(providerName) }
        guard !trimmedModel.isEmpty else { throw APIError.noModelConfigured(providerName) }

        var body: [String: Any] = [
            "model": trimmedModel,
            "messages": [
                ["role": instructionRole, "content": systemPrompt],
                ["role": "user", "content": userContent(text: text, images: images)]
            ]
        ]
        if includeTemperature {
            body["temperature"] = 0.3
        }
        if let maxTokensParameter {
            body[maxTokensParameter] = 4096
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(authorizationHeader, forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse(providerName)
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = errorMessage(from: data)
            throw APIError.requestFailed(providerName, "HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        let responseJSON = try parseJSONResponse(data, providerName: providerName)
        let trimmed = responseJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.emptyResponse(providerName)
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

    private func parseJSONResponse(_ data: Data, providerName: String) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse(providerName)
        }

        if let text = completionText(from: json) {
            return text
        }

        if let wrappedData = json["data"] as? [String: Any],
           let text = completionText(from: wrappedData) {
            return text
        }

        throw APIError.invalidResponse(providerName)
    }

    private func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message.truncatedForDisplay()
            }

            if let message = json["message"] as? String {
                return message.truncatedForDisplay()
            }
        }

        let raw = String(data: data, encoding: .utf8) ?? "Unknown error"
        return raw.truncatedForDisplay()
    }

    private func completionText(from json: [String: Any]) -> String? {
        guard let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            return nil
        }

        return message["content"] as? String
    }
}

private extension String {
    func truncatedForDisplay(limit: Int = 220) -> String {
        guard count > limit else { return self }
        return "\(prefix(limit))..."
    }
}
