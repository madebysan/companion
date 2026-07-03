import Foundation

// Handles OpenAI's chat completions endpoint with a conservative request body.
final class OpenAIAPI {
    static let shared = OpenAIAPI()
    static let defaultModelName = "gpt-5"

    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    func rewrite(
        _ text: String,
        systemPrompt: String,
        model overrideModel: String? = nil,
        images: [PromptImageAttachment] = []
    ) async throws -> String {
        let settings = UserSettings.shared
        let apiKey = settings.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        return try await OpenAICompatibleAPI.shared.rewrite(
            text,
            systemPrompt: systemPrompt,
            providerName: "OpenAI",
            endpoint: endpoint,
            apiKey: apiKey,
            authorizationHeader: "Bearer \(apiKey)",
            model: overrideModel ?? settings.openAIModel,
            images: images,
            instructionRole: "developer",
            includeTemperature: false,
            maxTokensParameter: nil
        )
    }
}
