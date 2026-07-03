import Foundation

// Handles communication with DeepSeek's OpenAI-compatible chat API.
final class DeepSeekAPI {
    static let shared = DeepSeekAPI()

    private let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    func rewrite(_ text: String, systemPrompt: String, model overrideModel: String? = nil) async throws -> String {
        let settings = UserSettings.shared
        let apiKey = settings.deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        return try await OpenAICompatibleAPI.shared.rewrite(
            text,
            systemPrompt: systemPrompt,
            providerName: "DeepSeek",
            endpoint: endpoint,
            apiKey: apiKey,
            authorizationHeader: "Bearer \(apiKey)",
            model: overrideModel ?? settings.deepSeekModel
        )
    }
}
