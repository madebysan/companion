import Foundation

// Handles fal's OpenRouter-backed OpenAI-compatible chat completions endpoint.
final class FalAPI {
    static let shared = FalAPI()

    private let endpoint = URL(string: "https://fal.run/openrouter/router/openai/v1/chat/completions")!

    func rewrite(
        _ text: String,
        systemPrompt: String,
        model overrideModel: String? = nil,
        images: [PromptImageAttachment] = []
    ) async throws -> String {
        let settings = UserSettings.shared
        let apiKey = settings.falAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        return try await OpenAICompatibleAPI.shared.rewrite(
            text,
            systemPrompt: systemPrompt,
            providerName: "fal",
            endpoint: endpoint,
            apiKey: apiKey,
            authorizationHeader: "Key \(apiKey)",
            model: overrideModel ?? settings.falModel,
            images: images
        )
    }
}
