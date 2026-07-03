import Foundation

enum GenerationRoute: Equatable {
    case auto
    case model(UserSettings.ModelRoute)

    var routeOverride: UserSettings.ModelRoute? {
        switch self {
        case .auto: return nil
        case .model(let route): return route
        }
    }

    var providerOverride: UserSettings.Provider? {
        switch self {
        case .auto: return nil
        case .model(let route): return route.provider
        }
    }

    func menuTitle(settings: UserSettings = .shared) -> String {
        switch self {
        case .auto:
            return "Auto"
        case .model(let route):
            return route.menuTitle
        }
    }
}

struct PromptImageAttachment {
    let fileName: String
    let mimeType: String
    let data: Data

    var sizeBytes: Int { data.count }
}

struct GenerationResult {
    let text: String
    let provider: UserSettings.Provider
    let model: String
}

extension UserSettings.Provider {
    func configuredModelName(settings: UserSettings = .shared) -> String {
        switch self {
        case .openAI:
            return settings.openAIModel
        case .claude:
            return settings.claudeModel
        case .lmStudio:
            return settings.lmStudioModel
        case .deepSeek:
            return settings.deepSeekModel
        case .fal:
            return settings.falModel
        }
    }

    func configuredModelLabel(settings: UserSettings = .shared) -> String {
        let model = configuredModelName(settings: settings)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return "No model" }

        let trimmed = model.replacingOccurrences(of: "~", with: "")
        if trimmed.count <= 22 { return trimmed }
        return "\(trimmed.prefix(19))..."
    }

    func supportsImageInput(settings: UserSettings = .shared) -> Bool {
        switch self {
        case .openAI:
            return Self.isKnownVisionModel(settings.openAIModel)
        case .claude:
            return true
        case .deepSeek:
            return false
        case .fal:
            return settings.falModelSupportsImages || Self.isKnownVisionModel(settings.falModel)
        case .lmStudio:
            return settings.localModelSupportsImages(settings.lmStudioModel)
        }
    }

    private static func isKnownVisionModel(_ model: String) -> Bool {
        let lower = model.lowercased()
        let markers = [
            "claude",
            "gemini",
            "gpt-4o",
            "gpt-4.1",
            "gpt-5",
            "o3",
            "o4",
            "vision",
            "pixtral",
            "llava",
            "qwen-vl",
            "qwen2-vl",
            "qwen2.5-vl",
            "vlm",
            "omni"
        ]
        return markers.contains { lower.contains($0) }
    }
}
