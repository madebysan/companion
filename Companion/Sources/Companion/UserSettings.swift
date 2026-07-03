import Foundation

// Wraps UserDefaults for all app settings
final class UserSettings {
    static let shared = UserSettings()

    private let defaults = UserDefaults.standard
    private static let legacyCompanionV2BundleID = "com.santiagoalonso.companion.v2"
    private static let legacyRewriteBundleID = "com.santiagoalonso.rewrite"

    private init() {
        migrateLegacyCompanionV2DefaultsIfNeeded()
        migrateLegacyRewriteDefaultsIfNeeded()
        migrateSavedActionsIfNeeded()
    }

    enum RewriteMode: String, CaseIterable {
        case fixGrammar = "fix_grammar"
        case improveWriting = "improve_writing"
        case humanize = "humanize"

        var label: String {
            switch self {
            case .fixGrammar: return "Fix Grammar"
            case .improveWriting: return "Improve Writing"
            case .humanize: return "Humanize"
            }
        }

        var description: String {
            switch self {
            case .fixGrammar: return "Fixes spelling, grammar, and punctuation. Keeps your words."
            case .improveWriting: return "Fixes errors and improves clarity, word choice, and flow."
            case .humanize: return "Strips AI-sounding patterns and makes text sound human."
            }
        }
    }

    enum Provider: String, CaseIterable, Codable {
        case openAI = "openai"
        case claude = "claude"
        case lmStudio = "lm_studio"
        case deepSeek = "deepseek"
        case fal = "fal"

        var label: String {
            switch self {
            case .openAI: return "OpenAI (Cloud)"
            case .claude: return "Claude (Cloud)"
            case .lmStudio: return "LM Studio (Local)"
            case .deepSeek: return "DeepSeek (Cloud)"
            case .fal: return "fal / OpenRouter (Remote)"
            }
        }

        var shortLabel: String {
            switch self {
            case .openAI: return "OpenAI"
            case .claude: return "Claude"
            case .lmStudio: return "Local"
            case .deepSeek: return "DeepSeek"
            case .fal: return "Remote"
            }
        }
    }

    struct SavedAction: Codable, Equatable {
        let id: String
        var name: String
        var prompt: String
        var provider: Provider
        var symbolName: String
        var routeID: String? = nil
    }

    struct ModelRoute: Codable, Equatable, Identifiable {
        let id: String
        var name: String
        var provider: Provider
        var model: String
        var supportsImages: Bool

        var menuTitle: String {
            if provider == .fal {
                return displayModel
            }
            return "\(provider.shortLabel) · \(displayModel)"
        }

        var displayModel: String {
            let cleaned = model.replacingOccurrences(of: "~", with: "")
            guard cleaned.count > 44 else { return cleaned }
            return "\(cleaned.prefix(41))..."
        }

