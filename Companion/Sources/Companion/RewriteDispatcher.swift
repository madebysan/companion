import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.santiagoalonso.companion", category: "RewriteDispatcher")

// Routes rewrite requests to the right provider based on saved action settings.
// Keeps legacy mode support for the macOS Services entry.
// Handles fallback from local to a remote fal/OpenRouter model when local is unavailable.
final class RewriteDispatcher {
    static let shared = RewriteDispatcher()

    enum DispatchError: Error, LocalizedError {
        case emptyInstruction
        case emptySelectionForAction(String)
        case noProviderAvailable(String)
        case imageUnsupported(String)

        var errorDescription: String? {
            switch self {
            case .emptyInstruction:
                return "Type a prompt first."
            case .emptySelectionForAction(let actionName):
                return "\(actionName) needs selected text. Type a custom prompt to create new text."
            case .noProviderAvailable(let detail): return detail
            case .imageUnsupported(let detail): return detail
            }
        }
    }

    // Legacy mode entry point for Services compatibility.
    func rewrite(_ text: String, mode: UserSettings.RewriteMode) async throws -> String {
        try await generate(text, mode: mode).text
    }

    func generate(
        _ text: String,
        mode: UserSettings.RewriteMode,
        route: GenerationRoute = .auto,
        images: [PromptImageAttachment] = []
    ) async throws -> GenerationResult {
        let settings = UserSettings.shared
        let provider = settings.provider(for: mode)
        guard let resolvedRoute = route.routeOverride ?? settings.defaultModelRoute(for: provider) else {
            throw DispatchError.noProviderAvailable("No model route is configured for \(provider.shortLabel).")
        }
        let systemPrompt = settings.prompt(for: mode)

        return try await generate(text, systemPrompt: systemPrompt, route: resolvedRoute, images: images)
    }

    func rewrite(_ text: String, action: UserSettings.SavedAction) async throws -> String {
        try await generate(text, action: action, route: .auto, images: []).text
    }

    func generate(
        _ text: String,
        action: UserSettings.SavedAction,
        route: GenerationRoute,
        images: [PromptImageAttachment]
    ) async throws -> GenerationResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DispatchError.emptySelectionForAction(action.name)
        }
        let settings = UserSettings.shared
        guard let resolvedRoute = route.routeOverride ?? settings.route(for: action) else {
            throw DispatchError.noProviderAvailable("No model route is configured for \(action.name).")
        }
        return try await generate(text, systemPrompt: action.prompt, route: resolvedRoute, images: images)
    }

    func rewrite(_ text: String, customInstruction: String) async throws -> String {
        try await generate(text, customInstruction: customInstruction, route: .auto, images: []).text
    }

    func generate(
        _ text: String,
        customInstruction: String,
        route: GenerationRoute,
        images: [PromptImageAttachment]
    ) async throws -> GenerationResult {
        let instruction = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { throw DispatchError.emptyInstruction }

        let hasSelectedText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let systemPrompt: String
        let userText: String

        if hasSelectedText {
            systemPrompt = """
                Apply this instruction to the selected text:
                \(instruction)

                Preserve the user's meaning unless the instruction explicitly asks for a stronger transformation.
                Return only the transformed text. Do not include a preamble, explanation, markdown fence, or quotes.
                """
            userText = text
        } else {
            systemPrompt = """
                Create new text from the user's instruction.

                Return only the requested text. Do not include a preamble, explanation, markdown fence, or quotes.
                """
            userText = instruction
        }

        let settings = UserSettings.shared
        let defaultRoute = settings.customPromptRouteID.flatMap { settings.modelRoute(for: $0) }
            ?? settings.defaultModelRoute(for: settings.customPromptProvider)
        guard let resolvedRoute = route.routeOverride ?? defaultRoute else {
            throw DispatchError.noProviderAvailable("No model route is configured for custom prompts.")
        }
        return try await generate(
            userText,
            systemPrompt: systemPrompt,
            route: resolvedRoute,
            images: images
        )
    }

    private func generate(
        _ text: String,
        systemPrompt: String,
        route: UserSettings.ModelRoute,
        images: [PromptImageAttachment] = []
    ) async throws -> GenerationResult {
        let settings = UserSettings.shared
        guard settings.hasAccess(to: route.provider) else {
            throw DispatchError.noProviderAvailable("Add a \(route.provider.shortLabel) API key in Settings or choose another route.")
        }
        try validateImages(images, route: route)

        switch route.provider {
        case .openAI:
            let result = try await OpenAIAPI.shared.rewrite(
                text,
                systemPrompt: systemPrompt,
                model: route.model,
                images: images
            )
            return GenerationResult(text: result, provider: .openAI, model: route.model)

        case .claude:
            let result = try await ClaudeAPI.shared.rewrite(
                text,
                systemPrompt: systemPrompt,
                model: route.model,
                images: images
            )
            return GenerationResult(text: result, provider: .claude, model: route.model)

        case .deepSeek:
            let result = try await DeepSeekAPI.shared.rewrite(
                text,
                systemPrompt: systemPrompt,
                model: route.model
            )
            return GenerationResult(text: result, provider: .deepSeek, model: route.model)

        case .fal:
            let result = try await FalAPI.shared.rewrite(
                text,
                systemPrompt: systemPrompt,
                model: route.model,
                images: images
            )
            return GenerationResult(text: result, provider: .fal, model: route.model)

        case .lmStudio:
            do {
                let result = try await LMStudioAPI.shared.rewrite(
                    text,
                    systemPrompt: systemPrompt,
                    model: route.model,
                    images: images
                )
                return GenerationResult(text: result, provider: .lmStudio, model: route.model)
            } catch {
                logger.notice("local provider failed: \(error.localizedDescription)")

                guard settings.fallbackToClaude else { throw error }
                guard let remoteRoute = settings.availableModelRoutes.first(where: { $0.provider != .lmStudio }) else {
                    throw DispatchError.noProviderAvailable(
                        "Local provider failed and no remote model is available. Add a cloud provider key in Settings, or disable fallback."
                    )
                }
                try validateImages(images, route: remoteRoute)

                notifyFallback()
                return try await generate(
                    text,
                    systemPrompt: systemPrompt,
                    route: remoteRoute,
                    images: images
                )
            }
        }
    }

    private func validateImages(_ images: [PromptImageAttachment], route: UserSettings.ModelRoute) throws {
        guard !images.isEmpty else { return }
        guard route.supportsImages else {
            throw DispatchError.imageUnsupported(
                "\(route.displayModel) cannot read images. Choose a model marked Images in Settings."
            )
        }
    }

    private func notifyFallback() {
        let content = UNMutableNotificationContent()
        content.title = "Companion"
        content.body = "Local model unavailable, used a remote model instead."
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "fallback-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