        static func makeID(provider: Provider, model: String) -> String {
            let cleaned = model
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "~", with: "")
            return "\(provider.rawValue):\(cleaned)"
        }
    }

    struct RemoteCatalogModel: Codable, Equatable, Identifiable {
        let id: String
        var name: String
        var supportsImages: Bool

        var routeModel: String {
            id.hasPrefix("~") ? id : "~\(id)"
        }

        var displayTitle: String {
            name.isEmpty ? routeModel : name
        }
    }

    private enum Keys {
        static let apiKey = "apiKey"
        static let openAIAPIKey = "openAIAPIKey"
        static let openAIModel = "openAIModel"
        static let claudeModel = "claudeModel"
        static let deepSeekAPIKey = "deepSeekAPIKey"
        static let deepSeekModel = "deepSeekModel"
        static let falAPIKey = "falAPIKey"
        static let falModel = "falModel"
        static let falModelSupportsImages = "falModelSupportsImages"
        static let prompt = "rewritePrompt"
        static let improvePrompt = "improveWritingPrompt"
        static let humanizePrompt = "humanizePrompt"
        static let rewriteMode = "rewriteMode"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let launchAtLogin = "launchAtLogin"
        static let shortcutKeyCode = "shortcutKeyCode"
        static let shortcutModifiers = "shortcutModifiers"
        static let providerFixGrammar = "providerFixGrammar"
        static let providerImproveWriting = "providerImproveWriting"
        static let providerHumanize = "providerHumanize"
        static let lmStudioBaseURL = "lmStudioBaseURL"
        static let lmStudioModel = "lmStudioModel"
        static let lmStudioModelSupportsImages = "lmStudioModelSupportsImages"
        static let lmStudioVisionModels = "lmStudioVisionModels"
        static let fallbackToClaude = "fallbackToClaude"
        static let hasSetFallbackDefault = "hasSetFallbackDefault"
        static let savedActions = "savedActions"
        static let savedActionsTemplateVersion = "savedActionsTemplateVersion"
        static let customPromptProvider = "customPromptProvider"
        static let customPromptRouteID = "customPromptRouteID"
        static let configuredModelRoutes = "configuredModelRoutes"
        static let lmStudioKnownModels = "lmStudioKnownModels"
        static let remoteCatalogModels = "remoteCatalogModels"
        static let didImportLegacyCompanionV2Defaults = "didImportLegacyCompanionV2Defaults"
        static let didImportLegacyRewriteDefaults = "didImportLegacyRewriteDefaults"
    }

    // Default prompt — minimal corrections only
    static let defaultFixPrompt = """
        Rewrite the following text, fixing any grammar, spelling, and punctuation errors. \
        Preserve the original tone, style, and meaning. Do not add or remove information. \
        Only return the corrected text with no preamble, explanation, or quotes.
        """

    // Improve prompt — more freedom to restructure and clarify
    static let defaultImprovePrompt = """
        Improve the following text. Fix any grammar, spelling, and punctuation errors, \
        but also improve clarity, word choice, and sentence structure where it helps. \
        You may swap words for better alternatives, restructure sentences, and break up \
        or combine sentences for better flow. Keep the original meaning and tone — \
        make it sound like a better version of the same person writing. \
        Only return the improved text with no preamble, explanation, or quotes.
        """

    // Humanizer prompt — condensed from the write-humanizer skill, adapted for one-shot replacement.
    static let defaultHumanizePrompt = """
        Rewrite the selected text to remove signs of AI-generated writing and make it sound natural.

        Preserve the meaning, facts, placeholders, names, dates, numbers, and quoted text. Do not invent examples, sources, numbers, quotes, scenarios, or attributions.

        Remove these patterns when present:
        - Inflated significance: "serves as", "testament", "pivotal", "crucial", "underscores", "broader landscape"
        - Promotional language: "groundbreaking", "vibrant", "rich", "showcase", "seamless", "transformative"
        - Vague attribution: "experts argue", "industry observers", "some critics say"
        - Superficial -ing phrases: "highlighting", "emphasizing", "fostering", "showcasing", "reflecting"
        - AI vocabulary: "delve", "enhance", "intricate", "tapestry", "valuable", "key", "landscape"
        - Negative parallelisms: "not just X, but Y"
        - Forced groups of three, false "from X to Y" ranges, synonym cycling, and generic upbeat conclusions
        - Chatbot artifacts: "Great question", "Here is", "I hope this helps", "let me know"
        - Excessive bold, emojis, dramatic headings, curly quotes, semicolons, and em dashes

        Use simple words. Use "is", "are", and "has" instead of inflated phrasing. Vary sentence length. Keep some human texture, but stay faithful to the source.

        Return only the final rewritten text. No draft, audit notes, preamble, explanation, markdown fence, or quotes.
        """

    static let defaultShortenPrompt = """
        Rewrite the selected text to be shorter and easier to scan.

        Preserve the meaning, facts, names, dates, numbers, and important nuance. Remove repetition, filler, and unnecessary setup. Keep the user's voice unless the text is clearly too formal or too casual.

        Return only the shortened text. No preamble, explanation, quotes, or headers.
        """

    static let defaultEmailWriterPrompt = """
        Turn the selected notes or rough text into a clear, polished email.

        Use a natural professional tone. Add a subject only if the selected text already implies one. Keep the message concise, specific, and easy to reply to. Preserve all facts, names, dates, times, numbers, asks, and constraints from the source. Do not invent missing details.

        Return only the email text. No preamble, explanation, quotes, or markdown.
        """

    static let defaultFormalTonePrompt = """
        Rewrite the selected text in a more formal and professional tone.

        Preserve the meaning, facts, names, dates, numbers, and asks. Improve grammar and clarity where needed. Avoid sounding stiff, legalistic, or inflated.

        Return only the rewritten text. No preamble, explanation, quotes, or headers.
        """

    static let defaultLMStudioBaseURL = "http://127.0.0.1:1234"
    static let defaultOpenAIModel = OpenAIAPI.defaultModelName
    static let defaultClaudeModel = ClaudeAPI.modelName
    static let defaultDeepSeekModel = "deepseek-v4-flash"
    static let defaultFalModel = "~anthropic/claude-sonnet-latest"
    static let defaultRemoteCatalogModelCount = defaultRemoteCatalogModels.count
    private static let currentSavedActionsTemplateVersion = 7
    private static let retiredDefaultActionIDs: Set<String> = ["my_voice_light"]
    private static let unavailableFalModels: Set<String> = ["deepseek/deepseek-v4-flash"]

    static let defaultSavedActions: [SavedAction] = [
        SavedAction(
            id: "fix_grammar",
            name: "Fix Grammar",
            prompt: defaultFixPrompt,
            provider: .lmStudio,
            symbolName: "text.badge.checkmark"
        ),
        SavedAction(
            id: "improve_writing",
            name: "Improve Writing",
            prompt: defaultImprovePrompt,
            provider: .fal,
            symbolName: "sparkles"
        ),
        SavedAction(
            id: "humanize",
            name: "Humanizer",
            prompt: defaultHumanizePrompt,
            provider: .fal,
            symbolName: "person.text.rectangle"
        ),
        SavedAction(
            id: "shorten_text",
            name: "Shorten Text",
            prompt: defaultShortenPrompt,
            provider: .fal,
            symbolName: "text.alignleft"
        ),
        SavedAction(
            id: "email_writer",
            name: "Email Writer",
            prompt: defaultEmailWriterPrompt,
            provider: .fal,
            symbolName: "envelope"
        ),
        SavedAction(
            id: "formal_tone",
            name: "Formal Tone",
            prompt: defaultFormalTonePrompt,
            provider: .fal,
            symbolName: "briefcase"
        )
    ]

    var savedActions: [SavedAction] {
        get {
            guard let actions = storedSavedActions(), !actions.isEmpty else {
                return Self.defaultSavedActions.map { migratedRouteAction($0) }
            }
            return actions.map { migratedRouteAction($0) }
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.savedActions)
        }
    }

    private func storedSavedActions() -> [SavedAction]? {
        guard let data = defaults.data(forKey: Keys.savedActions),
              let actions = try? JSONDecoder().decode([SavedAction].self, from: data) else {
            return nil
        }
        return actions
    }

    private func migratedRouteAction(_ action: SavedAction) -> SavedAction {
        guard action.routeID == nil else { return action }
        var migrated = action
        migrated.routeID = defaultModelRoute(for: action.provider)?.id
        return migrated
    }

    private func migrateLegacyRewriteDefaultsIfNeeded() {
        importLegacyDefaults(
            from: Self.legacyRewriteBundleID,
            flagKey: Keys.didImportLegacyRewriteDefaults,
            overwriteExisting: false
        )
    }

    private func migrateLegacyCompanionV2DefaultsIfNeeded() {
        importLegacyDefaults(
            from: Self.legacyCompanionV2BundleID,
            flagKey: Keys.didImportLegacyCompanionV2Defaults,
            overwriteExisting: true
        )
    }

    private func importLegacyDefaults(from bundleID: String, flagKey: String, overwriteExisting: Bool) {
        guard !defaults.bool(forKey: flagKey) else { return }
        defer { defaults.set(true, forKey: flagKey) }

        guard let legacyDomain = defaults.persistentDomain(forName: bundleID),
              !legacyDomain.isEmpty else { return }

        let keysToImport = [
            Keys.apiKey,
            Keys.openAIAPIKey,
            Keys.openAIModel,
            Keys.claudeModel,
            Keys.deepSeekAPIKey,
            Keys.deepSeekModel,
            Keys.falAPIKey,
            Keys.falModel,
            Keys.falModelSupportsImages,
            Keys.prompt,
            Keys.improvePrompt,
            Keys.humanizePrompt,
            Keys.rewriteMode,
            Keys.hasCompletedOnboarding,
            Keys.launchAtLogin,
            Keys.shortcutKeyCode,
            Keys.shortcutModifiers,
            Keys.providerFixGrammar,
            Keys.providerImproveWriting,
            Keys.providerHumanize,
            Keys.lmStudioBaseURL,
            Keys.lmStudioModel,
            Keys.lmStudioModelSupportsImages,
            Keys.lmStudioVisionModels,
            Keys.fallbackToClaude,
            Keys.hasSetFallbackDefault,
            Keys.savedActions,
            Keys.savedActionsTemplateVersion,
            Keys.customPromptProvider,
            Keys.customPromptRouteID,
            Keys.configuredModelRoutes,
            Keys.lmStudioKnownModels,
            Keys.remoteCatalogModels,
        ]

        for key in keysToImport where overwriteExisting || defaults.object(forKey: key) == nil {
            if let value = legacyDomain[key] {
                defaults.set(value, forKey: key)
            }
        }
    }

    private func migrateSavedActionsIfNeeded() {
        let currentVersion = defaults.integer(forKey: Keys.savedActionsTemplateVersion)
        guard currentVersion < Self.currentSavedActionsTemplateVersion else { return }

        var actions = storedSavedActions().flatMap { $0.isEmpty ? nil : $0 } ?? legacySeededDefaultActions()
        actions.removeAll { Self.retiredDefaultActionIDs.contains($0.id) }
        for defaultAction in Self.defaultSavedActions {
            guard !actions.contains(where: { $0.id == defaultAction.id }) else { continue }
            actions.append(legacySeededDefaultAction(for: defaultAction))
        }
        if currentVersion < 3 {
            migratePreferredLocalRoutes(in: &actions)
        }
        if currentVersion < 7 {
            migrateUnavailableFalRoutes(in: &actions)
        }

        savedActions = actions
        defaults.set(Self.currentSavedActionsTemplateVersion, forKey: Keys.savedActionsTemplateVersion)
    }

    private func migratePreferredLocalRoutes(in actions: inout [SavedAction]) {
        guard let preferredLocalRoute = defaultModelRoute(for: .lmStudio) else { return }
        for index in actions.indices {
            guard actions[index].provider == .lmStudio else { continue }
            let currentRoute = actions[index].routeID.flatMap { modelRoute(for: $0) }
            if actions[index].routeID == nil || currentRoute?.provider == .lmStudio {
                actions[index].routeID = preferredLocalRoute.id
            }
        }
    }

    private func migrateUnavailableFalRoutes(in actions: inout [SavedAction]) {
        guard let fallbackRoute = defaultModelRoute(for: .fal) else { return }
        for index in actions.indices {
            guard let routeID = actions[index].routeID,
                  Self.isUnavailableFalRouteID(routeID) else { continue }
            actions[index].provider = fallbackRoute.provider
            actions[index].routeID = fallbackRoute.id
        }

        if let routeID = defaults.string(forKey: Keys.customPromptRouteID),
           Self.isUnavailableFalRouteID(routeID) {
            defaults.removeObject(forKey: Keys.customPromptRouteID)
            customPromptProvider = fallbackRoute.provider
        }
    }

    private func legacySeededDefaultActions() -> [SavedAction] {
        Self.defaultSavedActions.map { legacySeededDefaultAction(for: $0) }
    }

    private func legacySeededDefaultAction(for defaultAction: SavedAction) -> SavedAction {
        var action = defaultAction
        switch defaultAction.id {
        case "fix_grammar":
            action.prompt = fixPrompt
            action.provider = provider(for: .fixGrammar)
        case "improve_writing":
            action.prompt = improvePrompt
            action.provider = provider(for: .improveWriting)
        case "humanize":
            action.prompt = humanizePrompt
            action.provider = provider(for: .humanize)
        default:
            break
        }
        return action
    }

    var customPromptProvider: Provider {
        get {
            guard let raw = defaults.string(forKey: Keys.customPromptProvider),
                  let provider = Provider(rawValue: raw) else {
                return .fal
            }
            return provider
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.customPromptProvider) }
    }

    var customPromptRouteID: String? {
        get {
            if let routeID = defaults.string(forKey: Keys.customPromptRouteID),
               modelRoute(for: routeID) != nil {
                return routeID
            }
            return defaultModelRoute(for: customPromptProvider)?.id
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.customPromptRouteID)
                if let route = modelRoute(for: newValue) {
                    customPromptProvider = route.provider
                }
            } else {
                defaults.removeObject(forKey: Keys.customPromptRouteID)
            }
        }
    }

    var configuredModelRoutes: [ModelRoute] {
        get {
            let decoded = defaults.data(forKey: Keys.configuredModelRoutes).flatMap {
                try? JSONDecoder().decode([ModelRoute].self, from: $0)
            }
            let routes = decoded?
                .filter { $0.provider == .fal }
                .filter { !$0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .filter { !Self.isUnavailableFalModel($0.model) }
            if let routes, !routes.isEmpty {
                return normalizedModelRoutes(routes)
            }
            return defaultCloudModelRoutes
        }
        set {
            let normalized = normalizedModelRoutes(newValue)
            guard let data = try? JSONEncoder().encode(normalized) else { return }
            defaults.set(data, forKey: Keys.configuredModelRoutes)
        }
    }

    var lmStudioKnownModels: [String] {
        get {
            guard let data = defaults.data(forKey: Keys.lmStudioKnownModels),
                  let models = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return uniqueModels(models)
        }
        set {
            guard let data = try? JSONEncoder().encode(uniqueModels(newValue)) else { return }
            defaults.set(data, forKey: Keys.lmStudioKnownModels)
        }
    }

    var lmStudioVisionModels: [String] {
        get {
            guard let data = defaults.data(forKey: Keys.lmStudioVisionModels),
                  let models = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return uniqueModels(models)
        }
        set {
            guard let data = try? JSONEncoder().encode(uniqueModels(newValue)) else { return }
            defaults.set(data, forKey: Keys.lmStudioVisionModels)
        }
    }

    func localModelSupportsImages(_ model: String) -> Bool {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return false }
        if Self.isKnownLocalVisionModel(model) {
            return true
        }

        let key = normalizedModelKey(model)
        if lmStudioVisionModels.contains(where: { normalizedModelKey($0) == key }) {
            return true
        }

        let selectedKey = normalizedModelKey(lmStudioModel)
        return key == selectedKey && defaults.bool(forKey: Keys.lmStudioModelSupportsImages)
    }

    func setLocalModel(_ model: String, supportsImages: Bool) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }

        var models = lmStudioVisionModels
        let key = normalizedModelKey(model)
        models.removeAll { normalizedModelKey($0) == key }
        if supportsImages {
            models.append(model)
        }
        lmStudioVisionModels = models

        if normalizedModelKey(lmStudioModel) == key {
            defaults.set(supportsImages, forKey: Keys.lmStudioModelSupportsImages)
        }
    }

    var remoteCatalogModels: [RemoteCatalogModel] {
        get {
            guard let data = defaults.data(forKey: Keys.remoteCatalogModels),
                  let models = try? JSONDecoder().decode([RemoteCatalogModel].self, from: data) else {
                return Self.defaultRemoteCatalogModels
            }
            let availableModels = models.filter { !Self.isUnavailableFalModel($0.routeModel) }
            return availableModels.isEmpty ? Self.defaultRemoteCatalogModels : availableModels
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.remoteCatalogModels)
        }
    }

    var allModelRoutes: [ModelRoute] {
        normalizedModelRoutes(directModelRoutes + localModelRoutes + configuredModelRoutes)
    }

    var availableModelRoutes: [ModelRoute] {
        allModelRoutes.filter { route in
            hasAccess(to: route.provider)
        }
    }

    func modelRoute(for routeID: String) -> ModelRoute? {
        allModelRoutes.first { $0.id == routeID }
    }

    func availableModelRoute(for routeID: String) -> ModelRoute? {
        availableModelRoutes.first { $0.id == routeID }
    }

    func defaultModelRoute(for provider: Provider) -> ModelRoute? {
        switch provider {
        case .lmStudio, .openAI, .deepSeek:
            return allModelRoutes.first { $0.provider == provider }
        case .claude:
            if hasAccess(to: .claude),
               let claudeRoute = allModelRoutes.first(where: { $0.provider == .claude }) {
                return claudeRoute
            }
            return allModelRoutes.first { $0.provider == .fal }
        case .fal:
            return allModelRoutes.first { $0.provider == .fal }
        }
    }

    func route(for action: SavedAction) -> ModelRoute? {
        if let routeID = action.routeID,
           let route = modelRoute(for: routeID) {
            return route
        }
        return defaultModelRoute(for: action.provider)
    }

    func availableRoute(for action: SavedAction) -> ModelRoute? {
        if let routeID = action.routeID,
           let route = availableModelRoute(for: routeID) {
            return route
        }
        guard let route = route(for: action), hasAccess(to: route.provider) else {
            return nil
        }
        return route
    }

    func hasAccess(to provider: Provider) -> Bool {
        switch provider {
        case .openAI:
            return !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .claude:
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .deepSeek:
            return !deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .fal:
            return !falAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .lmStudio:
            return !localModelRoutes.isEmpty
        }
    }

    private var directModelRoutes: [ModelRoute] {
        [
            ModelRoute(
                id: ModelRoute.makeID(provider: .openAI, model: openAIModel),
                name: "OpenAI",
                provider: .openAI,
                model: openAIModel,
                supportsImages: Self.defaultSupportsImages(provider: .openAI, model: openAIModel)
            ),
            ModelRoute(
                id: ModelRoute.makeID(provider: .claude, model: claudeModel),
                name: "Claude",
                provider: .claude,
                model: claudeModel,
                supportsImages: Self.defaultSupportsImages(provider: .claude, model: claudeModel)
            ),
            ModelRoute(
                id: ModelRoute.makeID(provider: .deepSeek, model: deepSeekModel),
                name: "DeepSeek",
                provider: .deepSeek,
                model: deepSeekModel,
                supportsImages: Self.defaultSupportsImages(provider: .deepSeek, model: deepSeekModel)
            )
        ]
    }

    private var defaultCloudModelRoutes: [ModelRoute] {
        [
            ModelRoute(
                id: ModelRoute.makeID(provider: .fal, model: falModel),
                name: "Remote",
                provider: .fal,
                model: falModel,
                supportsImages: falModelSupportsImages || Self.isKnownVisionModel(falModel)
            ),
        ]
    }

    private static let defaultRemoteCatalogModels: [RemoteCatalogModel] = [
        RemoteCatalogModel(
            id: "~anthropic/claude-sonnet-latest",
            name: "Claude Sonnet Latest",
            supportsImages: true
        ),
        RemoteCatalogModel(
            id: "~anthropic/claude-haiku-latest",
            name: "Claude Haiku Latest",
            supportsImages: true
        ),
        RemoteCatalogModel(
            id: "deepseek/deepseek-chat",
            name: "DeepSeek Chat",
            supportsImages: false
        ),
        RemoteCatalogModel(
            id: "openai/gpt-5",
            name: "GPT-5",
            supportsImages: true
        ),
        RemoteCatalogModel(
            id: "google/gemini-3-pro",
            name: "Gemini 3 Pro",
            supportsImages: true
        )
    ]

    private var localModelRoutes: [ModelRoute] {
        let models = preferredLocalModels(uniqueModels(lmStudioKnownModels + [lmStudioModel]))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return models.map { model in
            ModelRoute(
                id: ModelRoute.makeID(provider: .lmStudio, model: model),
                name: "Local",
                provider: .lmStudio,
                model: model,
                supportsImages: localModelSupportsImages(model)
            )
        }
    }

    private func normalizedModelRoutes(_ routes: [ModelRoute]) -> [ModelRoute] {
        var seen: Set<String> = []
        var normalized: [ModelRoute] = []
        for route in routes {
            let model = route.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { continue }
            let id = Self.ModelRoute.makeID(provider: route.provider, model: model)
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            var copy = route
            copy.model = model
            copy = ModelRoute(
                id: id,
                name: route.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? route.provider.shortLabel
                    : route.name,
                provider: route.provider,
                model: model,
                supportsImages: route.supportsImages || Self.defaultSupportsImages(provider: route.provider, model: model)
            )
            normalized.append(copy)
        }
        return normalized
    }

    private func preferredLocalModels(_ models: [String]) -> [String] {
        models.sorted { lhs, rhs in
            let lhsPriority = localModelPriority(lhs)
            let rhsPriority = localModelPriority(rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private func localModelPriority(_ model: String) -> Int {
        let lower = model.lowercased()
        if lower.contains("gemma-4-12b") || lower.contains("gemma4-12b") {
            return 0
        }
        if lower.contains("gemma") {
            return 1
        }
        if normalizedModelKey(model) == normalizedModelKey(lmStudioModel) {
            return 2
        }
        return 3
    }

    private func uniqueModels(_ models: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for model in models {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    static func isKnownVisionModel(_ model: String) -> Bool {
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

    static func isKnownLocalVisionModel(_ model: String) -> Bool {
        let lower = model.lowercased()
        let markers = [
            "vision",
            "pixtral",
            "llava",
            "qwen-vl",
            "qwen2-vl",
            "qwen2.5-vl",
            "vlm",
            "omni",
            "moondream",
            "minicpm-v"
        ]
        return markers.contains { lower.contains($0) }
    }

    static func defaultSupportsImages(provider: Provider, model: String) -> Bool {
        switch provider {
        case .openAI:
            return isKnownVisionModel(model)
        case .lmStudio:
            return isKnownLocalVisionModel(model)
        case .claude:
            return true
        case .deepSeek:
            return false
        case .fal:
            return isKnownVisionModel(model)
        }
    }

    static func isUnavailableFalModel(_ model: String) -> Bool {
        unavailableFalModels.contains(normalizedFalModel(model))
    }

    private static func isUnavailableFalRouteID(_ routeID: String) -> Bool {
        let cleaned = routeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.hasPrefix("\(Provider.fal.rawValue):") else { return false }
        let model = cleaned.dropFirst("\(Provider.fal.rawValue):".count)
        return unavailableFalModels.contains(normalizedFalModel(String(model)))
    }

    private static func normalizedFalModel(_ model: String) -> String {
        model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "~", with: "")
    }

    private func normalizedModelKey(_ model: String) -> String {
        model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var apiKey: String {
        get { defaults.string(forKey: Keys.apiKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.apiKey) }
    }

    var openAIAPIKey: String {
        get { defaults.string(forKey: Keys.openAIAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.openAIAPIKey) }
    }

    var openAIModel: String {
        get {
            let value = defaults.string(forKey: Keys.openAIModel) ?? ""
            return value.isEmpty ? Self.defaultOpenAIModel : value
        }
        set { defaults.set(newValue, forKey: Keys.openAIModel) }
    }

    var claudeModel: String {
        get {
            let value = defaults.string(forKey: Keys.claudeModel) ?? ""
            return value.isEmpty ? Self.defaultClaudeModel : value
        }
        set { defaults.set(newValue, forKey: Keys.claudeModel) }
    }

    var deepSeekAPIKey: String {
        get { defaults.string(forKey: Keys.deepSeekAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.deepSeekAPIKey) }
    }

    var deepSeekModel: String {
        get {
            let value = defaults.string(forKey: Keys.deepSeekModel) ?? ""
            return value.isEmpty ? Self.defaultDeepSeekModel : value
        }
        set { defaults.set(newValue, forKey: Keys.deepSeekModel) }
    }

    var falAPIKey: String {
        get { defaults.string(forKey: Keys.falAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.falAPIKey) }
    }

    var falModel: String {
        get {
            let value = defaults.string(forKey: Keys.falModel) ?? ""
            return value.isEmpty ? Self.defaultFalModel : value
        }
        set { defaults.set(newValue, forKey: Keys.falModel) }
    }

    var falModelSupportsImages: Bool {
        get { defaults.bool(forKey: Keys.falModelSupportsImages) }
        set { defaults.set(newValue, forKey: Keys.falModelSupportsImages) }
    }

    var rewriteMode: RewriteMode {
        get {
            guard let raw = defaults.string(forKey: Keys.rewriteMode),
                  let mode = RewriteMode(rawValue: raw) else { return .fixGrammar }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.rewriteMode) }
    }

    // Legacy mode helpers kept for the macOS Services menu.
    var activePrompt: String {
        prompt(for: rewriteMode)
    }

    func prompt(for mode: RewriteMode) -> String {
        switch mode {
        case .fixGrammar: return fixPrompt
        case .improveWriting: return improvePrompt
        case .humanize: return humanizePrompt
        }
    }

    var fixPrompt: String {
        get { defaults.string(forKey: Keys.prompt) ?? Self.defaultFixPrompt }
        set { defaults.set(newValue, forKey: Keys.prompt) }
    }

    var improvePrompt: String {
        get { defaults.string(forKey: Keys.improvePrompt) ?? Self.defaultImprovePrompt }
        set { defaults.set(newValue, forKey: Keys.improvePrompt) }
    }

    var humanizePrompt: String {
        get { defaults.string(forKey: Keys.humanizePrompt) ?? Self.defaultHumanizePrompt }
        set { defaults.set(newValue, forKey: Keys.humanizePrompt) }
    }

    // Legacy prompt setter maps to the active mode's prompt.
    var prompt: String {
        get { activePrompt }
        set {
            switch rewriteMode {
            case .fixGrammar: fixPrompt = newValue
            case .improveWriting: improvePrompt = newValue
            case .humanize: humanizePrompt = newValue
            }
        }
    }

    // Legacy provider routing per mode.
    func provider(for mode: RewriteMode) -> Provider {
        let key: String
        switch mode {
        case .fixGrammar: key = Keys.providerFixGrammar
        case .improveWriting: key = Keys.providerImproveWriting
        case .humanize: key = Keys.providerHumanize
        }
        if let raw = defaults.string(forKey: key),
           let provider = Provider(rawValue: raw) {
            return provider
        }
        // Defaults: Fix Grammar → local, others → Claude
        switch mode {
        case .fixGrammar: return .lmStudio
        case .improveWriting, .humanize: return .fal
        }
    }

    func setProvider(_ provider: Provider, for mode: RewriteMode) {
        let key: String
        switch mode {
        case .fixGrammar: key = Keys.providerFixGrammar
        case .improveWriting: key = Keys.providerImproveWriting
        case .humanize: key = Keys.providerHumanize
        }
        defaults.set(provider.rawValue, forKey: key)
    }

    var lmStudioBaseURL: String {
        get {
            let value = defaults.string(forKey: Keys.lmStudioBaseURL) ?? ""
            return value.isEmpty ? Self.defaultLMStudioBaseURL : value
        }
        set { defaults.set(newValue, forKey: Keys.lmStudioBaseURL) }
    }

    var lmStudioModel: String {
        get { defaults.string(forKey: Keys.lmStudioModel) ?? "" }
        set { defaults.set(newValue, forKey: Keys.lmStudioModel) }
    }

    var lmStudioModelSupportsImages: Bool {
        get { localModelSupportsImages(lmStudioModel) }
        set { setLocalModel(lmStudioModel, supportsImages: newValue) }
    }

    var fallbackToClaude: Bool {
        get {
            if !defaults.bool(forKey: Keys.hasSetFallbackDefault) {
                return true
            }
            return defaults.bool(forKey: Keys.fallbackToClaude)
        }
        set {
            defaults.set(newValue, forKey: Keys.fallbackToClaude)
            defaults.set(true, forKey: Keys.hasSetFallbackDefault)
        }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Keys.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Keys.hasCompletedOnboarding) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }

    // Store custom shortcut key code (nil = use default Cmd+Shift+E)
    var shortcutKeyCode: UInt32? {
        get {
            let val = defaults.integer(forKey: Keys.shortcutKeyCode)
            return val == 0 && !defaults.bool(forKey: "hasCustomShortcut") ? nil : UInt32(val)
        }
        set {
            if let newValue {
                defaults.set(Int(newValue), forKey: Keys.shortcutKeyCode)
                defaults.set(true, forKey: "hasCustomShortcut")
            } else {
                defaults.removeObject(forKey: Keys.shortcutKeyCode)
                defaults.set(false, forKey: "hasCustomShortcut")
            }
        }
    }

    var shortcutModifiers: UInt? {
        get {
            let val = defaults.integer(forKey: Keys.shortcutModifiers)
            return val == 0 && !defaults.bool(forKey: "hasCustomShortcut") ? nil : UInt(val)
        }
        set {
            if let newValue {
                defaults.set(Int(newValue), forKey: Keys.shortcutModifiers)
            } else {
                defaults.removeObject(forKey: Keys.shortcutModifiers)
            }
        }
    }
}
